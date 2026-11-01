package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InviteLinkPolicyTest {
    private val origin = "https://invites.example.test"
    private val id = "a".repeat(40)

    @Test fun retainsBothCustomHandlers() {
        for (scheme in listOf("sybl", "doorlight")) {
            val link = "$scheme://add/$id?name=Mara"
            assertEquals(link, InviteLinkPolicy.candidate(link, ""))
        }
    }

    @Test fun onlyConfiguredFragmentPathReachesDart() {
        val link = "$origin/invite/#v=1&id=$id"
        assertEquals(link, InviteLinkPolicy.candidate(link, origin))
        assertNull(InviteLinkPolicy.candidate(link, ""))
        for (bad in listOf(
            "$origin.evil.test/invite/#v=1&id=$id",
            "$origin/invite/?id=$id#v=1",
            "$origin/other/#v=1&id=$id",
            "http://invites.example.test/invite/#v=1&id=$id",
            "$link\n", "$link&name=" + "x".repeat(1024),
        )) assertNull(InviteLinkPolicy.candidate(bad, origin))
    }
}
