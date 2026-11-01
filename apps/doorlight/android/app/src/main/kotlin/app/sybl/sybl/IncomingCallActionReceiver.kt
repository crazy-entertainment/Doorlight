package app.sybl.sybl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

internal enum class IncomingCallNotificationAction { accept, decline, ignore }

internal fun incomingCallNotificationAction(raw: String?): IncomingCallNotificationAction? =
    when (raw) {
        ACTION_ACCEPT_INCOMING_CALL -> IncomingCallNotificationAction.accept
        ACTION_DECLINE_INCOMING_CALL -> IncomingCallNotificationAction.decline
        ACTION_IGNORE_INCOMING_CALL -> IncomingCallNotificationAction.ignore
        else -> null
    }

class IncomingCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = incomingCallNotificationAction(intent.action) ?: return
        val callId = intent.getStringExtra(EXTRA_INCOMING_CALL_ID).orEmpty()
        if (callId.isEmpty()) return
        if (action == IncomingCallNotificationAction.ignore) {
            JamiCore.ignoreIncomingCallNotification(callId)
            return
        }
        val pending = goAsync()
        JamiCore.submit(
            callId = callId,
            block = {
                when (action) {
                    IncomingCallNotificationAction.accept -> JamiCore.answerCallFromNotification(callId)
                    IncomingCallNotificationAction.decline -> JamiCore.refuse(callId)
                    IncomingCallNotificationAction.ignore -> false
                }
            },
        ) { pending.finish() }
    }
}
