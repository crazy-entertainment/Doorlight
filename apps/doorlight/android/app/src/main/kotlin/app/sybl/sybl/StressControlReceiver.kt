package app.sybl.sybl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** The manifest requires platform DUMP permission (shell/privileged tools).
 * The log property is only an opt-in switch, never caller authentication. */
class StressControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "app.sybl.sybl.STRESS" ||
            !Log.isLoggable("SybLStress", Log.VERBOSE) || !JamiCore.hasEventSink()) return
        val command = intent.getStringExtra("app.sybl.sybl.STRESS_COMMAND") ?: return
        val dispatchCommand = StressCommandPolicy.dispatchCommand(
            command, intent.getStringExtra("app.sybl.sybl.STRESS_PEER")) ?: return
        Log.v("SybLStress", "dispatch command=$command")
        JamiCore.emit(mapOf("type" to "stressCommand", "command" to dispatchCommand))
    }
}
