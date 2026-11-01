package app.sybl.sybl

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

internal const val EXTRA_START_CALL = "startCall"

internal object CallRequestNotifications {
    private const val CHANNEL = "sybl_call_request_v1"
    private const val NOTIFICATION_BASE = 0x53430000

    fun show(
        context: Context,
        peerId: String,
        conversationId: String,
        displayName: String,
    ) {
        val scope = JamiCore.captureAccountScope() ?: return
        val openToken = JamiCore.issueMessageAction(scope, peerId, conversationId, DmTopicWire.MAIN,
            replyAllowed = false) ?: return
        val callToken = JamiCore.issueMessageAction(scope, peerId, conversationId, DmTopicWire.MAIN,
            startCall = true, replyAllowed = false) ?: return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                "Call requests",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "A friend wants you to call them"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                setSound(null, null)
                enableVibration(false)
            },
        )
        val notificationId = NOTIFICATION_BASE xor peerId.hashCode()
        val open = PendingIntent.getActivity(
            context,
            notificationId,
            launchIntent(context, peerId, conversationId, startCall = false, token = openToken),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val call = PendingIntent.getActivity(
            context,
            notificationId xor 0x10000,
            launchIntent(context, peerId, conversationId, startCall = true, token = callToken),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val label = MessageNotificationPolicy.label(displayName, "A friend")
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_doorlight_notification)
            .setContentTitle("$label wants to call")
            .setContentText("Tap to open the chat.")
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setWhen(System.currentTimeMillis())
            .addAction(android.R.drawable.ic_menu_call, "Call", call)
            .build()
        if (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED) {
            try {
                NotificationManagerCompat.from(context).notify(notificationId, notification)
            } catch (_: SecurityException) {
                // Permission or vendor policy can change after the check.
            }
        }
    }

    private fun launchIntent(
        context: Context,
        peerId: String,
        conversationId: String,
        startCall: Boolean,
        token: String,
    ) = Intent(context, MainActivity::class.java).apply {
        action = ACTION_OPEN_MESSAGE_CONVERSATION
        data = Uri.Builder().scheme("sybl").authority("call-request")
            .appendPath(if (startCall) "call" else "open")
            .appendPath(conversationId)
            .build()
        addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        putExtra(EXTRA_MESSAGE_OWNER, peerId)
        putExtra(EXTRA_MESSAGE_CONVERSATION, conversationId)
        putExtra(EXTRA_MESSAGE_TOPIC, DmTopicWire.MAIN)
        putExtra(EXTRA_START_CALL, startCall)
        putExtra(EXTRA_MESSAGE_ACTION_TOKEN, token)
    }
}
