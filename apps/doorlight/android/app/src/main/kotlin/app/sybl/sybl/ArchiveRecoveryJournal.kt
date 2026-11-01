package app.sybl.sybl

import android.content.Context
import org.json.JSONObject
import java.nio.charset.StandardCharsets

internal data class ArchiveRecoveryRecord(
    val accountId: String,
    val currentSecret: String,
    val transientPassphrase: String,
)

/**
 * OS-protected transaction record for the brief interval in which archive migration or restore normalization has
 * re-keyed the live account archive. Normal backup export writes a separate snapshot and does not use this record.
 * The journal gives the next process enough information to finish an interrupted transient -> desired-secret
 * transition.
 */
internal object ArchiveRecoveryJournal {
    private val store = KeystoreSealedStore(
        preferencesName = "archive_recovery",
        keyAlias = "sybl.archive.recovery",
    )

    fun exists(context: Context): Boolean = store.exists(context)

    fun save(context: Context, record: ArchiveRecoveryRecord): Boolean = try {
        val json = JSONObject()
            .put("accountId", record.accountId)
            .put("currentSecret", record.currentSecret)
            .put("transientPassphrase", record.transientPassphrase)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        try {
            store.save(context, json)
        } finally {
            json.fill(0)
        }
    } catch (_: Throwable) {
        false
    }

    /** Null means absent. A present-but-corrupt journal throws so callers fail closed. */
    fun load(context: Context): ArchiveRecoveryRecord? {
        val clear = store.load(context) ?: return null
        return try {
            val json = JSONObject(String(clear, StandardCharsets.UTF_8))
            ArchiveRecoveryRecord(
                json.getString("accountId"),
                json.getString("currentSecret"),
                json.getString("transientPassphrase"),
            )
        } finally {
            clear.fill(0)
        }
    }

    fun clear(context: Context): Boolean = store.clear(context)
}
