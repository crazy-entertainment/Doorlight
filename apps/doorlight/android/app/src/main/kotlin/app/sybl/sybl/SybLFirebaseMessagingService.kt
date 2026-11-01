package app.sybl.sybl

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

@Suppress("OVERRIDE_DEPRECATION")
class SybLFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        JamiCore.attach(applicationContext)
        if (!JamiCore.backgroundWakeEnabled() || message.priority != RemoteMessage.PRIORITY_HIGH) return
        val kind = wire.classify(message.data)
        if (kind == PushWakeKind.IGNORE) return
        acquireWakeLock()
        JamiCore.start()
        PushForegroundService.start(applicationContext, kind)
        JamiCore.processPush(message.from.orEmpty(), message.data, kind)
    }

    override fun onNewToken(token: String) {
        JamiCore.attach(applicationContext)
        if (!JamiCore.backgroundWakeDesired()) return
        JamiCore.start()
        JamiCore.refreshBackgroundWakeToken(token)
    }

    private fun acquireWakeLock() {
        try {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:push").apply {
                setReferenceCounted(false)
                acquire(10_000L)
            }
        } catch (_: Throwable) {
            Log.w(TAG, "Push wake lock is unavailable")
        }
    }

    private companion object {
        const val TAG = "SybLPush"
        val wire = PushWakeWire()
    }
}
