package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWindowHandleTest {
    @Test
    fun `null JNI pointer is rejected`() {
        assertFalse(hasNativeWindow(0L))
    }

    @Test
    fun `signed arm64 pointer is accepted`() {
        // ANativeWindow addresses observed on arm64 commonly start with 0xb4, which is negative as a signed jlong.
        assertTrue(hasNativeWindow(Long.MIN_VALUE))
        assertTrue(hasNativeWindow(-1L))
    }
}
