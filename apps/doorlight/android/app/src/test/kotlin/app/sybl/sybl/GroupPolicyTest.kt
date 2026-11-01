package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GroupPolicyTest {
    @Test
    fun `notification room comes from canonical text rooms and preserves reply routing`() {
        val description = "sybl-group-layout:v1:" + java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString("""{"c":[],"r":[{"i":"chat","n":"Chat","k":"text"},{"i":"voice","n":"Voice","k":"voice"}]}""".toByteArray())
        assertEquals(setOf("chat"), GroupPolicy.textRooms(description))
        assertEquals("chat", GroupPolicy.messageRoom("[#chat] hello"))
        assertEquals("[#chat] reply", GroupPolicy.replyBody("chat", "reply"))
        assertNull(GroupPolicy.messageRoom("[#chat] hello", "other"))
        assertNull(GroupPolicy.replyBody("../invalid", "reply"))
        assertEquals(setOf("general", "games", "clips"), GroupPolicy.textRooms("legacy description"))
    }

    private val me = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private val alice = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private val bob = "cccccccccccccccccccccccccccccccccccccccc"

    @Test
    fun `title is trimmed bounded and rejects controls`() {
        assertEquals("The Crew", GroupPolicy.title("  The Crew  "))
        assertNull(GroupPolicy.title(""))
        assertNull(GroupPolicy.title("bad\nname"))
        assertNull(GroupPolicy.title("x".repeat(129)))
    }

    @Test
    fun `layout accepts only bounded versioned base64url`() {
        assertEquals(
            "sybl-group-layout:v1:eyJjIjpbXSwiciI6W119",
            GroupPolicy.layout("sybl-group-layout:v1:eyJjIjpbXSwiciI6W119"),
        )
        assertNull(GroupPolicy.layout("plain description"))
        assertNull(GroupPolicy.layout("sybl-group-layout:v1:bad+base64"))
        assertNull(
            GroupPolicy.layout(
                "sybl-group-layout:v1:" + "a".repeat(GroupPolicy.MAX_LAYOUT_UTF8_BYTES),
            ),
        )
    }

    @Test
    fun `members must be unique trusted remote identities`() {
        assertEquals(
            listOf(alice, bob),
            GroupPolicy.newMemberIds(listOf(bob, alice), me, setOf(alice, bob)),
        )
        assertNull(GroupPolicy.newMemberIds(listOf(alice, alice), me, setOf(alice)))
        assertNull(GroupPolicy.newMemberIds(listOf(me), me, setOf(me)))
        assertNull(GroupPolicy.newMemberIds(listOf(bob), me, setOf(alice)))
        assertNull(
            GroupPolicy.newMemberIds(
                listOf(bob),
                me,
                setOf(alice, bob),
                existingIds = setOf(bob),
            ),
        )
    }
}
