package ai.onlo.sdk.security

import ai.onlo.sdk.protocol.IdentityClass
import ai.onlo.sdk.protocol.RetryDirective
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import android.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.json.JSONObject

/** Data that may survive process death. It never contains a chat token or user JWT. */
internal data class ProtectedSession(
    val installationId: String,
    val credential: String,
    val generation: Long,
    /** Opaque local partition key; never a contact id or a server session id. */
    val ownerScopeId: String,
    val identityClass: IdentityClass,
    val logoutPending: Boolean,
)

/**
 * Exact non-secret wire fields for a session operation that may have reached the service before
 * the process lost its response. A user JWT is deliberately absent: it must be supplied again by
 * the host when an identify operation is retried.
 */
internal sealed interface PendingSessionTransition {
    val installationId: String
    val transitionId: String
    val proposedCredential: String
    val retryDirective: RetryDirective?
    val retryEligibleAtMs: Long?
    val retryAttempt: Int

    data class Bootstrap(
        override val installationId: String,
        override val transitionId: String,
        override val proposedCredential: String,
        override val retryDirective: RetryDirective? = null,
        override val retryEligibleAtMs: Long? = null,
        override val retryAttempt: Int = 0,
    ) : PendingSessionTransition

    data class Resume(
        override val installationId: String,
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
        override val retryDirective: RetryDirective? = null,
        override val retryEligibleAtMs: Long? = null,
        override val retryAttempt: Int = 0,
    ) : PendingSessionTransition

    data class Identify(
        override val installationId: String,
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
        override val retryDirective: RetryDirective? = null,
        override val retryEligibleAtMs: Long? = null,
        override val retryAttempt: Int = 0,
    ) : PendingSessionTransition

    data class Logout(
        override val installationId: String,
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
        override val retryDirective: RetryDirective? = null,
        override val retryEligibleAtMs: Long? = null,
        override val retryAttempt: Int = 0,
    ) : PendingSessionTransition
}

/** Session state and a possibly uncertain transition are committed together. */
internal data class ProtectedSessionState(
    val session: ProtectedSession?,
    val pendingTransition: PendingSessionTransition?,
) {
    init {
        require(session != null || pendingTransition != null) { "credential_empty" }
    }
}

internal sealed interface CredentialLoad {
    data object Empty : CredentialLoad
    data class Found(val state: ProtectedSessionState) : CredentialLoad
    data object Invalidated : CredentialLoad
}

/** Protected-session boundary. Implementations must never persist plaintext credentials. */
internal interface CredentialStore {
    suspend fun load(): CredentialLoad
    suspend fun save(state: ProtectedSessionState)
    suspend fun clear()
}

/** Encrypts sensitive SQLite payload columns with a distinct non-exportable Android Keystore key. */
internal class KeystorePayloadCipher {
    private val lock = Any()

    fun encrypt(plaintext: String): String = synchronized(lock) {
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(), SecureRandom())
        val ciphertext = cipher.doFinal(plaintext.toByteArray(StandardCharsets.UTF_8))
        "${Base64.encodeToString(cipher.iv, BASE64_FLAGS)}.${Base64.encodeToString(ciphertext, BASE64_FLAGS)}"
    }

    fun decrypt(serialized: String): String = synchronized(lock) {
        val parts = serialized.split('.', limit = 2)
        require(parts.size == 2) { "payload_ciphertext" }
        val iv = Base64.decode(parts[0], BASE64_FLAGS)
        val ciphertext = Base64.decode(parts[1], BASE64_FLAGS)
        require(iv.isNotEmpty() && ciphertext.isNotEmpty()) { "payload_ciphertext" }
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), javax.crypto.spec.GCMParameterSpec(GCM_TAG_BITS, iv))
        String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "ai.onlo.sdk.v1.outbox-payload"
        const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_BITS = 128
        const val BASE64_FLAGS = Base64.NO_WRAP or Base64.URL_SAFE
    }
}

/**
 * Encrypts the complete protected-session record with a non-exportable Android Keystore AES key.
 * The app-private file contains only an IV and authenticated ciphertext; it is never a plaintext
 * credential store and is excluded from Android backup.
 */
internal class KeystoreCredentialStore(context: Context) : CredentialStore {
    private val applicationContext = context.applicationContext
    private val ciphertextFile = File(applicationContext.noBackupFilesDir, FILE_NAME)
    private val lock = Any()

    override suspend fun load(): CredentialLoad = synchronized(lock) {
        if (!ciphertextFile.exists()) return@synchronized CredentialLoad.Empty
        try {
            val plaintext = decrypt(readCiphertext())
            CredentialLoad.Found(decode(plaintext))
        } catch (_: Exception) {
            // A removed or invalidated keystore key must not leave stale local identity usable.
            deleteCiphertext()
            CredentialLoad.Invalidated
        }
    }

    override suspend fun save(state: ProtectedSessionState) {
        synchronized(lock) {
            val encrypted = encrypt(encode(state))
            writeCiphertext(encrypted)
        }
    }

    override suspend fun clear() {
        synchronized(lock) { deleteCiphertext() }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    private fun encrypt(value: ByteArray): EncryptedRecord {
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(), SecureRandom())
        return EncryptedRecord(cipher.iv, cipher.doFinal(value))
    }

    private fun decrypt(value: EncryptedRecord): ByteArray {
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), javax.crypto.spec.GCMParameterSpec(GCM_TAG_BITS, value.iv))
        return cipher.doFinal(value.ciphertext)
    }

    private fun readCiphertext(): EncryptedRecord = DataInputStream(
        BufferedInputStream(FileInputStream(ciphertextFile)),
    ).use { input ->
        require(input.readInt() == FILE_MAGIC) { "credential_magic" }
        require(input.readInt() == FILE_VERSION) { "credential_version" }
        val iv = input.readBoundedBytes(MAX_IV_BYTES)
        val ciphertext = input.readBoundedBytes(MAX_CIPHERTEXT_BYTES)
        EncryptedRecord(iv, ciphertext)
    }

    private fun writeCiphertext(value: EncryptedRecord) {
        val parent = checkNotNull(ciphertextFile.parentFile)
        if (!parent.exists() && !parent.mkdirs()) throw IllegalStateException("credential_directory")
        val temporary = File(parent, "$FILE_NAME.tmp")
        FileOutputStream(temporary).use { fileOutput ->
            val output = DataOutputStream(BufferedOutputStream(fileOutput))
            output.writeInt(FILE_MAGIC)
            output.writeInt(FILE_VERSION)
            output.writeBoundedBytes(value.iv)
            output.writeBoundedBytes(value.ciphertext)
            output.flush()
            fileOutput.fd.sync()
        }
        if (!temporary.renameTo(ciphertextFile)) {
            temporary.delete()
            throw IllegalStateException("credential_replace")
        }
    }

    private fun deleteCiphertext() {
        if (ciphertextFile.exists()) ciphertextFile.delete()
        val temporary = File(checkNotNull(ciphertextFile.parentFile), "$FILE_NAME.tmp")
        if (temporary.exists()) temporary.delete()
    }

    private fun encode(value: ProtectedSessionState): ByteArray = JSONObject().apply {
        put("session", value.session?.let(::encodeSession))
        put("pendingTransition", value.pendingTransition?.let(::encodePendingTransition))
    }.toString().toByteArray(StandardCharsets.UTF_8)

    private fun decode(value: ByteArray): ProtectedSessionState {
        val objectValue = JSONObject(String(value, StandardCharsets.UTF_8))
        return ProtectedSessionState(
            session = objectValue.optJSONObject("session")?.let(::decodeSession),
            pendingTransition = objectValue.optJSONObject("pendingTransition")?.let(::decodePendingTransition),
        ).also { require(it.session != null || it.pendingTransition != null) { "credential_empty" } }
    }

    private fun encodeSession(value: ProtectedSession): JSONObject = JSONObject().apply {
        put("installationId", value.installationId)
        put("credential", value.credential)
        put("generation", value.generation)
        put("ownerScopeId", value.ownerScopeId)
        put("identityClass", value.identityClass.wireValue)
        put("logoutPending", value.logoutPending)
    }

    private fun decodeSession(objectValue: JSONObject): ProtectedSession = ProtectedSession(
        installationId = objectValue.getString("installationId"),
        credential = objectValue.getString("credential"),
        generation = objectValue.getLong("generation"),
        ownerScopeId = objectValue.getString("ownerScopeId"),
        identityClass = when (objectValue.getString("identityClass")) {
            IdentityClass.ANONYMOUS.wireValue -> IdentityClass.ANONYMOUS
            IdentityClass.IDENTIFIED.wireValue -> IdentityClass.IDENTIFIED
            else -> throw IllegalArgumentException("credential_identity")
        },
        logoutPending = objectValue.getBoolean("logoutPending"),
    )

    private fun encodePendingTransition(value: PendingSessionTransition): JSONObject = JSONObject().apply {
        put("installationId", value.installationId)
        put("transitionId", value.transitionId)
        put("proposedCredential", value.proposedCredential)
        value.retryDirective?.let { put("retryDirective", it.wireValue) }
        value.retryEligibleAtMs?.let { put("retryEligibleAtMs", it) }
        put("retryAttempt", value.retryAttempt)
        when (value) {
            is PendingSessionTransition.Bootstrap -> put("type", "bootstrap")
            is PendingSessionTransition.Resume -> {
                put("type", "resume")
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
            }
            is PendingSessionTransition.Identify -> {
                put("type", "identify")
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
            }
            is PendingSessionTransition.Logout -> {
                put("type", "logout")
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
            }
        }
    }

    private fun decodePendingTransition(value: JSONObject): PendingSessionTransition {
        val installationId = value.getString("installationId")
        val transitionId = value.getString("transitionId")
        val proposedCredential = value.getString("proposedCredential")
        val retryDirective = if (!value.has("retryDirective") || value.isNull("retryDirective")) null else value.getString("retryDirective").let { wire ->
            RetryDirective.entries.firstOrNull { it.wireValue == wire }
                ?: throw IllegalArgumentException("pending_retry_directive")
        }
        val retryEligibleAtMs = if (value.has("retryEligibleAtMs") && !value.isNull("retryEligibleAtMs")) {
            value.getLong("retryEligibleAtMs")
        } else {
            null
        }
        val retryAttempt = value.optInt("retryAttempt", 0).also { require(it >= 0) { "pending_retry_attempt" } }
        return when (value.getString("type")) {
            "bootstrap" -> PendingSessionTransition.Bootstrap(installationId, transitionId, proposedCredential, retryDirective, retryEligibleAtMs, retryAttempt)
            "resume" -> PendingSessionTransition.Resume(
                installationId, transitionId, value.getLong("expectedGeneration"), value.getString("presentedCredential"), proposedCredential, retryDirective, retryEligibleAtMs, retryAttempt,
            )
            "identify" -> PendingSessionTransition.Identify(
                installationId, transitionId, value.getLong("expectedGeneration"), value.getString("presentedCredential"), proposedCredential, retryDirective, retryEligibleAtMs, retryAttempt,
            )
            "logout" -> PendingSessionTransition.Logout(
                installationId, transitionId, value.getLong("expectedGeneration"), value.getString("presentedCredential"), proposedCredential, retryDirective, retryEligibleAtMs, retryAttempt,
            )
            else -> throw IllegalArgumentException("pending_transition_type")
        }
    }

    private fun DataInputStream.readBoundedBytes(maximum: Int): ByteArray {
        val size = readInt()
        require(size in 1..maximum) { "credential_size" }
        return ByteArray(size).also(::readFully)
    }

    private fun DataOutputStream.writeBoundedBytes(value: ByteArray) {
        writeInt(value.size)
        write(value)
    }

    private data class EncryptedRecord(val iv: ByteArray, val ciphertext: ByteArray)

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "ai.onlo.sdk.v1.session"
        const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_BITS = 128
        const val FILE_NAME = "onlo-protected-session-v1.bin"
        const val FILE_MAGIC = 0x4F4E4C4F // ONLO
        const val FILE_VERSION = 2
        const val MAX_IV_BYTES = 32
        const val MAX_CIPHERTEXT_BYTES = 16 * 1024
    }
}
