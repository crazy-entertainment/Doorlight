package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushWakeSideEffectContractTest {
    @Test
    fun `receiving a push does not open Flutter or read a conversation`() {
        val service = File(
            "src/main/kotlin/app/sybl/sybl/SybLFirebaseMessagingService.kt",
        ).readText()
        assertFalse(service.contains("MainActivity"))
        assertFalse(service.contains("loadChat"))
        assertFalse(service.contains("markRead"))
        assertFalse(service.contains("setActivityResumed"))

        val core = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText()
        val push = core.substring(
            core.indexOf("internal fun processPush"),
            core.indexOf("internal fun cancelMessageNotification"),
        )
        assertTrue(push.contains("pushNotificationReceived"))
        assertFalse(push.contains("loadChat"))
        assertFalse(push.contains("markRead"))
        assertFalse(push.contains("emit("))
    }
}
