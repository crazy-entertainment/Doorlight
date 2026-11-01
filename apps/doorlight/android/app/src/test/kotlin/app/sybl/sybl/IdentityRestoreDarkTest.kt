package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityRestoreDarkTest {
    @Test fun legacyJournalCannotSilentlyRegisterAnImportedIdentity() {
        for (phase in listOf("importing", "prepared", "privacyCommitted")) {
            val old = IdentityRestoreRecord(
                "synthetic-token", "imported-account", "old-account", setOf("old-account"),
                false, mapOf("Account.enable" to "false"), "synthetic-passphrase", phase,
            )
            assertTrue(IdentityRestoreRecord.decode(old.encode()).appearOffline)
        }
    }

    private fun source(): String = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText()
        .replace("\r\n", "\n")
        .replace(Regex("""/\*[\s\S]*?\*/"""), "")
        .replace(Regex("""//[^\n]*"""), "")

    @Test fun restoreReservesItsIdAndBootDispatchesOnTheDecision() {
        val src = source()
        val restore = src.substringAfter("fun restoreAccount(").substringBefore("private fun disablePendingRestoredAccount")
        assertFalse(Regex("""addAccount\(\s*\w+\s*\)""").containsMatchIn(restore))
        assertFalse(Regex("""IdentityRestoreRecord\(\s*java\.util\.UUID\.randomUUID\(\)\.toString\(\),\s*"{2}\s*,""")
            .containsMatchIn(restore))
        assertTrue(Regex("""runReservedRestoreImport\(""").containsMatchIn(restore))
        assertTrue(Regex("""nativeImport\s*=\s*\{\s*reserved\s*->\s*JamiService\.addAccount\(details,\s*reserved\)\s*\}""")
            .containsMatchIn(restore))
        assertTrue(Regex("""buildRecord\s*=\s*\{\s*reserved,\s*previous\s*->\s*IdentityRestoreRecord\(\s*java\.util\.UUID\.randomUUID\(\)\.toString\(\),\s*reserved,""")
            .containsMatchIn(restore))
        val start = src.substringAfter("fun start()").substringBefore("internal fun <T> submit(block")
        assertTrue(start.contains("when (decideRestoreBoot(pending,"))
        assertFalse(start.contains("dispatchRestoreBoot"))
        assertTrue(start.contains("RestoreBootDecision.FINISH_ROLLBACK ->"))
        assertTrue(start.contains("check(completeArchiveRestoreRollback(pending!!))"))
    }
}
