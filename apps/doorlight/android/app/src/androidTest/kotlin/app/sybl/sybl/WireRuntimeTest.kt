package app.sybl.sybl

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle

/** Runs the actual shared parsers with Android's ICU/JSON implementations.
 * Host JVM tests alone do not exercise those platform differences.
 * No account, daemon, network, Activity, or user data is used. */
class WireRuntimeTest : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            check(RichTimelineMetadata.project(mapOf("body" to "test"), false) != null)
            check(RichTimelineMetadata.stickerNotification(
                """{"v":1,"assetId":"test.asset","presentation":"inline"}""",
            ) == "Sticker")
            check(RichTimelineMetadata.stickerNotification(
                """{"v":1,"assetId":"test.asset","presentation":"hologram"}""",
            ) == null)
            check(HologramWire.decode("{}") == null)
            val now = System.currentTimeMillis()
            val body = PresenceWire.encode("ping", true, now, color = "amber")
            check(PresenceWire.decode(body, now)?.foreground == 1)
            check(PresenceWire.decode(body, now + 60_001) == null)
            result.putString("stream", "Android wire runtime: 6 assertions passed\n")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("stream", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
