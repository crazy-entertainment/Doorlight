package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlGlobalActionTest {
    @Test
    fun `authorized Android navigation uses the native action result`() {
        val source = File(
            "src/main/kotlin/app/sybl/sybl/AndroidRemoteControlHost.kt",
        ).readText()
        val applyGlobal = source.substringAfter("private fun applyGlobal(")
            .substringBefore("private fun safeEditableNode")

        assertFalse(applyGlobal.contains("systemActions"))
        assertTrue(applyGlobal.contains("performGlobalAction(action)"))
    }
}
