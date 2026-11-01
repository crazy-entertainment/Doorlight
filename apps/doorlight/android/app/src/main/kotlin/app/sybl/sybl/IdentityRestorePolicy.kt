package app.sybl.sybl

import org.json.JSONObject

/** Notification ingress can precede daemon startup; absence must come from a successful sealed read. */
internal class RestoreNotificationAdmission {
    private var pending: Boolean? = null
    fun update(value: Boolean): Boolean {
        val retired = pending == true && !value
        pending = value
        return retired
    }
    fun allows(readPending: () -> Boolean): Boolean {
        val blocked = pending ?: try { readPending() } catch (_: Exception) { true }
        pending = blocked
        return !blocked
    }
}

internal object BackupSettingsOwner {
    fun stamp(document: String, accountId: String): String {
        require(accountId.isNotEmpty())
        val value = settingsJsonObject(document)
        value.put("syblBackup", JSONObject().put("version", 1).put("sourceAccountId", accountId))
        return value.toString().also {
            require(it.toByteArray(Charsets.UTF_8).size <= MAX_SETTINGS_DOCUMENT_BYTES)
        }
    }

    fun read(document: String): String = try {
        val metadata = settingsJsonObject(document).opt("syblBackup") as? JSONObject
        if (metadata?.opt("version") != 1) ""
        else (metadata.opt("sourceAccountId") as? String).orEmpty()
            .takeIf { it.isNotEmpty() && it.length <= 128 }.orEmpty()
    } catch (_: Exception) { "" }
}

/** A persisted disable does not revoke volatile activity after a partial activation. */
internal fun preparedIdentityClosed(enabled: String?, active: String?): Boolean =
    enabled == "false" && active == "false"

/** Dart owns full settings migration. Native checks only the normalized privacy fields that gate activation. */
internal fun commitRestoredPrivacy(
    document: String,
    localAppLock: Boolean?,
    saveDocument: () -> Boolean,
    saveNotificationPolicy: (showMessage: Boolean, appLockEnabled: Boolean) -> Boolean,
    activateWithCurrentDocument: () -> Boolean,
): Boolean = try {
    val value = settingsJsonObject(document)
    require(value.opt("schemaVersion") == 16 || value.opt("schemaVersion") == 17 || value.opt("schemaVersion") == 18 || value.opt("schemaVersion") == 19 || value.opt("schemaVersion") == 20 || value.opt("schemaVersion") == 21 || value.opt("schemaVersion") == 22)
    require(IncomingCallMicrophonePolicy.decode(document) != null)
    val lock = (value.opt("appLock") as? JSONObject)?.opt("enabled") as? Boolean
        ?: error("Missing restored app-lock policy")
    require(localAppLock != null && lock == localAppLock)
    val preview = (value.opt("notifications") as? JSONObject)?.opt("showMessage") as? Boolean
        ?: error("Missing restored notification policy")
    require((value.opt("notifications") as? JSONObject)?.opt("hologramPresentationEnabled") is Boolean)
    saveDocument() && saveNotificationPolicy(preview, lock) && activateWithCurrentDocument()
} catch (_: Exception) { false }
