package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class ResetDoorlightTest {
    @Test fun `only exact persisted owner reaches acknowledged retirement removal and verification`() {
        var sequence = ""
        var retirement = true
        var confirmed = true
        fun reset(expected: String, marker: String?, selected: String?, accounts: List<String>) =
            resetLocalAccount(expected, marker, selected, accounts,
                retire = { sequence += "R"; retirement },
                remove = { assertEquals("account", it); sequence += "D" },
                removed = { assertEquals("account", it); sequence += "V"; confirmed })
        assertFalse(reset("account", "other", "account", listOf("account")))
        assertFalse(reset("account", "account", "other", listOf("account")))
        assertFalse(reset("account", "account", "account", listOf("account", "other")))
        assertFalse(reset("../account", "../account", null, emptyList()))
        assertEquals("", sequence)
        retirement = false
        assertFalse(reset("account", "account", "account", listOf("account")))
        assertEquals("R", sequence)
        retirement = true; confirmed = false; sequence = ""
        assertFalse(reset("account", "account", "account", listOf("account")))
        assertEquals("RDV", sequence)
        confirmed = true; sequence = ""
        assertTrue(reset("account", "account", null, emptyList()))
        assertEquals("RV", sequence)
        sequence = ""
        assertTrue(reset("account", "account", "account", listOf("account")))
        assertEquals("RDV", sequence)
    }
}
