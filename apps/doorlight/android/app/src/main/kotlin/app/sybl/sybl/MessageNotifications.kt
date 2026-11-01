package app.sybl.sybl

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.LocusIdCompat
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat

internal const val ACTION_OPEN_MESSAGE_CONVERSATION =
    "app.sybl.sybl.OPEN_MESSAGE_CONVERSATION"
internal const val ACTION_REPLY_TO_MESSAGE = "app.sybl.sybl.REPLY_TO_MESSAGE"
internal const val EXTRA_MESSAGE_OWNER = "messageOwner"
internal const val EXTRA_MESSAGE_CONVERSATION = "messageConversation"
internal const val EXTRA_MESSAGE_TOPIC = "messageTopic"
internal const val EXTRA_MESSAGE_ACTION_TOKEN = "messageActionToken"
internal const val KEY_TEXT_REPLY = "messageReply"

internal data class MessageNotificationInput(
    val accountScope: NativeAccountScope,
    val ownerKey: String,
    val conversationId: String,
    val conversationTitle: String,
    val group: Boolean,
    val senderId: String,
    val senderName: String,
    val body: String,
    val timestampMs: Long,
    val topicId: String,
)

internal object MessageNotificationPolicy {
    private const val NOTIFICATION_BASE = 0x534D0000
    private const val MAX_PREVIEW_CODE_POINTS = 240
    private const val MAX_LABEL_CODE_POINTS = 40

    fun notificationId(conversationId: String): Int =
        NOTIFICATION_BASE xor conversationId.hashCode()

    fun shortcutId(conversationId: String): String = "conversation:$conversationId"

    fun conversationShortcutIds(values: Iterable<String>): List<String> =
        values.filter { it.startsWith("conversation:") }.distinct()

    fun replyText(value: CharSequence?): String? {
        val text = value?.toString()?.trim().orEmpty()
        return text.takeIf {
            TimelineWireBounds.required(it, TimelineWireBounds.MAX_TEXT_CODE_UNITS)
        }
    }

    fun showDetails(preferred: Boolean, appLockEnabled: Boolean): Boolean =
        preferred && !appLockEnabled

    fun allowReply(appLockEnabled: Boolean): Boolean = !appLockEnabled

    fun preview(value: String): String {
        val oneLine = value.replace(Regex("\\s+"), " ").trim()
        if (oneLine.isEmpty()) return "New message"
        return abbreviate(oneLine, MAX_PREVIEW_CODE_POINTS)
    }

    fun label(value: String, fallback: String): String {
        val clean = value.replace(Regex("\\s+"), " ").trim().ifEmpty { fallback }
        return abbreviate(clean, MAX_LABEL_CODE_POINTS)
    }

    private fun abbreviate(value: String, maxCodePoints: Int): String {
        val count = value.codePointCount(0, value.length)
        if (count <= maxCodePoints) return value
        val end = value.offsetByCodePoints(0, maxCodePoints - 1)
        return value.substring(0, end) + "…"
    }
}

/** Android's native conversation template, shared by live messages and inline-reply completion. */
internal object MessageNotifications {
    private const val CHANNEL = "sybl_messages_v1"
    private const val PREFS = "sybl_notifications"
    private const val SHOW_MESSAGE = "show_message"
    private const val APP_LOCK_ENABLED = "app_lock_enabled"
    private const val MAX_LINES = 8

    private data class Line(
        val text: String,
        val timestampMs: Long,
        val sender: Person?,
        val topicId: String,
    )

    private data class Conversation(
        val accountScope: NativeAccountScope,
        val ownerKey: String,
        val id: String,
        var title: String,
        var group: Boolean,
        var lastSender: String,
        var topicId: String,
        var replyFailed: Boolean = false,
        val lines: ArrayDeque<Line> = ArrayDeque(),
    )

    private val conversations = linkedMapOf<String, Conversation>()
    private val restoreAdmission = RestoreNotificationAdmission()

    @Synchronized
    internal fun setIdentityRestorePending(pending: Boolean) {
        if (restoreAdmission.update(pending)) conversations.clear()
    }

    /** Cached Java objects are not OS notifications. Retire the former owner's published surfaces before release. */
    @Synchronized
    internal fun retireRestoredAccountNotifications(context: Context): Boolean = try {
        val cancelled = cancelActiveNotifications(context)
        val sanitized = sanitizeConversationShortcuts(context)
        val absent = context.getSystemService(NotificationManager::class.java).activeNotifications
            .none { it.notification.channelId == CHANNEL }
        (cancelled && sanitized && absent).also { if (it) conversations.clear() }
    } catch (_: RuntimeException) { false }

    /** A cold notification receiver can run before JamiCore starts. Unknown sealed state blocks publication. */
    private fun restorePending(context: Context): Boolean = !restoreAdmission.allows {
        IdentityRestoreJournal.load(context) != null
    }

    @Synchronized
    fun setPolicy(context: Context, showMessage: Boolean, appLockEnabled: Boolean): Boolean {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(SHOW_MESSAGE, showMessage)
            .putBoolean(APP_LOCK_ENABLED, appLockEnabled)
            .commit()
        val notificationsSanitized = !appLockEnabled || cancelActiveNotifications(context)
        val shortcutsSanitized = !appLockEnabled || sanitizeConversationShortcuts(context)
        conversations.values.toList().forEach { post(context, it, alert = false) }
        return saved && notificationsSanitized && shortcutsSanitized
    }

    @Synchronized
    internal fun applyFriendPolicy(context: Context) {
        conversations.values.toList().forEach {
            if (!JamiCore.messageAlertsAllowed(it.accountScope, it.ownerKey, it.group)) cancel(context, it.id)
        }
    }

    fun showMessage(context: Context, input: MessageNotificationInput) {
        synchronized(this) {
            if (restorePending(context)) return
            if (!JamiCore.messageAlertsAllowed(input.accountScope, input.ownerKey, input.group)) {
                cancel(context, input.conversationId)
                return
            }
            val sender = Person.Builder()
                .setName(MessageNotificationPolicy.label(input.senderName, "Someone"))
                .setKey(input.senderId)
                .build()
            if (conversations[input.conversationId]?.accountScope != input.accountScope) {
                conversations.remove(input.conversationId)
                JamiCore.retireMessageActions(input.conversationId)
            }
            if (!conversations.containsKey(input.conversationId) && conversations.size >= 128) return
            val conversation = conversations.getOrPut(input.conversationId) {
                Conversation(
                    accountScope = input.accountScope,
                    ownerKey = input.ownerKey,
                    id = input.conversationId,
                    title = input.conversationTitle,
                    group = input.group,
                    lastSender = sender.name.toString(),
                    topicId = input.topicId,
                )
            }
            conversation.title = input.conversationTitle
            conversation.group = input.group
            conversation.lastSender = sender.name.toString()
            conversation.topicId = input.topicId
            conversation.replyFailed = false
            conversation.lines.addLast(
                Line(
                    MessageNotificationPolicy.preview(input.body),
                    input.timestampMs,
                    sender,
                    input.topicId,
                ),
            )
            while (conversation.lines.size > MAX_LINES) conversation.lines.removeFirst()
            post(context, conversation, alert = true)
        }
    }

    @Synchronized
    fun finishReply(
        context: Context,
        action: MessageActionOwner,
        text: String,
        sent: Boolean,
    ) {
        if (!JamiCore.messageActionCurrent(action)) return
        val conversation = conversations[action.conversationId] ?: return
        if (conversation.accountScope != action.account || conversation.ownerKey != action.ownerKey ||
            conversation.topicId != action.topicId) return
        conversation.replyFailed = !sent
        if (sent) {
            conversation.lastSender = "You"
            conversation.lines.addLast(
                Line(
                    MessageNotificationPolicy.preview(text),
                    System.currentTimeMillis(),
                    null,
                    conversation.topicId,
                ),
            )
            while (conversation.lines.size > MAX_LINES) conversation.lines.removeFirst()
        }
        // Reposting the same ID is the platform contract that closes RemoteInput's spinner.
        post(context, conversation, alert = false)
    }

    @Synchronized
    fun cancel(context: Context, conversationId: String) {
        JamiCore.retireMessageActions(conversationId)
        conversations.remove(conversationId)
        NotificationManagerCompat.from(context).cancel(
            MessageNotificationPolicy.notificationId(conversationId),
        )
    }

    @Synchronized
    fun cancelTopic(context: Context, conversationId: String, topicId: String) {
        JamiCore.retireMessageActions(conversationId)
        val conversation = conversations[conversationId] ?: return
        conversation.lines.removeAll { it.topicId == topicId }
        val latest = conversation.lines.lastOrNull()
        if (latest == null) {
            cancel(context, conversationId)
            return
        }
        conversation.topicId = latest.topicId
        conversation.lastSender = latest.sender?.name?.toString() ?: "You"
        post(context, conversation, alert = false)
    }

    private fun showMessage(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(SHOW_MESSAGE, true)

    private fun appLockEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(APP_LOCK_ENABLED, true)

    @Synchronized
    internal fun repliesAllowed(context: Context): Boolean =
        try { !restorePending(context) && MessageNotificationPolicy.allowReply(appLockEnabled(context)) }
        catch (_: RuntimeException) { false }

    private fun cancelActiveNotifications(context: Context): Boolean = try {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications
            .filter { it.notification.channelId == CHANNEL }
            .forEach { manager.cancel(it.id) }
        true
    } catch (_: RuntimeException) {
        false
    }

    private fun sanitizeConversationShortcuts(context: Context): Boolean = try {
        val flags = ShortcutManagerCompat.FLAG_MATCH_DYNAMIC or
            ShortcutManagerCompat.FLAG_MATCH_PINNED or
            ShortcutManagerCompat.FLAG_MATCH_CACHED
        val ids = MessageNotificationPolicy.conversationShortcutIds(
            ShortcutManagerCompat.getShortcuts(context, flags).map { it.id } +
                conversations.keys.map(MessageNotificationPolicy::shortcutId),
        )
        if (ids.isEmpty()) {
            true
        } else {
            val openApp = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val genericPerson = Person.Builder().setName("Doorlight").setKey("locked").build()
            val updated = ShortcutManagerCompat.updateShortcuts(
                context,
                ids.map { shortcutId ->
                    ShortcutInfoCompat.Builder(context, shortcutId)
                        .setShortLabel("Doorlight")
                        .setLongLabel("Unlock Doorlight")
                        .setPerson(genericPerson)
                        .setLongLived(false)
                        .setIntent(openApp)
                        .build()
                },
            )
            ShortcutManagerCompat.removeLongLivedShortcuts(context, ids)
            ShortcutManagerCompat.removeDynamicShortcuts(context, ids)
            updated
        }
    } catch (_: RuntimeException) {
        false
    }

    private fun post(context: Context, conversation: Conversation, alert: Boolean) {
        if (!JamiCore.messageAlertsAllowed(conversation.accountScope, conversation.ownerKey, conversation.group)) {
            cancel(context, conversation.id)
            return
        }
        // Includes setPolicy/finishReply reposts, so a partially committed restore cannot expose old previews.
        if (restorePending(context)) return
        val actionToken = JamiCore.issueMessageAction(conversation.accountScope, conversation.ownerKey,
            conversation.id, conversation.topicId) ?: return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { lockscreenVisibility = Notification.VISIBILITY_PRIVATE },
        )
        val id = MessageNotificationPolicy.notificationId(conversation.id)
        val shortcutId = MessageNotificationPolicy.shortcutId(conversation.id)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN_MESSAGE_CONVERSATION
            data = Uri.Builder().scheme("sybl").authority("conversation")
                .appendPath(conversation.id).build()
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_MESSAGE_OWNER, conversation.ownerKey)
            putExtra(EXTRA_MESSAGE_CONVERSATION, conversation.id)
            putExtra(EXTRA_MESSAGE_TOPIC, conversation.topicId)
            putExtra(EXTRA_MESSAGE_ACTION_TOKEN, actionToken)
        }
        val open = PendingIntent.getActivity(
            context,
            id,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val appLockEnabled = appLockEnabled(context)
        val preview = MessageNotificationPolicy.showDetails(
            showMessage(context),
            appLockEnabled,
        )
        val sender = conversation.lines.lastOrNull { it.sender != null }?.sender
        val user = Person.Builder().setName("You").setKey("self").build()
        val style = NotificationCompat.MessagingStyle(user)
            .setGroupConversation(conversation.group)
        if (conversation.group) style.conversationTitle = conversation.title
        conversation.lines.forEach { line ->
            style.addMessage(
                if (preview) line.text else "New message",
                line.timestampMs,
                line.sender,
            )
        }
        val latest = conversation.lines.lastOrNull()
        val collapsed = when {
            appLockEnabled -> "New message"
            conversation.replyFailed -> "Reply could not be sent"
            latest == null -> "New message"
            latest.sender == null -> if (preview) "You: ${latest.text}" else "You replied"
            preview -> "${conversation.lastSender} wrote to you: \"${latest.text}\""
            else -> "${conversation.lastSender} wrote to you"
        }
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_doorlight_notification)
            .setContentTitle(if (appLockEnabled) "Doorlight" else conversation.title)
            .setContentText(collapsed)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setOnlyAlertOnce(!alert)
            .setWhen(latest?.timestampMs ?: System.currentTimeMillis())
        if (!appLockEnabled) {
            runCatching {
                val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                    .setShortLabel(
                        MessageNotificationPolicy.label(conversation.title, "Conversation"),
                    )
                    .setLongLived(true)
                    .setIntent(openIntent)
                    .apply { if (sender != null) setPerson(sender) }
                    .build()
                ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
            }
            val replyIntent = Intent(context, MessageNotificationActionReceiver::class.java).apply {
                action = ACTION_REPLY_TO_MESSAGE
                data = Uri.Builder().scheme("sybl").authority("reply")
                    .appendPath(conversation.id).build()
                putExtra(EXTRA_MESSAGE_OWNER, conversation.ownerKey)
                putExtra(EXTRA_MESSAGE_CONVERSATION, conversation.id)
                putExtra(EXTRA_MESSAGE_TOPIC, conversation.topicId)
                putExtra(EXTRA_MESSAGE_ACTION_TOKEN, actionToken)
            }
            val reply = PendingIntent.getBroadcast(
                context,
                id,
                replyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            val remoteInput = RemoteInput.Builder(KEY_TEXT_REPLY)
                .setLabel("Reply")
                .build()
            builder
                .setStyle(style)
                .setShortcutId(shortcutId)
                .setLocusId(LocusIdCompat(shortcutId))
                .addAction(
                    NotificationCompat.Action.Builder(
                        android.R.drawable.ic_menu_send,
                        "Reply",
                        reply,
                    ).addRemoteInput(remoteInput).setAllowGeneratedReplies(true).build(),
                )
        }
        val notification = builder.build()
        if (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED) {
            try {
                NotificationManagerCompat.from(context).notify(id, notification)
            } catch (_: SecurityException) {
                // Permission/vendor policy can change between the check and notify.
            }
        }
    }
}

class MessageNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REPLY_TO_MESSAGE) return
        // A mutable RemoteInput PendingIntent can already be in SystemUI when
        // app lock is enabled. Re-check the durable policy at execution time.
        if (!MessageNotifications.repliesAllowed(context)) return
        val token = intent.getStringExtra(EXTRA_MESSAGE_ACTION_TOKEN).orEmpty()
        val route = JamiCore.resolveMessageAction(token) ?: return
        if (!route.replyAllowed || route.startCall) return
        val text = MessageNotificationPolicy.replyText(
            RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_TEXT_REPLY),
        ) ?: return
        val pending = goAsync()
        JamiCore.attach(context.applicationContext)
        JamiCore.start()
        JamiCore.submit(
            DaemonOperation.SEND_CHAT_MESSAGE,
            block = {
                if (MessageNotifications.repliesAllowed(context) && JamiCore.consumeMessageAction(token, route))
                    JamiCore.sendNotificationReply(route, text) else ""
            },
        ) { result ->
            MessageNotifications.finishReply(
                context.applicationContext,
                route,
                text,
                result.orEmpty().isNotEmpty(),
            )
            pending.finish()
        }
    }
}
