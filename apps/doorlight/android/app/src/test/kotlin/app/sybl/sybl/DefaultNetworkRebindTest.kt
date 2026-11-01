package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class DefaultNetworkRebindTest {
    @Test
    fun `default network availability refreshes libjami on its worker`() {
        val source = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText()
        val callback = source.substring(
            source.indexOf("private val defaultNetworkCallback"),
            source.indexOf("private val diagnosticWatchdog"),
        )
        val attach = source.substring(source.indexOf("fun attach(context: Context)"), source.indexOf("internal fun setActivityResumed"))

        assertTrue(callback.contains("override fun onAvailable(network: Network)"))
        assertTrue(callback.contains("worker.execute(DaemonOperation.GENERIC)"))
        assertTrue(callback.contains("if (started) connectivitySweep()"))
        assertTrue(attach.contains("registerDefaultNetworkCallback(defaultNetworkCallback)"))
    }
}
