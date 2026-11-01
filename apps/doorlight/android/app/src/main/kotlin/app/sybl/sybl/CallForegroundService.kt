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
import android.os.IBinder
import android.util.Log

/**
 * User-visible foreground lifetime for the serverless daemon.
 *
 * Without push, the special-use foreground state keeps libjami registered while Flutter is paused or the phone is
 * locked. With push, it covers only the short background grace. A connected call upgrades the same notification
 * to microphone or camera ownership.
 */
class CallForegroundService : Service() {
    enum class CaptureType { NONE, CAMERA, SCREEN }
    private var mode = Mode.NONE

    override fun onCreate() {
        super.onCreate()
        current = this
        // Android can stop a newly requested foreground service when the Activity resumes again. Promote before
        // that re-entry can cancel the service, or Android later kills the process for a missed FGS deadline.
        showOnline()
        // START_STICKY may recreate this service without an Activity. Reattach and boot the process singleton.
        JamiCore.attach(applicationContext)
        JamiCore.start()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val result = when (intent?.action ?: ACTION_ONLINE) {
            ACTION_CALL -> {
                val captureType = runCatching {
                    CaptureType.valueOf(intent?.getStringExtra(EXTRA_CAPTURE_TYPE) ?: "NONE")
                }.getOrDefault(CaptureType.NONE)
                val promotionEpoch = intent?.getLongExtra(EXTRA_PROMOTION_EPOCH, NO_PROMOTION_EPOCH)
                    ?: NO_PROMOTION_EPOCH
                showForeground(call = true, captureType = captureType, promotionEpoch = promotionEpoch)
                START_STICKY
            }
            else -> {
                showOnline()
                START_STICKY
            }
        }
        JamiCore.onCallForegroundServiceStarted()
        return result
    }

    private fun showOnline() {
        // Re-entering foreground state resets the API-34 service-type set after a call, so microphone and camera
        // ownership are not retained while the account is merely waiting for a peer.
        if (mode == Mode.CALL) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            mode = Mode.NONE
        }
        showForeground(call = false, captureType = CaptureType.NONE, promotionEpoch = NO_PROMOTION_EPOCH)
    }

    private fun showForeground(call: Boolean, captureType: CaptureType, promotionEpoch: Long) {
        val nm = getSystemService(NotificationManager::class.java)
        val channelId = if (call) CALL_CHANNEL else ONLINE_CHANNEL
        val channelName = if (call) "Calls" else "Online status"
        val importance = if (call) NotificationManager.IMPORTANCE_DEFAULT else NotificationManager.IMPORTANCE_LOW
        nm.createNotificationChannel(NotificationChannel(channelId, channelName, importance).apply {
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })

        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, channelId)
            .setContentTitle("Doorlight")
            .setContentText(
                when {
                    captureType == CaptureType.SCREEN -> "Screen sharing in progress"
                    captureType == CaptureType.CAMERA -> "Video call in progress"
                    call -> "Voice call in progress"
                    else -> "Online for messages and calls"
                },
            )
            .setSmallIcon(R.drawable.ic_doorlight_notification)
            .setCategory(if (call) Notification.CATEGORY_CALL else Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= 34) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                if (call) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (captureType == CaptureType.CAMERA) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                if (captureType == CaptureType.SCREEN) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                startForeground(NOTIF_ID, notification, type)
            } else {
                startForeground(NOTIF_ID, notification)
            }
            mode = if (call) Mode.CALL else Mode.ONLINE
            // Intent-first video gates Camera2 on this exact request's confirmation: the CAMERA
            // service type is provably active before any hardware opens. Ordinary notification
            // refreshes carry no promotion token and therefore cannot confirm a newer lease.
            if (call && captureType != CaptureType.NONE && promotionEpoch != NO_PROMOTION_EPOCH) {
                JamiCore.onCallForegroundPromoted(promotionEpoch)
            }
        } catch (_: Throwable) {
            // Permission/vendor failures must not crash the process or leave an unpromoted service alive.
            Log.e("SybL", "foreground service promotion failed")
            if (call && captureType != CaptureType.NONE && promotionEpoch != NO_PROMOTION_EPOCH) {
                JamiCore.onCallForegroundPromotionFailed(promotionEpoch)
            }
            if (mode == Mode.NONE) stopSelf()
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        mode = Mode.NONE
        super.onDestroy()
    }

    private fun stopNow() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** The core chooses push-backed sleep or the persistent mode's explicit-exit behavior. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!JamiCore.dismissFromRecents()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    private enum class Mode { NONE, ONLINE, CALL }

    companion object {
        @Volatile private var current: CallForegroundService? = null
        private const val ACTION_ONLINE = "app.sybl.sybl.action.ONLINE"
        private const val ACTION_CALL = "app.sybl.sybl.action.CALL"
        private const val EXTRA_CAPTURE_TYPE = "captureType"
        private const val EXTRA_PROMOTION_EPOCH = "videoPromotionEpoch"
        private const val NO_PROMOTION_EPOCH = -1L
        private const val ONLINE_CHANNEL = "sybl_online"
        private const val CALL_CHANNEL = "sybl_ongoing_call"
        private const val NOTIF_ID = 42

        fun onlineIntent(context: Context) =
            Intent(context, CallForegroundService::class.java).setAction(ACTION_ONLINE)

        fun callIntent(
            context: Context,
            captureType: CaptureType,
            promotionEpoch: Long = NO_PROMOTION_EPOCH,
        ) =
            Intent(context, CallForegroundService::class.java)
                .setAction(ACTION_CALL)
                .putExtra(EXTRA_CAPTURE_TYPE, captureType.name)
                .putExtra(EXTRA_PROMOTION_EPOCH, promotionEpoch)

        /** Update an already-running service without asking Android to start a foreground service from background. */
        fun showOnlineIfRunning(): Boolean {
            val service = current ?: return false
            service.showOnline()
            return true
        }

        fun showCallIfRunning(
            captureType: CaptureType,
            promotionEpoch: Long = NO_PROMOTION_EPOCH,
        ): Boolean {
            val service = current ?: return false
            service.showForeground(call = true, captureType = captureType, promotionEpoch = promotionEpoch)
            return true
        }

        /** Do not cancel a foreground-service request before Android delivers it to [onCreate]. */
        fun stopIfRunning() {
            current?.stopNow()
        }

    }
}
