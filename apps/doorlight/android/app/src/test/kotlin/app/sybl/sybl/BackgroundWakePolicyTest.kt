package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundWakePolicyTest {
    @Test
    fun `wake is active only for an opted in Jami profile with Firebase`() {
        assertTrue(BackgroundWakePolicy.effective(true, "jami", true))
        assertFalse(BackgroundWakePolicy.effective(false, "jami", true))
        assertFalse(BackgroundWakePolicy.effective(true, "lan", true))
        assertFalse(BackgroundWakePolicy.effective(true, "strict", true))
        assertFalse(BackgroundWakePolicy.effective(true, "jami", false))
    }
}
