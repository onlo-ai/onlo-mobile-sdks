package ai.onlo.sdk.config

import ai.onlo.sdk.security.KeystorePayloadCipher
import android.content.Context
import java.io.File
import org.json.JSONObject

/** Last-known-good configuration is encrypted at rest and is never coupled to bearer credentials. */
internal data class StoredMobileConfig(val etag: String?, val raw: String?, val retryEligibleAtMs: Long? = null, val retryAttempt: Int = 0) {
    init { require((raw == null) == (etag == null)) { "config_lkg_pair" }; require(retryAttempt >= 0) { "config_retry_attempt" } }
}

internal interface ProtectedConfigStore {
    suspend fun load(): StoredMobileConfig?
    suspend fun save(value: StoredMobileConfig)
    suspend fun clear()
}

internal class KeystoreConfigStore(context: Context) : ProtectedConfigStore {
    private val file = File(context.applicationContext.noBackupFilesDir, "onlo-mobile-config-v1.enc")
    private val cipher = KeystorePayloadCipher()
    private val lock = Any()

    override suspend fun load(): StoredMobileConfig? = synchronized(lock) {
        if (!file.exists()) return@synchronized null
        try {
            val decoded = JSONObject(cipher.decrypt(file.readText(Charsets.UTF_8)))
            StoredMobileConfig(if (decoded.isNull("etag")) null else decoded.getString("etag"), if (decoded.isNull("raw")) null else decoded.getString("raw"), if (decoded.isNull("retryEligibleAtMs")) null else decoded.getLong("retryEligibleAtMs"), decoded.optInt("retryAttempt", 0))
        } catch (_: Exception) {
            // Authentication/key failure must not expose a stale configuration as trusted.
            file.delete()
            null
        }
    }

    override suspend fun save(value: StoredMobileConfig) = synchronized(lock) {
        val parent = checkNotNull(file.parentFile)
        if (!parent.exists() && !parent.mkdirs()) throw IllegalStateException("config_directory")
        require(value.retryAttempt >= 0) { "config_retry_attempt" }
        val encrypted = cipher.encrypt(JSONObject().apply { put("etag", value.etag); put("raw", value.raw); put("retryEligibleAtMs", value.retryEligibleAtMs); put("retryAttempt", value.retryAttempt) }.toString())
        val temporary = File(parent, "${file.name}.tmp")
        java.io.FileOutputStream(temporary).use { output -> output.write(encrypted.toByteArray(Charsets.UTF_8)); output.fd.sync() }
        if (!temporary.renameTo(file)) { temporary.delete(); throw IllegalStateException("config_replace") }
    }

    override suspend fun clear() = synchronized(lock) { file.delete(); File(checkNotNull(file.parentFile), "${file.name}.tmp").delete() }
}
