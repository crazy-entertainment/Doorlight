package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundWakeLifetimeTest {
    private fun decide(
        now: Long = 100_000L,
        enabled: Boolean = true,
        visible: Boolean = false,
        accountEnabled: Boolean = true,
        callActive: Boolean = false,
        taskRemoved: Boolean = false,
        backgroundAt: Long? = null,
        messageAt: Long? = null,
        callAt: Long? = null,
    ) = BackgroundWakeLifetime.decide(
        nowMs = now,
        pushEnabled = enabled,
        appVisible = visible,
        accountEnabled = accountEnabled,
        callActive = callActive,
        taskRemoved = taskRemoved,
        backgroundAtMs = backgroundAt,
        messagePushAtMs = messageAt,
        callPushAtMs = callAt,
    )

    @Test
    fun `persistent mode keeps an enabled account and online service active`() {
        val result = decide(enabled = false)
        assertTrue(result.keepAccountActive)
        assertTrue(result.keepOnlineForegroundService)
        assertNull(result.nextCheckMs)
    }

    @Test
    fun `visible app stays active without the online foreground service`() {
        val result = decide(visible = true)
        assertTrue(result.keepAccountActive)
        assertFalse(result.keepOnlineForegroundService)
    }

    @Test
    fun `background grace lasts five seconds`() {
        val result = decide(backgroundAt = 98_000L)
        assertTrue(result.keepAccountActive)
        assertEquals(3_000L, result.nextCheckMs)
        assertFalse(decide(backgroundAt = 94_999L).keepAccountActive)
    }

    @Test
    fun `message and call pushes use separate grace windows`() {
        assertEquals(20_000L, decide(messageAt = 90_000L).nextCheckMs)
        assertEquals(50_000L, decide(callAt = 90_000L).nextCheckMs)
        assertFalse(decide(messageAt = 69_999L).keepAccountActive)
        assertFalse(decide(callAt = 39_999L).keepAccountActive)
    }

    @Test
    fun `active calls override sleep and disabled accounts stay off`() {
        val call = decide(callActive = true, taskRemoved = true)
        assertTrue(call.keepAccountActive)
        assertTrue(call.keepOnlineForegroundService)
        assertFalse(decide(accountEnabled = false, callActive = false).keepAccountActive)
    }

    @Test
    fun `recents dismissal sleeps an idle push backed account immediately`() {
        val result = decide(taskRemoved = true, backgroundAt = 99_999L)
        assertFalse(result.keepAccountActive)
        assertFalse(result.keepOnlineForegroundService)
        assertNull(result.nextCheckMs)
    }
}
