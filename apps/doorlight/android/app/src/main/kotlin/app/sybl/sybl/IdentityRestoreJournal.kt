package app.sybl.sybl

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Separate from archive rekey recovery: a successful rekey does not commit restored privacy. */
internal data class IdentityRestoreRecord(
    val token: String,
    val accountId: String,
    val previousAccountId: String,
    val previousAccounts: Set<String>,
    val appearOffline: Boolean,
    val accountPolicy: Map<String, String>,
    val transientPassphrase: String,
    val phase: String = "importing",
    val normalizedDocument: String = "",
    val settingsAlreadyNormalized: Boolean = false,
    // Version 2 is a device-link admission, not an archive restore. Zero means
    // the exact local account is reserved but its native offer is not issued.
    val pairingOperation: Long? = null,
    val pairingAcknowledged: Boolean = false,
    // Archive restores must bind the imported master identity to an
    // independently known Friend ID before the account can be prepared.
    val expectedJamiId: String = "",
) {
    fun excludes(candidate: String): Boolean =
        if (accountId.isEmpty()) candidate !in previousAccounts else candidate == accountId

    fun encode(): String = JSONObject()
        .put("version", if (pairingOperation != null) 2 else if (expectedJamiId.isNotEmpty()) 3 else 1)
        .put("token", token).put("accountId", accountId)
        .put("previousAccountId", previousAccountId)
        .put("previousAccounts", JSONArray(previousAccounts.sorted()))
        .put("appearOffline", appearOffline).put("accountPolicy", JSONObject(accountPolicy))
        .put("transientPassphrase", transientPassphrase).put("phase", phase)
        .put("normalizedDocument", normalizedDocument)
        .put("settingsAlreadyNormalized", settingsAlreadyNormalized)
        .apply {
            if (pairingOperation != null) {
                put("pairingOperation", pairingOperation)
                put("pairingAcknowledged", pairingAcknowledged)
            } else if (expectedJamiId.isNotEmpty()) {
                put("expectedJamiId", expectedJamiId)
            }
        }.toString()

    companion object {
        fun decode(document: String): IdentityRestoreRecord {
            require(document.toByteArray(Charsets.UTF_8).size <= MAX_RESTORE_JOURNAL_BYTES)
            val value = JSONObject(document)
            val version = value.opt("version")
            require(version == 1 || version == 2 || version == 3)
            val pairingOperation = if (version == 2) {
                val raw = value.opt("pairingOperation")
                require(raw is Int || raw is Long)
                (raw as Number).toLong().also { require(it == 0L || it in 100000L..999999L) }
            } else {
                require(!value.has("pairingOperation") && !value.has("pairingAcknowledged"))
                null
            }
            val expectedJamiId = if (version == 3) {
                (value.opt("expectedJamiId") as? String)?.takeIf {
                    Regex("^[0-9a-f]{40}$").matches(it)
                } ?: error("Invalid expected restore identity")
            } else {
                require(!value.has("expectedJamiId"))
                ""
            }
            val pairingAcknowledged = if (version == 2)
                value.opt("pairingAcknowledged") as? Boolean ?: error("Invalid pairing acknowledgement")
                else false
            fun text(key: String) = value.opt(key) as? String ?: error("Invalid restore record")
            val ids = value.opt("previousAccounts") as? JSONArray ?: error("Invalid restore accounts")
            val previous = (0 until ids.length()).map {
                (ids.opt(it) as? String)?.takeIf(String::isNotEmpty) ?: error("Invalid restore account")
            }
            require(previous.size == previous.toSet().size)
            val policyValue = value.opt("accountPolicy") as? JSONObject ?: error("Invalid restore policy")
            val policy = policyValue.keys().asSequence().associateWith {
                policyValue.opt(it) as? String ?: error("Invalid restore policy value")
            }
            val record = IdentityRestoreRecord(
                text("token"), text("accountId"), text("previousAccountId"), previous.toSet(),
                value.opt("appearOffline") as? Boolean ?: error("Invalid restore offline choice"),
                policy, text("transientPassphrase"), text("phase"),
                if (value.has("normalizedDocument")) text("normalizedDocument") else "",
                if (value.has("settingsAlreadyNormalized")) value.opt("settingsAlreadyNormalized") as? Boolean
                    ?: error("Invalid restored settings state") else false,
                pairingOperation, pairingAcknowledged, expectedJamiId,
            )
            require(record.token.isNotEmpty())
            require(record.phase in setOf("importing", "prepared", "privacyCommitted", "rollingBack"))
            require(record.phase == "importing" || record.accountId.isNotEmpty())
            require(record.accountId.isEmpty() || record.accountId !in record.previousAccounts)
            require(record.normalizedDocument.toByteArray(Charsets.UTF_8).size <= MAX_SETTINGS_DOCUMENT_BYTES)
            require(!record.settingsAlreadyNormalized || record.normalizedDocument.isNotEmpty())
            if (record.pairingOperation != null) {
                require(record.phase != "rollingBack")
                require(record.accountId.isNotEmpty() && record.transientPassphrase.isEmpty())
                require(record.phase == "importing" || record.pairingAcknowledged)
                require(!record.pairingAcknowledged || (record.pairingOperation > 0L &&
                    record.phase != "importing" && record.settingsAlreadyNormalized &&
                    record.normalizedDocument.isNotEmpty()))
            }
            // Apply the conservative archive policy to older pending journals
            // as well. Device pairing still owns its explicit local choice.
            return if (record.pairingOperation == null) record.copy(appearOffline = true) else record
        }
    }
}

internal object IdentityRestoreJournal {
    private val store = KeystoreSealedStore("identity_restore", "sybl.identity.restore")

    fun load(context: Context): IdentityRestoreRecord? {
        val clear = store.load(context) ?: return null
        return try { IdentityRestoreRecord.decode(String(clear, Charsets.UTF_8)) }
        finally { clear.fill(0) }
    }

    fun save(context: Context, record: IdentityRestoreRecord): Boolean = try {
        val clear = record.encode().toByteArray(Charsets.UTF_8)
        try { clear.size <= MAX_RESTORE_JOURNAL_BYTES && store.save(context, clear) }
        finally { clear.fill(0) }
    } catch (_: Exception) { false }

    fun clear(context: Context): Boolean = store.clear(context)
}

private const val MAX_RESTORE_JOURNAL_BYTES = MAX_SETTINGS_DOCUMENT_BYTES + 16 * 1024
