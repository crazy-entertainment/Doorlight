package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlServiceLifetimeTest {
    @Test
    fun `host retains the connected accessibility service until detach`() {
        val source = File(
            "src/main/kotlin/app/sybl/sybl/AndroidRemoteControlHost.kt",
        ).readText()

        assertFalse(source.contains("WeakReference"))
        assertTrue(
            source.contains(
                "private var service: AndroidRemoteControlAccessibilityService? = null",
            ),
        )
        assertTrue(source.contains("service = value"))
        assertTrue(source.contains("service = null"))
    }
}
