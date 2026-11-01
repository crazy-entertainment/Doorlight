package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ArchiveProtectionTest {
    private val account = "account"
    private val secret = "a".repeat(43)

    @Test
    fun protectedArchiveAlwaysProvesTheSealedSecretWithoutRewriting() {
        val calls = mutableListOf<String>()
        val ok = reconcileArchiveProtection(
            account,
            secret,
            archiveHasPassword = true,
            saveRecovery = { calls += "save"; true },
            changePassword = { _, _ -> calls += "change"; true },
            validatePassword = {
                calls += "validate:$it"
                true
            },
            clearRecovery = { calls += "clear"; true },
            recover = { calls += "recover"; true },
        )
        assertTrue(ok)
        assertEquals(listOf("validate:$secret"), calls)
    }

    @Test
    fun wrongSealedSecretFailsOnEveryBoot() {
        repeat(2) {
            var changed = false
            assertFalse(
                reconcileArchiveProtection(
                    account,
                    secret,
                    archiveHasPassword = true,
                    saveRecovery = { true },
                    changePassword = { _, _ -> changed = true; true },
                    validatePassword = { false },
                    clearRecovery = { true },
                    recover = { true },
                ),
            )
            assertFalse(changed)
        }
    }

    @Test
    fun protectedArchiveValidationFailureDoesNotTrustRecovery() {
        assertFalse(
            reconcileArchiveProtection(
                account,
                secret,
                archiveHasPassword = true,
                saveRecovery = { true },
                changePassword = { _, _ -> false },
                validatePassword = { false },
                clearRecovery = { true },
                recover = { true },
            ),
        )
    }

    @Test
    fun plaintextMigrationJournalsBeforeChangingAndClearsAfterward() {
        val calls = mutableListOf<String>()
        assertTrue(
            reconcileArchiveProtection(
                account,
                secret,
                archiveHasPassword = false,
                saveRecovery = {
                    assertEquals(account, it.accountId)
                    assertEquals(secret, it.currentSecret)
                    assertEquals("", it.transientPassphrase)
                    calls += "save"
                    true
                },
                changePassword = { old, new ->
                    assertEquals("" to secret, old to new)
                    calls += "change"
                    true
                },
                validatePassword = {
                    assertEquals(secret, it)
                    calls += "validate"
                    true
                },
                clearRecovery = { calls += "clear"; true },
                recover = { calls += "recover"; true },
            ),
        )
        assertEquals(listOf("save", "change", "validate", "clear"), calls)
    }

    @Test
    fun uncertainChangeOrClearIsResolvedOnlyByTheJournal() {
        for ((changeResult, clearResult) in listOf(false to true, true to false)) {
            val calls = mutableListOf<String>()
            assertTrue(
                reconcileArchiveProtection(
                    account,
                    secret,
                    archiveHasPassword = false,
                    saveRecovery = { calls += "save"; true },
                    changePassword = { _, _ -> calls += "change"; changeResult },
                    validatePassword = { calls += "validate"; changeResult },
                    clearRecovery = { calls += "clear"; clearResult },
                    recover = { calls += "recover"; true },
                ),
            )
            assertEquals("save", calls.first())
            assertEquals("recover", calls.last())
        }
    }

    @Test
    fun persistenceFailureNeverTouchesTheArchive() {
        var changed = false
        assertFalse(
            reconcileArchiveProtection(
                account,
                secret,
                archiveHasPassword = false,
                saveRecovery = { false },
                changePassword = { _, _ -> changed = true; true },
                validatePassword = { true },
                clearRecovery = { true },
                recover = { true },
            ),
        )
        assertFalse(changed)
    }

    @Test
    fun snapshotExportKeepsInputAndOutputCredentialsSeparate() {
        var call: List<String>? = null
        assertTrue(
            exportArchiveSnapshot(account, "backup.gz", secret, "user passphrase") {
                    accountId,
                    destination,
                    inputScheme,
                    inputPassword,
                    outputScheme,
                    outputPassword,
                ->
                call = listOf(
                    accountId,
                    destination,
                    inputScheme,
                    inputPassword,
                    outputScheme,
                    outputPassword,
                )
                true
            },
        )
        assertEquals(
            listOf(account, "backup.gz", "password", secret, "password", "user passphrase"),
            call,
        )
    }

    @Test
    fun snapshotExportCanExplicitlyCreateAnUnprotectedDestination() {
        var call: List<String>? = null
        assertTrue(
            exportArchiveSnapshot(account, "backup.gz", secret, "") {
                    accountId,
                    destination,
                    inputScheme,
                    inputPassword,
                    outputScheme,
                    outputPassword,
                ->
                call = listOf(
                    accountId,
                    destination,
                    inputScheme,
                    inputPassword,
                    outputScheme,
                    outputPassword,
                )
                true
            },
        )
        assertEquals(
            listOf(account, "backup.gz", "password", secret, "", ""),
            call,
        )
    }

    @Test
    fun invalidSnapshotExportNeverCrossesTheDaemonBoundary() {
        var called = false
        assertFalse(
            exportArchiveSnapshot(account, "backup.gz", "wrong", "user passphrase") { _, _, _, _, _, _ ->
                called = true
                true
            },
        )
        assertFalse(called)
        assertFalse(
            exportArchiveSnapshot(account, "backup.gz", secret, "user passphrase") { _, _, _, _, _, _ ->
                false
            },
        )
    }
}
