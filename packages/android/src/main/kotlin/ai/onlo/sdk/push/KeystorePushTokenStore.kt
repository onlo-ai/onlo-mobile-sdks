package ai.onlo.sdk.push

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Keystore-encrypted, no-backup storage exclusively for the raw FCM token and owner partition. */
internal class KeystorePushTokenStore(context: Context) : PushTokenStore {
    private val file = File(context.applicationContext.noBackupFilesDir, FILE_NAME)
    private val lock = Any()

    override suspend fun load(): StoredPushToken? = synchronized(lock) {
        if (!file.exists()) return@synchronized null
        try {
            val parts = file.readText(StandardCharsets.UTF_8).split('.', limit = 2)
            require(parts.size == 2) { "push_ciphertext" }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], BASE64_FLAGS)))
            val value = JSONObject(String(cipher.doFinal(Base64.decode(parts[1], BASE64_FLAGS)), StandardCharsets.UTF_8))
            StoredPushToken(value.getString("ownerScopeId"), value.getString("token"), value.getBoolean("registered"), value.getBoolean("pendingUnregister"), value.optString("retryDirective").takeIf { it.isNotBlank() }?.let(ai.onlo.sdk.protocol.RetryDirective::fromWire), if (value.has("retryEligibleAtMs")) value.getLong("retryEligibleAtMs") else null, value.optInt("retryAttempt", 0), value.optString("notificationPreference").takeIf { it.isNotBlank() }?.let(ai.onlo.sdk.protocol.NotificationPreference::fromWire), value.optString("locale").takeIf { it.isNotBlank() }, value.optBoolean("transportPending", false))
        } catch (_: Exception) {
            file.delete()
            null
        }
    }

    override suspend fun save(value: StoredPushToken) = synchronized(lock) {
        val plaintext = JSONObject().apply {
            put("ownerScopeId", value.ownerScopeId)
            put("token", value.token)
            put("registered", value.registered)
            put("pendingUnregister", value.pendingUnregister)
            value.retryDirective?.let { put("retryDirective", it.wireValue) }
            value.retryEligibleAtMs?.let { put("retryEligibleAtMs", it) }
            put("retryAttempt", value.retryAttempt)
            value.notificationPreference?.let { put("notificationPreference", it.wireValue) }
            value.locale?.let { put("locale", it) }
            put("transportPending", value.transportPending)
        }.toString().toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key(), SecureRandom())
        val encoded = Base64.encodeToString(cipher.iv, BASE64_FLAGS) + "." + Base64.encodeToString(cipher.doFinal(plaintext), BASE64_FLAGS)
        val parent = checkNotNull(file.parentFile)
        if (!parent.exists() && !parent.mkdirs()) throw IllegalStateException("push_directory")
        val temporary = File(parent, "$FILE_NAME.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(encoded.toByteArray(StandardCharsets.UTF_8))
            output.fd.sync()
        }
        if (!temporary.renameTo(file)) { temporary.delete(); throw IllegalStateException("push_replace") }
    }

    override suspend fun clear() = synchronized(lock) { if (file.exists()) file.delete() }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    private companion object {
        const val FILE_NAME = "onlo-push-token.v1"
        const val KEY_ALIAS = "ai.onlo.sdk.v1.push-token"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val BASE64_FLAGS = Base64.NO_WRAP or Base64.URL_SAFE
    }
}
