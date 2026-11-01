package app.sybl.sybl

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.app.Activity
import android.graphics.Rect
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.view.Surface
import android.view.WindowManager
import java.io.File
import java.nio.file.Files
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import androidx.core.content.FileProvider
import net.jami.daemon.JamiService
import net.jami.daemon.JamiServiceJNI

class MainActivity : FlutterFragmentActivity(), JamiCore.VideoBinder {
    companion object {
        private const val PRIVACY_PREFS = "sybl_privacy"
        private const val CAPTURE_PROTECTION = "capture_protection_enabled"
        private const val MAX_PICK_COPY_BYTES = 2L * 1024 * 1024 * 1024
    }

    private val CORE = "syb.l/core"
    private val EVENTS = "syb.l/events"
    private val GRAVITY = "syb.l/gravity"
    private val gravitySensor by lazy { GravitySensor(this) }
    private val CAMERA_REQ = 1002
    private val PLACE_VIDEO_REQ = 1003
    private val SCREEN_SHARE_REQ = 1006
    private val PICK_FILE_REQ = 1004
    private val CREATE_DOC_REQ = 1005   // SAF Create-Document for an identity backup (M7.5 a)
    private fun logInfo(message: String) { if (JamiCore.debugBuild) android.util.Log.i("SybL", message) }
    private fun logError(message: String, error: Throwable? = null) {
        if (JamiCore.debugBuild && error != null) android.util.Log.e("SybL", message, error)
        else android.util.Log.e("SybL", if (JamiCore.debugBuild) message else "platform operation failed")
    }
    private var pendingPickResult: MethodChannel.Result? = null  // a pickFile awaiting the document picker
    private val deviceRevocationReplyOwner = Any()
    private var pendingPickMaxBytes = MAX_PICK_COPY_BYTES
    // Non-null = a backup owns the worker export + picker + copy. The temp path only exists once the export lands,
    // so it cannot gate the in-flight check itself. Each export owns a unique temporary snapshot.
    private var pendingBackupResult: MethodChannel.Result? = null
    private var pendingBackupScope: NativeAccountScope? = null
    private var pendingBackupTmp: String? = null  // temp export path awaiting Create-Document
    private var pendingInviteLink: String? = null
    private data class PendingConversation(
        val actionToken: String,
        val accountId: String,
        val ownerKey: String,
        val conversationId: String,
        val topicId: String,
        val startCall: Boolean,
    )
    private var pendingConversation: PendingConversation? = null

    // Two Flutter external textures: the daemon decoded-frame sinks render here. Producers persist for the
    // app lifetime (reused across calls); only the daemon native windows are (un)bound per call.
    private var renderer: FlutterRenderer? = null
    private var selfProducer: TextureRegistry.SurfaceProducer? = null
    private var remoteProducer: TextureRegistry.SurfaceProducer? = null
    private var selfWin = -1L
    private var remoteWin = -1L
    private var selfBoundId: String? = null
    private var remoteBoundId: String? = null
    // A sink can begin decoding before Dart has created its Texture (negotiation-timed) — cache + bind on create.
    private var pendingSelf: Triple<String, Int, Int>? = null
    private var pendingRemote: Triple<String, Int, Int>? = null
    private var pendingStartVideo: Pair<String, MethodChannel.Result>? = null // callId + result awaiting CAMERA perm
    private data class PendingScreen(
        val callId: String,
        val epoch: Long,
        val result: MethodChannel.Result,
    )
    private data class PendingPlace(
        val peerId: String,
        val initialAudioMuted: Boolean,
        val result: MethodChannel.Result,
    )
    private var pendingScreen: PendingScreen? = null
    private var pendingPlace: PendingPlace? = null // place-with-video awaiting CAMERA permission
    @Volatile private var activityDestroyed = false
    private val messagingCamera by lazy { MessagingCameraCapture(this) }
    // Nearby discovery receives Doorlight's own UDP multicast. Not reference-counted, so repeated acquire/release
    // calls from Dart can never leak or underflow the lock.
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nearbyRadio: NearbyRadio? = null
    // Android 13+ scopes FLAG_SECURE to sensitive Flutter surfaces (chats, calls, link codes) and hides only the
    // recents preview elsewhere. Older releases cannot hide that preview alone, so they keep whole-app protection.
    // Starts true: a cold launch may open straight into a chat before Dart reports its surfaces.
    private var sensitiveSurfaceVisible = true
    private var sensitiveSurfaceGeneration = 0
    private val captureScopedToSurfaces = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    override fun onCreate(savedInstanceState: Bundle?) {
        // Start protected before Flutter's first frame. A previously confirmed
        // opt-out is applied immediately after Activity creation.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        messagingCamera // Recover only orphan cleanup, never a composer attachment.
        applyCaptureProtection()
        pendingInviteLink = inviteLink(intent)
        pendingConversation = messageConversation(intent)
        JamiCore.attach(this)
        JamiCore.start()
        JamiCore.configureRecordingBridge()
        // If the process (and its goodbye-deactivated account) survived a previous exit into this relaunch,
        // re-activate only after the native canonical-privacy activation gate permits it.
        JamiCore.submit(DaemonOperation.REVIVE, block = { JamiCore.reviveActive(); null }) {}
        JamiCore.setVideoBinder(this)
        window.decorView.post { updateRemoteControlDisplayGeometry() }
        // Runtime permissions wait for Dart's home screen so onboarding opens unprompted.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val invite = inviteLink(intent)
        if (invite != null) {
            if (JamiCore.hasEventSink()) {
                pendingInviteLink = null
                JamiCore.emit(mapOf("type" to "inviteLink", "link" to invite))
            } else {
                pendingInviteLink = invite
            }
            return
        }
        val conversation = messageConversation(intent)
        if (conversation != null) {
            if (JamiCore.hasEventSink()) {
                pendingConversation = null
                if (validateConversation(conversation) == null) return
                JamiCore.emit(mapOf(
                    "type" to "openConversation",
                    "accountId" to conversation.accountId,
                    "actionToken" to conversation.actionToken,
                    "ownerKey" to conversation.ownerKey,
                    "conversationId" to conversation.conversationId,
                    "topicId" to conversation.topicId,
                    "startCall" to conversation.startCall,
                ))
            } else {
                pendingConversation = conversation
            }
            return
        }
        // Launcher and deep-link intents are untrusted. Diagnostic commands are
        // accepted only by the permission-protected StressControlReceiver.
    }

    private fun inviteLink(intent: Intent?): String? {
        return InviteLinkPolicy.candidate(intent?.data?.toString(), BuildConfig.DOORLIGHT_INVITE_ORIGIN)
    }

    private fun messageConversation(intent: Intent?): PendingConversation? {
        if (intent?.action != ACTION_OPEN_MESSAGE_CONVERSATION) return null
        val token = intent.getStringExtra(EXTRA_MESSAGE_ACTION_TOKEN).orEmpty()
        val route = JamiCore.resolveMessageAction(token) ?: return null
        return PendingConversation(
            token, route.account.accountId ?: return null,
            route.ownerKey, route.conversationId, route.topicId, route.startCall,
        )
    }

    private fun validateConversation(pending: PendingConversation?): PendingConversation? {
        if (pending == null) return null
        val action = JamiCore.resolveMessageAction(pending.actionToken) ?: return null
        if (action.ownerKey != pending.ownerKey || action.conversationId != pending.conversationId ||
            action.topicId != pending.topicId || action.startCall != pending.startCall ||
            action.account.accountId != pending.accountId) return null
        return pending
    }

    override fun onDestroy() {
        nearbyRadio?.close(); nearbyRadio = null
        activityDestroyed = true
        JamiCore.setVideoBinder(null, expected = this)
        messagingCamera.close()
        JamiCore.cancelKnownDeviceRevocations(deviceRevocationReplyOwner)
        // A finishing Activity enters push-backed sleep when available. The persistent fallback sends its existing
        // best-effort transport goodbye. A non-finishing destroy (recreate) stays up.
        if (isFinishing) JamiCore.submit(DaemonOperation.GOODBYE, block = { JamiCore.goodbye(); null }) {}
        // Permission dialogs own channel replies across an Activity callback. If this Activity is finishing before
        // Android answers, release that ownership now with the method's type-correct failure value.
        val start = pendingStartVideo; pendingStartVideo = null; start?.second?.success(false)
        val screen = pendingScreen; pendingScreen = null
        if (screen != null) {
            JamiCore.cancelScreenConsent(screen.callId, screen.epoch)
            screen.result.success(false)
        }
        val place = pendingPlace; pendingPlace = null; place?.result?.success(emptyPlacement())
        val pick = pendingPickResult; pendingPickResult = null
        pendingPickMaxBytes = MAX_PICK_COPY_BYTES
        pick?.success(null)
        val tmp = pendingBackupTmp; pendingBackupTmp = null; tmp?.let { cleanupTemp(it) }
        // An in-flight copier owns the selected document and its result until
        // it has either published success or completed destination cleanup.
        if (!backupCopyInFlight) {
            val backupResult = pendingBackupResult; pendingBackupResult = null
            pendingBackupScope = null; backupResult?.success(false)
        }
        releaseAll()
        releaseMulticastLock()
        selfProducer?.release(); selfProducer = null
        remoteProducer?.release(); remoteProducer = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        renderer = flutterEngine.renderer
        nearbyRadio?.close()
        nearbyRadio = NearbyRadio(this, flutterEngine.dartExecutor.binaryMessenger)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = JamiCore.setEventSink(events)
                override fun onCancel(arguments: Any?) = JamiCore.setEventSink(null)
            }
        )
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, GRAVITY).setStreamHandler(gravitySensor)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CORE).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureAccount" -> {
                    val name = call.argument<String>("displayName") ?: "Me"
                    val preferred = call.argument<String>("preferredAccountId") ?: ""
                    val preferredPeer = call.argument<String>("preferredPeerId") ?: ""
                    val createIfMissing = call.argument<Boolean>("createIfMissing") ?: false
                    var response: Map<String, Any?>? = null
                    // A visible retry reaches this same channel without recreating the Activity. Queue the
                    // retryable boot transaction first; the serial daemon worker keeps ensureAccount behind it.
                    JamiCore.start()
                    JamiCore.submitCommand(
                        DaemonOperation.ENSURE_ACCOUNT,
                        block = {
                            response = JamiCore.ensureAccount(
                                name,
                                preferred,
                                preferredPeer,
                                createIfMissing,
                            )
                        },
                    ) { failure ->
                        if (failure == null) result.success(response)
                        else if (JamiCore.retiredReason != null) result.error("relaunch_required", "Restart Doorlight", JamiCore.retiredReason)
                        else result.error("native_startup_failed", "Native engine is unavailable", null)
                    }
                }
                "myJamiId" -> JamiCore.submit(
                    DaemonOperation.READ_IDENTITY, block = { JamiCore.myJamiId() },
                ) { result.success(it) }
                "replayPendingNativeEvents" -> result.success(JamiCore.replayPendingNativeEvents())
                "getPeerId" -> JamiCore.submit(
                    DaemonOperation.READ_PEER, block = { JamiCore.peerId() },
                ) { result.success(it) }
                "listFriends" -> JamiCore.submit(
                    DaemonOperation.READ_PEER, block = { JamiCore.listFriends() },
                ) { result.success(it) }
                "listKnownDevices" -> JamiCore.submit(
                    DaemonOperation.READ_DEVICES,
                    block = { JamiCore.listKnownDevices() },
                ) { result.success(it ?: emptyList<Map<String, Any>>()) }
                "revokeKnownDevice" -> {
                    val accountId = call.argument<String>("accountId") ?: ""
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    val scope = JamiCore.captureAccountScope(accountId)
                    JamiCore.revokeKnownDevice(accountId, deviceId, scope, deviceRevocationReplyOwner) {
                        result.success(it.toWire())
                    }
                }
                "updateProfile" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val displayName = call.argument<String>("displayName") ?: ""
                    val avatar = call.argument<String>("avatar") ?: ""
                    val fileType = call.argument<String>("fileType") ?: ""
                    val flag = call.argument<Number>("flag")?.toInt() ?: -1
                    JamiCore.submit(
                        DaemonOperation.UPDATE_PROFILE,
                        block = {
                            JamiCore.updateProfile(
                                displayName,
                                avatar,
                                fileType,
                                flag,
                                scope,
                            )
                        },
                    ) { result.success(it == true) }
                }
                "addFriend" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    JamiCore.submit(
                        DaemonOperation.SUBSCRIBE_PRESENCE, block = { JamiCore.addFriend(peer, scope) },
                    ) { result.success(it == true) }
                }
                "createGroup" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val title = call.argument<String>("title") ?: ""
                    val members = call.argument<List<String>>("memberIds") ?: emptyList()
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.createGroup(title, members, scope) },
                    ) { result.success(it ?: "") }
                }
                "addGroupMembers" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val members = call.argument<List<String>>("memberIds") ?: emptyList()
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.addGroupMembers(conversationId, members, scope) },
                    ) { result.success(it == true) }
                }
                "removeGroupMember" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val memberId = call.argument<String>("memberId") ?: ""
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.removeGroupMember(conversationId, memberId, scope) },
                    ) { result.success(it == true) }
                }
                "renameGroup" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.renameGroup(conversationId, title, scope) },
                    ) { result.success(it == true) }
                }
                "updateGroupLayout" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val description = call.argument<String>("description") ?: ""
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.updateGroupLayout(conversationId, description, scope) },
                    ) { result.success(it == true) }
                }
                "leaveGroup" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    JamiCore.submit(
                        DaemonOperation.GROUP_MUTATION,
                        block = { JamiCore.leaveGroup(conversationId, scope) },
                    ) { result.success(it == true) }
                }
                "setPresenceSubscriptions" -> {
                    val peers = call.argument<List<String>>("peerJamiIds") ?: emptyList()
                    JamiCore.submit(DaemonOperation.SUBSCRIBE_PRESENCE, block = {
                        JamiCore.setPresenceSubscriptions(peers)
                    }) { result.success(it == true) }
                }
                "listGroupCalls" -> {
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    JamiCore.submit(
                        DaemonOperation.GENERIC,
                        block = { JamiCore.listGroupCalls(conversationId) },
                    ) { result.success(it ?: emptyList<Map<String, String>>()) }
                }
                "reserveGroupCall" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("accountId") ?: "")
                    val conversation = call.argument<String>("conversationId") ?: ""
                    val reservation = call.argument<String>("reservationId") ?: ""
                    JamiCore.submit(DaemonOperation.GENERIC,
                        block = { JamiCore.reserveGroupCall(scope, conversation, reservation) },
                    ) { result.success(it == true) }
                }
                "joinGroupCall" -> {
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val reservationId = call.argument<String>("reservationId") ?: ""
                    val hostUri = call.argument<String>("hostUri") ?: ""
                    val hostDevice = call.argument<String>("hostDevice") ?: ""
                    val initialAudioMuted = call.argument<Boolean>("initialAudioMuted") ?: false
                    JamiCore.submit(
                        DaemonOperation.PLACE_CALL,
                        block = {
                            JamiCore.joinGroupCall(
                                conversationId,
                                conferenceId,
                                reservationId,
                                hostUri,
                                hostDevice,
                                initialAudioMuted,
                            )
                        },
                    ) {
                        result.success(
                            it ?: mapOf(
                                "conferenceId" to "",
                                "callId" to "",
                                "hosting" to false,
                            ),
                        )
                    }
                }
                "leaveGroupCall" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val reservationId = call.argument<String>("reservationId") ?: ""
                    JamiCore.submit(
                        DaemonOperation.HANG_UP,
                        conferenceId,
                        { JamiCore.leaveGroupCall(conferenceId, reservationId) },
                    ) { result.success(it == true) }
                }
                "setGroupMicMuted" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val muted = call.argument<Boolean>("muted") ?: false
                    JamiCore.submit(
                        DaemonOperation.SET_MIC_MUTED,
                        conferenceId,
                        { JamiCore.setGroupMicMuted(conferenceId, muted) },
                    ) { result.success(it == true) }
                }
                "setGroupDeafened" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val deafened = call.argument<Boolean>("deafened") ?: false
                    JamiCore.submit(
                        DaemonOperation.GENERIC,
                        conferenceId,
                        { JamiCore.setGroupDeafened(conferenceId, deafened) },
                    ) { result.success(it == true) }
                }
                "setGroupConferenceLayout" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val layout = call.argument<Int>("layout") ?: -1
                    JamiCore.submit(DaemonOperation.GENERIC, conferenceId, {
                        JamiCore.setGroupConferenceLayout(conferenceId, layout)
                    }) { result.success(it == true) }
                }
                "setGroupActiveStream" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val participantAccountId = call.argument<String>("accountId") ?: ""
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    val streamId = call.argument<String>("streamId") ?: ""
                    val active = call.argument<Boolean>("active") ?: false
                    JamiCore.submit(DaemonOperation.GENERIC, conferenceId, {
                        JamiCore.setGroupActiveStream(
                            conferenceId, participantAccountId, deviceId, streamId, active,
                        )
                    }) { result.success(it == true) }
                }
                "muteGroupParticipant" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val participantAccountId = call.argument<String>("accountId") ?: ""
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    val streamId = call.argument<String>("streamId") ?: ""
                    val muted = call.argument<Boolean>("muted") ?: false
                    JamiCore.submit(DaemonOperation.GENERIC, conferenceId, {
                        JamiCore.muteGroupParticipant(
                            conferenceId, participantAccountId, deviceId, streamId, muted,
                        )
                    }) { result.success(it == true) }
                }
                "disconnectGroupParticipant" -> {
                    val conferenceId = call.argument<String>("conferenceId") ?: ""
                    val participantAccountId = call.argument<String>("accountId") ?: ""
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    JamiCore.submit(DaemonOperation.HANG_UP, conferenceId, {
                        JamiCore.disconnectGroupParticipant(
                            conferenceId, participantAccountId, deviceId,
                        )
                    }) { result.success(it == true) }
                }
                "publishGroupCallPresence" -> {
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val payload = call.argument<String>("payload") ?: ""
                    JamiCore.submit(
                        DaemonOperation.SEND_CALL_MESSAGE,
                        block = { JamiCore.publishGroupCallPresence(conversationId, payload) },
                    ) { result.success(it == true) }
                }
                "placeCall" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val withVideo = call.argument<Boolean>("withVideo") ?: false
                    val initialAudioMuted = call.argument<Boolean>("initialAudioMuted") ?: false
                    if (withVideo && !hasCamera()) {
                        if (pendingPlace != null) {
                            result.success(emptyPlacement()) // one permission request owns the pending result
                        } else {
                            pendingPlace = PendingPlace(
                                peerId = peer,
                                initialAudioMuted = initialAudioMuted,
                                result = result,
                            ) // place after CAMERA is granted (read display on main)
                            try {
                                requestPermissions(arrayOf(Manifest.permission.CAMERA), PLACE_VIDEO_REQ)
                            } catch (e: Throwable) {
                                logError("placeCall camera permission", e)
                                pendingPlace = null
                                result.success(emptyPlacement())
                            }
                        }
                    } else {
                        val deg = displayRotationDeg()
                        JamiCore.submit(DaemonOperation.PLACE_CALL, block = {
                            JamiCore.placeCall(peer, withVideo, deg, initialAudioMuted)
                        }) {
                            if (activityDestroyed) {
                                cleanupStalePlacement(it)
                                result.success(emptyPlacement())
                            } else result.success(it ?: emptyPlacement())
                        }
                    }
                }
                "answerCall" -> {
                    val id = call.argument<String>("callId") ?: ""
                    val initialAudioMuted = call.argument<Boolean>("initialAudioMuted") ?: false
                    logInfo("MethodChannel answerCall($id)")
                    JamiCore.submit(
                        DaemonOperation.ANSWER_CALL,
                        id,
                        { JamiCore.answerCall(id, initialAudioMuted) },
                    ) {
                        result.success(it)
                    }
                }
                "hangUp" -> {
                    val id = call.argument<String>("callId") ?: ""
                    JamiCore.submit(DaemonOperation.HANG_UP, id, { JamiCore.hangUp(id) }) { result.success(it) }
                }
                "refuse" -> {
                    val id = call.argument<String>("callId") ?: ""
                    JamiCore.submit(DaemonOperation.REFUSE_CALL, id, { JamiCore.refuse(id) }) { result.success(it) }
                }
                "sendCallMessage" -> {
                    val id = call.argument<String>("callId") ?: ""
                    val payload = call.argument<String>("payload") ?: ""
                    val channel = call.argument<String>("channel") ?: "annotation"
                    val scope = JamiCore.captureCallMessage(id)
                    JamiCore.submit(DaemonOperation.SEND_CALL_MESSAGE, id, {
                        scope != null && JamiCore.sendCallMessage(scope, payload, channel)
                    }) { result.success(it == true) }
                }
                "remoteControlStop" ->
                    result.success(AndroidRemoteControlHost.stopLocal("flutter-stop"))
                "remoteControlAccessibilityStatus" ->
                    result.success(AndroidRemoteControlHost.isServiceEnabled())
                "androidCaptureProtectionStatus" ->
                    result.success(captureProtectionStatus())
                "setAndroidCaptureProtection" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val saved = getSharedPreferences(PRIVACY_PREFS, MODE_PRIVATE)
                        .edit()
                        .putBoolean(CAPTURE_PROTECTION, enabled)
                        .commit()
                    if (!saved) {
                        result.error(
                            "capture_preference",
                            "The privacy preference could not be saved.",
                            null,
                        )
                    } else {
                        applyCaptureProtection()
                        result.success(captureProtectionStatus())
                    }
                }
                "setAndroidSensitiveSurface" -> {
                    sensitiveSurfaceVisible = call.argument<Boolean>("visible") ?: true
                    val generation = ++sensitiveSurfaceGeneration
                    val secure = applyCaptureProtection()
                    if (!secure) {
                        result.success(false)
                    } else {
                        // Reply only after a frame carrying the secure window attributes is committed, so Dart
                        // never reveals private content on a still-capturable surface. Fail closed if no
                        // frame commits before the deadline, including while the window is invisible.
                        var answered = false
                        val answer = Runnable {
                            if (answered) return@Runnable
                            answered = true
                            result.success(
                                generation == sensitiveSurfaceGeneration &&
                                    (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0,
                            )
                        }
                        val main = Handler(Looper.getMainLooper())
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            window.decorView.viewTreeObserver.registerFrameCommitCallback { main.post(answer) }
                            window.decorView.invalidate()
                            main.postDelayed({
                                if (!answered) {
                                    answered = true
                                    result.success(false)
                                }
                            }, 500)
                        } else {
                            // Android 9 and older keep whole-app protection, so the window is already secure.
                            main.post(answer)
                        }
                    }
                }
                "setAnnotationOverlay", "setAndroidAnnotationOverlay" ->
                    result.success(
                        AndroidRemoteControlHost.updateAnnotationOverlay(
                            call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(),
                        ),
                    )
                "openRemoteControlAccessibilitySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    } catch (e: Throwable) {
                        logError("open accessibility settings", e)
                        result.success(false)
                    }
                }
                "probeReachable" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val owner = JamiCore.capturePresenceProbe()
                    JamiCore.submit(DaemonOperation.PROBE_PRESENCE, block = {
                        JamiCore.probeReachable(peer, owner)
                    }) { result.success(it) }
                }
                "sendComposerActivity" -> {
                    val accountId = call.argument<String>("accountId") ?: ""
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val kind = call.argument<String>("kind") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_COMPOSER_ACTIVITY, block = {
                        JamiCore.sendComposerActivity(accountId, peer, conversationId, kind)
                    }) { result.success(it == true) }
                }
                "sendFileThumbnail" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fileId = call.argument<String>("fileId") ?: ""
                    val pngBase64 = call.argument<String>("pngBase64") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_FILE_THUMBNAIL, block = {
                        JamiCore.sendFileThumbnail(
                            peer,
                            conversationId,
                            fileId,
                            pngBase64,
                        )
                    }) { result.success(it == true) }
                }
                "sendHologramControl" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("accountId") ?: "")
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val payload = call.argument<String>("payload") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_HOLOGRAM_CONTROL, block = {
                        JamiCore.sendHologramControl(scope, peer, payload)
                    }) { result.success(it == true) }
                }
                "sendFileDeclined" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fileId = call.argument<String>("fileId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_FILE_DECISION, block = {
                        JamiCore.sendFileDeclined(peer, conversationId, fileId)
                    }) { result.success(it == true) }
                }
                "notifyCallRequest" -> {
                    val peer = call.argument<String>("peerJamiId").orEmpty()
                    JamiCore.submit(DaemonOperation.SEND_CALL_REQUEST, block = {
                        JamiCore.sendCallRequest(peer)
                    }) { result.success(it == true) }
                }
                "setForeground" -> {
                    // Android presence follows onResume/onPause, including headless
                    // restarts. Keep the cross-platform method as an acknowledged no-op.
                    result.success(null)
                }
                "setPresenceMetadata" -> {
                    JamiCore.setPresenceMetadata(
                        call.argument<Boolean>("shareActivity") ?: false,
                        call.argument<String>("color") ?: "",
                    )
                    result.success(null)
                }
                "setMessageNotificationPreview" -> {
                    JamiCore.submit(DaemonOperation.GENERIC, block = {
                        JamiCore.setMessageNotificationPreview(
                            call.argument<Boolean>("showMessage") ?: true,
                            call.argument<Boolean>("appLockEnabled") ?: true,
                        )
                    }) { result.success(it == true) }
                }
                "saveAppSettingsDocument" -> {
                    JamiCore.saveAppSettingsDocument(call.argument<String>("document") ?: "") {
                        result.success(it)
                    }
                }
                "backgroundWakeAvailability" ->
                    result.success(JamiCore.backgroundWakeAvailability())
                "setReliableBackgroundNotifications" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    if (scope == null) { result.success(false); return@setMethodCallHandler }
                    JamiCore.setReliableBackgroundNotifications(
                        call.argument<Boolean>("enabled") ?: false,
                        call.argument<String>("connectionProfile") ?: "jami",
                        call.argument<String>("relayUrl") ?: "",
                        scope,
                    ) { result.success(it) }
                }
                "rotateBackgroundWakeCapability" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    if (scope == null) { result.success(false); return@setMethodCallHandler }
                    JamiCore.rotateBackgroundWakeCapability(
                        call.argument<String>("relayUrl") ?: "",
                        scope,
                    ) { result.success(it) }
                }
                "dismissMessageNotification" -> {
                    JamiCore.cancelMessageNotification(
                        call.argument<String>("conversationId") ?: "",
                    )
                    result.success(null)
                }
                "takePendingInviteLink" -> {
                    val link = pendingInviteLink.orEmpty()
                    pendingInviteLink = null
                    result.success(link)
                }
                "takePendingConversation" -> {
                    val conversation = validateConversation(pendingConversation)
                    pendingConversation = null
                    result.success(
                        conversation?.let {
                            mapOf(
                                "ownerKey" to it.ownerKey,
                                "accountId" to it.accountId,
                                "actionToken" to it.actionToken,
                                "conversationId" to it.conversationId,
                                "topicId" to it.topicId,
                                "startCall" to it.startCall,
                            )
                        },
                    )
                }
                "consumeMessageOpen" -> {
                    val token = call.argument<String>("actionToken").orEmpty()
                    val action = JamiCore.resolveMessageAction(token)
                    val matches = action != null && action.account.accountId == call.argument<String>("accountId") &&
                        action.ownerKey == call.argument<String>("ownerKey") &&
                        action.conversationId == call.argument<String>("conversationId") &&
                        action.topicId == call.argument<String>("topicId") &&
                        action.startCall == (call.argument<Boolean>("startCall") == true)
                    result.success(matches && JamiCore.consumeMessageAction(token, action!!))
                }
                "connectivitySweep" -> JamiCore.submit(
                    DaemonOperation.CONNECTIVITY_SWEEP,
                    block = { JamiCore.connectivitySweep(); null },
                ) { result.success(null) }
                "setMicMuted" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    val muted = call.argument<Boolean>("muted") ?: false
                    submitCommand(
                        "setMicMuted", result, DaemonOperation.SET_MIC_MUTED, callId,
                    ) {
                        check(JamiCore.setMicMuted(callId, muted)) { "stale or missing call" }
                    }
                }
                "setAudioTransmissionMode" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    val mode = call.argument<String>("mode") ?: ""
                    submitCommand(
                        "setAudioTransmissionMode",
                        result,
                        DaemonOperation.SET_AUDIO_TRANSMISSION_MODE,
                        callId,
                    ) {
                        check(JamiCore.setAudioTransmissionMode(callId, mode)) {
                            "stale call, invalid mode, or voice activation unavailable"
                        }
                    }
                }
                "setAudioMeterEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    submitCommand(
                        "setAudioMeterEnabled", result, DaemonOperation.SET_AUDIO_METER,
                    ) { JamiCore.setAudioMeterEnabled(enabled) }
                }
                "setSpeaker" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    JamiCore.setSpeaker(on)
                    result.success(null)
                }
                "setAppearOffline" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    JamiCore.retirePresenceProbes()
                    submitCommand(
                        "setAppearOffline", result, DaemonOperation.SET_APPEAR_OFFLINE,
                    ) {
                        check(JamiCore.invokeAccountCommand(scope) { JamiCore.setAppearOffline(on) }) {
                            "Selected account changed"
                        }
                    }
                }
                "setConnectionProfile" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    val profile = call.argument<String>("profile") ?: "jami"
                    val dhtBootstrap = call.argument<String>("dhtBootstrap") ?: ""
                    val turnServer = call.argument<String>("turnServer") ?: ""
                    val turnRealm = call.argument<String>("turnRealm") ?: ""
                    val turnUser = call.argument<String>("turnUser") ?: ""
                    val turnPassword = call.argument<String>("turnPassword") ?: ""
                    submitCommand(
                        "setConnectionProfile", result, DaemonOperation.SET_CONNECTION_PROFILE,
                    ) {
                        check(JamiCore.invokeAccountCommand(scope) {
                            JamiCore.setConnectionProfile(profile, dhtBootstrap, turnServer, turnRealm, turnUser, turnPassword)
                        }) { "Selected account changed" }
                    }
                }
                "createVideoTexture" -> {
                    val role = if (call.argument<String>("role") == "self") JamiCore.VideoRole.SELF else JamiCore.VideoRole.REMOTE
                    result.success(ensureProducer(role))
                }
                "listScreenSources" -> result.success(emptyList<Map<String, Any>>())
                "setOutgoingVideoSource" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    when (call.argument<String>("kind") ?: "off") {
                        "screen" -> beginScreenShare(callId, result)
                        "camera" -> startCameraSource(callId, result)
                        "off" -> JamiCore.submit(DaemonOperation.STOP_VIDEO, callId, {
                            JamiCore.stopVideo(callId)
                        }) { result.success(it ?: false) }
                        else -> result.success(false)
                    }
                }
                "startVideo" -> {
                    startCameraSource(call.argument<String>("callId") ?: "", result)
                }
                "stopVideo" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    JamiCore.submit(DaemonOperation.STOP_VIDEO, callId, {
                        JamiCore.stopVideo(callId)
                    }) { result.success(it ?: false) }
                }
                "switchCamera" -> JamiCore.submit(
                    DaemonOperation.SWITCH_CAMERA,
                    call.argument<String>("callId") ?: "",
                    block = {
                        val callId = call.argument<String>("callId") ?: ""
                        if (callId.isEmpty()) false else JamiCore.switchCamera(callId)
                    },
                ) { result.success(it) }
                "hasCameraPermission" -> result.success(hasCamera())
                "hasMicPermission" -> result.success(hasMic())
                "requestRuntimePermissions" -> {
                    requestRuntimePerms()
                    result.success(null)
                }
                "acquireMulticastLock" -> result.success(acquireMulticastLock())
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                "pickFile" -> {
                    if (pendingPickResult != null || pendingBackupResult != null) {
                        result.success(null)   // a pick is already in flight (modal) → no-op the new caller
                    } else {
                        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                            ?: MAX_PICK_COPY_BYTES
                        if (maxBytes !in 1..MAX_PICK_COPY_BYTES) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        pendingPickResult = result
                        pendingPickMaxBytes = maxBytes
                        val mimeType = call.argument<String>("mimeType")
                            ?.takeIf { it.isNotBlank() }
                            ?: "*/*"
                        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = mimeType
                        }
                        try {
                            startActivityForResult(i, PICK_FILE_REQ)
                        } catch (e: Throwable) {
                            logError("pickFile", e)
                            pendingPickResult = null
                            pendingPickMaxBytes = MAX_PICK_COPY_BYTES
                            result.success(null)
                        }
                    }
                }
                "prepareVoiceRecording" -> result.success(JamiCore.prepareVoiceRecording(
                    call.argument<String>("accountId") ?: "",
                    call.argument<String>("peerJamiId") ?: "",
                    call.argument<String>("conversationId") ?: ""))
                "renewVoiceRecording" -> result.success(com.llfbandit.record.SybLRecordingBridge.renew(
                    call.argument<String>("path") ?: ""))
                "captureComposerPhoto" -> messagingCamera.capture(call.argument<String>("accountId") ?: "") {
                    result.success(it)
                }
                "gifLibraryDirectory" -> result.success(File(noBackupFilesDir, "gif-library").absolutePath)
                "archivedChatsDirectory" -> result.success(File(noBackupFilesDir, "archived-chats").absolutePath)
                "stageStarterGif" -> {
                    val id = call.argument<String>("id") ?: ""
                    // A fixed bundled asset, copied to a fresh owned picker stage.
                    // Never place built-ins in the quota-limited personal library.
                    val staged = if (!Regex("[a-z]{1,20}").matches(id)) null else try {
                        val outgoing = File(filesDir, "outgoing").apply { mkdirs() }
                        val stage = Files.createTempDirectory(outgoing.toPath(), "picked-").toFile()
                        val destination = File(stage, "$id.gif")
                        var complete = false
                        try {
                            assets.open("flutter_assets/assets/gifs/doorlight/$id.gif").use { input ->
                                complete = copyBoundedToFile(input, destination, 4L * 1024 * 1024)
                            }
                            if (complete) destination.absolutePath else null
                        } finally {
                            if (!complete) { destination.delete(); stage.delete() }
                        }
                    } catch (_: Throwable) { null }
                    result.success(staged)
                }
                "stageGifLibraryEntry" -> {
                    val hash = call.argument<String>("hash") ?: ""
                    // Only a content-addressed leaf in our no-backup library is
                    // accepted. No arbitrary source path crosses this channel.
                    val staged = if (!Regex("[0-9a-f]{64}").matches(hash)) null else try {
                        val source = File(File(noBackupFilesDir, "gif-library"), "$hash.gif")
                        if (!Files.isRegularFile(source.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)) null
                        else {
                            val outgoing = File(filesDir, "outgoing").apply { mkdirs() }
                            val stage = Files.createTempDirectory(outgoing.toPath(), "picked-").toFile()
                            val destination = File(stage, "$hash.gif")
                            var complete = false
                            try {
                                Files.newInputStream(source.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS).use { input ->
                                    complete = copyBoundedToFile(input, destination, 4L * 1024 * 1024)
                                }
                                if (complete) destination.absolutePath else null
                            } finally {
                                if (!complete) { destination.delete(); stage.delete() }
                            }
                        }
                    } catch (_: Throwable) { null }
                    result.success(staged)
                }
                "discardPickedFile" -> {
                    cleanupPickerCopy(call.argument<String>("path") ?: "")
                    result.success(null)
                }
                "sendFile" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val topicId = call.argument<String>("topicId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_FILE, block = {
                        JamiCore.sendFile(peer, conversationId, path, name, topicId)
                    }) {
                        // A successfully announced shared file must remain seedable for delayed accepts and history
                        // downloads. Only abandon our private picker copy when native setup itself failed.
                        if (it != true) cleanupPickerCopy(path)
                        result.success(it)
                    }
                }
                "acceptFile" -> {
                    val scope = JamiCore.captureAccountScope()
                    val attempt = call.argument<String>("attemptId") ?: ""
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val iid = call.argument<String>("interactionId") ?: ""
                    val fid = call.argument<String>("fileId") ?: ""
                    val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: 0L
                    val routeRevision = JamiCore.captureFileAcceptRoute(scope, peer, conversationId)
                    if (routeRevision == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    // Reload the exact signed commit before download. A bounded
                    // offer cache may have evicted an old history item, and UI
                    // metadata never supplies native size or media policy.
                    JamiCore.loadSearchMessage(scope, peer, conversationId, iid) { reply ->
                        val item = (reply?.get("items") as? List<*>)?.singleOrNull() as? Map<*, *>
                        val body = item?.get("body") as? Map<*, *>
                        if (item?.get("daemonId") != iid ||
                            item?.get("mimeType") != "application/data-transfer+json" ||
                            item?.get("deleted") != false || body?.get("fileId") != fid) {
                            result.success(false)
                        } else {
                            val offer = FileOffer(
                                (body["totalBytes"] as? Number)?.toLong() ?: -1L,
                                body["displayName"] as? String ?: "",
                                item["authorId"] as? String ?: "",
                                false,
                                item["mediaMetadata"] as? String,
                            )
                            JamiCore.submit(DaemonOperation.ACCEPT_FILE, block = {
                                JamiCore.acceptFile(peer, conversationId, iid, fid, maxBytes, attempt, scope,
                                    routeRevision, offer)
                            }) { result.success(it) }
                        }
                    }
                }
                "openReceivedFile" -> result.success(
                    openReceivedFile(call.argument<String>("path") ?: "")
                )
                "cancelFile" -> {
                    val scope = JamiCore.captureAccountScope()
                    val attempt = call.argument<String>("attemptId") ?: ""
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fid = call.argument<String>("fileId") ?: ""
                    JamiCore.submit(DaemonOperation.CANCEL_FILE, block = {
                        JamiCore.cancelFile(peer, conversationId, fid, attempt, scope)
                    }) { result.success(it == true) }
                }
                "fileInfo" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fid = call.argument<String>("fileId") ?: ""
                    JamiCore.submit(DaemonOperation.FILE_INFO, block = {
                        JamiCore.fileInfo(peer, conversationId, fid)
                    }) {
                        result.success(it)
                    }
                }
                "loadFolder" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val n = call.argument<Int>("n") ?: 200
                    JamiCore.submit(DaemonOperation.LOAD_FOLDER, block = {
                        JamiCore.loadFolder(peer, conversationId, n)
                    }) { result.success(it ?: 0L) }
                }
                "sendOwnedMessage" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("accountId"))
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversation = call.argument<String>("conversationId") ?: ""
                    val mime = call.argument<String>("mimeType") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    val reply = call.argument<String>("replyTo") ?: ""
                    val topic = call.argument<String>("topicId") ?: ""
                    val room = call.argument<String>("roomId") ?: ""
                    val operation = call.argument<String>("operationId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.sendOwnedMessage(scope, peer, conversation, mime, body, reply, topic, room, operation)
                    }) { result.success(it ?: "unknown") }
                }
                "sendOwnedReaction" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("accountId"))
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversation = call.argument<String>("conversationId") ?: ""
                    val message = call.argument<String>("messageId") ?: ""
                    val removed = call.argument<String>("removedId") ?: ""
                    val emoji = call.argument<String>("emoji") ?: ""
                    val topic = call.argument<String>("topicId") ?: ""
                    val room = call.argument<String>("roomId") ?: ""
                    val operation = call.argument<String>("operationId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.sendOwnedReaction(scope, peer, conversation, message, removed, emoji, topic, room, operation)
                    }) { result.success(it ?: "unknown") }
                }
                "sendOwnedFile" -> {
                    val scope = JamiCore.captureAccountScope(call.argument<String>("accountId"))
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversation = call.argument<String>("conversationId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val topic = call.argument<String>("topicId") ?: ""
                    val room = call.argument<String>("roomId") ?: ""
                    val media = call.argument<String>("media") ?: ""
                    val operation = call.argument<String>("operationId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.sendOwnedFile(scope, peer, conversation, path, name, topic, room, media, operation)
                    }) { result.success(it ?: "unknown") }
                }
                "acknowledgeFileSeed" -> {
                    val account = call.argument<String>("accountId") ?: ""
                    val scope = JamiCore.captureAccountScope(account)
                    val conversation = call.argument<String>("conversationId") ?: ""
                    val operation = call.argument<String>("operationId") ?: ""
                    val commit = call.argument<String>("commitId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.acknowledgeFileSeed(scope, conversation, operation, commit)
                    }) { result.success(it ?: false) }
                }
                "sendChatMessage" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    val replyTo = call.argument<String>("replyTo") ?: ""
                    val topicId = call.argument<String>("topicId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.sendChatMessage(peer, conversationId, body, replyTo, topicId)
                    }) { result.success(it.orEmpty().isNotEmpty()) }
                }
                "sendDmTopicEvent" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.sendDmTopicEvent(peer, conversationId, body)
                    }) { result.success(it.orEmpty()) }
                }
                "setMessageDisplayed" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val messageId = call.argument<String>("messageId") ?: ""
                    JamiCore.submit(DaemonOperation.SEND_CHAT_MESSAGE, block = {
                        JamiCore.setMessageDisplayed(peer, conversationId, messageId)
                    }) { result.success(it == true) }
                }
                "loadChat" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fromMessage = call.argument<String>("fromMessage") ?: ""
                    val n = call.argument<Int>("n") ?: 50
                    JamiCore.submit(DaemonOperation.LOAD_CHAT, block = {
                        JamiCore.loadChat(peer, conversationId, fromMessage, n)
                    }) { result.success(it ?: 0L) }
                }
                "searchHistory" -> {
                    val account = call.argument<String>("accountId") ?: ""
                    val scope = JamiCore.captureAccountScope(account)
                    JamiCore.searchHistory(scope,
                        call.argument<String>("peerJamiId") ?: "",
                        call.argument<String>("conversationId") ?: "",
                        call.argument<String>("query") ?: "",
                        call.argument<Int>("limit") ?: 0) { result.success(it) }
                }
                "loadSearchMessage" -> {
                    val account = call.argument<String>("accountId") ?: ""
                    JamiCore.loadSearchMessage(JamiCore.captureAccountScope(account),
                        call.argument<String>("peerJamiId") ?: "",
                        call.argument<String>("conversationId") ?: "",
                        call.argument<String>("messageId") ?: "") { result.success(it) }
                }
                "retireHistorySearch" -> {
                    val account = call.argument<String>("accountId") ?: ""
                    JamiCore.retireHistorySearch(JamiCore.captureAccountScope(account))
                    result.success(null)
                }
                "loadDmTopicState" -> {
                    val peer = call.argument<String>("peerJamiId") ?: ""
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    val fromMessage = call.argument<String>("fromMessage") ?: ""
                    val pageSize = call.argument<Int>("pageSize") ?: 200
                    JamiCore.submit(DaemonOperation.LOAD_CHAT, block = {
                        JamiCore.loadDmTopicState(
                            peer,
                            conversationId,
                            fromMessage,
                            pageSize,
                        )
                    }) { result.success(it ?: 0L) }
                }
                "cancelDmTopicStateLoad" -> {
                    val loadId = call.argument<Number>("loadId")?.toLong() ?: 0L
                    result.success(JamiCore.cancelDmTopicStateLoad(loadId))
                }
                "cancelChatLoad" -> {
                    val loadId = call.argument<Number>("loadId")?.toLong() ?: 0L
                    // Local correlation cancellation only: no libjami call is
                    // involved, so retire it synchronously before a late
                    // SwarmLoaded callback can claim the request.
                    result.success(JamiCore.cancelChatLoad(loadId))
                }
                "acceptConnect" -> {
                    val cid = call.argument<String>("conversationId") ?: ""
                    // Erase the pending entry SYNCHRONOUSLY (main thread) before queueing the daemon op, so a racing
                    // SetEventSink replay can't re-surface a request we're already accepting (the ghost-card race).
                    val pending = JamiCore.takePending(cid)
                    if (pending == null) {
                        result.error("request_not_pending", "Connection request is no longer pending", null)
                    } else {
                        submitCommand(
                            "acceptConnect", result, DaemonOperation.ACCEPT_CONNECT,
                            onFailure = { JamiCore.restorePending(cid, pending) },
                        ) {
                            JamiCore.acceptConnect(pending.accountId, cid, pending.from, pending.isGroup)
                        }
                    }
                }
                "declineConnect" -> {
                    val cid = call.argument<String>("conversationId") ?: ""
                    val pending = JamiCore.takePending(cid)
                    if (pending == null) {
                        result.error("request_not_pending", "Connection request is no longer pending", null)
                    } else {
                        submitCommand(
                            "declineConnect", result, DaemonOperation.DECLINE_CONNECT,
                            onFailure = { JamiCore.restorePending(cid, pending) },
                        ) {
                            JamiCore.declineConnect(pending.accountId, cid, pending.from, pending.isGroup)
                        }
                    }
                }
                "removeContact" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val ban = call.argument<Boolean>("ban") ?: false
                    JamiCore.submit(DaemonOperation.REMOVE_CONTACT, block = {
                        JamiCore.removeContact(uri, ban)
                    }) { result.success(it == true) }
                }
                "backupIdentity" -> {
                    val pass = call.argument<String>("passphrase") ?: ""
                    val settingsDocument = call.argument<String>("settingsDocument") ?: ""
                    val scope = JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))
                    if (scope?.accountId.isNullOrEmpty() || pendingBackupResult != null || pendingPickResult != null) {
                        // A backup is already in flight (the SAF Create-Document modal is up) —
                        // no-op the new caller so its MethodChannel.Result is answered (mirrors pickFile's guard).
                        result.success(false)
                    } else {
                        pendingBackupResult = result
                        pendingBackupScope = scope
                        // Export to a temp file on the worker, then let the user choose where to save it (SAF). The
                        // temp file holds the exported archive; we copy it to the chosen document + delete.
                        JamiCore.submit(DaemonOperation.EXPORT_IDENTITY, block = {
                            JamiCore.exportToTempFile(pass, settingsDocument, scope)
                        }) { tmp ->
                            if (pendingBackupResult !== result) {
                                if (tmp != null) cleanupTemp(tmp)
                                return@submit
                            }
                            if (tmp == null || !JamiCore.ownsAccountScope(scope)) {
                                if (tmp != null) cleanupTemp(tmp)
                                completeBackup(result, false)
                            } else {
                                pendingBackupTmp = tmp
                                val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE); type = "application/gzip"
                                    putExtra(Intent.EXTRA_TITLE, "sybl-identity-backup.gz")
                                }
                                try {
                                    startActivityForResult(i, CREATE_DOC_REQ)
                                } catch (e: Throwable) {
                                    logError("backupIdentity create-doc", e)
                                    cleanupTemp(tmp); pendingBackupTmp = null; completeBackup(result, false)
                                }
                            }
                        }
                    }
                }
                "resetDoorlight" -> {
                    val expected = call.argument<String>("expectedAccountId") ?: ""
                    JamiCore.start()
                    JamiCore.submit(DaemonOperation.RESTORE_IDENTITY, block = {
                        JamiCore.resetDoorlight(expected)
                    }) { result.success(it) }
                }
                "relaunchRetired" -> {
                    // A reset or a failed libjami init/start retires this process. The daemon worker and services
                    // keep it alive after the Activity closes, so "close and reopen" lands back on the retired engine.
                    if (JamiCore.retiredReason == null) {
                        result.error("relaunch_not_required", "Doorlight is not retired", null)
                    } else {
                        startActivity(Intent.makeRestartActivityTask(componentName))
                        Runtime.getRuntime().exit(0)
                    }
                }
                "restoreIdentity" -> {
                    val expectedOwner = call.argument<String>("expectedAccountId")
                    val scope = JamiCore.captureAccountScope()?.takeIf {
                        expectedOwner == null || it.accountId.orEmpty() == expectedOwner
                    }
                    val fp = call.argument<String>("filePath") ?: ""
                    val pass = call.argument<String>("passphrase") ?: ""
                    val profile = call.argument<String>("connectionProfile") ?: "jami"
                    val bootstrap = call.argument<String>("dhtBootstrap") ?: ""
                    val turnServer = call.argument<String>("turnServer") ?: ""
                    val turnRealm = call.argument<String>("turnRealm") ?: ""
                    val turnUser = call.argument<String>("turnUser") ?: ""
                    val turnPassword = call.argument<String>("turnPassword") ?: ""
                    val appearOffline = call.argument<Boolean>("appearOffline") ?: false
                    val expectedJamiId = call.argument<String>("expectedJamiId") ?: ""
                    JamiCore.submit(DaemonOperation.RESTORE_IDENTITY, block = {
                        JamiCore.restoreAccount(
                            fp,
                            pass,
                            profile,
                            bootstrap,
                            turnServer,
                            turnRealm,
                            turnUser,
                            turnPassword,
                            appearOffline,
                            expectedJamiId,
                            scope,
                        )
                    }) {
                        cleanupPickerCopy(fp)
                        result.success(it)
                    }
                }
                "devicePairing" -> {
                    val expected = call.argument<String>("expectedAccountId") ?: ""
                    val scope = JamiCore.captureAccountScope()?.takeIf { it.accountId.orEmpty() == expected }
                    val network = listOf("connectionProfile", "dhtBootstrap", "turnServer", "turnRealm", "turnUser", "turnPassword")
                        .associateWith { call.argument<String>(it) ?: "" }
                    JamiCore.devicePairingCommand(
                        call.argument<String>("action") ?: "", call.argument<String>("flowToken") ?: "",
                        call.argument<String>("accountId") ?: "", call.argument<String>("uri") ?: "",
                        call.argument<String>("code") ?: "", call.argument<String>("settingsDocument") ?: "",
                        network, call.argument<Boolean>("appearOffline") ?: false, scope,
                    ) { result.success(it) }
                }
                "getPendingIdentityRestore" -> {
                    JamiCore.start()
                    JamiCore.submit(DaemonOperation.RESTORE_IDENTITY, block = {
                        JamiCore.getPendingIdentityRestore()
                    }) {
                        if (it?.get("status") == "engineUnavailable" && JamiCore.retiredReason != null)
                            result.error("relaunch_required", "Restart Doorlight", JamiCore.retiredReason)
                        else result.success(it)
                    }
                }
                "discardIdentityRestore" -> {
                    val expected = call.argument<String>("expectedAccountId") ?: ""
                    val scope = JamiCore.captureAccountScope()?.takeIf { it.accountId.orEmpty() == expected }
                    val restoredAccount = call.argument<String>("accountId") ?: ""
                    val token = call.argument<String>("restoreToken") ?: ""
                    JamiCore.submit(DaemonOperation.RESTORE_IDENTITY, block = {
                        JamiCore.discardIdentityRestore(restoredAccount, token, scope)
                    }) { result.success(it) }
                }
                "finalizeIdentityRestore" -> {
                    val scope = JamiCore.captureAccountScope()
                    JamiCore.finalizeIdentityRestore(
                        call.argument<String>("accountId") ?: "",
                        call.argument<String>("restoreToken") ?: "",
                        call.argument<String>("settingsDocument") ?: "",
                        scope,
                    ) { result.success(it) }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Complete UI-critical commands only after their worker operation returns; surface failures to Dart. */
    private fun submitCommand(
        name: String,
        result: MethodChannel.Result,
        operation: DaemonOperation = DaemonOperation.GENERIC,
        callId: String? = null,
        onFailure: () -> Unit = {},
        block: () -> Unit,
    ) {
        JamiCore.submitCommand(operation, callId, block) { failure ->
            if (failure == null) {
                result.success(null)
            } else {
                onFailure()
                result.error("daemon_command_failed", "$name failed", null)
            }
        }
    }

    private fun hasMic() =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun emptyPlacement(): Map<String, Any> = mapOf("callId" to "", "cameraOn" to false)

    /** Complete the currently-owned backup result once; stale worker/copy callbacks become cleanup-only. */
    private fun completeBackup(result: MethodChannel.Result, ok: Boolean, residue: Boolean = false) {
        if (pendingBackupResult !== result) return
        pendingBackupResult = null
        backupCopyInFlight = false
        pendingBackupScope = null
        if (residue) result.error("backup_destination_cleanup_failed",
            "Backup failed. Delete the file at your chosen destination; it may contain your identity.", null)
        else result.success(ok)
    }

    private fun acquireMulticastLock(): Boolean = try {
        val lock = multicastLock ?: (applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager)
            ?.createMulticastLock("doorlight-nearby")
            ?.also { it.setReferenceCounted(false); multicastLock = it }
        if (lock != null && !lock.isHeld) lock.acquire()
        lock?.isHeld == true
    } catch (e: Throwable) {
        logError("acquireMulticastLock", e)
        false
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (e: Throwable) {
            logError("releaseMulticastLock", e)
        }
    }

    private fun requestRuntimePerms() {
        val want = mutableListOf<String>()
        if (!hasMic()) want.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            want.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (want.isNotEmpty()) requestPermissions(want.toTypedArray(), 1001)
    }

    // ---- video texture binding (M2): JamiCore.VideoBinder, all on the main thread ----

    private fun producerFor(role: JamiCore.VideoRole) =
        if (role == JamiCore.VideoRole.SELF) selfProducer else remoteProducer

    /** Get-or-create the persistent producer for [role]; apply an early bind if one arrived. Returns its texture id. */
    private fun ensureProducer(role: JamiCore.VideoRole): Long {
        producerFor(role)?.let { return it.id() }
        val p = renderer!!.createSurfaceProducer()
        if (role == JamiCore.VideoRole.SELF) selfProducer = p else remoteProducer = p
        val pending = if (role == JamiCore.VideoRole.SELF) pendingSelf else pendingRemote
        if (pending != null) {
            doBind(role, p, pending.first, pending.second, pending.third)
            if (role == JamiCore.VideoRole.SELF) pendingSelf = null else pendingRemote = null
        }
        return p.id()
    }

    override fun bindSink(role: JamiCore.VideoRole, sinkId: String, width: Int, height: Int) {
        val producer = producerFor(role)
        if (producer == null) {
            // texture-before-decode race: stash and bind when Dart creates the producer
            if (role == JamiCore.VideoRole.SELF) pendingSelf = Triple(sinkId, width, height)
            else pendingRemote = Triple(sinkId, width, height)
            return
        }
        doBind(role, producer, sinkId, width, height)
    }

    private fun doBind(role: JamiCore.VideoRole, producer: TextureRegistry.SurfaceProducer, sinkId: String, w: Int, h: Int) {
        producer.setSize(w, h)
        val boundId = if (role == JamiCore.VideoRole.SELF) selfBoundId else remoteBoundId
        val curWin = if (role == JamiCore.VideoRole.SELF) selfWin else remoteWin
        if (boundId == sinkId && curWin != -1L) {
            JamiServiceJNI.setNativeWindowGeometry(curWin, w, h)   // same sink, new geometry
            return
        }
        if (boundId != null && curWin != -1L) releaseRole(role)    // bound to a different sink → drop first
        val win = JamiServiceJNI.acquireNativeWindow(producer.surface)
        // JNI returns the pointer bits in a signed jlong. arm64 native-window addresses commonly have the high bit
        // set and therefore compare negative in Kotlin; only the null pointer is an acquisition failure.
        if (!hasNativeWindow(win)) {
            logError("failed to acquire native window for $role")
            return
        }
        val ok = try {
            JamiServiceJNI.setNativeWindowGeometry(win, w, h)
            JamiService.registerVideoCallback(sinkId, win)
        } catch (e: Throwable) {
            logError("failed to register $role video sink", e)
            false
        }
        if (!ok) {
            // Do not retain an acquired native window that the daemon refused to bind; no decodingStopped callback
            // is guaranteed for a registration that never succeeded.
            try { JamiServiceJNI.releaseNativeWindow(win) } catch (_: Throwable) {}
            logError("failed to bind $role sink '$sinkId' win=$win ${w}x$h")
            return
        }
        if (role == JamiCore.VideoRole.SELF) { selfWin = win; selfBoundId = sinkId }
        else { remoteWin = win; remoteBoundId = sinkId }
        logInfo("bound $role sink '$sinkId' win=$win ok=$ok ${w}x$h")
    }

    override fun unbindSink(role: JamiCore.VideoRole, sinkId: String) {
        // Only release if the stopped sink is the one CURRENTLY bound to this role. A late decodingStopped for
        // an old sink (quick toggle / renegotiation) must not tear down a freshly-bound window.
        val bound = if (role == JamiCore.VideoRole.SELF) selfBoundId else remoteBoundId
        if (sinkId == bound) releaseRole(role)
        else logInfo("ignore stale unbind $role '$sinkId' (bound='$bound')")
        // Drop a stale pending bind for the same sink so it can't attach to a producer later.
        if (role == JamiCore.VideoRole.SELF) { if (pendingSelf?.first == sinkId) pendingSelf = null }
        else { if (pendingRemote?.first == sinkId) pendingRemote = null }
    }

    override fun releaseSink(role: JamiCore.VideoRole) {
        if (role == JamiCore.VideoRole.SELF) pendingSelf = null else pendingRemote = null
        releaseRole(role)
    }

    override fun releaseAll() {
        pendingSelf = null
        pendingRemote = null
        releaseRole(JamiCore.VideoRole.SELF)
        releaseRole(JamiCore.VideoRole.REMOTE)
    }

    override fun prepareProjectionPreview(
        width: Int,
        height: Int,
        onReady: (Surface?) -> Unit,
    ) {
        val activeRenderer = renderer
        if (activeRenderer == null) {
            onReady(null)
            return
        }
        val producer = selfProducer ?: activeRenderer.createSurfaceProducer().also {
            selfProducer = it
        }
        // A screen source replaces the camera's daemon-owned self sink. The
        // producer itself remains stable, so Dart keeps the same texture id.
        releaseRole(JamiCore.VideoRole.SELF)
        producer.setSize(width, height)
        onReady(producer.surface)
    }

    private fun releaseRole(role: JamiCore.VideoRole) {
        val win = if (role == JamiCore.VideoRole.SELF) selfWin else remoteWin
        val boundId = if (role == JamiCore.VideoRole.SELF) selfBoundId else remoteBoundId
        try { if (boundId != null && win != -1L) JamiServiceJNI.unregisterVideoCallback(boundId, win) } catch (_: Throwable) {}
        try { if (win != -1L) JamiServiceJNI.releaseNativeWindow(win) } catch (_: Throwable) {}
        if (role == JamiCore.VideoRole.SELF) { selfWin = -1L; selfBoundId = null }
        else { remoteWin = -1L; remoteBoundId = null }
    }

    private fun hasCamera() =
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun startCameraSource(callId: String, result: MethodChannel.Result) {
        if (hasCamera()) {
            val deg = displayRotationDeg()
            JamiCore.submit(DaemonOperation.START_VIDEO, callId, {
                JamiCore.startVideo(callId, deg)
            }) {
                if (activityDestroyed) {
                    if (it == true) cleanupStaleVideoStart(callId)
                    result.success(false)
                } else {
                    result.success(it ?: false)
                }
            }
            return
        }
        if (pendingStartVideo != null) {
            result.success(false)
            return
        }
        pendingStartVideo = Pair(callId, result)
        try {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_REQ)
        } catch (e: Throwable) {
            logError("startVideo camera permission", e)
            pendingStartVideo = null
            result.success(false)
        }
    }

    private fun beginScreenShare(callId: String, result: MethodChannel.Result) {
        if (pendingScreen != null || callId.isEmpty()) {
            result.success(false)
            return
        }
        JamiCore.submit(DaemonOperation.START_VIDEO, callId, {
            JamiCore.reserveScreenConsent(callId)
        }) { epoch ->
            val token = epoch ?: -1L
            if (token < 0L || activityDestroyed) {
                if (token >= 0L) JamiCore.cancelScreenConsent(callId, token)
                result.success(false)
                return@submit
            }
            pendingScreen = PendingScreen(callId, token, result)
            try {
                val manager = getSystemService(
                    MEDIA_PROJECTION_SERVICE,
                ) as MediaProjectionManager
                val intent = if (Build.VERSION.SDK_INT >= 34) {
                    manager.createScreenCaptureIntent(
                        MediaProjectionConfig.createConfigForDefaultDisplay(),
                    )
                } else {
                    manager.createScreenCaptureIntent()
                }
                startActivityForResult(intent, SCREEN_SHARE_REQ)
            } catch (e: Throwable) {
                pendingScreen = null
                JamiCore.cancelScreenConsent(callId, token)
                logError("screen capture consent", e)
                result.success(false)
            }
        }
    }

    private fun displayRotationDeg(): Int {
        val rot = if (Build.VERSION.SDK_INT >= 30) display?.rotation ?: Surface.ROTATION_0
                  else @Suppress("DEPRECATION") windowManager.defaultDisplay.rotation
        return when (rot) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        JamiCore.setDisplayRotation(displayRotationDeg())
        updateRemoteControlDisplayGeometry()
        val metrics = screenCaptureMetrics()
        JamiCore.resizeScreenShare(
            metrics.first,
            metrics.second,
            metrics.third,
        )
    }

    private fun captureProtectionEnabled(): Boolean = captureProtectionPreference {
        getSharedPreferences(PRIVACY_PREFS, MODE_PRIVATE)
            .all[CAPTURE_PROTECTION]
    }

    /** Applies the preference and surface scope; returns whether the window is now secure. */
    private fun applyCaptureProtection(): Boolean {
        val enabled = captureProtectionEnabled()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(!enabled)
        val secure = enabled && (!captureScopedToSurfaces || sensitiveSurfaceVisible)
        if (secure) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        return (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
    }

    // Reports the armed protection, not the momentary flag: with surface scoping the flag is legitimately clear
    // while no sensitive surface is visible.
    private fun captureProtectionStatus(): String {
        val flagged = (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
        val armed = if (captureScopedToSurfaces) captureProtectionEnabled() else flagged
        return if (armed) "exclude" else "none"
    }

    override fun onResume() {
        super.onResume()
        JamiCore.setActivityResumed(true)
        gravitySensor.setResumed(true)
        updateRemoteControlDisplayGeometry()
    }

    override fun onPause() {
        nearbyRadio?.stop()
        JamiCore.setActivityResumed(false)
        gravitySensor.setResumed(false)
        super.onPause()
    }

    private fun updateRemoteControlDisplayGeometry() {
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val metrics = windowManager.maximumWindowMetrics
                val bounds = metrics.bounds
                JamiCore.updateRemoteControlDisplayGeometry(
                    bounds.width(),
                    bounds.height(),
                    remoteControlGestureBounds(bounds.width(), bounds.height()),
                )
            } else {
                @Suppress("DEPRECATION")
                val metrics = android.util.DisplayMetrics().also {
                    windowManager.defaultDisplay.getRealMetrics(it)
                }
                JamiCore.updateRemoteControlDisplayGeometry(
                    metrics.widthPixels,
                    metrics.heightPixels,
                    remoteControlGestureBounds(metrics.widthPixels, metrics.heightPixels),
                )
            }
        } catch (e: Throwable) {
            logError("remote control display geometry", e)
            JamiCore.updateRemoteControlDisplayGeometry(0, 0, Rect())
        }
    }

    private fun remoteControlGestureBounds(width: Int, height: Int): Rect {
        val (left, top, right, bottom) =
            AndroidRemoteControlPolicy.fullDisplayGestureBounds(width, height)
        return Rect(left, top, right, bottom)
    }

    private fun screenCaptureMetrics(): Triple<Int, Int, Int> {
        val density = resources.configuration.densityDpi
        if (Build.VERSION.SDK_INT >= 30) {
            val bounds = windowManager.maximumWindowMetrics.bounds
            return Triple(bounds.width(), bounds.height(), density)
        }
        @Suppress("DEPRECATION")
        val metrics = android.util.DisplayMetrics().also {
            windowManager.defaultDisplay.getRealMetrics(it)
        }
        return Triple(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (nearbyRadio?.onRequestPermissionsResult(requestCode) == true) return
        if (requestCode == CAMERA_REQ) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            val pending = pendingStartVideo
            if (granted && pending != null) {
                val deg = displayRotationDeg()
                JamiCore.submit(DaemonOperation.START_VIDEO, pending.first, {
                    JamiCore.startVideo(pending.first, deg)
                }) {
                    if (pendingStartVideo === pending) {
                        pendingStartVideo = null
                        pending.second.success(it ?: false)
                    } else if (it == true) {
                        cleanupStaleVideoStart(pending.first)
                    }
                }
            } else if (pending != null && pendingStartVideo === pending) {
                pendingStartVideo = null
                pending.second.success(false)
            }
        } else if (requestCode == PLACE_VIDEO_REQ) {
            // place-with-video: place either way — with video if granted, audio-only if denied.
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            val p = pendingPlace
            if (p != null) {
                val deg = displayRotationDeg()
                JamiCore.submit(DaemonOperation.PLACE_CALL, block = {
                    JamiCore.placeCall(p.peerId, granted, deg, p.initialAudioMuted)
                }) {
                    if (pendingPlace === p) {
                        pendingPlace = null
                        p.result.success(it ?: emptyPlacement())
                    } else {
                        cleanupStalePlacement(it)
                    }
                }
            }
        }
    }

    // ---- file picking (M5): ACTION_OPEN_DOCUMENT → copy the content URI to persistent app-private outgoing
    // storage (sendFile needs a filesystem path and delayed/history downloads need the source to remain seedable). ----

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SCREEN_SHARE_REQ) {
            val pending = pendingScreen ?: return
            if (resultCode != Activity.RESULT_OK || data == null || activityDestroyed) {
                pendingScreen = null
                JamiCore.cancelScreenConsent(pending.callId, pending.epoch)
                pending.result.success(false)
                return
            }
            val metrics = screenCaptureMetrics()
            JamiCore.submit(DaemonOperation.START_VIDEO, pending.callId, {
                JamiCore.startScreenShare(
                    pending.callId,
                    pending.epoch,
                    resultCode,
                    data,
                    metrics.first,
                    metrics.second,
                    metrics.third,
                )
            }) {
                if (pendingScreen === pending && !activityDestroyed) {
                    pendingScreen = null
                    pending.result.success(it ?: false)
                } else if (it == true) {
                    cleanupStaleVideoStart(pending.callId)
                }
            }
            return
        }
        if (requestCode == CREATE_DOC_REQ) {
            // Identity backup (M7.5 a): copy the temporary archive to the user-chosen document, then delete it.
            // The result stays owned across the copy; only the temp path is consumed here.
            val tmp = pendingBackupTmp; pendingBackupTmp = null
            val res = pendingBackupResult
            if (tmp == null || res == null) { tmp?.let { cleanupTemp(it) }; return }
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null || activityDestroyed ||
                !JamiCore.ownsAccountScope(pendingBackupScope)) {
                val residue = if (resultCode == RESULT_OK && uri != null) {
                    cleanupBackupDestination(uri) == IdentityDocumentExportResult.RESIDUE
                } else false
                cleanupTemp(tmp); completeBackup(res, false, residue); return
            }
            backupCopyInFlight = true
            val scope = pendingBackupScope
            try {
                Thread {
                    val outcome = copyFileToUri(tmp, uri) {
                        !activityDestroyed && JamiCore.ownsAccountScope(scope)
                    }
                    cleanupTemp(tmp)
                    runOnUiThread {
                        if (outcome == IdentityDocumentExportResult.SAVED &&
                            (activityDestroyed || !JamiCore.ownsAccountScope(scope))) {
                            try {
                                Thread {
                                    val cleaned = cleanupBackupDestination(uri)
                                    runOnUiThread { completeBackup(res, false,
                                        cleaned == IdentityDocumentExportResult.RESIDUE) }
                                }.start()
                            } catch (_: Throwable) {
                                val cleaned = cleanupBackupDestination(uri)
                                completeBackup(res, false, cleaned == IdentityDocumentExportResult.RESIDUE)
                            }
                        } else completeBackup(res,
                            outcome == IdentityDocumentExportResult.SAVED,
                            outcome == IdentityDocumentExportResult.RESIDUE)
                    }
                }.start()
            } catch (e: Throwable) {
                logError("backupIdentity copy thread", e)
                val residue = cleanupBackupDestination(uri) == IdentityDocumentExportResult.RESIDUE
                cleanupTemp(tmp); completeBackup(res, false, residue)
            }
            return
        }
        if (requestCode != PICK_FILE_REQ) return
        val r = pendingPickResult
        val maxBytes = pendingPickMaxBytes
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            if (r != null && pendingPickResult === r) {
                pendingPickResult = null
                pendingPickMaxBytes = MAX_PICK_COPY_BYTES
                r.success(null)
            }
            return
        }
        // Copy off the main thread (a large file would jank the UI); reply on the UI thread.
        try {
            Thread {
                val path = copyToOutgoingStore(uri, maxBytes)
                runOnUiThread {
                    if (r != null && pendingPickResult === r) {
                        pendingPickResult = null
                        pendingPickMaxBytes = MAX_PICK_COPY_BYTES
                        r.success(path)
                    } else if (path != null) {
                        cleanupPickerCopy(path)
                    }
                }
            }.start()
        } catch (e: Throwable) {
            logError("pickFile copy thread", e)
            if (r != null && pendingPickResult === r) {
                pendingPickResult = null
                pendingPickMaxBytes = MAX_PICK_COPY_BYTES
                r.success(null)
            }
        }
    }

    private fun copyToOutgoingStore(uri: Uri, maxBytes: Long): String? = try {
        // Keep the handoff outside cacheDir so Android cannot purge it before libjami emits CREATED/INVALID.
        val dir = File(filesDir, "outgoing").apply { mkdirs() }
        if (!dir.isDirectory) return null
        // The generated directory is atomically reserved by the filesystem. It prevents overlapping Activity
        // instances from choosing/truncating the same name while preserving the original leaf for recipients.
        val stage = Files.createTempDirectory(dir.toPath(), "picked-").toFile()
        val dest = File(stage, safeOutgoingLeaf(queryName(uri) ?: "file"))
        var complete = false
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                if (!copyBoundedToFile(input, dest, maxBytes)) return null
            } ?: return null
            complete = true
            dest.absolutePath
        } finally {
            if (!complete) {
                dest.delete()
                stage.delete()
            }
        }
    } catch (e: Throwable) { logError("copyToCache", e); null }

    private fun safeOutgoingLeaf(name: String): String {
        var leaf = name.substringAfterLast('/').substringAfterLast('\\')
            .filter { it >= ' ' && it != '\u007f' }
            .trim()
        if (leaf.isEmpty() || leaf == "." || leaf == "..") leaf = "file"
        if (leaf.length > 200) leaf = leaf.take(200).trim().ifEmpty { "file" }
        return leaf
    }

    private fun queryName(uri: Uri): String? = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    } catch (_: Throwable) { null }

    // ---- identity backup (M7.5 a): copy the temp export → the SAF document the user picked, then clean up ----

    private fun openReceivedFile(path: String): Boolean = try {
        val file = openableReceivedFile(filesDir, getExternalFilesDir(null), path) ?: return false
        val mime = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
        )
        true
    } catch (e: Throwable) {
        logError("openReceivedFile", e)
        false
    }

    private fun deleteBackupDestination(uri: Uri): Boolean =
        android.provider.DocumentsContract.deleteDocument(contentResolver, uri)

    private fun truncateBackupDestination(uri: Uri): Boolean {
        contentResolver.openOutputStream(uri, "wt")?.use { it.flush() } ?: return false
        return contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize == 0L } == true
    }

    private fun cleanupBackupDestination(uri: Uri) = IdentityDocumentExport.cleanup(
        { deleteBackupDestination(uri) }, { truncateBackupDestination(uri) })

    private var backupCopyInFlight = false

    private fun copyFileToUri(path: String, uri: Uri, current: () -> Boolean) = IdentityDocumentExport.copy(
        { File(path).inputStream() }, { contentResolver.openOutputStream(uri, "wt") },
        { deleteBackupDestination(uri) }, { truncateBackupDestination(uri) }, current)

    private fun cleanupTemp(path: String) { try { File(path).delete() } catch (_: Throwable) {} }

    /** An operation owned by a destroyed Activity must not leave a headless call/camera behind. */
    private fun cleanupStalePlacement(outcome: Map<String, Any?>?) {
        val callId = outcome?.get("callId") as? String ?: ""
        if (callId.isNotEmpty()) JamiCore.submit(DaemonOperation.HANG_UP, callId, {
            JamiCore.hangUp(callId); null
        }) {}
    }

    private fun cleanupStaleVideoStart(callId: String) {
        if (callId.isNotEmpty()) JamiCore.submit(DaemonOperation.STOP_VIDEO, callId, {
            JamiCore.stopVideo(callId); null
        }) {}
    }

    /** Delete only a picker copy inside its generated app-private staging directory. */
    private fun cleanupPickerCopy(path: String) {
        JamiCore.discardUnissuedStage(path)
    }
}
