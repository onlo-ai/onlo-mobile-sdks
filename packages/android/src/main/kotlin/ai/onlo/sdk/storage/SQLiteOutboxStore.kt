package ai.onlo.sdk.storage

import ai.onlo.sdk.protocol.ChatAttachment
import ai.onlo.sdk.protocol.ProtocolJsonCodec
import ai.onlo.sdk.security.KeystorePayloadCipher
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** SQLite-backed, owner-partitioned outbox for the Android native core. */
internal class SQLiteOutboxStore(context: Context) : OwnerScopedOutboxStore {
    private val helper = Database(context.applicationContext)
    private val payloadCipher = KeystorePayloadCipher()

    override suspend fun enqueue(entry: OutboxEntry): Unit = onDatabase { database ->
        ensureUnblocked(database, entry.ownerScope)
        database.beginTransaction()
        try {
            // Allocate a monotonic per-owner sequence transactionally; wall-clock collisions
            // must never let UUID ordering reorder two host sends.
            val next = database.rawQuery("SELECT COALESCE(MAX(ordering_key), 0) + 1 FROM $OUTBOX_TABLE WHERE owner_scope = ?", arrayOf(entry.ownerScope.storageKey())).useCursor { cursor -> cursor.moveToFirst(); cursor.getLong(0) }
            val values = entry.values().apply { put("ordering_key", next) }
            val inserted = database.insertWithOnConflict(OUTBOX_TABLE, null, values, SQLiteDatabase.CONFLICT_ABORT)
            check(inserted != -1L) { "outbox_conflict" }
            database.setTransactionSuccessful()
        } finally { database.endTransaction() }
    }

    override suspend fun eligible(ownerScope: OwnerScope, nowMs: Long, limit: Int): List<OutboxEntry> = onDatabase {
        require(limit in 1..100) { "outbox_limit" }
        ensureUnblocked(it, ownerScope)
        try {
            it.query(
                OUTBOX_TABLE,
                null,
                // Return the owner-global head even when its retry is not due: callers must not
                // skip it and send a later message out of order.
                "owner_scope = ? AND state IN (?, ?)",
                arrayOf(
                    ownerScope.storageKey(),
                    OutboxState.QUEUED.name,
                    OutboxState.FAILED_RETRYABLE.name,
                ),
                null,
                null,
                "ordering_key ASC, client_message_id ASC",
                limit.toString(),
            ).useCursor { cursor -> buildList { while (cursor.moveToNext()) add(cursor.toEntry()) } }
        } catch (_: Exception) {
            // A key invalidation or malformed ciphertext means no identified payload can be
            // trusted. Remove encrypted payloads but retain blocked-owner authorization markers.
            purgeUnreadableOutbox(it)
            emptyList()
        }
    }

    override suspend fun markSending(ownerScope: OwnerScope, clientMessageId: String): Boolean = onDatabase {
        ensureUnblocked(it, ownerScope)
        // SQLiteDatabase's ContentValues does not support expressions. Keep the increment in a
        // transaction so a process restart can safely recover a row left in SENDING.
        it.beginTransaction()
        try {
            val row = it.query(
                OUTBOX_TABLE,
                arrayOf("attempt_count"),
                "owner_scope = ? AND client_message_id = ? AND state IN (?, ?)",
                arrayOf(
                    ownerScope.storageKey(),
                    clientMessageId,
                    OutboxState.QUEUED.name,
                    OutboxState.FAILED_RETRYABLE.name,
                ),
                null,
                null,
                null,
            ).useCursor { cursor -> if (cursor.moveToFirst()) cursor.getInt(0) else null }
            if (row == null) return@onDatabase false
            val updated = ContentValues().apply {
                put("state", OutboxState.SENDING.name)
                put("attempt_count", row + 1)
                putNull("next_attempt_at_ms")
                putNull("last_error_code")
            }
            val changed = it.update(
                OUTBOX_TABLE,
                updated,
                "owner_scope = ? AND client_message_id = ?",
                arrayOf(ownerScope.storageKey(), clientMessageId),
            ) == 1
            it.setTransactionSuccessful()
            changed
        } finally {
            it.endTransaction()
        }
    }

    override suspend fun markAccepted(ownerScope: OwnerScope, clientMessageId: String, serverMessageId: String, conversationId: String): Boolean = onDatabase {
        ensureUnblocked(it, ownerScope)
        it.update(
            OUTBOX_TABLE,
            ContentValues().apply {
            put("state", OutboxState.ACCEPTED.name)
            put("server_message_id_ciphertext", payloadCipher.encrypt(serverMessageId))
            put("server_conversation_id_ciphertext", payloadCipher.encrypt(conversationId))
            putNull("last_error_code")
            putNull("next_attempt_at_ms")
            },
            "owner_scope = ? AND client_message_id = ? AND state = ?",
            arrayOf(ownerScope.storageKey(), clientMessageId, OutboxState.SENDING.name),
        ) == 1
    }

    override suspend fun acceptedAwaitingReconciliation(ownerScope: OwnerScope): List<OutboxEntry> = onDatabase {
        ensureUnblocked(it, ownerScope)
        it.query(
            OUTBOX_TABLE,
            null,
            "owner_scope = ? AND state = ?",
            arrayOf(ownerScope.storageKey(), OutboxState.ACCEPTED.name),
            null,
            null,
            "ordering_key ASC, client_message_id ASC",
        ).useCursor { cursor -> buildList { while (cursor.moveToNext()) add(cursor.toEntry()) } }
    }

    override suspend fun markReconciled(ownerScope: OwnerScope, clientMessageId: String): Unit = update(
        ownerScope,
        clientMessageId,
        ContentValues().apply { put("state", OutboxState.RECONCILED.name) },
    )

    override suspend fun markRetryableFailure(
        ownerScope: OwnerScope,
        clientMessageId: String,
        errorCode: String,
        nextAttemptAtMs: Long,
    ): Unit = update(
        ownerScope = ownerScope,
        clientMessageId = clientMessageId,
        values = ContentValues().apply {
            put("state", OutboxState.FAILED_RETRYABLE.name)
            put("last_error_code", errorCode)
            put("next_attempt_at_ms", nextAttemptAtMs)
        },
    )

    override suspend fun markTerminalFailure(
        ownerScope: OwnerScope,
        clientMessageId: String,
        errorCode: String,
    ): Unit = update(
        ownerScope = ownerScope,
        clientMessageId = clientMessageId,
        values = ContentValues().apply {
            put("state", OutboxState.FAILED_TERMINAL.name)
            put("last_error_code", errorCode)
            putNull("next_attempt_at_ms")
        },
    )

    override suspend fun recoverInterruptedSends(ownerScope: OwnerScope, nowMs: Long): Unit = onDatabase {
        ensureUnblocked(it, ownerScope)
        it.update(
            OUTBOX_TABLE,
            ContentValues().apply {
                put("state", OutboxState.FAILED_RETRYABLE.name)
                put("last_error_code", "interrupted")
                put("next_attempt_at_ms", nowMs)
            },
            "owner_scope = ? AND state = ?",
            arrayOf(ownerScope.storageKey(), OutboxState.SENDING.name),
        )
    }

    override suspend fun blockOwner(ownerScope: OwnerScope): Unit = onDatabase {
        it.beginTransaction()
        try {
            it.insertWithOnConflict(
                OWNER_ACCESS_TABLE,
                null,
                ContentValues().apply {
                    put("owner_scope", ownerScope.storageKey())
                    put("blocked", 1)
                },
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            it.update(
                OUTBOX_TABLE,
                ContentValues().apply { put("state", OutboxState.CANCELLED.name) },
                "owner_scope = ? AND state IN (?, ?, ?)",
                arrayOf(
                    ownerScope.storageKey(),
                    OutboxState.QUEUED.name,
                    OutboxState.SENDING.name,
                    OutboxState.FAILED_RETRYABLE.name,
                ),
            )
            it.setTransactionSuccessful()
        } finally {
            it.endTransaction()
        }
    }

    override suspend fun blockAndPurgeOwner(ownerScope: OwnerScope): Unit = onDatabase {
        it.beginTransaction()
        try {
            it.insertWithOnConflict(
                OWNER_ACCESS_TABLE,
                null,
                ContentValues().apply {
                    put("owner_scope", ownerScope.storageKey())
                    put("blocked", 1)
                },
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            it.delete(OUTBOX_TABLE, "owner_scope = ?", arrayOf(ownerScope.storageKey()))
            it.delete(TRANSCRIPT_TABLE, "owner_scope = ?", arrayOf(ownerScope.storageKey()))
            it.setTransactionSuccessful()
        } finally {
            it.endTransaction()
        }
    }

    override suspend fun purgeOwner(ownerScope: OwnerScope): Unit = onDatabase {
        it.beginTransaction()
        try {
            it.delete(OUTBOX_TABLE, "owner_scope = ?", arrayOf(ownerScope.storageKey()))
            // Purge payloads but retain the tombstone: stale tasks must remain unauthorized.
            it.delete(TRANSCRIPT_TABLE, "owner_scope = ?", arrayOf(ownerScope.storageKey()))
            it.setTransactionSuccessful()
        } finally {
            it.endTransaction()
        }
    }

    override suspend fun clearAll(): Unit = onDatabase {
        it.beginTransaction()
        try {
            it.delete(OUTBOX_TABLE, null, null)
            it.delete(OWNER_ACCESS_TABLE, null, null)
            it.delete(TRANSCRIPT_TABLE, null, null)
            it.setTransactionSuccessful()
        } finally {
            it.endTransaction()
        }
    }

    override suspend fun replaceTranscript(ownerScope: OwnerScope, conversationId: String, payload: String): Unit = onDatabase {
        ensureUnblocked(it, ownerScope)
        var unreadable = false
        it.beginTransaction()
        try {
            val values = try { loadTranscriptMap(it, ownerScope) } catch (_: Exception) { unreadable = true; org.json.JSONObject() }.apply { put(conversationId, payload) }
            if (!unreadable) {
                it.insertWithOnConflict(TRANSCRIPT_TABLE, null, ContentValues().apply {
                    put("owner_scope", ownerScope.storageKey()); put("payload_ciphertext", payloadCipher.encrypt(values.toString()))
                }, SQLiteDatabase.CONFLICT_REPLACE)
                it.setTransactionSuccessful()
            }
        } finally { it.endTransaction() }
        if (unreadable) {
            purgeUnreadableOutbox(it)
            throw TranscriptStorageUnreadableException()
        }
    }
    override suspend fun transcript(ownerScope: OwnerScope, conversationId: String): String? = onDatabase {
        ensureUnblocked(it, ownerScope)
        try { loadTranscriptMap(it, ownerScope).optString(conversationId).takeUnless { it.isEmpty() || it == "null" } } catch (_: Exception) { purgeUnreadableOutbox(it); throw TranscriptStorageUnreadableException() }
    }

    private fun loadTranscriptMap(database: SQLiteDatabase, ownerScope: OwnerScope): org.json.JSONObject = database.query(
        TRANSCRIPT_TABLE, arrayOf("payload_ciphertext"), "owner_scope = ?", arrayOf(ownerScope.storageKey()), null, null, null,
    ).useCursor { cursor -> if (cursor.moveToFirst()) org.json.JSONObject(payloadCipher.decrypt(cursor.getString(0))) else org.json.JSONObject() }

    private suspend fun update(ownerScope: OwnerScope, clientMessageId: String, values: ContentValues) {
        onDatabase {
            ensureUnblocked(it, ownerScope)
            val changed = it.update(
                OUTBOX_TABLE,
                values,
                "owner_scope = ? AND client_message_id = ?",
                arrayOf(ownerScope.storageKey(), clientMessageId),
            )
            check(changed == 1) { "outbox_missing" }
        }
    }

    private suspend fun <T> onDatabase(block: (SQLiteDatabase) -> T): T = withContext(Dispatchers.IO) {
        block(helper.writableDatabase)
    }

    private fun ensureUnblocked(database: SQLiteDatabase, ownerScope: OwnerScope) {
        val blocked = database.query(
            OWNER_ACCESS_TABLE,
            arrayOf("blocked"),
            "owner_scope = ?",
            arrayOf(ownerScope.storageKey()),
            null,
            null,
            null,
            "1",
        ).useCursor { cursor -> cursor.moveToFirst() && cursor.getInt(0) != 0 }
        if (blocked) throw OwnerBlockedException()
    }

    private fun OutboxEntry.values(): ContentValues = ContentValues().apply {
        put("owner_scope", ownerScope.storageKey())
        put("client_message_id", clientMessageId)
        put("local_conversation_id_ciphertext", payloadCipher.encrypt(localConversationId))
        put("message_ciphertext", payloadCipher.encrypt(message))
        put("attachments_ciphertext", payloadCipher.encrypt(attachments.toJson()))
        put("created_at_ms", createdAtMs)
        put("ordering_key", orderingKey)
        put("state", state.name)
        put("attempt_count", attemptCount)
        nextAttemptAtMs?.let { put("next_attempt_at_ms", it) } ?: putNull("next_attempt_at_ms")
        lastErrorCode?.let { put("last_error_code", it) } ?: putNull("last_error_code")
        serverMessageId?.let { put("server_message_id_ciphertext", payloadCipher.encrypt(it)) }
            ?: putNull("server_message_id_ciphertext")
        serverConversationId?.let { put("server_conversation_id_ciphertext", payloadCipher.encrypt(it)) }
            ?: putNull("server_conversation_id_ciphertext")
    }

    private fun Cursor.toEntry(): OutboxEntry = OutboxEntry(
        ownerScope = ownerScopeFromKey(getString(getColumnIndexOrThrow("owner_scope"))),
        clientMessageId = getString(getColumnIndexOrThrow("client_message_id")),
        localConversationId = payloadCipher.decrypt(getString(getColumnIndexOrThrow("local_conversation_id_ciphertext"))),
        message = payloadCipher.decrypt(getString(getColumnIndexOrThrow("message_ciphertext"))),
        attachments = payloadCipher.decrypt(
            getString(getColumnIndexOrThrow("attachments_ciphertext")),
        ).attachmentsFromJson(),
        createdAtMs = getLong(getColumnIndexOrThrow("created_at_ms")),
        orderingKey = getLong(getColumnIndexOrThrow("ordering_key")),
        state = OutboxState.valueOf(getString(getColumnIndexOrThrow("state"))),
        attemptCount = getInt(getColumnIndexOrThrow("attempt_count")),
        nextAttemptAtMs = getNullableLong("next_attempt_at_ms"),
        lastErrorCode = getNullableString("last_error_code"),
        serverMessageId = getNullableString("server_message_id_ciphertext")?.let(payloadCipher::decrypt),
        serverConversationId = getNullableString("server_conversation_id_ciphertext")?.let(payloadCipher::decrypt),
    )

    private fun List<ChatAttachment>.toJson(): String = JSONArray().apply {
        forEach { put(ProtocolJsonCodec.encodeChatAttachment(it)) }
    }.toString()

    private fun String.attachmentsFromJson(): List<ChatAttachment> = JSONArray(this).let { values ->
        buildList {
            for (index in 0 until values.length()) {
                add(ProtocolJsonCodec.decodeChatAttachment(values.getJSONObject(index)))
            }
        }
    }

    private fun Cursor.getNullableString(column: String): String? = getColumnIndexOrThrow(column).let { index ->
        if (isNull(index)) null else getString(index)
    }

    private fun Cursor.getNullableLong(column: String): Long? = getColumnIndexOrThrow(column).let { index ->
        if (isNull(index)) null else getLong(index)
    }

    private fun ownerScopeFromKey(value: String): OwnerScope {
        val anonymous = value.split(":", limit = 2)
        return when {
            anonymous.size == 2 && anonymous[0] == "anonymous" -> OwnerScope.Anonymous(anonymous[1])
            anonymous.size == 2 && anonymous[0] == "identified" -> OwnerScope.Identified(anonymous[1])
            else -> throw IllegalStateException("owner_scope")
        }
    }

    private fun purgeUnreadableOutbox(database: SQLiteDatabase) {
        if (database.inTransaction()) {
            database.delete(OUTBOX_TABLE, null, null)
            // Blocked-owner markers are authorization boundaries, not encrypted payloads.
            database.delete(TRANSCRIPT_TABLE, null, null)
            return
        }
        database.beginTransaction()
        try {
            database.delete(OUTBOX_TABLE, null, null)
            // Preserve durable blocked-owner markers across ciphertext corruption cleanup.
            database.delete(TRANSCRIPT_TABLE, null, null)
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    /** The database is SDK-owned and deliberately resides outside Android's backup set. */
    private class Database(context: Context) : SQLiteOpenHelper(
        context,
        java.io.File(context.noBackupFilesDir, DATABASE_NAME).absolutePath,
        null,
        DATABASE_VERSION,
    ) {
        override fun onCreate(database: SQLiteDatabase) {
            database.execSQL(
                """
                CREATE TABLE $OUTBOX_TABLE (
                  owner_scope TEXT NOT NULL,
                  client_message_id TEXT NOT NULL,
                  local_conversation_id_ciphertext TEXT NOT NULL,
                  message_ciphertext TEXT NOT NULL,
                  attachments_ciphertext TEXT NOT NULL,
                  created_at_ms INTEGER NOT NULL,
                  ordering_key INTEGER NOT NULL,
                  state TEXT NOT NULL,
                  attempt_count INTEGER NOT NULL,
                  next_attempt_at_ms INTEGER,
                  last_error_code TEXT,
                  server_message_id_ciphertext TEXT,
                  server_conversation_id_ciphertext TEXT,
                  PRIMARY KEY(owner_scope, client_message_id)
                )
                """.trimIndent(),
            )
            database.execSQL(
                "CREATE INDEX outbox_eligible ON $OUTBOX_TABLE(owner_scope, state, next_attempt_at_ms, ordering_key)",
            )
            database.execSQL(
                "CREATE TABLE $OWNER_ACCESS_TABLE (owner_scope TEXT PRIMARY KEY, blocked INTEGER NOT NULL)",
            )
            database.execSQL("CREATE TABLE $TRANSCRIPT_TABLE (owner_scope TEXT PRIMARY KEY, payload_ciphertext TEXT NOT NULL)")
        }

        override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                database.execSQL("ALTER TABLE $OUTBOX_TABLE ADD COLUMN server_conversation_id_ciphertext TEXT")
            }
        }
    }

    private companion object {
        const val DATABASE_NAME = "onlo-sdk-v1.db"
        const val DATABASE_VERSION = 2
        const val OUTBOX_TABLE = "outbox"
        const val OWNER_ACCESS_TABLE = "owner_access"
        const val TRANSCRIPT_TABLE = "transcript"
    }
}

private inline fun <T> Cursor.useCursor(block: (Cursor) -> T): T = try {
    block(this)
} finally {
    close()
}
