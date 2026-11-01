package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageNotificationPolicyTest {
    @Test
    fun `reply rejects blank and malformed text`() {
        assertNull(MessageNotificationPolicy.replyText("   "))
        assertNull(MessageNotificationPolicy.replyText("\uD800"))
        assertEquals("hello", MessageNotificationPolicy.replyText("  hello  "))
    }

    @Test
    fun `preview is single line bounded and surrogate safe`() {
        assertEquals("hello there", MessageNotificationPolicy.preview("hello\nthere"))
        val preview = MessageNotificationPolicy.preview("😀".repeat(300))
        assertTrue(preview.endsWith("…"))
        assertEquals(240, preview.codePointCount(0, preview.length))
        assertFalse(preview.last().isHighSurrogate())
    }

    @Test
    fun `app lock overrides previews and inline replies`() {
        assertFalse(MessageNotificationPolicy.showDetails(true, appLockEnabled = true))
        assertFalse(MessageNotificationPolicy.showDetails(false, appLockEnabled = true))
        assertFalse(MessageNotificationPolicy.allowReply(appLockEnabled = true))
        assertTrue(MessageNotificationPolicy.showDetails(true, appLockEnabled = false))
        assertTrue(MessageNotificationPolicy.allowReply(appLockEnabled = false))
    }

    @Test
    fun `conversation notification identity is stable and scoped`() {
        assertEquals(
            MessageNotificationPolicy.notificationId("one"),
            MessageNotificationPolicy.notificationId("one"),
        )
        assertNotEquals(
            MessageNotificationPolicy.notificationId("one"),
            MessageNotificationPolicy.notificationId("two"),
        )
        assertEquals("conversation:one", MessageNotificationPolicy.shortcutId("one"))
        assertEquals(
            listOf("conversation:one", "conversation:two"),
            MessageNotificationPolicy.conversationShortcutIds(
                listOf("other", "conversation:one", "conversation:one", "conversation:two"),
            ),
        )
    }

}
