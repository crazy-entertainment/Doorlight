package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityRestoreReservedIdTest {
    private fun record(
        account: String, phase: String = "importing", pairing: Long? = null,
        previous: Set<String> = setOf("old-account"),
    ) = IdentityRestoreRecord(
        "synthetic-token", account, "old-account", previous, true,
        mapOf("Account.enable" to "false"), if (pairing == null) "synthetic-passphrase" else "",
        phase, pairingOperation = pairing,
    )

    // Characterisation of the boot behaviour that predates the pure decision.
    @Test fun noJournalDecidesNothing() {
        assertEquals(RestoreBootDecision.NONE, decideRestoreBoot(null, listOf("a", "b")))
    }

    @Test fun historicalUnboundJournalStaysBlockedWhateverTheListHolds() {
        for (list in listOf(emptyList(), listOf("old-account"), listOf("old-account", "new-one"))) {
            assertEquals(RestoreBootDecision.BLOCKED_UNBOUND, decideRestoreBoot(record(""), list))
        }
    }

    @Test fun boundPresentImportingResumesAndOtherPhasesOnlyDisable() {
        assertEquals(RestoreBootDecision.RESUME_BOUND_IMPORT,
            decideRestoreBoot(record("mine"), listOf("old-account", "mine")))
        for (phase in listOf("prepared", "privacyCommitted")) {
            assertEquals(RestoreBootDecision.DISABLE_BOUND,
                decideRestoreBoot(record("mine", phase), listOf("mine")))
        }
    }

    @Test fun boundAbsentClearsOnlyForArchiveRestore() {
        assertEquals(RestoreBootDecision.CLEAR_NOTHING_CREATED,
            decideRestoreBoot(record("mine"), listOf("old-account")))
        for (phase in listOf("importing", "prepared")) {
            assertEquals(RestoreBootDecision.PAIRING_ABSENT,
                decideRestoreBoot(record("mine", phase, pairing = 0L), listOf("old-account")))
        }
    }

    @Test fun boundAbsentClearsOnlyWhenEveryAccountIsExplainedByPreviousAccounts() {
        val previous = setOf("a", "b")
        assertEquals(RestoreBootDecision.CLEAR_NOTHING_CREATED,
            decideRestoreBoot(record("mine", previous = previous), listOf("a", "b")))
        assertEquals(RestoreBootDecision.CLEAR_NOTHING_CREATED,
            decideRestoreBoot(record("mine", previous = previous), listOf("b")))
        assertEquals(RestoreBootDecision.CLEAR_NOTHING_CREATED,
            decideRestoreBoot(record("mine", previous = previous), emptyList()))
        assertEquals(RestoreBootDecision.BLOCKED_UNEXPLAINED_ACCOUNT,
            decideRestoreBoot(record("mine", previous = previous), listOf("a", "b", "unknown")))
        assertEquals(RestoreBootDecision.BLOCKED_UNEXPLAINED_ACCOUNT,
            decideRestoreBoot(record("mine", previous = previous), listOf("unknown")))
    }

    @Test fun unexplainedAccountNeverChangesPresentOrPairingRows() {
        val previous = setOf("a")
        assertEquals(RestoreBootDecision.RESUME_BOUND_IMPORT,
            decideRestoreBoot(record("mine", previous = previous), listOf("a", "mine", "unknown")))
        assertEquals(RestoreBootDecision.DISABLE_BOUND,
            decideRestoreBoot(record("mine", "prepared", previous = previous), listOf("mine", "unknown")))
        assertEquals(RestoreBootDecision.DISABLE_BOUND,
            decideRestoreBoot(record("mine", pairing = 7L, previous = previous), listOf("mine", "unknown")))
        assertEquals(RestoreBootDecision.PAIRING_ABSENT,
            decideRestoreBoot(record("mine", pairing = 7L, previous = previous), listOf("a", "unknown")))
        assertEquals(RestoreBootDecision.BLOCKED_UNBOUND,
            decideRestoreBoot(record("", previous = previous), listOf("a", "unknown")))
    }

    @Test fun pairingPresentIsOnlyDisabledNeverAwaitedAsAnImport() {
        for (op in listOf(0L, 123456L)) {
            assertEquals(RestoreBootDecision.DISABLE_BOUND,
                decideRestoreBoot(record("mine", pairing = op), listOf("mine")))
        }
    }

    @Test fun rollbackNeverResumesImportEvenWhenCandidateIsPresent() {
        for (accounts in listOf(emptyList(), listOf("mine"), listOf("mine", "unknown"))) {
            assertEquals(RestoreBootDecision.FINISH_ROLLBACK,
                decideRestoreBoot(record("mine", "rollingBack"), accounts))
        }
    }

    // Simulated durable world: only the journal and the daemon account list survive a crash.
    private class World(val existing: MutableList<String> = mutableListOf("old-account")) {
        var journal: IdentityRestoreRecord? = null
        val ops = mutableListOf<String>()
        var saveOk = true
        var listThrows = false
        var idsToOffer = mutableListOf("reserved-1")
        var importBehaviour: (String) -> String = { id -> existing += id; id }
        var admitOk = true

        fun run() = runReservedRestoreImport(
            listAccounts = { ops += "list"; if (listThrows) error("list") else existing.toSet() },
            newId = { ops += "newId"; idsToOffer.removeAt(0) },
            buildRecord = { id, previous ->
                IdentityRestoreRecord("t", id, "old-account", previous, true,
                    mapOf("Account.enable" to "false"), "pass")
            },
            admit = { ops += "admit"; admitOk },
            saveJournal = { ops += "save"; if (saveOk) { journal = it; true } else false },
            nativeImport = { ops += "import:$it"; importBehaviour(it) },
        )

        fun boot() = decideRestoreBoot(journal, existing)
    }

    @Test fun failureBeforeJournalSaveLeavesNothing() {
        val listFail = World().apply { listThrows = true }
        assertTrue(listFail.run() is RestoreImportOutcome.NothingCreated)
        val notAdmitted = World().apply { admitOk = false }
        assertTrue(notAdmitted.run() is RestoreImportOutcome.NothingCreated)
        for (w in listOf(listFail, notAdmitted)) {
            assertNull(w.journal)
            assertEquals(listOf("old-account"), w.existing)
            assertTrue(w.ops.none { it.startsWith("import") || it == "save" })
        }
        val saveFail = World().apply { saveOk = false }
        assertTrue(saveFail.run() is RestoreImportOutcome.JournalNotSaved)
        assertTrue(saveFail.ops.none { it.startsWith("import") })
        assertEquals(listOf("old-account"), saveFail.existing)
    }

    @Test fun deathAfterJournalBeforeImportClearsAndAdoptsNothingElse() {
        val w = World().apply { importBehaviour = { throw IllegalStateException("process died") } }
        assertTrue(w.run() is RestoreImportOutcome.ImportRejected)
        assertEquals("reserved-1", w.journal?.accountId)
        // An unrelated account appears; it must not be adopted in place of the reserved one, and boot
        // must not clear the journal that would otherwise let pickAccount adopt it.
        assertEquals(RestoreBootDecision.CLEAR_NOTHING_CREATED, w.boot())
        w.existing += "unrelated-new"
        assertEquals(RestoreBootDecision.BLOCKED_UNEXPLAINED_ACCOUNT, w.boot())
        assertFalse(w.journal!!.excludes("unrelated-new"))
        assertTrue(w.journal!!.excludes("reserved-1"))
    }

    @Test fun deathAfterNativeCreateResumesExactlyTheReservedId() {
        val w = World().apply { importBehaviour = { id -> existing += id; throw IllegalStateException("died") } }
        w.existing += "unrelated-new"
        w.run()
        assertEquals(RestoreBootDecision.RESUME_BOUND_IMPORT, w.boot())
        assertEquals("reserved-1", w.journal?.accountId)
    }

    @Test fun differentOrEmptyReturnedIdIsNotAdopted() {
        for (returned in listOf("", "other-id")) {
            val w = World().apply { importBehaviour = { returned } }
            assertTrue(w.run() is RestoreImportOutcome.ImportRejected)
            assertEquals("reserved-1", w.journal?.accountId)
            assertEquals(1, w.ops.count { it.startsWith("import") })
        }
    }

    @Test fun collidingReservedIdIsNeverReused() {
        val retry = World(mutableListOf("old-account", "taken")).apply { idsToOffer = mutableListOf("taken", "fresh") }
        val outcome = retry.run() as RestoreImportOutcome.Imported
        assertEquals("fresh", outcome.record.accountId)
        assertTrue(retry.ops.contains("import:fresh") && !retry.ops.contains("import:taken"))
        val exhausted = World(mutableListOf("taken")).apply { idsToOffer = mutableListOf("taken", "taken", "taken", "taken") }
        assertTrue(exhausted.run() is RestoreImportOutcome.NothingCreated)
        assertNull(exhausted.journal)
        assertTrue(exhausted.ops.none { it.startsWith("import") || it == "save" })
    }

    @Test fun collisionRetryIsBoundedAtFourGeneratorCalls() {
        val w = World(mutableListOf("taken")).apply { idsToOffer = MutableList(10) { "taken" } }
        assertTrue(w.run() is RestoreImportOutcome.NothingCreated)
        assertEquals(4, w.ops.count { it == "newId" })
        assertEquals(6, w.idsToOffer.size)
        assertNull(w.journal)
        assertTrue(w.ops.none { it == "save" || it == "admit" || it.startsWith("import") })
    }

    @Test fun interruptedBeforeAcknowledgementOrActivationStillNamesTheDisabledReservedAccount() {
        val w = World()
        val outcome = w.run() as RestoreImportOutcome.Imported
        // Nothing after the import ran: no enable, no activation, no second journal write.
        assertEquals(listOf("list", "newId", "admit", "save", "import:reserved-1"), w.ops)
        assertEquals(outcome.record, w.journal)
        assertEquals("reserved-1", w.journal!!.accountId)
        assertEquals("importing", w.journal!!.phase)
        assertEquals("false", w.journal!!.accountPolicy["Account.enable"])
        assertTrue(w.journal!!.appearOffline)
        assertEquals(RestoreBootDecision.RESUME_BOUND_IMPORT, w.boot())
        assertEquals(w.journal, IdentityRestoreRecord.decode(w.journal!!.encode()))
    }
}
