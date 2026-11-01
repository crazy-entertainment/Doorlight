package app.sybl.sybl

import java.io.File

/**
 * Reconciles libjami's archive password with the OS-sealed device secret.
 *
 * The recovery record is written before every live-archive migration or
 * restore normalization. Its `currentSecret`
 * is the desired durable state and `transientPassphrase` is the state from
 * which recovery should continue. Normal backup export never re-keys the live
 * archive and therefore does not create this journal.
 */
internal fun reconcileArchiveProtection(
    accountId: String,
    deviceSecret: String,
    archiveHasPassword: Boolean,
    saveRecovery: (ArchiveRecoveryRecord) -> Boolean,
    changePassword: (oldPassword: String, newPassword: String) -> Boolean,
    validatePassword: (password: String) -> Boolean,
    clearRecovery: () -> Boolean,
    recover: () -> Boolean,
): Boolean {
    if (accountId.isEmpty() || !ArchiveSecretFormat.isValid(deviceSecret)) return false

    if (archiveHasPassword) {
        // Never infer authority from the sealed-store lifecycle. A validly
        // formatted but wrong secret can survive every later boot, so prove it
        // against libjami every time without rewriting the archive.
        return validatePassword(deviceSecret)
    }

    if (!saveRecovery(ArchiveRecoveryRecord(accountId, deviceSecret, ""))) {
        return false
    }
    changePassword("", deviceSecret)
    if (validatePassword(deviceSecret) && clearRecovery()) return true

    // The change can report false after committing, and a failed verification
    // or journal clear leaves state uncertain. Only the durable journal may
    // decide whether migration still needs doing or already committed.
    return recover()
}

/**
 * Exports one immutable archive snapshot without changing the live archive's
 * password. The credential roles remain explicit all the way to libjami.
 */
internal fun exportArchiveSnapshot(
    accountId: String,
    destinationPath: String,
    deviceSecret: String,
    backupPassphrase: String,
    export: (
        accountId: String,
        destinationPath: String,
        inputScheme: String,
        inputPassword: String,
        outputScheme: String,
        outputPassword: String,
    ) -> Boolean,
): Boolean {
    if (accountId.isEmpty() ||
        destinationPath.isEmpty() ||
        !ArchiveSecretFormat.isValid(deviceSecret)
    ) {
        return false
    }
    return export(
        accountId,
        destinationPath,
        "password",
        deviceSecret,
        if (backupPassphrase.isEmpty()) "" else "password",
        backupPassphrase,
    )
}

/** The pending platform document callback owns this snapshot until its exact cleanup. */
internal fun exportTemporaryArchiveSnapshot(directory: File, export: (File) -> Boolean): File? {
    if (!directory.isDirectory && !directory.mkdirs()) return null
    val destination = File.createTempFile("sybl-identity-", ".gz", directory)
    var retained = false
    return try {
        if (export(destination) && destination.isFile) {
            retained = true
            destination
        } else null
    } finally {
        if (!retained) destination.delete()
    }
}

/** Both rejected export and failed restoration are failures, never a completed backup. */
internal fun exportWithRestoredAccountDetails(
    previous: Map<String, String>,
    temporary: Map<String, String>,
    setDetails: (Map<String, String>) -> Unit,
    export: () -> Boolean,
): Boolean {
    var exported = false
    try {
        setDetails(temporary)
        exported = export()
    } catch (_: Exception) {
        exported = false
    } finally {
        try { setDetails(previous) } catch (_: Exception) { exported = false }
    }
    return exported
}
