package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CapturePreferencePolicyTest {
    @Test fun `only an explicit Boolean opt out removes protection`() {
        assertFalse(captureProtectionPreference { false })
        for (value in listOf(null, true, "false", 0, 0L, 0.0f, emptySet<String>())) {
            assertTrue(captureProtectionPreference { value })
        }
    }

    @Test fun `unreadable preferences keep startup protected`() {
        assertTrue(captureProtectionPreference { throw ClassCastException() })
        assertTrue(captureProtectionPreference { throw IllegalStateException() })
    }
}
