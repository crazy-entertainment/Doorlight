package app.sybl.sybl

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

class PushForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val stop = Runnable { stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        runningOrStarting = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        showForeground()
        val kind = runCatching {
            PushWakeKind.valueOf(intent?.getStringExtra(EXTRA_KIND).orEmpty())
        }.getOrDefault(PushWakeKind.MESSAGE)
        handler.removeCallbacks(stop)
        handler.postDelayed(stop, if (kind == PushWakeKind.CALL) 60_000L else 30_000L)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(stop)
        runningOrStarting = false
        super.onDestroy()
    }

    private fun showForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Background delivery", NotificationManager.IMPORTANCE_LOW).apply {
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            },
        )
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("Doorlight")
            .setContentText("Checking for new activity")
            .setSmallIcon(R.drawable.ic_doorlight_notification)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setContentIntent(openApp)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Throwable) {
            Log.e(TAG, "Push foreground service failed")
            stopSelf()
        }
    }

    companion object {
        private const val TAG = "SybLPush"
        private const val ACTION = "app.sybl.sybl.action.PUSH_WAKE"
        private const val EXTRA_KIND = "kind"
        private const val CHANNEL = "sybl_background_delivery"
        private const val NOTIFICATION_ID = 43

        internal fun start(context: Context, kind: PushWakeKind) {
            try {
                runningOrStarting = true
                context.startForegroundService(
                    Intent(context, PushForegroundService::class.java)
                        .setAction(ACTION)
                        .putExtra(EXTRA_KIND, kind.name),
                )
            } catch (_: Throwable) {
                runningOrStarting = false
                Log.e(TAG, "Push foreground service could not start")
            }
        }

        internal fun isRunningOrStarting(): Boolean = runningOrStarting

        internal fun stop(context: Context) {
            runningOrStarting = false
            context.stopService(Intent(context, PushForegroundService::class.java))
        }

        @Volatile private var runningOrStarting = false
    }
}
