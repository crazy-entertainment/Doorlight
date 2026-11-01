package app.sybl.sybl

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DevicePairingJournalTest {
    private fun reserved() = IdentityRestoreRecord(
        "synthetic-token", "reserved-account", "old-account", setOf("old-account"),
        true, mapOf("Account.enable" to "false"), "", pairingOperation = 0L,
    )

    @Test fun reservedAccountIsDurableBeforeAnOfferExistsAndCannotBeAutoAdopted() {
        val record = reserved()
        assertEquals(record, IdentityRestoreRecord.decode(record.encode()))
        assertEquals(2, JSONObject(record.encode()).getInt("version"))
        assertTrue(record.excludes("reserved-account"))
        assertFalse(record.excludes("old-account"))
        assertFalse(record.excludes("unrelated-account"))
        assertFalse(record.encode().contains("jami-auth"))
    }

    @Test fun preparedPrivacyWithoutPeerAcknowledgementIsStillAnIncompleteAdmission() {
        val record = reserved().copy(pairingOperation = 123456L,
            normalizedDocument = "locally normalized settings", settingsAlreadyNormalized = true)
        assertEquals(record, IdentityRestoreRecord.decode(record.encode()))
        assertThrows(Exception::class.java) {
            IdentityRestoreRecord.decode(record.copy(phase = "prepared").encode())
        }
        val ready = record.copy(phase = "prepared", pairingAcknowledged = true)
        assertEquals(ready, IdentityRestoreRecord.decode(ready.encode()))
        assertEquals(ready.copy(phase = "privacyCommitted"),
            IdentityRestoreRecord.decode(ready.copy(phase = "privacyCommitted").encode()))
    }

    @Test fun contradictoryOrLegacyPairingRecordsFailClosed() {
        val record = reserved().copy(pairingOperation = 123456L)
        val invalid = listOf(
            record.copy(accountId = ""), record.copy(transientPassphrase = "not-a-pairing-code"),
            record.copy(pairingOperation = 1L), record.copy(pairingOperation = 1000000L),
            record.copy(pairingAcknowledged = true), record.copy(phase = "prepared"),
            record.copy(phase = "privacyCommitted", pairingAcknowledged = true),
        )
        for (item in invalid) assertThrows(Exception::class.java) { IdentityRestoreRecord.decode(item.encode()) }
        for (document in listOf(
            JSONObject(record.encode()).put("version", 1).toString(),
            JSONObject(record.encode()).put("pairingOperation", "123456").toString(),
            JSONObject(record.encode()).put("pairingOperation", 123456.5).toString(),
            JSONObject(record.encode()).put("pairingAcknowledged", "false").toString(),
        )) assertThrows(Exception::class.java) { IdentityRestoreRecord.decode(document) }
    }
}
