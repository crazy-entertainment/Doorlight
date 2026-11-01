package app.sybl.sybl

/** What boot must do with the sealed restore journal, given the daemon's account list. */
internal enum class RestoreBootDecision {
    NONE,
    // Historical record with no account ID: ownership is never inferred.
    BLOCKED_UNBOUND,
    // Bound archive import, account absent, but the list holds an account the journal does not explain.
    BLOCKED_UNEXPLAINED_ACCOUNT,
    // Bound archive import, account exists, authentication not yet confirmed.
    RESUME_BOUND_IMPORT,
    // Bound account exists and only needs to be closed (prepared/committed archive or pairing).
    DISABLE_BOUND,
    // Bound archive import whose native account was never created.
    CLEAR_NOTHING_CREATED,
    // Bound device-link admission with no native account yet; its own recovery owns it.
    PAIRING_ABSENT,
    FINISH_ROLLBACK,
}

internal fun decideRestoreBoot(record: IdentityRestoreRecord?, accounts: Collection<String>): RestoreBootDecision =
    when {
        record == null -> RestoreBootDecision.NONE
        record.accountId.isEmpty() -> RestoreBootDecision.BLOCKED_UNBOUND
        record.phase == "rollingBack" -> RestoreBootDecision.FINISH_ROLLBACK
        record.accountId in accounts ->
            if (record.phase == "importing" && record.pairingOperation == null)
                RestoreBootDecision.RESUME_BOUND_IMPORT
            else RestoreBootDecision.DISABLE_BOUND
        record.pairingOperation == null ->
            if (accounts.all { it in record.previousAccounts }) RestoreBootDecision.CLEAR_NOTHING_CREATED
            else RestoreBootDecision.BLOCKED_UNEXPLAINED_ACCOUNT
        else -> RestoreBootDecision.PAIRING_ABSENT
    }

internal fun canDiscardArchiveRestore(record: IdentityRestoreRecord, selectedAccount: String?): Boolean =
    record.pairingOperation == null && Regex("(?:[0-9a-f]{16}|[0-9a-f]{32})").matches(record.accountId) &&
        record.accountId !in record.previousAccounts && record.accountId != record.previousAccountId &&
        record.accountId != selectedAccount &&
        (selectedAccount.isNullOrEmpty() || selectedAccount == record.previousAccountId)

/** Persist deletion intent before touching native state; retirement follows exact data absence. */
internal fun rollbackArchiveRestore(
    record: IdentityRestoreRecord,
    selectedAccount: String?,
    saveRollback: (IdentityRestoreRecord) -> Boolean,
    removeCandidate: () -> Boolean,
    clearJournals: () -> Boolean,
): Boolean = canDiscardArchiveRestore(record, selectedAccount) &&
    saveRollback(record.copy(phase = "rollingBack")) && removeCandidate() && clearJournals()

internal sealed class RestoreImportOutcome {
    /** Nothing was journaled or created. */
    object NothingCreated : RestoreImportOutcome()
    /** The journal write reported failure; the native import was not attempted. */
    object JournalNotSaved : RestoreImportOutcome()
    /** The journal names the reserved ID, but the import threw or returned another ID. */
    object ImportRejected : RestoreImportOutcome()
    class Imported(val record: IdentityRestoreRecord) : RestoreImportOutcome()
}

/** Reserve, journal, import under the reserved ID, and require the same ID back. */
internal fun runReservedRestoreImport(
    listAccounts: () -> Set<String>,
    newId: () -> String,
    buildRecord: (id: String, previous: Set<String>) -> IdentityRestoreRecord,
    admit: (IdentityRestoreRecord) -> Boolean,
    saveJournal: (IdentityRestoreRecord) -> Boolean,
    nativeImport: (id: String) -> String,
    attempts: Int = 4,
): RestoreImportOutcome {
    val previous = try { listAccounts() } catch (_: Throwable) { return RestoreImportOutcome.NothingCreated }
    val reserved = (0 until attempts).asSequence()
        .map { try { newId() } catch (_: Throwable) { "" } }
        .firstOrNull { it.isNotEmpty() && it !in previous }
        ?: return RestoreImportOutcome.NothingCreated
    val record = try { buildRecord(reserved, previous) } catch (_: Throwable) {
        return RestoreImportOutcome.NothingCreated
    }
    if (!admit(record)) return RestoreImportOutcome.NothingCreated
    if (!saveJournal(record)) return RestoreImportOutcome.JournalNotSaved
    val returned = try { nativeImport(reserved) } catch (_: Throwable) {
        return RestoreImportOutcome.ImportRejected
    }
    return if (returned == reserved) RestoreImportOutcome.Imported(record) else RestoreImportOutcome.ImportRejected
}
