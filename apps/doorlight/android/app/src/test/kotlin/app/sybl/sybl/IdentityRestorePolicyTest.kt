package app.sybl.sybl

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityRestorePolicyTest {
    @Test fun profileColorSchemaKeepsRestoreDurabilityAndRejectsFutureSchemas() {
        for (version in listOf(16, 17, 18, 19, 20, 21, 22, 23)) {
            val value = JSONObject().put("schemaVersion", version)
                .put("microphone", JSONObject().put("globalDefault", "pushToTalk")
                    .put("reviewRequired", false).put("conversationOverrides", org.json.JSONArray()))
                .put("appLock", JSONObject().put("enabled", true))
                .put("notifications", JSONObject().put("showMessage", false)
                    .put("hologramPresentationEnabled", true).put("messageAlertsEnabled", true))
                .put("friendPreferences", JSONObject().put("reviewRequired", false)
                    .put("overrides", org.json.JSONArray()))
            val calls = mutableListOf<String>()
            val accepted = commitRestoredPrivacy(value.toString(), true,
                saveDocument = { calls += "save"; true },
                saveNotificationPolicy = { preview, locked ->
                    assertFalse(preview)
                    assertTrue(locked)
                    calls += "privacy"
                    true
                },
                activateWithCurrentDocument = { calls += "activate"; true })
            assertEquals(version <= 22, accepted)
            assertEquals(if (version <= 22) listOf("save", "privacy", "activate") else emptyList<String>(), calls)
        }
    }

    @Test fun preparedIdentityRequiresBothPersistedDisableAndVolatileInactivity() {
        for (enabled in listOf(null, "", "true", "false", "FALSE")) {
            for (active in listOf(null, "", "true", "false", "FALSE")) {
                assertEquals(enabled == "false" && active == "false",
                    preparedIdentityClosed(enabled, active))
            }
        }
    }

    @Test
    fun coldNotificationPublicationAndRepliesRequireProvedNoPendingRestore() {
        val fresh = RestoreNotificationAdmission()
        assertTrue(fresh.allows { false })
        val cold = RestoreNotificationAdmission()
        assertFalse(cold.allows { true })
        assertFalse(cold.allows { error("Cached pending state must not fall back to absence") })
        cold.update(false)
        assertTrue(cold.allows { error("Confirmed retirement is authoritative") })
    }

    @Test
    fun failedSealedReadAndPartialPrivacyCommitKeepPublicationBlockedUntilTransactionRetires() {
        val gate = RestoreNotificationAdmission()
        assertFalse(gate.allows { throw IllegalStateException("Synthetic sealed read failure") })
        assertFalse(gate.allows { false })
        gate.update(true)
        // A permissive mirror write is not retirement of the transaction that owns this gate.
        assertFalse(gate.allows { false })
        gate.update(false)
        assertTrue(gate.allows { true })
    }

    private fun record(account: String = "") = IdentityRestoreRecord(
        "synthetic-token", account, "old-account", setOf("old-account", "other-account"),
        true, mapOf("Account.enable" to "false", "DHT.PublicInCalls" to "false"), "synthetic-passphrase",
    )

    @Test
    fun archiveRestoreJournalBindsExpectedFriendIdAcrossRestart() {
        val expectedId = "a".repeat(40)
        val bound = record("imported-account").copy(expectedJamiId = expectedId)
        val document = bound.encode()
        assertEquals(3, JSONObject(document).getInt("version"))
        assertEquals(bound, IdentityRestoreRecord.decode(document))
        assertEquals("", IdentityRestoreRecord.decode(record("imported-account").encode()).expectedJamiId)
        for (invalid in listOf("", "A".repeat(40), "z".repeat(40), "a".repeat(39))) {
            val malformed = JSONObject(document).put("expectedJamiId", invalid).toString()
            assertThrows(Exception::class.java) { IdentityRestoreRecord.decode(malformed) }
        }
        assertThrows(Exception::class.java) {
            IdentityRestoreRecord.decode(JSONObject(document).put("version", 1).toString())
        }
    }

    @Test
    fun durablePreImportRecordExcludesEveryUnboundCandidateWithoutGuessingItsOwner() {
        val restored = IdentityRestoreRecord.decode(record().encode())
        assertEquals(record(), restored)
        assertFalse(restored.excludes("old-account"))
        assertFalse(restored.excludes("other-account"))
        assertTrue(restored.excludes("one-new-account"))
        assertTrue(restored.excludes("another-new-account"))
    }

    @Test
    fun legacyRestoreDefaultCannotSilentlyRegisterTheImportedIdentity() {
        for (phase in listOf("importing", "prepared", "privacyCommitted")) {
            val old = record("imported-account").copy(appearOffline = false, phase = phase)
            assertTrue(IdentityRestoreRecord.decode(old.encode()).appearOffline)
        }
    }

    @Test
    fun boundPreparedAndCommittedRecordsKeepTheExactAccountBarrier() {
        for (phase in listOf("importing", "prepared", "privacyCommitted")) {
            val original = record("imported-account").copy(phase = phase)
            val restored = IdentityRestoreRecord.decode(original.encode())
            assertEquals(original, restored)
            assertTrue(restored.excludes("imported-account"))
            assertFalse(restored.excludes("old-account"))
            assertFalse(restored.excludes("unrelated-account"))
        }
        val committed = record("imported-account").copy(
            phase = "privacyCommitted", normalizedDocument = "synthetic normalized document",
        )
        assertEquals(committed, IdentityRestoreRecord.decode(committed.encode()))
        val retry = committed.copy(phase = "prepared", settingsAlreadyNormalized = true)
        assertEquals(retry, IdentityRestoreRecord.decode(retry.encode()))
    }

    @Test
    fun corruptOrContradictoryRecordCannotFabricateNoPendingRestore() {
        for (document in listOf(
            "{}", "null", "{", record().copy(phase = "prepared").encode(),
            record("old-account").encode(), record("imported-account").copy(phase = "future").encode(),
            JSONObject(record().encode()).put("appearOffline", "false").toString(),
        )) assertThrows(document, Exception::class.java) { IdentityRestoreRecord.decode(document) }
    }

    @Test
    fun exportStampsActualNativeOwnerAndRestoresOnlyExplicitMetadata() {
        val source = """{"schemaVersion":15,"syblBackup":{"version":1,"sourceAccountId":"forged"}}"""
        val exported = BackupSettingsOwner.stamp(source, "actual-native-owner")
        assertEquals("actual-native-owner", BackupSettingsOwner.read(exported))
        assertEquals("", BackupSettingsOwner.read("""{"schemaVersion":14}"""))
        assertEquals("", BackupSettingsOwner.read("""{"syblBackup":{"version":2,"sourceAccountId":"old"}}"""))
        assertEquals("", BackupSettingsOwner.read("invalid"))
        assertThrows(Exception::class.java) {
            BackupSettingsOwner.stamp("""{"data":"${"a".repeat(MAX_SETTINGS_DOCUMENT_BYTES - 12)}"}""", "account")
        }
    }
    @Test fun rollbackIsDurableBeforeRemovalAndRetiresOnlyAfterConfirmedCleanup() {
        val candidate = record("0123456789abcdef0123456789abcdef")
        for (failure in listOf("save", "remove", "clear", "none")) {
            val calls = mutableListOf<String>()
            var durable = candidate
            val result = rollbackArchiveRestore(candidate, "old-account",
                saveRollback = { calls += "save"; if (failure == "save") false else { durable = it; true } },
                removeCandidate = {
                    calls += "remove"
                    assertEquals("rollingBack", IdentityRestoreRecord.decode(durable.encode()).phase)
                    failure != "remove"
                },
                clearJournals = { calls += "clear"; failure != "clear" })
            assertEquals(failure == "none", result)
            assertEquals(when (failure) {
                "save" -> listOf("save")
                "remove" -> listOf("save", "remove")
                else -> listOf("save", "remove", "clear")
            }, calls)
        }
    }

    @Test fun rollbackCannotDeleteSelectedPreviousUnboundOrPairingIdentity() {
        for (candidate in listOf(record(), record("old-account"), record("../escape"), record("unexpected"),
            record("0123456789abcdef0123456789abcdef").copy(previousAccounts = setOf("0123456789abcdef0123456789abcdef")),
            record("0123456789abcdef0123456789abcdef").copy(previousAccountId = "0123456789abcdef0123456789abcdef"),
            record("0123456789abcdef0123456789abcdef").copy(pairingOperation = 123456L))) {
            assertFalse(rollbackArchiveRestore(candidate, null,
                { error("must not write") }, { error("must not delete") }, { error("must not clear") }))
        }
        assertFalse(canDiscardArchiveRestore(record("0123456789abcdef0123456789abcdef"), "0123456789abcdef0123456789abcdef"))
        assertFalse(canDiscardArchiveRestore(record("0123456789abcdef0123456789abcdef"), "unrelated-selected-owner"))
        assertThrows(Exception::class.java) {
            IdentityRestoreRecord.decode(record("0123456789abcdef0123456789abcdef").copy(
                pairingOperation = 123456L, transientPassphrase = "", phase = "rollingBack").encode())
        }
    }

}
