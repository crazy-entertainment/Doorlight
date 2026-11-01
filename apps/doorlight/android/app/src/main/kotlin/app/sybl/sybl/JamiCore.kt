package app.sybl.sybl

import com.llfbandit.record.SybLRecordingBridge

import org.json.JSONObject

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.ImageFormat
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log as AndroidLog
import android.util.Size
import android.view.Surface
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.FirebaseApp
import com.google.firebase.installations.FirebaseInstallations
import io.flutter.plugin.common.EventChannel
import net.jami.daemon.Blob
import net.jami.daemon.Callback
import net.jami.daemon.ConfigurationCallback
import net.jami.daemon.ConversationCallback
import net.jami.daemon.DataTransferCallback
import net.jami.daemon.IntVect
import net.jami.daemon.JamiService
import net.jami.daemon.NetworkServiceCallback
import net.jami.daemon.CurrentMediaListAdapter
import net.jami.daemon.PresenceCallback
import net.jami.daemon.StringMap
import net.jami.daemon.StringVect
import net.jami.daemon.SwarmMessage
import net.jami.daemon.SwarmMessageVect
import net.jami.daemon.UintVect
import net.jami.daemon.VectMap
import net.jami.daemon.VideoCallback
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Process-singleton owner of the libjami daemon for M1 (1:1 voice).
 *
 * Contract:
 *  - the daemon is booted once ([start]) and lives for the app's lifetime;
 *  - MethodChannel control operations run on one worker ([worker]), which guarantees ensureAccount/placeCall
 *    execute after init; camera frames enter on [camHandler], and a few callback-side queries run on daemon threads;
 *  - EVERY daemon callback arrives on a daemon thread and is marshaled to the main looper before it
 *    touches the Flutter EventChannel ([emit]).
 *
 * Audio is daemon-owned on Android (AAudioLayer) — there is no PCM here; we only hold the mic permission,
 * route audio ([CallAudioController]) and drive the foreground online/call lifetime ([CallForegroundService]).
 */
private const val TAG = "SybL"
private const val BACKGROUND_WAKE_PREFS = "background-wake"
private const val BACKGROUND_WAKE_REQUESTED = "requested"
private const val BACKGROUND_WAKE_PROFILE = "connection-profile"
private const val BACKGROUND_WAKE_RELAY_URL = "relay-url"
private const val BACKGROUND_WAKE_REGISTERED = "registered"
private const val SCREEN_DEVICE_ID = "desktop"
private const val SCREEN_MRL = "camera://desktop"
private const val SCREEN_FPS = 24
private const val SCREEN_BITRATE_BPS = 192 * 8 * 1024
private const val SCREEN_START_TIMEOUT_MS = 5_000L

/** Release logcat must not retain stable identities, peer ids, paths, or untrusted names. */
private object Log {
    fun i(tag: String, message: String): Int =
        if (JamiCore.debugBuild) AndroidLog.i(tag, message) else 0
    fun w(tag: String, message: String): Int =
        AndroidLog.w(tag, if (JamiCore.debugBuild) message else "native warning")
    fun e(tag: String, message: String): Int =
        AndroidLog.e(tag, if (JamiCore.debugBuild) message else "native operation failed")
    fun e(tag: String, message: String, error: Throwable): Int =
        if (JamiCore.debugBuild) AndroidLog.e(tag, message, error)
        else AndroidLog.e(tag, "native operation failed")
}

/** MIME under which Syb-L's in-call side-channel JSON (M8 annotation draw events) travels — a custom type so it
 *  passes straight through to CallSignal::IncomingMessage (not intercepted like confInfo/vcard) and is never
 *  confused with any other in-call message. Mirrored on the Windows bridge (kAnnotMime). */
private const val ANNOT_MIME = "application/x-sybl-annotate"
private const val CONTROL_MIME = "application/x-sybl-control"
private const val MAX_TYPED_CALL_MESSAGE_BYTES = AndroidRemoteControlProtocol.MAX_PACKET_BYTES
// The custom MIME for the presence ping/pong (presence v2). A non-swarm account message with this type is never
// committed to git. Payload = {"t":"ping"|"pong","fg":0|1,"ts":<sender ms>}: a ping is auto-answered NATIVELY
// (incomingAccountMessage → pong) so a backgrounded phone still proves liveness while Dart is frozen; the fg flag
// tells the peer in-app (green) vs merely reachable (dim). Mirrored on the Windows bridge.
internal const val PROBE_MIME = "application/x-sybl-presence"
internal const val FILE_THUMBNAIL_MIME = "application/x-sybl-file-thumbnail"
internal const val FILE_DECLINED_MIME = "application/x-sybl-file-declined"
internal const val CALL_REQUEST_MIME = "application/x-sybl-call-request"
internal const val ACTION_ACCEPT_INCOMING_CALL = "app.sybl.sybl.ACCEPT_INCOMING_CALL"
internal const val ACTION_DECLINE_INCOMING_CALL = "app.sybl.sybl.DECLINE_INCOMING_CALL"
internal const val ACTION_IGNORE_INCOMING_CALL = "app.sybl.sybl.IGNORE_INCOMING_CALL"
internal const val EXTRA_INCOMING_CALL_ID = "incomingCallId"

object JamiCore {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var activityResumed = false
    private const val WORKER_TRACE_TAG = "SybLWorker"
    private val diagnosticCallTokens = DiagnosticCallTokens()
    private val controlMessageAdmission = ControlMessageAdmission()
    private val workerTracker = DiagnosticTaskTracker("worker", sink = ::traceDiagnostic)
    private val callSignalTracker = DiagnosticTaskTracker("call-signal", sink = ::traceDiagnostic)
    private val worker = ObservedSerialExecutor(
        delegate = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "sybl-daemon-worker")
        },
        tracker = workerTracker,
        enabled = ::diagnosticsEnabled,
        nowMs = ::monotonicMs,
    )
    private val conferenceInfoIngress = ConferenceInfoIngress(
        schedule = { task -> main.postDelayed(task, 100L) },
        dispatch = { task -> worker.execute(DaemonOperation.READ_PEER) { task.run() } },
    )
    // The foreground service can outlive every Activity, so the application owns one process-lifetime callback.
    // A newly available default network is the point at which libjami must discard stale DHT/ICE state.
    private val defaultNetworkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            worker.execute(DaemonOperation.GENERIC) {
                if (started) connectivitySweep()
            }
        }
    }
    private val diagnosticWatchdog = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "sybl-diagnostic-watchdog").apply { isDaemon = true }
    }.apply {
        scheduleWithFixedDelay({ pollDiagnosticStalls() }, 1L, 1L, TimeUnit.SECONDS)
    }
    // Channel behavior is immutable after first creation. v2 deliberately replaces the original quiet
    // notification channel with ringtone audio + vibration for an actual incoming-call alert.
    private const val INCOMING_CALL_CHANNEL = "sybl_incoming_call_v2"
    private const val INCOMING_CALL_NOTIFICATION_BASE = 0x53420000
    private const val MAX_ARCHIVE_PASSPHRASE_CHARS = 1024
    /** Callback threads may deliver a final state before an older CURRENT/ring callback. Keep a small bounded
     * history so those overtaken callbacks cannot recreate calls; live/tombstoned calls remain owned elsewhere. */
    private const val RECENT_TERMINAL_CALL_LIMIT = 64

    /** Process-lifetime libjami phases are separate from retryable post-start boot reconciliation. */
    @Volatile private var daemonInitAttempted = false
    @Volatile private var daemonInitSucceeded = false
    @Volatile private var daemonStartAttempted = false
    @Volatile private var daemonStartSucceeded = false
    /** True only after the complete daemon boot transaction succeeds. */
    @Volatile private var started = false
    @Volatile private var resetDoorlightPending = false
    /** Why this process can never boot again, or null. Leaving the Activity does not end it, so Dart relaunches. */
    internal val retiredReason: String? get() = when {
        resetDoorlightPending -> "reset"
        daemonInitAttempted && !daemonInitSucceeded || daemonStartAttempted && !daemonStartSucceeded -> "engine"
        else -> null
    }
    private fun resetDoorlightMarker(): String? {
        val preferences = appContext.getSharedPreferences(
            CanonicalIncomingCallMicrophonePolicy.PREFERENCES_NAME, Context.MODE_PRIVATE)
        val value = preferences.all["flutter.resetDoorlight.pending.v1"] ?: return null
        check(value is String && value.isNotEmpty() && value.length <= 128) { "Invalid reset ownership" }
        return value
    }
    private val deviceRevocations = DeviceRevocationRegistry()
    private var deviceRevocationTimerReady = true
    private val deviceRevocationCheck = Runnable { drainDeviceRevocations() }
    @Volatile internal var accountId: String? = null
        set(value) {
            field = value
            deviceRevocations.selectAccount(value)
            main.post(deviceRevocationCheck)
        }
    private val accountAuthority = NativeAccountAuthority()
    private val messagingCaptureAuthority = MessagingCaptureAuthority(accountAuthority::owns)
    internal fun beginMessagingCapture(expectedAccountId: String) =
        messagingCaptureAuthority.begin(accountAuthority.capture(expectedAccountId))
    internal fun ownsMessagingCapture(lease: MessagingCaptureLease) =
        messagingCaptureAuthority.owns(lease) && !identityRestoreCommitting && pendingIdentityRestore == null
    internal fun retireMessagingCapture(lease: MessagingCaptureLease) = messagingCaptureAuthority.retire(lease)
    private data class RecordingOwner(val capture: MessagingCaptureLease, val peer: String,
                                      val conversation: String, val directory: File)

    internal fun configureRecordingBridge() {
        SybLRecordingBridge.configure(current = { value ->
            val owner = value as? RecordingOwner
            owner != null && ownsMessagingCapture(owner.capture) && keepOnline && activityResumed &&
                appContext.getSystemService(android.app.KeyguardManager::class.java)?.isDeviceLocked == false &&
                !identityRestoreRecoveryFailed && routingSnapshot.owns(owner.peer, owner.conversation)
        }, released = { value ->
            (value as? RecordingOwner)?.let {
                retireMessagingCapture(it.capture)
                // Only succeeds for an empty, never-written/cancelled stage.
                // Recorded reviews and issued file stages remain untouched.
                it.directory.delete()
            }
        })
    }

    internal fun prepareVoiceRecording(account: String, peer: String, conversation: String): String? {
        val owner = normalizeOwnerKey(peer)
        if (!keepOnline || !activityResumed || !routingSnapshot.owns(owner, conversation)) return null
        val capture = beginMessagingCapture(account) ?: return null
        var stage: File? = null
        try {
            val root = File(appContext.filesDir, "outgoing").apply { mkdirs() }
            stage = java.nio.file.Files.createTempDirectory(root.toPath(), "picked-").toFile()
            val output = File(stage, "voice.m4a")
            if (!output.createNewFile() || !::stageRegistry.isInitialized ||
                !stageRegistry.reserveRecording(output.absolutePath)) {
                output.delete()
                throw IllegalStateException("recording recovery unavailable")
            }
            if (SybLRecordingBridge.offer(RecordingOwner(capture, owner, conversation, stage), output.absolutePath)) {
                return output.absolutePath
            }
        } catch (_: Exception) { }
        stage?.delete()
        retireMessagingCapture(capture)
        return null
    }

    private fun stopRecorderBeforeCall(): Boolean = try {
        SybLRecordingBridge.revoke().get(3, java.util.concurrent.TimeUnit.SECONDS)
    } catch (_: Exception) {
        // A timeout/error is not a hardware-release acknowledgement.
        false
    }
    private val ownedMessageOperations = OwnedMessageOperations()
    private val messageActions = MessageActionTokens()
    private val ownedFileOperations = OwnedFileOperations()
    private lateinit var stageRegistry: StageRegistry

    private fun initializeStageRegistry() {
        val store = KeystoreSealedStore("sybl_stages_v1", "sybl_stages_v1")
        val source = try { store.load(appContext)?.toString(Charsets.UTF_8) } catch (_: Throwable) { "corrupt" }
        stageRegistry = StageRegistry(source) { value ->
            store.save(appContext, value.toByteArray(Charsets.UTF_8)) &&
                store.load(appContext)?.toString(Charsets.UTF_8) == value
        }
        if (!stageRegistry.healthy) return
        val root = File(appContext.filesDir, "outgoing")
        for (record in stageRegistry.records()) {
            if (record.recording && !record.issued &&
                (!File(record.path).exists() || deleteOwnedPickerStagingFile(root, File(record.path)))) {
                if (!stageRegistry.forget(record.path)) return
            }
        }
    }

    internal fun discardUnissuedStage(path: String): Boolean {
        if (!::stageRegistry.isInitialized) return false
        return synchronized(stageRegistry) {
            !stageRegistry.ownsIssued(path) &&
                (!File(path).exists() || deleteOwnedPickerStagingFile(File(appContext.filesDir, "outgoing"), File(path))) &&
                stageRegistry.forget(path)
        }
    }

    internal fun captureAccountScope(expectedAccountId: String? = null) = accountAuthority.capture(expectedAccountId)
    internal fun ownsAccountScope(scope: NativeAccountScope?) = accountAuthority.owns(scope)

    internal fun invokeAccountCommand(scope: NativeAccountScope?, action: () -> Unit) =
        accountAuthority.invoke(scope, action)

    internal lateinit var appContext: Context
    internal val debugBuild: Boolean
        get() = ::appContext.isInitialized &&
            (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private var audio: CallAudioController? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile internal var lastRegistration: String? = null
    private val registrationByAccount = ConcurrentHashMap<String, String>()
    private val announcedByAccount = ConcurrentHashMap<String, Boolean>()
    // The libjami master-identity archive is protected with a random device
    // secret sealed by Android Keystore. This is separate from the recovery
    // journal used for crash-safe migration/restore re-keying. Neither mechanism
    // encrypts libjami's live device key, swarm repositories, or received
    // files; Android app-private storage/FBE and the app lock own those wider
    // boundaries.
    @Volatile internal var archiveSecret = ""
    @Volatile private var archiveRecoveryBlocked = false
    @Volatile private var archiveProtectionReady = false
    @Volatile private var pendingIdentityRestore: IdentityRestoreRecord? = null
        set(value) {
            field = value
            if (value != null) messageActions.clear()
            MessageNotifications.setIdentityRestorePending(value != null)
        }
    @Volatile private var identityRestoreRecoveryFailed = false
    private var pendingIdentityRestoreOwner: NativeAccountScope? = null
    @Volatile private var identityRestoreCommitting = false
    @Volatile private var preparedNetworkOwner: NativeAccountScope? = null
    @Volatile private var activeCallId: String? = null
        set(value) {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.DIRECT, value != null)
            field = value
        }
    @Volatile private var activeGroupConferenceId: String? = null
        set(value) {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.GROUP, value != null)
            field = value
        }
    @Volatile private var activeGroupHosting = false
    @Volatile private var pendingGroupConferenceId: String? = null
        set(value) {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.GROUP_PENDING, value != null)
            field = value
        }
    @Volatile private var groupReservationId: String? = null
    private val retiredGroupLegs = ConcurrentHashMap<String, NativeAccountScope>()
    @Volatile private var groupPlacementStarted = false
    private val detachedGroupReservations = LinkedHashMap<Pair<String, String>, NativeAccountScope>()
    private val groupCallLegs = ConcurrentHashMap<String, String>()
    private val groupConversationByConference = ConcurrentHashMap<String, String>()
    private val previousGroupHostPreference = ConcurrentHashMap<String, String?>()
    @Volatile private var previousGroupPlaybackVolume: Double? = null
    // The first admitted trusted-friend call to reach CURRENT. Unlike activeCallId, this is never merely ringing/placing
    // leg. Guarded by callLifecycleLock so concurrent daemon callbacks cannot both claim media/UI ownership.
    @Volatile private var currentWinnerCallId: String? = null
    private val callPeers = ConcurrentHashMap<String, String>()
    private val rejectedCallIds = ConcurrentHashMap.newKeySet<String>()
    // Online is the user's account choice. With push disabled it owns the persistent service. With push enabled,
    // Home, lock, and task dismissal can sleep the account without changing this choice.
    @Volatile private var keepOnline = false
    @Volatile private var backgroundWakeRetryKey = Any()
    private val backgroundWakeActivity: BackgroundWakeAccountActivity by lazy {
        BackgroundWakeAccountActivity(
            worker = { action -> worker.execute(DaemonOperation.SET_BACKGROUND_WAKE) { action() } },
            main = { action -> main.post { action() } },
            setActive = { owner, active ->
                setWakeAccountActive(owner, active)
                if (active) runCatching { JamiService.connectivityChanged() }
            },
            changed = ::applyBackgroundWakeLifetime,
        )
    }
    @Volatile private var wakeRegistrationInstance: WakeRegistration? = null
    private var backgroundAtMs: Long? = null
    private var messagePushAtMs: Long? = null
    private var callPushAtMs: Long? = null
    private var taskRemovedWithPush = false
    private val backgroundWakeCheck = Runnable { applyBackgroundWakeLifetime() }
    private val callLifecycleLock = Any()
    private val callSignalDispatchLock = Any()
    private val recentTerminalCallIds = LinkedHashSet<String>() // guarded; bounded callback-overtake memory
    @Volatile private var placingOutgoing = false // guarded by callLifecycleLock; volatile for lock-free diagnostics
        set(value) {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.PLACING, value)
            field = value
        }
    private var reservedCallPeerId: String? = null // guarded; owns the one global slot before and after CURRENT
        set(value) {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.RESERVED, value != null)
            field = value
        }
    private var outgoingPlacementBarrier: CountDownLatch? = null // guarded; callback-to-placement event handoff
    private var winnerCallIdDuringPlacement: String? = null // guarded; survives winner terminal until reply
    private val terminalDuringPlacement = HashSet<String>() // guarded; callbacks can beat placeCall's return
    @Volatile internal var micMuted = false
    @Volatile private var speakerOn = false
    // Incoming media offers are copied out of daemon-owned callback memory and retained per call. The same registry
    // lets a new EventChannel listener recover a ring that arrived while no Flutter Activity was attached.
    private val incomingCalls = IncomingCallRegistry {
        // Ring removal must reconcile wake ownership even if this leg never
        // owned media (decline, timeout, or a terminal arriving before answer).
        main.post { applyBackgroundWakeLifetime() }
    }

    // ---- file transfer (M5): swarm-conversation P2P, the only model libjami exposes ----
    // The peer's CANONICAL 1:1 conversation id (cached once resolved). Canonical = the daemon's own
    // contact->conversation mapping (getContacts["conversationId"]), so BOTH devices agree on one id even when
    // the racing mutual addContact created duplicate contact swarms (M6 consolidation).
    @Volatile private var routingSnapshot = RoutingSnapshot.empty()
    private val routingLock = Any()
    private val callMessageAuthority = CallMessageAuthority()
    private val dmTopicArchives by lazy { DmTopicArchiveStore(appContext) }
    private val liveMessageEffects = LiveMessageEffects()
    private val incomingMicrophoneSettings by lazy {
        CanonicalIncomingCallMicrophonePolicy(
            appContext.getSharedPreferences(
                CanonicalIncomingCallMicrophonePolicy.PREFERENCES_NAME, Context.MODE_PRIVATE,
            ),
        )
    }
    @Volatile private var routingGeneration = 0L
    /** Serializes libjami load-id creation with pending-map insertion against a fast warm-cache callback. */
    private val loadRegistrationLock = Any()
    private class HistorySearchEntry(
        val owner: NativeAccountScope,
        val peer: String,
        val request: HistorySearchRequest,
        val limit: Int,
        val epoch: Long,
        val reply: (Map<String, Any>?) -> Unit,
    ) {
        @Volatile var nativeId = 0L
        var delivered = false // Accessed on the serial daemon worker only.
    }
    @Volatile private var historySearchEntry: HistorySearchEntry? = null
    private val historySearchEpoch = java.util.concurrent.atomic.AtomicLong()

    internal fun searchHistory(scope: NativeAccountScope?, peer: String, conversation: String,
                               literal: String, limit: Int, reply: (Map<String, Any>?) -> Unit) {
        val epoch = historySearchEpoch.get()
        worker.execute(DaemonOperation.LOAD_CHAT) {
            val account = scope?.accountId.orEmpty()
            val owner = normalizeOwnerKey(peer)
            val pattern = HistorySearchProjection.literalPattern(literal)
            if (account.isEmpty() || !accountAuthority.owns(scope) || !isActiveAccount(account) ||
                !routingSnapshot.owns(owner, conversation) || !ReactionProjection.validIdentity(conversation) ||
                pattern == null || limit !in 1..200 || historySearchEntry != null || epoch != historySearchEpoch.get()) {
                main.post { reply(null) }
                return@execute
            }
            val entry = HistorySearchEntry(scope!!, owner,
                HistorySearchRequest(account, conversation, groupConversationId(owner) != null, literal, limit),
                limit, epoch, reply)
            historySearchEntry = entry
            try {
                // Exact account/conversation only. Time/author/cursor filters can
                // discard editions before Jami folds history, so leave them empty.
                entry.nativeId = JamiService.searchConversation(account, conversation, "", "", pattern, "",
                    0L, 0L, (limit + 1).toLong(), 0)
                if (entry.nativeId == 0L) {
                    historySearchEntry = null
                    deliverHistorySearch(entry, null)
                }
            } catch (_: Throwable) {
                // Admission may be uncertain. Retain the native slot rather than
                // allowing retries to accumulate unobserved scans.
                entry.request.retire()
                deliverHistorySearch(entry, null)
            }
        }
    }

    private fun deliverHistorySearch(entry: HistorySearchEntry, value: Map<String, Any>?) {
        if (entry.delivered) return
        entry.delivered = true
        main.post {
            entry.reply(if (entry.epoch == historySearchEpoch.get() && accountAuthority.owns(entry.owner) &&
                routingSnapshot.owns(entry.peer, entry.request.conversation)) value else null)
        }
    }

    internal fun retireHistorySearch(scope: NativeAccountScope?) {
        if (!accountAuthority.owns(scope)) return
        historySearchEpoch.incrementAndGet()
        historySearchEntry?.takeIf { it.owner == scope }?.request?.retire()
        // A selected-message load keeps its lease until the daemon answers; the advanced epoch makes
        // that answer unavailable.
    }

    private fun searchMessageFacts(
        account: String,
        owner: NativeAccountScope,
        peer: String,
        conversation: String,
    ) = SearchMessageLoadFacts(
        accountOwned = accountAuthority.owns(owner),
        accountActive = isActiveAccount(account),
        routingOwns = routingSnapshot.owns(peer, conversation),
        epoch = historySearchEpoch.get(),
        restorePending = identityRestoreCommitting || pendingIdentityRestore != null ||
            identityRestoreRecoveryFailed,
    )

    /** Fresh folded message for one private-search hit. Answers [reply] exactly once; only the daemon's
     *  swarmLoaded answer supplies content, and no read state is touched. */
    internal fun loadSearchMessage(scope: NativeAccountScope?, peer: String, conversation: String,
                                   messageId: String, reply: (Map<String, Any>?) -> Unit) {
        val epoch = historySearchEpoch.get()
        try {
            worker.execute(DaemonOperation.LOAD_CHAT) {
                val account = scope?.accountId.orEmpty()
                val owner = normalizeOwnerKey(peer)
                if (scope == null) {
                    main.post { reply(null) }
                    return@execute
                }
                val load = SearchMessageConversationLoad(
                    account, scope, owner, conversation, messageId, groupConversationId(owner) != null, epoch,
                ) { value -> main.post { reply(value) } }
                try {
                    synchronized(loadRegistrationLock) {
                        if (!SearchMessageLoadPolicy.admit(account, owner, conversation, messageId, epoch,
                                searchMessageFacts(account, scope, owner, conversation),
                                conversationLoads.canStart())) {
                            load.answer(null)
                            return@synchronized
                        }
                        val loadId = JamiService.loadSybLMessage(account, conversation, messageId)
                        if (loadId == 0L || !conversationLoads.register(loadId, load)) {
                            load.answer(null)
                            return@synchronized
                        }
                        main.postDelayed({ conversationLoads.sweepExpired() },
                            ConversationLoadRegistry.DEFAULT_DEADLINE_MS + 1_000L)
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "loadSearchMessage", e)
                    load.answer(null)
                }
            }
        } catch (_: Throwable) {
            main.post { reply(null) }
        }
    }

    private fun completeSearchMessage(load: SearchMessageConversationLoad, acc: String, conv: String,
                                      messages: SwarmMessageVect) {
        try {
            val ids = ArrayList<String>()
            for (i in 0 until minOf(messages.size, 2)) ids.add(messages.get(i).id.orEmpty())
            SearchMessageLoadPolicy.dispatch(
                load, acc, conv, searchMessageFacts(load.account, load.owner, load.peerId, load.conversationId), ids,
                onProject = { index ->
                    val item = timelineItem(acc, load.peerId, conv, messages.get(index), myJamiId(), false)
                    load.answer(if (item == null || item.value["daemonId"] != load.messageId) null else mapOf(
                        "accountId" to acc,
                        "peerId" to load.peerId,
                        "conversationId" to conv,
                        "messageId" to load.messageId,
                        "kind" to if (load.group) "group" else "direct",
                        "items" to listOf(item.value),
                    ))
                },
                onUnavailable = { load.answer(null) },
            )
        } catch (e: Throwable) {
            Log.e(TAG, "loadSearchMessage completion", e)
            load.answer(null)
        }
    }

    private fun onHistorySearch(id: Long, account: String, conversation: String, messages: VectMap) {
        val entry = historySearchEntry ?: return
        if (account != entry.request.account || (conversation.isNotEmpty() && conversation != entry.request.conversation) ||
            (entry.nativeId != 0L && id != entry.nativeId)) return
        var size = 0
        val copied = ArrayList<Map<String, String>>()
        try {
            size = messages.size
            if (conversation.isNotEmpty() && size in 0..entry.limit + 1) {
                var remaining = HistorySearchProjection.MAX_CALLBACK_BYTES
                for (index in 0 until size) {
                    val raw = messages[index]
                    val bounded = HistorySearchProjection.copyFields(remaining) { raw[it] }
                        ?: throw IllegalArgumentException()
                    copied.add(bounded.first)
                    remaining = bounded.second
                }
            }
        } catch (_: Throwable) {
            size = Int.MAX_VALUE
            copied.clear()
        }
        // Copy while SWIG owns the callback values; dispatch after admission has
        // returned, including synchronous missing-conversation callbacks.
        val count = size
        worker.execute(DaemonOperation.LOAD_CHAT) {
            if (historySearchEntry !== entry || id != entry.nativeId) return@execute
            if (!accountAuthority.owns(entry.owner) || !routingSnapshot.owns(entry.peer, entry.request.conversation)) {
                entry.request.retire()
            }
            entry.request.accept(account, conversation, count) { copied[it] }
            if (entry.request.terminal) {
                historySearchEntry = null
                val batch = entry.request.result()
                val scoped = batch?.let {
                    val hits = (it["hits"] as List<*>).map { hit ->
                        (hit as Map<*, *>).entries.associate { field -> field.key as String to field.value } + mapOf(
                            "accountId" to entry.request.account, "peerId" to entry.peer,
                            "conversationId" to entry.request.conversation,
                            "kind" to if (entry.peer.startsWith("group:")) "group" else "direct")
                    }
                    mapOf<String, Any>("hits" to hits, "truncated" to (it["truncated"] == true))
                }
                deliverHistorySearch(entry, scoped)
            }
        }
    }
    private val subscribedPeers = ConcurrentHashMap.newKeySet<String>()
    private val connectedPeers = ConcurrentHashMap.newKeySet<String>()
    private fun clearPeerTransferState() {
        fileOffers.clear()
        xfers.clear()
        receiveDestByFile.clear()
        receiveAttempts.clear()
        reservedReceivePaths.clear()
        // libjami's load ids are process-wide. Retire active ownership while
        // keeping completed/cancelled ids quarantined against late callbacks.
        conversationLoads.clearActive()
    }
    internal data class FileXfer(
        val fileId: String,
        val interactionId: String,
        val name: String,
        val size: Long,
        val outgoing: Boolean,
        val authorId: String,
        val topicId: String,
        val topicTagged: Boolean,
        val roomId: String,
    )
    private data class TransferKey(val peerId: String, val conversationId: String, val fileId: String)
    // Only exact signed commits may supply download policy. History can be reloaded
    // on demand; neither passive offers nor callback labels grow with chat history.
    private val fileOffers = BoundedFileCache<FileOfferKey, FileOffer>(1024)
    private val xfers = BoundedFileCache<FileOfferKey, FileXfer>(1024)
    private val receiveDestByFile = ConcurrentHashMap<TransferKey, String>()
    private data class ReceiveAttempt(val account: NativeAccountScope, val id: String)
    private val receiveAttempts = ConcurrentHashMap<TransferKey, ReceiveAttempt>()
    private val reservedReceivePaths = ConcurrentHashMap.newKeySet<String>()

    // ---- file-keeping (M6): persistent shared folder over the swarm's data-transfer history ----
    // Retention knob (founder owns the value at M11): how many recent commits to scan + file items to surface.
    @Volatile internal var folderKeepLast = 200
    // libjami allocates folder and chat loads from one process-wide id namespace. Keep one tagged registry so
    // a callback can never be claimed by the wrong feature or by a later request that reused a retired random id.
    private val conversationLoads = ConversationLoadRegistry(
        onRetired = { (it as? SearchMessageConversationLoad)?.answer(null) },
    )

    private fun clearPeerTransferState(peerId: String) {
        receiveAttempts.keys.removeIf { it.peerId == peerId }
        xfers.removeWhere { it.peerId == peerId }
        fileOffers.removeWhere { it.peerId == peerId }
        for ((key, path) in receiveDestByFile.entries.toList()) {
            if (key.peerId == peerId && receiveDestByFile.remove(key, path)) {
                reservedReceivePaths.remove(path)
            }
        }
        conversationLoads.removePeer(peerId)
    }

    // STRONG references to every daemon director, held for the whole process lifetime. SWIG keeps only a
    // weak global ref to these Java peers, so without this the GC collects them and the next native
    // callback dereferences a dead object → SIGSEGV at 0x40. Constructed in start() AFTER loadLibrary:
    // a SWIG director ctor calls into the native lib, so it must not run before the .so is loaded.
    private var configCb: ConfigCb? = null
    private var callCb: CallCb? = null
    private var presenceCb: PresenceCb? = null
    private var dataCb: DataTransferCallback? = null
    private var videoCb: VideoCallback? = null
    private var convCb: ConversationCallback? = null
    private var netCb: NetworkServiceCallback? = null

    // ---- video (M2) state ----
    // The daemon decoded-frame sinks are bound to Flutter Surfaces by MainActivity (it owns the
    // FlutterEngine renderer). PtVideoCallback routes each sink to a ROLE; the binder does the bind.
    enum class VideoRole { SELF, REMOTE }
    interface VideoBinder {
        /** Create/resize the producer for [role], acquire its native window, register the daemon sink. Main thread. */
        fun bindSink(role: VideoRole, sinkId: String, width: Int, height: Int)
        fun unbindSink(role: VideoRole, sinkId: String)
        fun releaseSink(role: VideoRole)
        /** Release both daemon sink bindings + native windows; Flutter producers remain reusable. Main thread. */
        fun releaseAll()
        /** Reuse Flutter's self texture as a local screen-share decoder target. Main thread. */
        fun prepareProjectionPreview(
            width: Int,
            height: Int,
            onReady: (Surface?) -> Unit,
        )
    }
    private data class ActiveVideoSink(val role: VideoRole, val width: Int, val height: Int, val callId: String)
    private val activeVideoSinks = ConcurrentHashMap<String, ActiveVideoSink>()
    // libjami can deliver lifecycle callbacks from different media threads. Serialize each registry mutation
    // together with its published role snapshot so an old stop can never overtake a replacement start.
    private val videoSinkSignalLock = Any()
    @Volatile private var videoBinder: VideoBinder? = null
    fun setVideoBinder(b: VideoBinder?, expected: VideoBinder? = null) {
        if (b == null && expected != null && videoBinder !== expected) return
        if (videoBinder !== b) {
            // An Activity replacement retires capture and queued UI commands.
            // A retained Flutter listener can then acquire a fresh authority.
            detachCaptureUi()
            if (b != null && eventSink != null) captureUiAuthority.attach()
        }
        videoBinder = b
        if (b != null) {
            for ((id, sink) in activeVideoSinks) {
                main.post { if (videoBinder === b) b.bindSink(sink.role, id, sink.width, sink.height) }
            }
            (camHandler ?: startCamThread()).post {
                currentProjectionAttempt?.let(::prepareProjectionPreview)
            }
        } else {
            (camHandler ?: startCamThread()).post {
                currentProjectionAttempt?.let(::retireProjectionPreview)
            }
        }
    }

    // Camera2 capture (client-managed video on Android: WE push frames into the daemon).
    // Intent-first lifecycle: placeCall/startVideo only ARM a lease (register + default the device,
    // predict the sink id) and dial immediately; Camera2 opens when the daemon's StartCapture demand
    // meets a confirmed camera-typed foreground promotion. LocalVideoPolicy (pure) owns every
    // transition; [videoPhase] is guarded by callLifecycleLock and decisions execute on their thread.
    private val camManager by lazy { appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager }
    private var camThread: HandlerThread? = null
    private var camHandler: Handler? = null
    @Volatile private var camId: String? = null // physical Camera2 selection (flips); daemon identity lives in the lease
    @Volatile private var camFacing = CameraCharacteristics.LENS_FACING_FRONT
    @Volatile private var sensorOrientation = 0
    @Volatile private var displayDeg = 0        // current display rotation in degrees, fed by MainActivity
    @Volatile private var capRotation = 0       // angle handed to captureVideoFrame + setDeviceOrientation
    @Volatile private var capW = 1280
    @Volatile private var capH = 720
    /** Predicted local sink id ("camera://<registeredDeviceId>"): the daemon-created VideoInput's
     *  sink, the frame-push target, and the media SOURCE ownership key. Mirrors the lease. */
    @Volatile internal var localInputId: String? = null
    private data class OutgoingVideoSnapshot(
        val kind: LocalVideoKind? = null,
        val uri: String = "",
        val callId: String = "",
        val epoch: Long = 0,
        val width: Int = 0,
        val height: Int = 0,
    )
    @Volatile private var outgoingVideo = OutgoingVideoSnapshot()
    internal val cameraOn: Boolean get() = outgoingVideo.kind == LocalVideoKind.CAMERA
    internal val sharingScreen: Boolean get() = outgoingVideo.kind == LocalVideoKind.SCREEN
    @Volatile private var videoPhase: VideoPhase = VideoPhase.Idle // guarded; volatile for lock-free diagnostics
    private var videoSeq = 0L                            // guarded; source of epochs/attempt gens/query epochs
    private val peerMediaAnswersPending = HashSet<String>() // guarded; preserves independent local send intent
    @Volatile private var remoteControlSourceRevision = 0L
    @Volatile private var remoteControlAttemptGeneration = -1L
    private data class RemoteControlDisplayGeometry(
        val width: Int = 0,
        val height: Int = 0,
        val safeLeft: Int = 0,
        val safeTop: Int = 0,
        val safeRight: Int = 0,
        val safeBottom: Int = 0,
    ) {
        fun safeBounds() = Rect(safeLeft, safeTop, safeRight, safeBottom)
    }
    @Volatile private var remoteControlDisplayGeometry = RemoteControlDisplayGeometry()
    @Volatile private var liveAttemptGen = -1L           // hot-path mirror for frame push + Camera2 callbacks
    private var placementAbandoned = false               // guarded; recents dismissal during an in-flight placement

    /** Last video intent/effect authorized for each call. A transition may intentionally move to
     * [VideoPhase.Idle] while returning an off decision; retaining that decision's epoch here lets
     * the executor perform it, while a later arm for the same call immediately makes it stale. */
    private data class VideoEffectAuthority(val epoch: Long, val sinkId: String?)
    private val videoEffectAuthority = HashMap<String, VideoEffectAuthority>() // guarded by callLifecycleLock

    /** Per-attempt Camera2 resources: each generation owns its own reader/device/session so a stale
     *  callback can close only what belongs to it. Confined to [camHandler]. */
    private class CameraAttempt(val generation: Long) {
        var reader: ImageReader? = null
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        fun close() {
            try { session?.close() } catch (_: Throwable) {}
            try { device?.close() } catch (_: Throwable) {}
            try { reader?.close() } catch (_: Throwable) {}
            session = null; device = null; reader = null
        }
    }
    private var currentAttempt: CameraAttempt? = null // camHandler-confined
    /** Direct calls use GPU -> hardware encoder -> `captureVideoPacket`, which the daemon passes
     *  through without re-encoding. A local conference host instead sends the VirtualDisplay's RGBA
     *  frames to the daemon because its mixer needs raw input before it can compose the conference. */
    private class ScreenEncoder(
        val codec: MediaCodec,
        val width: Int,
        val height: Int,
    ) {
        var input: Surface? = null
        @Volatile var firstPacketPublished = false
        /** Codec initialization data (AVC SPS/PPS, HEVC VPS/SPS/PPS, or the codec's equivalent)
         *  re-sent ahead of recovery frames. */
        var codecData: ByteBuffer? = null

        fun close() {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
            try { input?.release() } catch (_: Throwable) {}
            input = null
            codecData = null
        }
    }

    /** Decodes the already-encoded outbound packets onto Flutter's self
     * texture. It never owns [surface] and a preview failure cannot stop the
     * peer-facing share. */
    private class ScreenPreviewDecoder private constructor(
        private val codec: MediaCodec,
        private val surface: Surface,
    ) {
        private val outputInfo = MediaCodec.BufferInfo()
        private var started = false

        fun offer(source: ByteBuffer, info: MediaCodec.BufferInfo): Boolean {
            val keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            if (!started && !keyframe) return false
            var rendered = drain()
            val index = codec.dequeueInputBuffer(0)
            if (index < 0) return rendered
            val input = codec.getInputBuffer(index)
            if (input == null || info.size > input.capacity()) {
                codec.queueInputBuffer(index, 0, 0, info.presentationTimeUs, 0)
                return rendered
            }
            val packet = source.duplicate().apply {
                position(info.offset)
                limit(info.offset + info.size)
            }
            input.clear()
            input.put(packet)
            codec.queueInputBuffer(
                index,
                0,
                info.size,
                info.presentationTimeUs,
                if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
            )
            started = true
            rendered = drain() || rendered
            return rendered
        }

        private fun drain(): Boolean {
            var rendered = false
            while (true) {
                val index = codec.dequeueOutputBuffer(outputInfo, 0)
                when {
                    index >= 0 -> {
                        codec.releaseOutputBuffer(index, true)
                        rendered = true
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                    else -> return rendered
                }
            }
        }

        fun close() {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
        }

        companion object {
            fun open(
                mime: String,
                width: Int,
                height: Int,
                outputFormat: MediaFormat,
                surface: Surface,
            ): ScreenPreviewDecoder? {
                var codec: MediaCodec? = null
                return try {
                    val format = MediaFormat.createVideoFormat(mime, width, height)
                    for (index in 0..2) {
                        outputFormat.getByteBuffer("csd-$index")?.duplicate()?.let {
                            format.setByteBuffer("csd-$index", it)
                        }
                    }
                    codec = MediaCodec.createDecoderByType(mime)
                    codec.configure(format, surface, null, 0)
                    codec.start()
                    ScreenPreviewDecoder(codec, surface)
                } catch (e: Throwable) {
                    Log.e(TAG, "screen preview decoder", e)
                    try { codec?.release() } catch (_: Throwable) {}
                    null
                }
            }
        }
    }

    private class ProjectionAttempt(
        val callId: String,
        val generation: Long,
        val epoch: Long,
        val mime: String,
        var width: Int,
        var height: Int,
        var densityDpi: Int,
        @Volatile var capturedContentWidth: Int,
        @Volatile var capturedContentHeight: Int,
        val rawConferenceFrames: Boolean,
    ) {
        var encoder: ScreenEncoder? = null
        var projection: MediaProjection? = null
        var display: VirtualDisplay? = null
        var preview: ScreenPreviewDecoder? = null
        var previewSurface: Surface? = null
        var previewFormat: MediaFormat? = null
        var previewActive = false
        var conferenceReader: ImageReader? = null
        @Volatile var firstPacketPublished = false
        fun close() {
            try { display?.release() } catch (_: Throwable) {}
            preview?.close()
            conferenceReader?.close()
            encoder?.close()
            try { projection?.stop() } catch (_: Throwable) {}
            display = null; preview = null; previewSurface = null
            conferenceReader = null
            previewFormat = null; encoder = null; projection = null
        }
    }
    @Volatile private var currentProjectionAttempt: ProjectionAttempt? = null
    private data class ProjectionConsent(
        val callId: String,
        val epoch: Long,
        val resultCode: Int,
        val data: Intent,
        val width: Int,
        val height: Int,
        val densityDpi: Int,
    )
    private val projectionConsents = HashMap<Long, ProjectionConsent>() // guarded by callLifecycleLock
    private data class CameraRollback(val callId: String, val displayRotation: Int)
    private val projectionRollbacks = HashMap<Long, CameraRollback>() // guarded
    private var pendingProjectionConsent: Pair<String, Long>? = null // guarded

    private fun nextVideoSeq(): Long { videoSeq += 1; return videoSeq } // call under callLifecycleLock

    /** Apply one pure transition under the lifecycle lock, sync the mirrors, return its decisions. */
    private fun transitionVideo(block: (VideoPhase) -> VideoTransition): List<VideoDecision> =
        synchronized(callLifecycleLock) {
            val t = block(videoPhase)
            videoPhase = t.phase
            liveAttemptGen = when (val p = t.phase) {
                is VideoPhase.Opening -> p.attemptGen
                is VideoPhase.Capturing -> p.attemptGen
                is VideoPhase.PendingReplacement -> p.attemptGen ?: -1L
                else -> -1L
            }
            when (t.phase) {
                is VideoPhase.Armed, is VideoPhase.Opening, is VideoPhase.Capturing -> {
                    val lease = t.phase.currentLease()!!
                    localInputId = lease.sinkId
                    outgoingVideo = OutgoingVideoSnapshot(
                        lease.kind,
                        lease.sinkId,
                        lease.ownerCallId ?: activeCallId.orEmpty(),
                        lease.epoch,
                        lease.width,
                        lease.height,
                    )
                }
                is VideoPhase.PendingReplacement -> { /* truth holds until the adjudication resolves */ }
                else -> {
                    localInputId = null
                    outgoingVideo = OutgoingVideoSnapshot(epoch = outgoingVideo.epoch)
                }
            }
            t.phase.currentLease()?.let { lease ->
                lease.ownerCallId?.let { owner ->
                    if (!recentTerminalCallIds.contains(owner)) {
                        val old = videoEffectAuthority[owner]
                        if (old == null || lease.epoch >= old.epoch) {
                            videoEffectAuthority[owner] = VideoEffectAuthority(lease.epoch, lease.sinkId)
                        }
                    }
                }
            }
            for (decision in t.decisions) {
                when (decision) {
                    is VideoDecision.DisableCallVideo -> {
                        val old = videoEffectAuthority[decision.callId]
                        if (!recentTerminalCallIds.contains(decision.callId) &&
                            (old == null || decision.epoch >= old.epoch)) {
                            videoEffectAuthority[decision.callId] =
                                VideoEffectAuthority(decision.epoch, decision.sinkId)
                        }
                    }
                    is VideoDecision.ReportCameraState -> {
                        val old = videoEffectAuthority[decision.callId]
                        if (!recentTerminalCallIds.contains(decision.callId) &&
                            (old == null || decision.epoch >= old.epoch)) {
                            videoEffectAuthority[decision.callId] = VideoEffectAuthority(
                                decision.epoch,
                                t.phase.currentLease()?.takeIf { it.epoch == decision.epoch }?.sinkId
                                    ?: old?.takeIf { it.epoch == decision.epoch }?.sinkId,
                            )
                        }
                    }
                    else -> Unit
                }
            }
            t.decisions
        }

    /** Validate an asynchronous video effect at the last possible point before it touches libjami,
     * Flutter, or the foreground service. Off decisions remain valid after their transition moved
     * the coordinator to Idle; any newer same-call intent replaces this authority immediately. */
    private fun isVideoEffectCurrent(
        callId: String,
        epoch: Long,
        sinkId: String? = null,
        requiresLiveIntent: Boolean = false,
    ): Boolean = synchronized(callLifecycleLock) {
        val authority = videoEffectAuthority[callId] ?: return@synchronized false
        if (authority.epoch != epoch || (sinkId != null && authority.sinkId != sinkId)) {
            return@synchronized false
        }
        if (activeMediaTarget() != callId || recentTerminalCallIds.contains(callId)) return@synchronized false
        if (!requiresLiveIntent) return@synchronized true
        val lease = videoPhase.currentLease() ?: return@synchronized false
        lease.epoch == epoch && lease.ownerCallId == callId
    }

    private fun leaseFor(d: VideoDecision.OpenCamera): VideoLease? = synchronized(callLifecycleLock) {
        val lease = videoPhase.currentLease() ?: return@synchronized null
        if (lease.epoch != d.epoch || liveAttemptGen != d.attemptGen) return@synchronized null
        val owner = lease.ownerCallId
        if (owner != null && (activeMediaTarget() != owner || recentTerminalCallIds.contains(owner))) {
            return@synchronized null
        }
        lease
    }

    private fun postMainAfterCameraQueue(block: () -> Unit) {
        val enqueue: () -> Unit = {
            main.post(block)
            Unit
        }
        val handler = camHandler
        if (handler != null) handler.post(enqueue) else enqueue()
    }

    /** Queue an FGS update behind every already-queued Camera2 close, then revalidate the originating
     * effect immediately before changing the service type. */
    private fun syncCallFgsAfterCameraQueue(callId: String, epoch: Long, requiresLiveIntent: Boolean) {
        postMainAfterCameraQueue fgs@{
            if (isVideoEffectCurrent(callId, epoch, requiresLiveIntent = requiresLiveIntent)) {
                syncCallFgsVideo()
            }
        }
    }

    private fun executeVideoDecisions(decisions: List<VideoDecision>) {
        for (d in decisions) when (d) {
            is VideoDecision.OpenCamera -> {
                val lease = leaseFor(d)
                val registered = lease?.registeredDeviceId
                if (registered != null) {
                    try { JamiService.setDeviceOrientation(registered, capRotation) } catch (_: Throwable) {}
                }
                (camHandler ?: startCamThread()).post {
                    val current = leaseFor(d)
                    if (current != null) {
                        if (d.kind == LocalVideoKind.SCREEN) {
                            openProjection(current, d.attemptGen)
                        } else {
                            openCamera(d.physicalCameraId, d.attemptGen)
                        }
                    }
                }
            }
            is VideoDecision.CloseCamera -> camHandler?.post { closeAttempt(d.attemptGen) }
            is VideoDecision.RequestKeyFrame -> (camHandler ?: startCamThread()).post {
                val attempt = currentProjectionAttempt
                if (attempt?.generation == d.attemptGen && liveAttemptGen == d.attemptGen) {
                    requestScreenKeyFrame(attempt)
                }
            }
            is VideoDecision.DisableCallVideo -> {
                val acc = accountId
                worker.execute(DaemonOperation.DISABLE_VIDEO, diagnosticCallToken(d.callId)) {
                    if (!isVideoEffectCurrent(d.callId, d.epoch, d.sinkId)) return@execute
                    if (acc != null && accountId == acc &&
                        isVideoEffectCurrent(d.callId, d.epoch, d.sinkId)) {
                        try {
                            JamiService.requestMediaChange(
                                acc,
                                mediaSignalingTarget(d.callId),
                                videoMediaList(micMuted, videoMuted = true, source = d.sinkId),
                            )
                        } catch (e: Throwable) { Log.e(TAG, "disable-video re-invite", e) }
                    }
                    emitCameraStateIfAuthoritative(d.callId, false, d.epoch, d.sinkId)
                    syncCallFgsAfterCameraQueue(d.callId, d.epoch, requiresLiveIntent = false)
                }
            }
            is VideoDecision.ReportCameraState -> {
                emitCameraStateIfAuthoritative(d.callId, d.on, d.epoch)
                syncCallFgsAfterCameraQueue(d.callId, d.epoch, requiresLiveIntent = d.on)
            }
            is VideoDecision.QueryAdoption -> {
                // Reached only when a call site did not sequence the query itself (belt): resolve
                // with the same exact-source rule, without any follow-up work.
                val acc = accountId ?: continue
                worker.execute(DaemonOperation.QUERY_CAMERA_ADOPTION, diagnosticCallToken(d.winnerCallId)) {
                    val stillPending = synchronized(callLifecycleLock) {
                        val p = videoPhase as? VideoPhase.PendingReplacement
                        p?.queryEpoch == d.queryEpoch && p.winnerCallId == d.winnerCallId &&
                            p.lease.sinkId == d.sinkId
                    }
                    if (!stillPending) return@execute
                    val owns = adoptPlacementCameraIfOwned(acc, d.winnerCallId, d.sinkId)
                    executeVideoDecisions(transitionVideo {
                        LocalVideoPolicy.resolveReplacement(it, d.queryEpoch, owns, nextVideoSeq())
                    })
                }
            }
        }
    }

    private fun revokeLease() = executeVideoDecisions(transitionVideo { LocalVideoPolicy.revoke(it) })

    private fun activeMediaTarget(): String? = activeCallId ?: activeGroupConferenceId

    private fun mediaSignalingTarget(ownerCallId: String): String =
        if (ownerCallId == activeGroupConferenceId) {
            GroupCallWire.mediaTarget(
                ownerCallId,
                groupCallLegs[ownerCallId].orEmpty(),
                activeGroupHosting,
            )
        } else {
            ownerCallId
        }

    /** Adjudicate the lease against [winnerCallId] (exact-source rule) and run [afterResolve] once
     *  the outcome is applied. Enters PendingReplacement under the lifecycle lock BEFORE any caller
     *  retires the lease-owning sibling. */
    private fun beginLeaseReplacement(acc: String, winnerCallId: String, afterResolve: (() -> Unit)? = null) {
        val decisions = transitionVideo { phase ->
            LocalVideoPolicy.beginReplacement(phase, winnerCallId, nextVideoSeq())
        }
        val query = decisions.filterIsInstance<VideoDecision.QueryAdoption>().firstOrNull()
        executeVideoDecisions(decisions.filter { it !is VideoDecision.QueryAdoption })
        if (query == null) {
            afterResolve?.invoke()
            return
        }
        worker.execute(DaemonOperation.QUERY_CAMERA_ADOPTION, diagnosticCallToken(query.winnerCallId)) {
            val owns = adoptPlacementCameraIfOwned(acc, query.winnerCallId, query.sinkId)
            executeVideoDecisions(transitionVideo {
                LocalVideoPolicy.resolveReplacement(it, query.queryEpoch, owns, nextVideoSeq())
            })
            afterResolve?.invoke()
        }
    }

    private fun isActiveAccount(id: String): Boolean =
        !resetDoorlightPending && !identityRestoreCommitting && pendingIdentityRestore == null &&
            !identityRestoreRecoveryFailed && id.isNotEmpty() && id == accountId

    private fun selectAccount(id: String) {
        if (accountId.orEmpty() != id) retireDevicePairing()
        accountAuthority.select(id)
        val previousAccount = accountId
        if (previousAccount != id) {
            historySearchEntry?.request?.retire()
            messageActions.clear()
            backgroundWakeController.accountChanged(id)
            val knownActive = runCatching {
                JamiService.getVolatileAccountDetails(id).toNative()["Account.active"].let {
                    when (it) { "true" -> true; "false" -> false; else -> null }
                }
            }.getOrNull()
            backgroundWakeActivity.select(id, knownActive)
            AndroidRemoteControlHost.stopLocal("identity-changed")
            synchronized(routingLock) {
                routingGeneration += 1
                routingSnapshot = RoutingSnapshot.empty(id, routingSnapshot.revision + 1)
                callMessageAuthority.updateRouting(routingSnapshot)
            }
            subscribedPeers.clear()
            connectedPeers.clear()
            clearPeerTransferState()
            callPeers.clear()
            rejectedCallIds.clear()
            synchronized(callLifecycleLock) {
                currentWinnerCallId = null
                reservedCallPeerId = null
                winnerCallIdDuringPlacement = null
                outgoingPlacementBarrier?.countDown()
                outgoingPlacementBarrier = null
                recentTerminalCallIds.clear()
                videoEffectAuthority.clear()
            }
            // Publish the new owner atomically with clearing its unauthenticated request budget. An old-account
            // callback either lands before this lock and is cleared, or observes the new owner and is rejected.
            val staleConversationIds = synchronized(pendingConnectLock) {
                val stale = pendingConnect.entries
                    .filter { it.value.accountId == previousAccount }
                    .map { it.key }
                if (!previousAccount.isNullOrEmpty() &&
                    rejectedConnectRescanAccounts.size < MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS
                ) {
                    // The daemon owns the authoritative request set. A single account marker also catches a
                    // request whose callback had not reached this process before ownership changed.
                    rejectedConnectRescanAccounts += previousAccount
                }
                accountId = id
                pendingConnect.clear()
                pendingConnectGate.clear()
                stale
            }
            if (previousAccount != null) {
                for (conversationId in staleConversationIds) {
                    try {
                        JamiService.declineConversationRequest(previousAccount, conversationId)
                        rememberRejectedConnect(RejectedConnect(previousAccount, conversationId))
                    } catch (e: Throwable) {
                        Log.e(TAG, "decline stale conversation request", e)
                    }
                }
                scheduleRejectedConnectDrain()
            }
        } else {
            accountId = id
        }
        dmTopicArchives.selectAccount(id)
        lastRegistration = registrationByAccount[id]
        lastRegistration?.let {
            emit(mapOf("type" to "registrationState", "accountId" to id, "state" to it))
        }
        announcedByAccount[id]?.let {
            emit(mapOf("type" to "deviceAnnounced", "accountId" to id, "announced" to it))
        }
    }

    fun attach(context: Context) {
        if (!::appContext.isInitialized) {
            appContext = context.applicationContext
            initializeStageRegistry()
            audio = CallAudioController(appContext)
            try {
                appContext.getSystemService(ConnectivityManager::class.java)
                    .registerDefaultNetworkCallback(defaultNetworkCallback)
            } catch (e: Throwable) {
                Log.e(TAG, "default network callback registration failed", e)
            }
        }
    }

    internal fun setActivityResumed(resumed: Boolean) {
        if (activityResumed != resumed) retirePresenceProbes()
        SybLRecordingBridge.setForeground(resumed)
        backgroundWakeRetryKey = Any()
        activityResumed = resumed
        if (!resumed) retireDevicePairing()
        if (resumed) {
            backgroundAtMs = null
            if (::appContext.isInitialized) backgroundWakeController.resumed()
            taskRemovedWithPush = false
            incomingCalls.snapshot().keys.forEach(::cancelIncomingCallNotification)
        } else {
            backgroundAtMs = SystemClock.elapsedRealtime()
            surfacePendingIncomingCallIfIdle()
        }
        applyBackgroundWakeLifetime()
    }

    internal fun setMessageNotificationPreview(
        enabled: Boolean,
        appLockEnabled: Boolean,
    ): Boolean = MessageNotifications.setPolicy(appContext, enabled, appLockEnabled)

    internal fun backgroundWakeAvailability(): Boolean = BuildConfig.SYBL_FIREBASE_CONFIGURED

    private val backgroundWakeController: BackgroundWakeController by lazy {
        BackgroundWakeController(
            registration = wakeRegistration(),
            tokens = ConsentWakeTokens(
                loadCleanupPending = {
                    val preferences = backgroundWakePreferences()
                    // Old builds could register before an explicit choice.
                    preferences.getBoolean("firebase-cleanup-pending",
                        preferences.getBoolean(BACKGROUND_WAKE_REQUESTED, false) ||
                            preferences.getBoolean(BACKGROUND_WAKE_REGISTERED, false))
                },
                saveCleanupPending = {
                    backgroundWakePreferences().edit()
                        .putBoolean("firebase-cleanup-pending", it).commit()
                },
                backend = object : BackgroundWakeTokens {
                @Suppress("DEPRECATION")
                override fun setEnabled(enabled: Boolean) {
                    checkNotNull(FirebaseApp.initializeApp(appContext)) { "Firebase is not configured" }
                    FirebaseMessaging.getInstance().setAutoInitEnabled(enabled)
                }
                override fun get(callback: (String?) -> Unit) {
                    FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                        callback(if (task.isSuccessful) task.result else null)
                    }
                }
                override fun delete(callback: (Boolean) -> Unit) {
                    checkNotNull(FirebaseApp.initializeApp(appContext)) { "Firebase is not configured" }
                    FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener { token ->
                        if (!token.isSuccessful) callback(false)
                        else FirebaseInstallations.getInstance().delete()
                            .addOnCompleteListener { callback(it.isSuccessful) }
                    }
                }
            }),
            load = {
                val preferences = backgroundWakePreferences()
                SavedBackgroundWake(
                    requested = preferences.getBoolean("google-wake-consent-v1", false) &&
                        preferences.getBoolean(BACKGROUND_WAKE_REQUESTED, false),
                    profile = preferences.getString(BACKGROUND_WAKE_PROFILE, "jami").orEmpty(),
                    relayUrl = preferences.getString(BACKGROUND_WAKE_RELAY_URL, "").orEmpty(),
                    registered = preferences.getBoolean(BACKGROUND_WAKE_REGISTERED, false),
                    ownerAccount = preferences.getString("owner-account", "").orEmpty(),
                    retiringRelay = preferences.getString("retiring-relay", null),
                    renewedAtMs = (preferences.all["renewed-at-ms"] as? Long) ?: 0,
                )
            },
            save = { saved ->
                val preferences = backgroundWakePreferences()
                val cleanupPending = preferences.getBoolean("firebase-cleanup-pending",
                    preferences.getBoolean(BACKGROUND_WAKE_REQUESTED, false) ||
                        preferences.getBoolean(BACKGROUND_WAKE_REGISTERED, false))
                preferences.edit()
                    .putBoolean("firebase-cleanup-pending", cleanupPending)
                    .putBoolean("google-wake-consent-v1", saved.requested)
                    .putBoolean(BACKGROUND_WAKE_REQUESTED, saved.requested)
                    .putString(BACKGROUND_WAKE_PROFILE, saved.profile)
                    .putString(BACKGROUND_WAKE_RELAY_URL, saved.relayUrl)
                    .putBoolean(BACKGROUND_WAKE_REGISTERED, saved.registered)
                    .putString("owner-account", saved.ownerAccount)
                    .putString("retiring-relay", saved.retiringRelay)
                    .putLong("renewed-at-ms", saved.renewedAtMs)
                    .commit()
            },
            available = ::backgroundWakeAvailability,
            account = { accountId },
            worker = { action -> worker.execute(DaemonOperation.SET_BACKGROUND_WAKE) { action() } },
            main = { action -> main.post { action() } },
            clearDaemonToken = { JamiService.setPushNotificationToken("") },
            publish = { owner, handle ->
                if (owner == accountId) publishBackgroundWakeCapability(handle)
            },
            ready = { owner, handle ->
                val scope = backgroundWakeController.scope()
                main.post {
                    if (backgroundWakeController.owns(scope, owner) && backgroundWakeController.handle() == handle) {
                        try {
                            eventSink?.success(mapOf("type" to "backgroundWakeReady", "accountId" to owner, "handle" to handle))
                        } catch (error: Throwable) { Log.e(TAG, "Wake state delivery failed", error) }
                    }
                }
            },
            reconcileLifetime = ::applyBackgroundWakeLifetime,
        )
    }

    internal fun setReliableBackgroundNotifications(
        enabled: Boolean,
        connectionProfile: String,
        relayUrl: String,
        scope: NativeAccountScope?,
        callback: (Boolean) -> Unit,
    ) = backgroundWakeController.configure(enabled, connectionProfile, relayUrl,
        ownerCurrent = { accountAuthority.owns(scope) }, callback = callback)

    internal fun refreshBackgroundWakeToken(token: String) = backgroundWakeController.refresh(token)

    internal fun backgroundWakeEnabled(): Boolean =
        ::appContext.isInitialized && backgroundWakeController.enabled()

    internal fun backgroundWakeDesired(): Boolean =
        ::appContext.isInitialized && backgroundWakeController.desired()

    private fun backgroundWakeRequested(): Boolean = backgroundWakeController.enabled()

    private fun backgroundWakePreferences() =
        appContext.getSharedPreferences(BACKGROUND_WAKE_PREFS, Context.MODE_PRIVATE)

    private fun wakeRegistration(): WakeRegistration =
        wakeRegistrationInstance ?: synchronized(this) {
            val sealed = KeystoreSealedStore("wake_credentials_sealed", "sybl.wake.credentials")
            val deletion = KeystoreSealedStore("wake_delete_sealed", "sybl.wake.deletion")
            wakeRegistrationInstance ?: WakeRegistration(
                SealedWakeRegistrationStore(
                    SharedPreferencesWakeRegistrationStore(backgroundWakePreferences()),
                    read = { sealed.load(appContext) },
                    write = { sealed.save(appContext, it) },
                    remove = { sealed.clear(appContext) },
                ),
                HttpWakeRegistrationTransport(),
                SealedWakeDeletionJournal(
                    read = { deletion.load(appContext) },
                    write = { deletion.save(appContext, it) },
                    remove = { deletion.clear(appContext) },
                ),
            ).also { wakeRegistrationInstance = it }
        }

    internal fun rotateBackgroundWakeCapability(relayUrl: String, scope: NativeAccountScope?, callback: (Boolean) -> Unit) =
        backgroundWakeController.rotate(relayUrl, ownerCurrent = { accountAuthority.owns(scope) }, callback = callback)

    internal fun processPush(from: String, data: Map<String, String>, kind: PushWakeKind) {
        if (kind == PushWakeKind.IGNORE || !backgroundWakeEnabled()) return
        main.post {
            if (!backgroundWakeEnabled()) return@post
            val owner = backgroundWakeController.wakeOwner()
            val scope = backgroundWakeController.scope()
            val now = SystemClock.elapsedRealtime()
            backgroundWakeRetryKey = Any()
            if (kind == PushWakeKind.CALL) callPushAtMs = now else messagePushAtMs = now
            taskRemovedWithPush = false
            applyBackgroundWakeLifetime()
            submit(DaemonOperation.SET_BACKGROUND_WAKE, block = {
                val account = owner ?: return@submit false
                if (!backgroundWakeController.owns(scope, account) || !backgroundWakeEnabled() || !keepOnline) {
                    return@submit false
                }
                try {
                    setWakeAccountActive(account, true)
                    JamiService.connectivityChanged()
                    if (kind != PushWakeKind.RELAY) {
                        JamiService.pushNotificationReceived(from.take(512), StringMap.toSwig(data))
                    }
                    true
                } catch (e: Throwable) {
                    if (backgroundWakeController.owns(scope, account)) backgroundWakeActivity.acknowledge(account, null)
                    throw e
                }
            }) { applyBackgroundWakeLifetime() }
        }
    }

    internal fun cancelMessageNotification(conversationId: String) {
        if (TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) {
            MessageNotifications.cancel(appContext, conversationId)
        }
    }

    private val captureUiAuthority = CaptureUiAuthority()
    private val captureCommandOwner = ThreadLocal<Any?>()

    internal fun detachCaptureUi() {
        captureUiAuthority.detach()
        synchronized(callLifecycleLock) {
            pendingProjectionConsent = null
            projectionConsents.clear()
            projectionRollbacks.clear()
        }
        revokeLease()
        reconcileFgsAfterLeaseRevoke()
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        if (sink == null) detachCaptureUi()
        else if (videoBinder != null) captureUiAuthority.attach()
        eventSink = sink
        // The daemon often reaches REGISTERED before Dart attaches this listener; EventChannel drops
        // events emitted before onListen, so replay the latest registration state to the fresh listener.
        val acc = accountId
        val reg = lastRegistration
        if (sink != null && acc != null && reg != null) {
            emit(mapOf("type" to "registrationState", "accountId" to acc, "state" to reg))
        }
        if (sink != null && acc != null) {
            announcedByAccount[acc]?.let {
                emit(mapOf("type" to "deviceAnnounced", "accountId" to acc, "announced" to it))
            }
        }
        if (sink != null) {
            emit(mapOf(
                "type" to "remoteControlAccessibilityState",
                "enabled" to AndroidRemoteControlHost.isServiceEnabled(),
            ))
        }
        // Account-scoped requests and calls are replayed only by replayPendingNativeEvents(), after Dart has
        // installed both the native-selected account and its trusted-friend snapshot.
    }

    private val annotationIngress = AnnotationIngress()
    private val controlFlutterIngress = AnnotationIngress()

    internal fun emit(event: Map<String, Any?>) {
        val annotationBytes = if (event["type"] == "callMessage" && event["channel"] == "annotation") {
            val payload = event["payload"] as? String ?: return
            if (payload.length > 65536) return
            payload.toByteArray(Charsets.UTF_8).size.also {
                if (!annotationIngress.admit(it, SystemClock.elapsedRealtime())) return
            }
        } else 0
        val controlBytes = if (event["type"] == "callMessage" && event["channel"] == "control") {
            val payload = event["payload"] as? String ?: return
            if (payload.length > 6000) return
            payload.toByteArray(Charsets.UTF_8).size.also {
                if (it > 6000 || !controlFlutterIngress.admit(it, SystemClock.elapsedRealtime())) return
            }
        } else 0
        val posted = main.post {
            try {
                eventSink?.success(event)
            } catch (e: Throwable) {
                // EventChannel is another JNI boundary. A detached/corrupt
                // Flutter sink must not unwind onto the Android main looper.
                Log.e(TAG, "event delivery failed", e)
            } finally {
                if (annotationBytes > 0) annotationIngress.delivered(annotationBytes)
                if (controlBytes > 0) controlFlutterIngress.delivered(controlBytes)
            }
        }
        if (!posted) {
            if (annotationBytes > 0) annotationIngress.delivered(annotationBytes)
            if (controlBytes > 0) controlFlutterIngress.delivered(controlBytes)
        }
    }

    /** Replay only after Dart installs the native-selected account and friend gates. */
    fun replayPendingNativeEvents(): Boolean {
        val selected = accountId ?: return false
        if (eventSink == null) return false
        val pendingReplay = synchronized(pendingConnectLock) {
            pendingConnect.entries
                .filter { it.value.accountId == selected }
                .map { it.key to it.value }
        }
        for ((cid, pending) in pendingReplay) {
            emit(mapOf("type" to "connectRequest", "accountId" to pending.accountId,
                "conversationId" to cid, "fromJamiId" to pending.from,
                "isGroup" to pending.isGroup, "name" to pending.name))
        }
        synchronized(callSignalDispatchLock) {
            for ((callId, pending) in incomingCalls.snapshot()) {
                if (pending.accountId != selected) continue
                if (!directCallAllowed(pending.accountId, pending.fromJamiId)) {
                    retireDeniedIncomingCall(callId, pending)
                    continue
                }
                emit(mapOf("type" to "incomingCall", "accountId" to pending.accountId,
                    "callId" to callId, "fromJamiId" to pending.fromJamiId,
                    "fromName" to "", "withVideo" to listHasActiveVideo(pending.offer)))
            }
        }
        // The daemon persists undecided requests, but pendingConnect is process-local. Query on the daemon
        // worker after Dart has installed its account/friend gates, then pass each row through the same
        // validation and bounded admission as a live callback. A concurrent callback is deduplicated there.
        worker.execute(DaemonOperation.REPLAY_CONNECT_REQUESTS) {
            if (!isActiveAccount(selected)) return@execute
            try {
                val requests = JamiService.getConversationRequests(selected)
                for (index in 0 until requests.size) {
                    if (!isActiveAccount(selected)) break
                    val request = requests.get(index).toNative()
                    val conversationId = request["id"].orEmpty()
                    if (!TimelineWireBounds.required(
                            conversationId,
                            TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                        )) {
                        // An invalid daemon ID cannot safely be passed to declineConversationRequest.
                        // Keep it out of the UI while still recovering later valid rows.
                        Log.e(TAG, "persisted conversation request has invalid id")
                        continue
                    }
                    onConversationRequest(
                        selected,
                        conversationId,
                        request["from"].orEmpty(),
                        request["mode"].orEmpty(),
                        request["title"].orEmpty(),
                    )
                }
            } catch (e: Throwable) {
                Log.e(TAG, "replay persisted conversation requests", e)
            }
        }
        return isActiveAccount(selected)
    }

    /** Boot the daemon once. Adopts a persisted account if one exists (the reuse path). */
    fun start() {
        worker.execute(DaemonOperation.BOOT) {
            if (started) return@execute
            try {
                // Read the sealed adoption barrier before daemon start or account selection.
                identityRestoreRecoveryFailed = false
                val resetAccount = resetDoorlightMarker()
                resetDoorlightPending = resetAccount != null
                pendingIdentityRestore = try { IdentityRestoreJournal.load(appContext) }
                    catch (error: Throwable) { identityRestoreRecoveryFailed = true; throw error }
                check(decideRestoreBoot(pendingIdentityRestore, emptyList()) != RestoreBootDecision.BLOCKED_UNBOUND) {
                    "Interrupted restore account ownership is unresolved"
                }
                if (!daemonInitAttempted) {
                    System.loadLibrary("jami-core-jni")
                    // Construct the directors only now that the native lib is loaded; keep strong refs in fields.
                    val cfg = ConfigCb()
                    val call = CallCb()
                    val pres = PresenceCb()
                    val data = DataCb()
                    val video = PtVideoCallback()
                    val conv = ConvCb()
                    val net = NetworkServiceCallback()
                    configCb = cfg; callCb = call; presenceCb = pres
                    dataCb = data; videoCb = video; convCb = conv; netCb = net
                    // Native init is not transactional either. Latch the attempt before crossing JNI so a failed
                    // or throwing call cannot duplicate process-global registration on a later boot request.
                    daemonInitAttempted = true
                    daemonInitSucceeded = JamiService.init(cfg, call, pres, data, video, conv, net)
                }
                check(daemonInitSucceeded) { "libjami initialization failed and cannot be retried safely" }
                if (!daemonStartAttempted) {
                    // Manager initialization is not transactional, so a failed start cannot be retried safely.
                    daemonStartAttempted = true
                    daemonStartSucceeded = JamiService.start()
                }
                check(daemonStartSucceeded) { "libjami start failed and cannot be retried safely" }
                // call.cpp applies this only while an incoming call is still
                // RINGING. Zero/negative expire immediately, so Int.MAX_VALUE
                // is the API's effective "until a human decides" value.
                JamiService.setRingingTimeout(Int.MAX_VALUE)
                // Older builds used the process-global capture flag for the mic button. Android's AAudio path does
                // not apply it live, but the preference can survive an upgrade; keep that legacy gate open and use
                // call-scoped muteLocalMedia below.
                micMuted = false
                try { JamiService.muteCapture(false) }
                catch (e: Throwable) { Log.e(TAG, "legacy muteCapture normalization failed", e) }
                var list = JamiService.getAccountList()
                val pending = pendingIdentityRestore
                when (decideRestoreBoot(pending, (0 until list.size).map { list.get(it) })) {
                    RestoreBootDecision.NONE, RestoreBootDecision.PAIRING_ABSENT -> Unit
                    RestoreBootDecision.BLOCKED_UNBOUND -> error("Interrupted restore account ownership is unresolved")
                    RestoreBootDecision.BLOCKED_UNEXPLAINED_ACCOUNT -> error("Interrupted restore met an account it cannot explain")
                    RestoreBootDecision.RESUME_BOUND_IMPORT -> {
                        disablePendingRestoredAccount(pending!!.accountId)
                        check(awaitRestoredUsername(pending.accountId).isNotEmpty()) {
                            "Interrupted restore authentication is unresolved"
                        }
                    }
                    RestoreBootDecision.DISABLE_BOUND -> disablePendingRestoredAccount(pending!!.accountId)
                    RestoreBootDecision.FINISH_ROLLBACK -> {
                        check(completeArchiveRestoreRollback(pending!!)) { "Restore cleanup remains unresolved" }
                        list = JamiService.getAccountList()
                    }
                    RestoreBootDecision.CLEAR_NOTHING_CREATED -> {
                        check(completeArchiveRestoreRollback(pending!!)) { "Restore cleanup remains unresolved" }
                    }
                }
                check(initializeArchiveProtection(list)) {
                    "Device archive protection is unavailable"
                }
                pendingIdentityRestore?.takeIf { it.pairingOperation == null || it.pairingAcknowledged }
                    ?.let(::completePendingRestorePreparation)
                if (resetAccount != null && list.contains(resetAccount)) disablePendingRestoredAccount(resetAccount)
                val picked = if (resetAccount == null) pickAccount(list, pendingIdentityRestore?.previousAccountId.orEmpty()) else null
                if (picked != null) {
                    pinCallPolicy(picked)
                    selectAccount(picked)
                    refreshRoutingSnapshot(picked)
                    preparedNetworkOwner = captureAccountScope(picked)
                    val details = JamiService.getAccountDetails(picked).toNative()
                    keepOnline = details["Account.enable"] != "false"
                    val jid = details["Account.username"] ?: ""
                    Log.i(TAG, "daemon up — reusing account $picked jamiId=$jid")
                } else {
                    Log.i(TAG, "daemon up — no account yet")
                }
                pendingIdentityRestoreOwner = pendingIdentityRestore?.let { accountAuthority.capture() }
                // Identity creation is allowed only after every boot
                // prerequisite above has completed successfully.
                started = true
                // The daemon loaded accounts inactive. Legacy/corrupt policy
                // stays offline until Dart commits normalized local privacy.
                picked?.let { activatePreparedAccount(it) }
            } catch (e: Throwable) {
                started = false
                identityRestoreRecoveryFailed = identityRestoreRecoveryFailed || pendingIdentityRestore != null
                Log.e(TAG, "daemon init failed", e)
            }
        }
    }

    /** Run a daemon op on the worker thread; deliver the result on the main thread. */
    internal fun <T> submit(block: () -> T?, cb: (T?) -> Unit) =
        submit(DaemonOperation.GENERIC, null, block, cb)

    internal fun <T> submit(
        operation: DaemonOperation = DaemonOperation.GENERIC,
        callId: String? = null,
        block: () -> T?,
        cb: (T?) -> Unit,
    ) {
        val captures = operation == DaemonOperation.START_VIDEO ||
            operation == DaemonOperation.PLACE_CALL || operation == DaemonOperation.ANSWER_CALL
        val uiOwner = if (captures) captureUiAuthority.capture() else null
        worker.execute(operation, diagnosticCallToken(callId)) {
            val r = try {
                if (captures && !captureUiAuthority.owns(uiOwner)) null else {
                    if (captures) captureCommandOwner.set(uiOwner)
                    block()
                }
            } catch (e: Throwable) { Log.e(TAG, "daemon op failed", e); null }
            finally { if (captures) captureCommandOwner.remove() }
            main.post { cb(r) }
        }
    }

    /** Run a command on the daemon worker and preserve failure as part of the MethodChannel contract. */
    internal fun submitCommand(block: () -> Unit, cb: (Throwable?) -> Unit) =
        submitCommand(DaemonOperation.GENERIC, null, block, cb)

    internal fun submitCommand(
        operation: DaemonOperation = DaemonOperation.GENERIC,
        callId: String? = null,
        block: () -> Unit,
        cb: (Throwable?) -> Unit,
    ) {
        worker.execute(operation, diagnosticCallToken(callId)) {
            val failure: Throwable? = try {
                block()
                null
            } catch (e: Throwable) {
                Log.e(TAG, "daemon command failed", e)
                e
            }
            main.post { cb(failure) }
        }
    }

    private fun monotonicMs(): Long = System.nanoTime() / 1_000_000L

    private fun diagnosticsEnabled(): Boolean =
        debugBuild || AndroidLog.isLoggable(WORKER_TRACE_TAG, AndroidLog.VERBOSE)

    private fun diagnosticCallToken(callId: String?): String? =
        if (diagnosticsEnabled()) diagnosticCallTokens.token(callId) else null

    private fun traceDiagnostic(message: String) {
        if (diagnosticsEnabled()) AndroidLog.v(WORKER_TRACE_TAG, message)
    }

    private fun callSignalOperation(state: String): String = when (state) {
        "CURRENT" -> "STATE_CURRENT"
        "RINGING" -> "STATE_RINGING"
        "INCOMING" -> "STATE_INCOMING"
        "HUNGUP" -> "STATE_HUNGUP"
        "OVER" -> "STATE_OVER"
        "FAILURE" -> "STATE_FAILURE"
        "BUSY" -> "STATE_BUSY"
        "PEER_BUSY" -> "STATE_PEER_BUSY"
        else -> "STATE_OTHER"
    }

    private fun beginCallSignal(operation: String, callId: String): Long? {
        if (!diagnosticsEnabled()) return null
        return callSignalTracker.queued(
            operation = operation,
            callToken = diagnosticCallToken(callId),
            stallAfterMs = 3_000L,
            nowMs = monotonicMs(),
            thread = Thread.currentThread(),
        )
    }

    private fun acquiredCallSignal(sequence: Long?) {
        if (sequence != null) callSignalTracker.started(sequence, monotonicMs(), Thread.currentThread())
    }

    private fun finishedCallSignal(sequence: Long?, failure: Throwable? = null) {
        if (sequence != null) callSignalTracker.finished(sequence, monotonicMs(), failure)
    }

    private fun pollDiagnosticStalls() {
        if (!diagnosticsEnabled()) return
        try {
            val now = monotonicMs()
            val stalls = workerTracker.pollStalls(now) + callSignalTracker.pollStalls(now)
            for (stall in stalls) dumpDiagnosticStall(stall)
        } catch (t: Throwable) {
            AndroidLog.w(WORKER_TRACE_TAG, "diagnostic watchdog failed: ${t.javaClass.simpleName}")
        }
    }

    private fun dumpDiagnosticStall(stall: DiagnosticStall) {
        AndroidLog.w(
            WORKER_TRACE_TAG,
            "STALL lane=${stall.lane} seq=${stall.sequence} op=${stall.operation}" +
                (stall.callToken?.let { " call=$it" } ?: "") +
                " phase=${stall.phase} elapsedMs=${stall.elapsedMs}",
        )
        AndroidLog.w(
            WORKER_TRACE_TAG,
            "STATE placing=$placingOutgoing active=${diagnosticCallToken(activeCallId) ?: "-"} " +
                "winner=${diagnosticCallToken(currentWinnerCallId) ?: "-"} incoming=${incomingCalls.snapshot().size} " +
                "peers=${callPeers.size} rejected=${rejectedCallIds.size} video=${videoPhase.javaClass.simpleName} " +
                "workerQueue=${workerTracker.pendingSummary()} signalQueue=${callSignalTracker.pendingSummary()}",
        )
        val threads = linkedSetOf<Thread>()
        stall.thread?.let(threads::add)
        worker.thread()?.let(threads::add)
        for (thread in threads) {
            AndroidLog.w(
                WORKER_TRACE_TAG,
                "THREAD name=${thread.name.take(64)} ref=${System.identityHashCode(thread)} state=${thread.state}",
            )
            for (frame in thread.stackTrace.take(48)) {
                AndroidLog.w(WORKER_TRACE_TAG, "  at ${frame.className}.${frame.methodName}(${frame.fileName}:${frame.lineNumber})")
            }
        }
        for (event in (workerTracker.recentEvents() + callSignalTracker.recentEvents()).takeLast(32)) {
            AndroidLog.w(WORKER_TRACE_TAG, "RECENT $event")
        }
    }

    // ---- ops (called on the worker via submit) ----

    /** Pick the identity account deterministically. When the daemon lists MORE THAN ONE account (a stray/duplicate
     *  can linger — e.g. an old onboarding blip), prefer the one that actually has a contact (your person) over
     *  whichever getAccountList() happens to order first, so which identity loads is never a coin-flip. With one
     *  account this is just list[0]; a brand-new account has no contacts yet but is the only entry. */
    private fun pickAccount(list: StringVect, preferred: String = ""): String? {
        if (list.size == 0) return null
        val ids = (0 until list.size).map { list.get(it) }
            .filterNot { pendingIdentityRestore?.excludes(it) == true }.sorted()
        if (ids.isEmpty()) return null
        if (preferred.isNotEmpty() && ids.contains(preferred)) return preferred
        if (ids.size == 1) return ids.first()
        for (id in ids) {
            try { if (JamiService.getContacts(id).size > 0) return id } catch (_: Throwable) {}
        }
        return ids.first()
    }

    /** Finish an archive migration/restore re-key interrupted after the live archive changed password. Worker only. */
    private fun recoverInterruptedArchiveRekey(accounts: StringVect): Boolean {
        val hadJournal = try {
            ArchiveRecoveryJournal.exists(appContext)
        } catch (e: Throwable) {
            archiveRecoveryBlocked = true
            Log.e(TAG, "archive recovery journal could not be inspected", e)
            return false
        }
        val record = try {
            ArchiveRecoveryJournal.load(appContext)
        } catch (e: Throwable) {
            archiveRecoveryBlocked = hadJournal
            Log.e(TAG, "archive recovery journal could not be opened", e)
            return false
        } ?: run {
            archiveRecoveryBlocked = false
            return true
        }
        val ids = (0 until accounts.size).map { accounts.get(it) }
        if (!ids.contains(record.accountId)) {
            val cleared = ArchiveRecoveryJournal.clear(appContext)
            archiveRecoveryBlocked = !cleared
            return cleared
        }

        // First test the desired state without rewriting the archive. A crash
        // can occur after a durable replace but before the journal is cleared.
        var desiredIsValid = try {
            JamiService.isPasswordValid(record.accountId, record.currentSecret)
        } catch (_: Throwable) {
            false
        }
        if (!desiredIsValid) {
            try {
                JamiService.changeAccountPassword(
                    record.accountId,
                    record.transientPassphrase,
                    record.currentSecret,
                )
            } catch (_: Throwable) {
                false
            }
            desiredIsValid = try {
                JamiService.isPasswordValid(record.accountId, record.currentSecret)
            } catch (_: Throwable) {
                false
            }
        }

        if (desiredIsValid && ArchiveRecoveryJournal.clear(appContext)) {
            archiveSecret = record.currentSecret
            archiveRecoveryBlocked = false
            Log.i(TAG, "completed interrupted archive re-key")
            return true
        } else {
            archiveRecoveryBlocked = true
            Log.e(TAG, "interrupted archive re-key could not be recovered")
            return false
        }
    }

    /**
     * Load the Keystore-sealed working secret, finish any interrupted
     * passphrase round-trip, and migrate every loaded plaintext archive once.
     *
     * Worker only. Failure is sticky for this process and blocks account
     * creation/import/export; silently falling back to an empty password would
     * downgrade protection precisely when the archive state is uncertain.
     */
    private fun initializeArchiveProtection(accounts: StringVect): Boolean {
        val stored = try {
            ArchiveSecretStore.loadOrCreate(appContext)
        } catch (e: Throwable) {
            Log.e(TAG, "device archive secret could not be opened", e)
            archiveRecoveryBlocked = true
            archiveProtectionReady = false
            return false
        }

        archiveSecret = stored.secret
        val pending = pendingIdentityRestore
        if (pending?.phase == "importing" && pending.pairingOperation == null && pending.accountId.isNotEmpty() &&
            accounts.contains(pending.accountId)) {
            val recoveryReady = try {
                val existing = ArchiveRecoveryJournal.load(appContext)
                if (existing != null) existing.accountId == pending.accountId
                else ArchiveRecoveryJournal.save(appContext,
                    ArchiveRecoveryRecord(pending.accountId, stored.secret, pending.transientPassphrase))
            } catch (_: Throwable) { false }
            if (!recoveryReady) {
                archiveProtectionReady = false
                archiveRecoveryBlocked = true
                return false
            }
        }
        if (!recoverInterruptedArchiveRekey(accounts)) {
            archiveProtectionReady = false
            return false
        }
        // A legacy recovery journal can target the old empty working password.
        // The sealed device secret remains authoritative after that
        // transaction has been repaired.
        archiveSecret = stored.secret

        val accountIds = (0 until accounts.size).map { accounts.get(it) }
        var reconciled = true
        for (candidateAccount in accountIds) {
            // An unacknowledged link is an explicitly owned, inactive admission,
            // not a legacy plaintext archive to migrate or an identity to adopt.
            if (pending?.pairingOperation != null && !pending.pairingAcknowledged &&
                pending.accountId == candidateAccount) continue
            val details = try {
                JamiService.getAccountDetails(candidateAccount).toNative()
            } catch (e: Throwable) {
                Log.e(TAG, "archive protection details could not be read", e)
                reconciled = false
                break
            }
            val hasPassword = when (details["Account.archiveHasPassword"]) {
                "true" -> true
                "false" -> false
                else -> {
                    Log.e(TAG, "archive protection state is missing or malformed")
                    reconciled = false
                    break
                }
            }
            val protected = reconcileArchiveProtection(
                accountId = candidateAccount,
                deviceSecret = stored.secret,
                archiveHasPassword = hasPassword,
                saveRecovery = { ArchiveRecoveryJournal.save(appContext, it) },
                changePassword = { old, next ->
                    try {
                        JamiService.changeAccountPassword(candidateAccount, old, next)
                    } catch (_: Throwable) {
                        false
                    }
                },
                validatePassword = { password ->
                    try {
                        JamiService.isPasswordValid(candidateAccount, password)
                    } catch (_: Throwable) {
                        false
                    }
                },
                clearRecovery = { ArchiveRecoveryJournal.clear(appContext) },
                recover = { recoverInterruptedArchiveRekey(JamiService.getAccountList()) },
            )
            if (!protected) {
                reconciled = false
                break
            }
        }

        archiveProtectionReady = reconciled
        archiveRecoveryBlocked = !reconciled
        if (reconciled) {
            Log.i(TAG, "device archive protection ready")
        } else {
            Log.e(
                TAG,
                "device archive protection could not be reconciled; refusing password-sensitive operations",
            )
        }
        return reconciled
    }

    /** Worker-only. Exact persisted consent is retained until Dart clears preferences. */
    internal fun resetDoorlight(expectedAccount: String): Boolean = try {
        check(started && archiveProtectionReady && !archiveRecoveryBlocked)
        val marker = resetDoorlightMarker()
        check(pendingIdentityRestore == null && !identityRestoreCommitting &&
            !identityRestoreRecoveryFailed && pairingEntry?.flow?.terminal != false)
        synchronized(callLifecycleLock) {
            check(activeCallId == null && activeGroupConferenceId == null &&
                pendingGroupConferenceId == null && reservedCallPeerId == null && !placingOutgoing)
            check(accountId == null || accountId == expectedAccount)
        }
        val list = JamiService.getAccountList()
        resetLocalAccount(expectedAccount, marker, accountId, (0 until list.size).map { list.get(it) },
            retire = {
                synchronized(callLifecycleLock) {
                    check(activeCallId == null && activeGroupConferenceId == null &&
                        pendingGroupConferenceId == null && reservedCallPeerId == null && !placingOutgoing)
                    resetDoorlightPending = true
                }
                if (!stopRecorderBeforeCall()) false else {
                    if (list.contains(expectedAccount)) disablePendingRestoredAccount(expectedAccount)
                    selectAccount("")
                    accountAuthority.select(null)
                    accountId = null
                    true
                }
            },
            remove = { JamiService.removeAccount(it) },
            removed = { id ->
                !JamiService.getAccountList().contains(id) && listOf("files", "cache").all {
                    !java.nio.file.Files.exists(File(File(appContext.filesDir, it), id).toPath(),
                        java.nio.file.LinkOption.NOFOLLOW_LINKS)
                } && MessageNotifications.retireRestoredAccountNotifications(appContext)
            })
    } catch (_: Throwable) { false }

    fun ensureAccount(
        displayName: String,
        preferredAccountId: String = "",
        preferredPeerId: String = "",
        createIfMissing: Boolean = false,
    ): Map<String, Any?> {
        check(started) { "Native engine is unavailable" }
        check(!resetDoorlightPending) { "Finish resetting and restart Doorlight" }
        check(archiveProtectionReady) { "Device archive protection is unavailable" }
        val list = JamiService.getAccountList()
        val existing = pickAccount(list, preferredAccountId)
        check(!createIfMissing || pendingIdentityRestore == null) { "An identity restore is pending" }
        if (existing == null && !createIfMissing) {
            return mapOf("status" to "noAccount")
        }
        val safeDisplayName = ProfileWireBounds.displayName(displayName)?.trim().orEmpty()
        val id = existing ?: createAccount(
            safeDisplayName.takeIf(String::isNotEmpty)
                ?: throw IllegalArgumentException("Invalid display name"),
        )
        pinCallPolicy(id)
        selectAccount(id)
        val jamiId = awaitUsername(id)
        refreshRoutingSnapshot(id)
        val details = JamiService.getAccountDetails(id).toNative()
        val storedDisplayName =
            ProfileWireBounds.displayName(details["Account.displayName"].orEmpty()).orEmpty()
        val effectiveDisplayName = storedDisplayName.ifEmpty { safeDisplayName.ifEmpty { "Me" } }
        Log.i(TAG, "ensureAccount($displayName) jamiId=$jamiId")
        // Surface deviceAnnounced now so the UI can gate the first call until the account is actually reachable
        // on the DHT — a cold daemon often isn't ready the instant it REGISTERs, so the first call races ICE
        // setup and FAILUREs. (volatileAccountDetailsChanged also emits this when it flips later.)
        val announced = JamiService.getVolatileAccountDetails(id).toNative()["Account.deviceAnnounced"] == "true"
        announcedByAccount[id] = announced
        emit(mapOf("type" to "deviceAnnounced", "accountId" to id, "announced" to announced))
        // Surface the PERSISTED Account.enable so Dart can reconcile the appear-offline pref with the daemon's
        // truth (the two are written non-atomically; a crash between them must not leave a silently-dark boot
        // under a "visible" UI — or vice versa).
        val enabled = details["Account.enable"] != "false"
        setOnlineLifetime(enabled)
        val avatar = readPeerProfile(
            File(File(File(appContext.filesDir, "files"), id), "profile.vcf"),
        )?.avatarBase64.orEmpty()
        return mapOf("status" to "ok", "accountId" to id, "jamiId" to jamiId, "displayName" to effectiveDisplayName,
            "avatarBase64" to avatar,
            "enabled" to enabled, "announced" to announced,
            "registration" to (registrationByAccount[id] ?: "UNREGISTERED"))
    }

    private fun createAccount(displayName: String): String {
        val deviceSecret = archiveSecret
        check(archiveProtectionReady && ArchiveSecretFormat.isValid(deviceSecret)) {
            "Device archive protection is unavailable"
        }
        val details = StringMap.toSwig(
            mapOf(
                "Account.type" to "RING",
                "Account.displayName" to displayName,
                // libjami creates archive.gz encrypted from birth instead of
                // writing a plaintext archive and migrating it afterward.
                "Account.archivePasswordScheme" to "password",
                "Account.archivePassword" to deviceSecret,
                // reachable while backgrounded via the jami.net DHT proxy (the real client does this for push)
                "Account.proxyEnabled" to "true",
                // Glare happens before either leg is CURRENT, so the daemon skips this gate and still arbitrates.
                // Once a call is CURRENT, reject a second call inside libjami before it can ring or wait.
                DENY_SECOND_CALL_KEY to "true",
                // M7.5 (I2): pin OFF "anyone on the DHT can call me" — non-contacts are refused. It's the daemon
                // default, but we set it explicitly so the gate doesn't depend on a default that could drift.
                "DHT.PublicInCalls" to "false",
                // M7.5 (L3): a NEW account defaults to the 'jami' profile, which reaches peers via the DHT — so the
                // cleartext LAN broadcast of {accountId, displayName} is pure leak. Pin it OFF at creation (not just
                // in applyConnectionProfile, which only runs on a manual profile switch). Selecting 'lan' re-enables.
                "Account.peerDiscovery" to "false",
                "Account.accountDiscovery" to "false",
                "Account.accountPublish" to "false"
            )
        )
        val id = JamiService.addAccount(details)
        Log.i(TAG, "addAccount -> $id")
        return id
    }

    /** Reconcile reused/imported accounts too: an archive can carry a stale or missing daemon default. */
    private fun pinCallPolicy(id: String) {
        if (id.isEmpty()) return
        val details = JamiService.getAccountDetails(id).toNative().toMutableMap()
        if (!pinDenySecondCall(details)) return
        JamiService.setAccountDetails(id, StringMap.toSwig(details))
        Log.i(TAG, "pinCallPolicy($id): $DENY_SECOND_CALL_KEY=true")
    }

    /** Account.username = the 40-hex Jami ID; not populated the instant after create — poll briefly. */
    private fun awaitUsername(id: String): String {
        repeat(50) {
            val u = JamiService.getAccountDetails(id).toNative()["Account.username"] ?: ""
            if (u.isNotEmpty()) return u
            Thread.sleep(100)
        }
        return JamiService.getAccountDetails(id).toNative()["Account.username"] ?: ""
    }

    fun myJamiId(): String {
        val id = accountId ?: return ""
        return JamiService.getAccountDetails(id).toNative()["Account.username"] ?: ""
    }

    /** Legacy pure read for rolling compatibility. Relationship/routing mutation belongs to account/contact
     *  callbacks and explicit trust commands; this accessor never refreshes or selects native routing. */
    fun peerId(): String {
        val acc = accountId ?: return ""
        if (routingSnapshot.accountId != acc) return ""
        return routingSnapshot.friends.keys.firstOrNull().orEmpty()
    }

    fun placeCall(
        peer: String,
        withVideo: Boolean = false,
        displayRotationDeg: Int = 0,
        initialAudioMuted: Boolean = false,
    ): Map<String, Any> {
        val failed = mapOf<String, Any>(
            "callId" to "",
            "cameraOn" to false,
            "outgoingVideoKind" to "off",
            "outgoingVideoRevision" to outgoingVideo.epoch,
        )
        if (pendingIdentityRestore != null || identityRestoreRecoveryFailed) return failed
        val acc = accountId ?: return failed
        val targetPeer = bareJamiId(peer)
        if (targetPeer.isEmpty() || !routingSnapshot.isTrusted(targetPeer)) return failed
        val placementBarrier = CountDownLatch(1)
        synchronized(callLifecycleLock) {
            // A call may have become active while a video placement was waiting on Android's permission dialog.
            if (activeCallId != null || activeGroupConferenceId != null || reservedCallPeerId != null) return failed
            placingOutgoing = true
            reservedCallPeerId = targetPeer
            outgoingPlacementBarrier = placementBarrier
            placementAbandoned = false
            winnerCallIdDuringPlacement = null
            terminalDuringPlacement.clear()
            // This value is part of the initial libjami offer. PTT and voice activation
            // therefore start privacy-closed instead of waiting for Dart's CURRENT transaction.
            micMuted = initialAudioMuted
        }
        // Intent-first: arm the camera lease (register + default the device — no hardware open, no
        // wait) and dial immediately with an ENABLED, unmuted, EMPTY-source video entry. The daemon
        // resolves the default device at addMediaStream and asks for frames via StartCapture only
        // when media negotiation completes; capture failure later downgrades this call's video
        // honestly instead of ever delaying call creation.
        var videoIntent = false
        return withOutgoingPlacementCompletion(
            placementBarrier, callLifecycleLock, { outgoingPlacementBarrier },
            retire = {
                placingOutgoing = false
                clearCallReservationIfIdleLocked(targetPeer)
                placementAbandoned = false
                winnerCallIdDuringPlacement = null
                terminalDuringPlacement.clear()
                outgoingPlacementBarrier = null
            },
        ) {
            try {
                if (!stopRecorderBeforeCall()) return@withOutgoingPlacementCompletion failed
                videoIntent = withVideo && prepareCameraLease(displayRotationDeg, ownerCallId = null)
                val media = if (videoIntent) {
                    videoMediaList(initialAudioMuted, videoMuted = false, source = "")
                } else {
                    audioMedia(initialAudioMuted)
                }
                // If a crossed leg became CURRENT while camera permission/preparation was in progress, do not create
                // a new outgoing SIP leg just to retire it. A merely incoming leg is intentionally not a winner here:
                // its callback waits for this placement event, then libjami refreshes and arbitrates both real legs.
                val winnerBeforeDial = synchronized(callLifecycleLock) {
                    val winner = currentWinnerCallId ?: winnerCallIdDuringPlacement
                    if (winner != null) {
                        placingOutgoing = false
                        if (reservedCallPeerId == targetPeer && currentWinnerCallId == null) {
                            reservedCallPeerId = callPeers[winner]
                        }
                        winnerCallIdDuringPlacement = null
                        terminalDuringPlacement.clear()
                    }
                    winner
                }
                if (winnerBeforeDial != null) {
                    if (videoIntent) beginLeaseReplacement(acc, winnerBeforeDial)
                    Log.i(TAG, "placeCall cancelled: CURRENT $winnerBeforeDial established before dialing")
                    return@withOutgoingPlacementCompletion failed
                }
                val callId = JamiService.placeCallWithMedia(acc, targetPeer, media)
                var endedEarly = false
                var anotherCallWon = false
                var abandoned = false
                var adjudicationWinner: String? = null
                synchronized(callLifecycleLock) {
                    val placementWinner = winnerCallIdDuringPlacement
                    endedEarly = callId.isNotEmpty() && terminalDuringPlacement.remove(callId)
                    abandoned = placementAbandoned
                    placementAbandoned = false
                    if (callId.isNotEmpty() && !endedEarly) {
                        callPeers[callId] = targetPeer
                    }
                    val active = activeCallId
                    if (callId.isNotEmpty() && !endedEarly && !abandoned && placementWinner != null && placementWinner != callId) {
                        anotherCallWon = true
                        rejectedCallIds.add(callId)
                    } else if (callId.isNotEmpty() && !endedEarly && !abandoned && (active == null || active == callId)) {
                        activeCallId = callId
                        localInputId?.let { sinkId ->
                            activeVideoSinks.computeIfPresent(sinkId) { _, sink -> sink.copy(callId = callId) }
                        }
                    } else if (callId.isNotEmpty() && !endedEarly && !abandoned) {
                        anotherCallWon = true
                        // Decide + tombstone atomically with terminal cleanup; adding this after unlock can recreate a
                        // tombstone after the loser's final terminal callback already removed it.
                        rejectedCallIds.add(callId)
                    } else if (callId.isNotEmpty() && abandoned) {
                        rejectedCallIds.add(callId)
                    }
                    placingOutgoing = false
                    if (callId.isEmpty() || endedEarly || abandoned) {
                        clearCallReservationIfIdleLocked(targetPeer)
                    }
                    winnerCallIdDuringPlacement = null
                    adjudicationWinner = currentWinnerCallId?.takeIf { winner ->
                        videoIntent && anotherCallWon && activeCallId == winner && winner != callId
                    }
                    terminalDuringPlacement.clear()
                }
                val offeredVideo = videoIntent && callId.isNotEmpty() && !endedEarly && !anotherCallWon && !abandoned
                if (offeredVideo) {
                    // Bind the armed (still unbound) lease to the returned call. A lease already adopted
                    // by a CURRENT-before-reply winner, or already revoked, is left untouched.
                    executeVideoDecisions(transitionVideo { phase ->
                        LocalVideoPolicy.bindCall(phase, phase.currentLease()?.epoch ?: -1L, callId)
                    })
                } else if (videoIntent) {
                    // The placement lost (winner/terminal/abandoned). Adjudicate a surviving winner via
                    // the exact-source rule; otherwise revoke. Never a speculative glare re-INVITE here.
                    val winner = adjudicationWinner
                    if (winner != null) beginLeaseReplacement(acc, winner)
                    else {
                        revokeLease()
                        reconcileFgsAfterLeaseRevoke()
                    }
                }
                if (abandoned && callId.isNotEmpty()) {
                    // Recents dismissal ran while the daemon was still creating this call: end it now.
                    try { JamiService.hangUp(acc, callId) } catch (e: Throwable) { Log.e(TAG, "hangUp(abandoned placement)", e) }
                }
                if (anotherCallWon) {
                    try { JamiService.hangUp(acc, callId) } catch (e: Throwable) { Log.e(TAG, "hangUp(placement lost)", e) }
                }
                Log.i(TAG, "placeCall($peer) requestedVideo=$withVideo videoIntent=$offeredVideo entries=${media.size} -> $callId")
                if (offeredVideo) main.post {
                    val stillActive = synchronized(callLifecycleLock) {
                        activeCallId == callId && !recentTerminalCallIds.contains(callId)
                    }
                    if (stillActive) startCallAudio(video = true)
                }
                val source = outgoingVideo
                return@withOutgoingPlacementCompletion mapOf(
                    "callId" to callId,
                    "cameraOn" to offeredVideo,
                    "outgoingVideoKind" to if (offeredVideo) "camera" else "off",
                    "outgoingVideoUri" to if (offeredVideo) source.uri else "",
                    "outgoingVideoRevision" to source.epoch,
                    "outgoingVideoWidth" to source.width,
                    "outgoingVideoHeight" to source.height,
                )
            } catch (e: Throwable) {
                if (videoIntent) {
                    revokeLease()
                    reconcileFgsAfterLeaseRevoke()
                }
                throw e
            }
        }
    }

    private fun incomingCallNotificationId(callId: String): Int =
        INCOMING_CALL_NOTIFICATION_BASE xor callId.hashCode()

    private fun directCallAllowed(account: String, peer: String): Boolean {
        if (!isActiveAccount(account) || pendingIdentityRestore != null || identityRestoreRecoveryFailed) return false
        return try {
            val routing = routingSnapshot
            PendingRemovalCallPolicy(appContext.getSharedPreferences(
                CanonicalIncomingCallMicrophonePolicy.PREFERENCES_NAME, Context.MODE_PRIVATE,
            )).allows(account, peer, routing) && routingSnapshot === routing && isActiveAccount(account) &&
                pendingIdentityRestore == null && !identityRestoreRecoveryFailed
        } catch (_: Exception) { false }
    }

    private fun retireDeniedIncomingCall(callId: String, pending: PendingIncomingCall) {
        synchronized(callLifecycleLock) {
            if (incomingCalls[callId] !== pending) return
            rejectedCallIds.add(callId)
            incomingCalls.remove(callId)
            clearCallReservationIfIdleLocked(pending.fromJamiId)
        }
        cancelIncomingCallNotification(callId)
        worker.execute(DaemonOperation.CALLBACK_REFUSE, diagnosticCallToken(callId)) {
            if (!isActiveAccount(pending.accountId)) return@execute
            try { JamiService.refuse(pending.accountId, callId) } catch (_: Throwable) {}
        }
    }

    private fun showIncomingCallNotification(callId: String) {
        main.post {
            val call = incomingCalls[callId] ?: return@post
            if (!directCallAllowed(call.accountId, call.fromJamiId)) {
                retireDeniedIncomingCall(callId, call)
                return@post
            }
            if (!shouldShowIncomingCallNotification(activeCallId, activityResumed)) return@post
            try {
                val manager = appContext.getSystemService(NotificationManager::class.java)
                val channel = NotificationChannel(
                    INCOMING_CALL_CHANNEL,
                    "Incoming calls",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 500, 350, 500)
                    setSound(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                }
                manager.createNotificationChannel(channel)
                val openApp = Intent(appContext, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                val notificationId = incomingCallNotificationId(callId)
                val contentIntent = PendingIntent.getActivity(
                    appContext,
                    notificationId,
                    openApp,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                fun actionIntent(action: String, requestOffset: Int) =
                    PendingIntent.getBroadcast(
                        appContext,
                        notificationId xor requestOffset,
                        Intent(appContext, IncomingCallActionReceiver::class.java).apply {
                            this.action = action
                            putExtra(EXTRA_INCOMING_CALL_ID, callId)
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                val caller = readPeerProfile(
                    cachedPeerProfile(call.accountId, call.fromJamiId),
                )?.displayName?.takeIf { it.isNotBlank() } ?: "Someone"
                val notification = Notification.Builder(appContext, INCOMING_CALL_CHANNEL)
                    .setContentTitle("Incoming Doorlight call")
                    .setContentText("$caller is calling")
                    .setSmallIcon(R.drawable.ic_doorlight_notification)
                    .setCategory(Notification.CATEGORY_CALL)
                    .setVisibility(Notification.VISIBILITY_PRIVATE)
                    .setContentIntent(contentIntent)
                    // Android shows this Activity over a locked screen. If Android 14+ special access has been
                    // denied, SystemUI intentionally degrades it to an expanded lock-screen heads-up alert.
                    .setFullScreenIntent(contentIntent, true)
                    .setOngoing(true)
                    .setTimeoutAfter(35_000)
                    .addAction(
                        android.R.drawable.sym_action_call,
                        "Accept",
                        actionIntent(ACTION_ACCEPT_INCOMING_CALL, 1),
                    )
                    .addAction(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "Decline",
                        actionIntent(ACTION_DECLINE_INCOMING_CALL, 2),
                    )
                    .addAction(
                        android.R.drawable.ic_menu_view,
                        "Ignore",
                        actionIntent(ACTION_IGNORE_INCOMING_CALL, 3),
                    )
                    .build()
                if (incomingCalls[callId] !== call) return@post
                if (!directCallAllowed(call.accountId, call.fromJamiId)) {
                    retireDeniedIncomingCall(callId, call)
                    return@post
                }
                manager.notify(notificationId, notification)
            } catch (e: Throwable) {
                // Notification permission can be denied, and vendor notification services can fail independently.
                // The native pending-ring replay still lets a later foreground Activity recover the live call.
                Log.e(TAG, "incoming call notification failed", e)
            }
        }
    }

    private fun cancelIncomingCallNotification(callId: String) {
        if (!::appContext.isInitialized) return
        main.post {
            appContext.getSystemService(NotificationManager::class.java)
                .cancel(incomingCallNotificationId(callId))
        }
    }

    private fun surfacePendingIncomingCallIfIdle() {
        if (activeCallId != null) return
        val acc = accountId ?: return
        val pending = incomingCalls.snapshot().entries
            .firstOrNull { (id, call) ->
                if (call.accountId != acc) false
                else if (directCallAllowed(acc, call.fromJamiId)) true
                else { retireDeniedIncomingCall(id, call); false }
            } ?: return
        val callId = pending.key
        val call = pending.value
        showIncomingCallNotification(callId)
        // Dart may already hold this as its hidden pre-CURRENT leg; re-emission is idempotent. It is also needed
        // when the prior visible call was CURRENT, because Dart correctly did not retain a policy-denied ring.
        emit(mapOf("type" to "incomingCall", "accountId" to acc,
            "callId" to callId, "fromJamiId" to call.fromJamiId,
            "fromName" to "", "withVideo" to listHasActiveVideo(call.offer)))
    }

    fun saveAppSettingsDocument(document: String, callback: (Boolean) -> Unit) {
        try {
            val owner = captureAccountScope()
            val save = incomingMicrophoneSettings.prepareSave(document)
            submit(block = {
                val saved = save()
                MessageNotifications.applyFriendPolicy(appContext)
                if (saved && started && accountAuthority.owns(owner)) owner?.accountId?.let { activatePreparedAccount(it) }
                saved
            }) { callback(it == true) }
        } catch (_: Exception) {
            callback(false)
        }
    }

    fun answerCallFromNotification(callId: String): Boolean = answerNotificationWithMicrophonePolicy(
        callId, accountId, incomingCalls, routingSnapshot,
        readPolicy = { incomingMicrophoneSettings.load() },
        restorePending = pendingIdentityRestore != null || identityRestoreRecoveryFailed,
        answer = ::answerCall,
    )

    internal fun messageAlertsAllowed(scope: NativeAccountScope, owner: String, group: Boolean): Boolean {
        val account = scope.accountId ?: return false
        if (!accountAuthority.owns(scope) || !isActiveAccount(account) || identityRestoreRecoveryFailed || pendingIdentityRestore != null) return false
        val policy = incomingMicrophoneSettings.currentDocument()?.let(FriendPreferencePolicy::decode) ?: return false
        return if (group) policy.allowsGroupMessageAlerts(account) else policy.allowsMessageAlerts(account, owner)
    }

    private fun friendHologramsAllowed(account: String, peer: String): Boolean =
        incomingMicrophoneSettings.currentDocument()?.let(FriendPreferencePolicy::decode)
            ?.allowsHolograms(account, peer) == true

    fun answerCall(callId: String, initialAudioMuted: Boolean = false): Boolean {
        if (pendingIdentityRestore != null || identityRestoreRecoveryFailed) return false
        val acc = accountId
        if (acc == null) { Log.w(TAG, "answerCall($callId) — NO account, cannot accept"); return false }
        // Required for video: MIRROR the offered media list rather than always sending audio-only. For an
        // audio-only offer this is identical to M1; for a video offer it answers receive-only (video MUTED,
        // still ENABLED) so we render the peer without auto-enabling our own camera.
        messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.ANSWER, true)
        try {
            return answerRetainedIncomingCall(
                callId, acc, incomingCalls, allowed = ::directCallAllowed,
                prepare = ::stopRecorderBeforeCall,
                denied = { retireDeniedIncomingCall(callId, it) },
            ) { pending ->
                // Explicit bootstrap state, not the previous call's process-global mute latch.
                micMuted = initialAudioMuted
                val media = mirrorOffer(callId, pending.offer, initialAudioMuted)
                val ok = JamiService.acceptWithMedia(acc, callId, media)
                if (ok) {
                    incomingCalls.remove(callId)
                    cancelIncomingCallNotification(callId)
                }
                Log.i(TAG, "acceptWithMedia($callId) entries=${media.size} -> $ok")
                return@answerRetainedIncomingCall ok
            }
        } finally {
            messagingCaptureAuthority.setBlocked(MessagingCaptureBlocker.ANSWER, false)
        }
    }

    fun refuse(callId: String): Boolean {
        val acc = accountId ?: return false
        val ok = JamiService.refuse(acc, callId)
        if (ok) {
            incomingCalls.remove(callId)
            cancelIncomingCallNotification(callId)
        }
        return ok
    }

    fun hangUp(callId: String): Boolean {
        val acc = accountId ?: return false
        Log.i(TAG, "hangUp($callId)")
        val ok = JamiService.hangUp(acc, callId)
        if (ok) {
            incomingCalls.remove(callId)
            cancelIncomingCallNotification(callId)
        }
        return ok
    }

    /** M8: send an in-call side-channel message (the annotation draw protocol) to the peer on [callId]. Rides the
     *  live call's SIP dialog as an in-dialog SIP MESSAGE over the established P2P transport (NOT the DHT/swarm —
     *  ephemeral, low-latency). The payload travels under our custom MIME; the peer surfaces it via incomingMessage.
     *  Worker thread (a daemon call). isMixed=false (1:1, not a conference); from="" (the daemon fills the sender). */
    fun sendCallMessage(
        callId: String,
        payload: String,
        channel: String = "annotation",
    ): Boolean {
        val scope = captureCallMessage(callId) ?: return false
        return sendCallMessage(scope, payload, channel)
    }

    internal fun captureCallMessage(callId: String): CallMessageScope? =
        synchronized(callLifecycleLock) {
            val acc = accountId ?: return null
            if (callId != activeCallId || callId != currentWinnerCallId ||
                recentTerminalCallIds.contains(callId)) return null
            callMessageAuthority.capture(acc, callId, callPeers[callId].orEmpty())
        }

    internal fun sendCallMessage(
        scope: CallMessageScope,
        payload: String,
        channel: String = "annotation",
    ): Boolean {
        val acc = scope.accountId
        val callId = scope.callId
        if (callId.isEmpty() || payload.isEmpty() ||
            payload.length > MAX_TYPED_CALL_MESSAGE_BYTES
        ) {
            return false
        }
        val payloadBytes = try {
            payload.toByteArray(Charsets.UTF_8).size
        } catch (_: Throwable) {
            return false
        }
        if (payloadBytes > MAX_TYPED_CALL_MESSAGE_BYTES) return false
        val mime = when (channel) {
            "annotation" -> ANNOT_MIME
            "control" -> CONTROL_MIME
            else -> return false
        }
        val ownsCall = synchronized(callLifecycleLock) {
            accountId == acc && activeCallId == callId &&
                currentWinnerCallId == callId &&
                !recentTerminalCallIds.contains(callId) &&
                callPeers[callId] == scope.peer && callMessageAuthority.current(scope)
        }
        if (!ownsCall) return false
        try {
            JamiService.sendTextMessage(acc, callId, StringMap.toSwig(mapOf(mime to payload)), "", false)
        } catch (e: Throwable) {
            Log.e(TAG, "sendCallMessage", e)
            return false
        }
        return true
    }

    /** Recents dismissal sleeps an idle push-backed account. The persistent fallback keeps its prior explicit-exit
     * behavior. Return true while a live call or camera teardown still owns foreground-service lifetime. */
    fun dismissFromRecents(): Boolean {
        backgroundWakeRetryKey = Any()
        if (backgroundWakeEnabled()) {
            AndroidRemoteControlHost.stopLocal("task-dismissed")
            activityResumed = false
            backgroundAtMs = SystemClock.elapsedRealtime()
            taskRemovedWithPush = true
            main.post { applyBackgroundWakeLifetime() }
            return hasCallLifetime()
        }
        setOnlineLifetime(false)
        AndroidRemoteControlHost.stopLocal("task-dismissed")
        val acc = accountId ?: return false
        val active = activeCallId
        val pending = incomingCalls.snapshot()
            .filter { (_, call) -> call.accountId == acc }
            .map { (callId, _) -> callId }
        // An in-flight placement has no call id yet: mark it abandoned so placeCall hangs up
        // whatever id the daemon returns, and revoke the armed camera lease now.
        val asynchronousTeardown = synchronized(callLifecycleLock) {
            if (placingOutgoing) placementAbandoned = true
            pendingProjectionConsent = null
            projectionConsents.clear()
            projectionRollbacks.clear()
            placingOutgoing || videoPhase !is VideoPhase.Idle
        }
        revokeLease()
        if (active == null && asynchronousTeardown) demoteCallFgsIfIdle()
        Log.i(TAG, "dismissFromRecents active=$active pending=${pending.size}")
        worker.execute(DaemonOperation.DISMISS_FROM_RECENTS, diagnosticCallToken(active)) {
            for (callId in pending) {
                try { refuse(callId) } catch (e: Throwable) { Log.e(TAG, "refuse(dismiss)", e) }
            }
            if (active != null) {
                try { JamiService.hangUp(acc, active) } catch (e: Throwable) { Log.e(TAG, "hangUp(dismiss)", e) }
            }
            try { setWakeAccountActive(acc, false) }
            catch (e: Throwable) { Log.e(TAG, "goodbye(dismiss)", e) }
        }
        // Keep the service alive until terminal handling, or until the Camera2 queue has physically
        // processed the revocation above. CallForegroundService must not synchronously remove the
        // CAMERA type while a close is still queued.
        return active != null || asynchronousTeardown
    }

    /** Fire ONE non-swarm reachability probe to [peer] and return the daemon's message id (as a string) so Dart
     *  can correlate the delivery-status event. A PLAIN Jami ID (not swarm:) routes the P2P message-channel path
     *  (opening a channel if needed to wake a cold peer) and is never a git commit — the shared-file history stays
     *  clean. HONEST LIFECYCLE (daemon-verified): the message is queued in the account's message engine, PERSISTED
     *  to cache/<acct>/messages across restarts, and retried on reconnect events until SENT or 20 cumulative
     *  retries (im/message_engine.h MAX_RETRIES); there is no cancel API. The `flags` arg is inert in this daemon
     *  (a marshaling bug drops the onlyConnected bit — configurationmanager.cpp:272), so Dart bounds the queue by
     *  never firing a new probe while one is in flight. "" if it couldn't send. */
    private val presenceProbeEpoch = java.util.concurrent.atomic.AtomicLong(0)
    internal fun retirePresenceProbes() { presenceProbeEpoch.incrementAndGet() }
    internal fun capturePresenceProbe(): Pair<NativeAccountScope, Long>? =
        captureAccountScope()?.let { it to presenceProbeEpoch.get() }

    private fun ownsPresenceProbe(owner: Pair<NativeAccountScope, Long>?): Boolean =
        owner != null && accountAuthority.owns(owner.first) && owner.second == presenceProbeEpoch.get() && keepOnline

    internal fun probeReachable(peer: String, owner: Pair<NativeAccountScope, Long>?): String {
        if (!shareForegroundPresence || !ownsPresenceProbe(owner)) return ""
        val acc = owner!!.first.accountId ?: return ""
        val bare = bareJamiId(peer)
        if (bare.isEmpty() || !routingSnapshot.isTrusted(bare)) return ""
        return try {
            val id = JamiService.sendAccountTextMessage(acc, bare, StringMap.toSwig(mapOf(PROBE_MIME to presenceJson("ping"))), 0)
            if (id == 0L) "" else id.toString() // the daemon returns 0 on its failure paths — honor the "" contract
        } catch (e: Throwable) { Log.e(TAG, "probeReachable", e); "" }
    }

    /** Best-effort composing state for one exact direct conversation. */
    fun sendComposerActivity(expectedAccountId: String, peer: String, conversationId: String, kind: String): Boolean {
        val acc = accountId ?: return false
        val bare = bareJamiId(peer)
        if (expectedAccountId != acc ||
            (kind != "typing" && kind != "idle") ||
            !routingSnapshot.owns(bare, conversationId)) {
            return false
        }
        return try {
            JamiService.setIsComposing(acc, "swarm:$conversationId", kind == "typing")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "sendComposerActivity", e)
            false
        }
    }

    /** Best-effort, connected-contact-only preview for one exact file offer. */
    fun sendFileThumbnail(
        peer: String,
        conversationId: String,
        fileId: String,
        pngBase64: String,
    ): Boolean {
        val acc = accountId ?: return false
        val bare = bareJamiId(peer)
        if (bare !in connectedPeers ||
            !routingSnapshot.isTrusted(bare) ||
            !routingSnapshot.owns(bare, conversationId)
        ) {
            return false
        }
        val body = FileThumbnailWire.encode(
            conversationId,
            fileId,
            pngBase64,
            System.currentTimeMillis(),
        ) ?: return false
        return try {
            JamiService.sendAccountTextMessage(
                acc,
                bare,
                StringMap.toSwig(mapOf(FILE_THUMBNAIL_MIME to body)),
                1,
            ) != 0L
        } catch (e: Throwable) {
            Log.e(TAG, "sendFileThumbnail", e)
            false
        }
    }

    fun listGroupCalls(conversationId: String): List<Map<String, String>> {
        val acc = accountId ?: return emptyList()
        if (routingSnapshot.group(conversationId) == null) return emptyList()
        return snapshot(JamiService.getActiveCalls(acc, conversationId)).filter {
            GroupCallWire.roomId(it["id"].orEmpty()) != null &&
                it["uri"].orEmpty().isNotEmpty() && it["device"].orEmpty().isNotEmpty()
        }
    }

    internal fun reserveGroupCall(scope: NativeAccountScope?, conversationId: String, reservationId: String): Boolean {
        var reserved = false
        invokeAccountCommand(scope) {
            if (!keepOnline || pendingIdentityRestore != null || identityRestoreRecoveryFailed ||
                routingSnapshot.group(conversationId) == null ||
                GroupCallWire.roomId(reservationId) == null) return@invokeAccountCommand
            synchronized(callLifecycleLock) {
                if (activeCallId != null || activeGroupConferenceId != null ||
                    pendingGroupConferenceId != null || reservedCallPeerId != null || placingOutgoing) return@invokeAccountCommand
                pendingGroupConferenceId = reservationId
                groupReservationId = reservationId
                groupPlacementStarted = false
                groupConversationByConference[reservationId] = conversationId
                reserved = true
            }
            if (!stopRecorderBeforeCall()) reserved = false
        }
        if (!reserved && accountAuthority.owns(scope) && scope != null &&
            groupReservationId != reservationId && GroupCallWire.roomId(reservationId) != null) {
            synchronized(callLifecycleLock) {
                detachedGroupReservations[reservationId to reservationId] = scope
                while (detachedGroupReservations.size > 64) detachedGroupReservations.remove(detachedGroupReservations.keys.first())
            }
        }
        return reserved
    }

    fun joinGroupCall(
        conversationId: String,
        conferenceId: String,
        reservationId: String,
        hostUri: String,
        hostDevice: String,
        initialAudioMuted: Boolean,
    ): Map<String, Any> {
        val failed = mapOf<String, Any>("conferenceId" to "", "callId" to "", "hosting" to false)
        if (pendingIdentityRestore != null || identityRestoreRecoveryFailed) return failed
        val acc = accountId ?: return failed
        val route = routingSnapshot.group(conversationId) ?: return failed
        if (GroupCallWire.roomId(conferenceId) == null || route.localRole.isEmpty()) return failed
        synchronized(callLifecycleLock) {
            if (activeCallId != null || activeGroupConferenceId != null ||
                reservationId.isEmpty() || groupReservationId != reservationId || groupPlacementStarted ||
                pendingGroupConferenceId != reservationId ||
                groupConversationByConference[reservationId] != conversationId) return failed
            groupPlacementStarted = true
            groupConversationByConference.remove(reservationId)
            groupConversationByConference[conferenceId] = conversationId
            pendingGroupConferenceId = conferenceId
            micMuted = initialAudioMuted
        }
        var hosting = false
        var issued = false
        return try {
            if (!stopRecorderBeforeCall()) return failed
            val target = if (hostUri.isEmpty() && hostDevice.isEmpty()) {
                val details = JamiService.getAccountDetails(acc).toNative()
                val volatileDetails = JamiService.getVolatileAccountDetails(acc).toNative()
                val self = details["Account.username"].orEmpty()
                val device = volatileDetails["Account.deviceID"].orEmpty()
                if (self.isEmpty() || device.isEmpty()) return failed
                val preferences = JamiService.getConversationPreferences(acc, conversationId).toNative()
                previousGroupHostPreference.putIfAbsent(
                    conversationId,
                    preferences["hostConferences"] ?: "false",
                )
                JamiService.setConversationPreferences(
                    acc,
                    conversationId,
                    StringMap.toSwig(mapOf("hostConferences" to "true")),
                )
                hosting = true
                "rdv:$conversationId/$self/$device/$conferenceId"
            } else {
                val host = bareJamiId(hostUri)
                if (host.isEmpty() || hostDevice.isEmpty() ||
                    listGroupCalls(conversationId).none {
                        it["id"] == conferenceId && bareJamiId(it["uri"]) == host && it["device"] == hostDevice
                    }
                ) return failed
                "rdv:$conversationId/$host/$hostDevice/$conferenceId"
            }
            groupConversationByConference[conferenceId] = conversationId
            activeGroupHosting = hosting
            issued = true
            val callId = JamiService.placeCallWithMedia(
                acc,
                target,
                videoMediaList(initialAudioMuted, videoMuted = true, source = ""),
            )
            if (!hosting && callId.isEmpty()) return failed
            if (callId.isNotEmpty()) groupCallLegs[conferenceId] = callId
            activeGroupConferenceId = conferenceId
            activeGroupHosting = hosting
            pendingGroupConferenceId = null
            main.post { startCallAudio() }
            if (!hosting && callId.isNotEmpty()) {
                val reported = JamiService.getCallDetails(acc, callId).toNative()["CALL_STATE"]
                val state = reported ?: "FAILURE"
                if (state == "CURRENT" || isTerminalCallState(state)) {
                    emit(mapOf("type" to "groupCallLegState", "accountId" to acc,
                        "conferenceId" to conferenceId, "reservationId" to reservationId,
                        "callId" to callId, "state" to state))
                    if (reported != null && isTerminalCallState(state)) clearGroupCall(conferenceId)
                }
            }
            mapOf("conferenceId" to conferenceId, "callId" to callId, "hosting" to hosting)
        } catch (error: Throwable) {
            Log.e(TAG, "joinGroupCall failed")
            failed
        } finally {
            if (!issued && groupReservationId == reservationId) clearGroupCall(conferenceId)
        }
    }

    fun leaveGroupCall(conferenceId: String, reservationId: String): Boolean {
        val acc = accountId ?: return false
        if (reservationId.isEmpty()) return false
        synchronized(callLifecycleLock) {
            if (accountAuthority.owns(detachedGroupReservations[conferenceId to reservationId])) return true
        }
        if (groupReservationId != reservationId || GroupCallWire.roomId(conferenceId) == null ||
            (activeGroupConferenceId != conferenceId && pendingGroupConferenceId != conferenceId)
        ) return false
        val leg = groupCallLegs[conferenceId]
        val ok = if (!groupPlacementStarted && activeGroupConferenceId == null) {
            true
        } else if (leg.isNullOrEmpty()) {
            JamiService.hangUpConference(acc, conferenceId)
        } else {
            JamiService.hangUp(acc, leg)
        }
        val detached = ok &&
            (leg.isNullOrEmpty() || !JamiService.getCallList(acc).contains(leg)) &&
            !JamiService.getConferenceList(acc).contains(conferenceId)
        if (detached) clearGroupCall(conferenceId)
        return detached
    }

    fun setGroupMicMuted(conferenceId: String, muted: Boolean): Boolean {
        if (!muted && (pendingIdentityRestore != null || identityRestoreRecoveryFailed)) return false
        val acc = accountId ?: return false
        if (activeGroupConferenceId != conferenceId) return false
        val target = mediaSignalingTarget(conferenceId)
        val ok = JamiService.muteLocalMedia(acc, target, "MEDIA_TYPE_AUDIO", muted)
        if (ok) micMuted = muted
        return ok
    }

    fun setGroupDeafened(conferenceId: String, deafened: Boolean): Boolean {
        if (activeGroupConferenceId != conferenceId) return false
        return try {
            if (deafened) {
                if (previousGroupPlaybackVolume == null) {
                    previousGroupPlaybackVolume = JamiService.getVolume("speaker")
                }
                JamiService.setVolume("speaker", 0.0)
            } else {
                JamiService.setVolume("speaker", previousGroupPlaybackVolume ?: 1.0)
                previousGroupPlaybackVolume = null
            }
            true
        } catch (error: Throwable) {
            Log.e(TAG, "setGroupDeafened failed", error)
            false
        }
    }

    fun setGroupConferenceLayout(conferenceId: String, layout: Int): Boolean {
        val acc = accountId ?: return false
        if (activeGroupConferenceId != conferenceId || layout !in 0..1) return false
        return try {
            JamiService.setConferenceLayout(acc, conferenceId, layout)
            true
        } catch (error: Throwable) {
            Log.e(TAG, "setGroupConferenceLayout failed", error)
            false
        }
    }

    fun setGroupActiveStream(
        conferenceId: String,
        participantAccountId: String,
        deviceId: String,
        streamId: String,
        active: Boolean,
    ): Boolean {
        val acc = accountId ?: return false
        if (activeGroupConferenceId != conferenceId || participantAccountId.isEmpty() ||
            deviceId.isEmpty() || streamId.isEmpty()
        ) return false
        return try {
            JamiService.setActiveStream(acc, conferenceId, participantAccountId, deviceId, streamId, active)
            true
        } catch (error: Throwable) {
            Log.e(TAG, "setGroupActiveStream failed", error)
            false
        }
    }

    fun muteGroupParticipant(
        conferenceId: String,
        participantAccountId: String,
        deviceId: String,
        streamId: String,
        muted: Boolean,
    ): Boolean {
        val acc = accountId ?: return false
        if (activeGroupConferenceId != conferenceId || participantAccountId.isEmpty() || deviceId.isEmpty()) {
            return false
        }
        return try {
            JamiService.muteStream(acc, conferenceId, participantAccountId, deviceId, streamId, muted)
            true
        } catch (error: Throwable) {
            Log.e(TAG, "muteGroupParticipant failed", error)
            false
        }
    }

    fun disconnectGroupParticipant(
        conferenceId: String,
        participantAccountId: String,
        deviceId: String,
    ): Boolean {
        val acc = accountId ?: return false
        if (activeGroupConferenceId != conferenceId || participantAccountId.isEmpty() || deviceId.isEmpty()) {
            return false
        }
        return try {
            JamiService.hangupParticipant(acc, conferenceId, participantAccountId, deviceId)
            true
        } catch (error: Throwable) {
            Log.e(TAG, "disconnectGroupParticipant failed", error)
            false
        }
    }

    fun publishGroupCallPresence(conversationId: String, payload: String): Boolean {
        val acc = accountId ?: return false
        val route = routingSnapshot.group(conversationId) ?: return false
        if (payload.toByteArray(Charsets.UTF_8).size > GroupCallWire.MAX_PRESENCE_BYTES) return false
        val body = StringMap.toSwig(mapOf(GroupCallWire.PRESENCE_MIME to payload))
        var sent = true
        for (member in route.activeMemberIds) {
            if (member == routingSnapshot.selfId) continue
            sent = JamiService.sendAccountTextMessage(acc, member, body, 0) != 0L && sent
        }
        return sent
    }

    private fun clearGroupCall(
        conferenceId: String,
        expectedReservation: String? = null,
        expectedOwner: NativeAccountScope? = captureAccountScope(),
    ): Boolean {
        val conversation: String?
        val previous: String?
        val volume: Double?
        val decisions: List<VideoDecision>
        synchronized(callLifecycleLock) {
            if (!accountAuthority.owns(expectedOwner) ||
                (expectedReservation != null && groupReservationId != expectedReservation) ||
                (activeGroupConferenceId != conferenceId && pendingGroupConferenceId != conferenceId)) return false
            val reservation = groupReservationId
            if (reservation != null && expectedOwner != null) {
                detachedGroupReservations[conferenceId to reservation] = expectedOwner
                while (detachedGroupReservations.size > 64) detachedGroupReservations.remove(detachedGroupReservations.keys.first())
            }
            decisions = if (videoPhase.currentLease()?.ownerCallId == conferenceId) {
                transitionVideo { LocalVideoPolicy.revoke(it) }
            } else emptyList()
            groupReservationId = null
            groupPlacementStarted = false
            if (activeGroupConferenceId == conferenceId) activeGroupConferenceId = null
            if (pendingGroupConferenceId == conferenceId) pendingGroupConferenceId = null
            activeGroupHosting = false
            groupCallLegs.remove(conferenceId)?.let { leg ->
                if (expectedOwner != null) retiredGroupLegs[leg] = expectedOwner
                while (retiredGroupLegs.size > 64) retiredGroupLegs.keys.firstOrNull()?.let { retiredGroupLegs.remove(it) }
            }
            conversation = groupConversationByConference.remove(conferenceId)
            previous = conversation?.let { previousGroupHostPreference.remove(it) ?: "false" }
            volume = previousGroupPlaybackVolume
            previousGroupPlaybackVolume = null
            micMuted = false
        }
        executeVideoDecisions(decisions)
        if (conversation != null && previous != null && accountAuthority.owns(expectedOwner)) {
            try {
                JamiService.setConversationPreferences(
                    expectedOwner!!.accountId,
                    conversation,
                    StringMap.toSwig(mapOf("hostConferences" to previous)),
                )
            } catch (_: Throwable) {}
        }
        volume?.let { try { JamiService.setVolume("speaker", it) } catch (_: Throwable) {} }
        main.post { if (activeCallId == null && activeGroupConferenceId == null && pendingGroupConferenceId == null) stopCallAudio() }
        return true
    }

    private fun groupConferenceForCall(accountId: String, callId: String): String? {
        if (!isActiveAccount(accountId) || accountAuthority.owns(retiredGroupLegs[callId])) return null
        groupCallLegs.entries.firstOrNull { it.value == callId }?.let { return it.key }
        val fromDaemon = try { JamiService.getConferenceId(accountId, callId) } catch (_: Throwable) { "" }
        if (GroupCallWire.roomId(fromDaemon) != null) {
            if (accountId != this.accountId ||
                (fromDaemon != activeGroupConferenceId && fromDaemon != pendingGroupConferenceId) ||
                !groupConversationByConference.containsKey(fromDaemon)) return null
            val known = groupCallLegs[fromDaemon]
            if (!activeGroupHosting && known != null && known != callId) return null
            if (!activeGroupHosting) groupCallLegs[fromDaemon] = callId
            return fromDaemon
        }
        return null
    }

    /** Persistent direct-contact decision for one exact file offer. */
    internal fun sendHologramControl(scope: NativeAccountScope?, peer: String, payload: String): Boolean {
        val account = scope?.accountId ?: return false
        val packet = HologramWire.decode(payload) ?: return false
        val sender = bareJamiId(peer)
        var sent = false
        invokeAccountCommand(scope) {
            if (!keepOnline || identityRestoreRecoveryFailed ||
                !HologramWire.authorized(routingSnapshot, account, sender, packet.conversation)) return@invokeAccountCommand
            try {
                sent = JamiService.sendAccountTextMessage(account, sender,
                    StringMap.toSwig(mapOf(HologramWire.MIME to payload)), 1) != 0L
            } catch (_: Throwable) { Log.w(TAG, "Hologram control send failed") }
        }
        return sent
    }

    private val hologramRateLock = Any()
    private var hologramWindow = 0L
    private var hologramCount = 0

    fun sendFileDeclined(peer: String, conversationId: String, fileId: String): Boolean {
        val acc = accountId ?: return false
        val bare = bareJamiId(peer)
        if (!routingSnapshot.isTrusted(bare) ||
            !routingSnapshot.owns(bare, conversationId)
        ) {
            return false
        }
        val body = FileThumbnailWire.encodeDeclined(conversationId, fileId) ?: return false
        return try {
            JamiService.sendAccountTextMessage(
                acc,
                bare,
                StringMap.toSwig(mapOf(FILE_DECLINED_MIME to body)),
                0,
            ) != 0L
        } catch (e: Throwable) {
            Log.e(TAG, "sendFileDeclined", e)
            false
        }
    }

    fun sendCallRequest(peer: String): Boolean {
        val acc = accountId ?: return false
        val bare = bareJamiId(peer)
        val route = routingSnapshot.friend(bare) ?: return false
        if (!route.confirmed || route.canonicalConversationId.isNullOrEmpty()) return false
        return try {
            JamiService.sendAccountTextMessage(
                acc,
                bare,
                StringMap.toSwig(
                    mapOf(CALL_REQUEST_MIME to CallRequestWire.encode(System.currentTimeMillis())),
                ),
                0,
            ) != 0L
        } catch (e: Throwable) {
            Log.e(TAG, "sendCallRequest", e)
            false
        }
    }

    // ---- presence v2 (ping/pong + opt-in foreground status) ----

    /** Only a resumed native Activity establishes foreground presence. A service-only
     * restart and a detached Flutter engine must never manufacture foreground state. */
    internal val foreground: Boolean get() = activityResumed
    @Volatile private var presenceColor = "amber"
    @Volatile private var shareForegroundPresence = false

    internal fun localIdentityColor(): String = presenceColor

    /** The ping/pong wire payload. Both bridges emit exactly this shape — keep them in lockstep. */
    fun setPresenceMetadata(
        shareActivity: Boolean,
        color: String,
    ) {
        val changed = shareForegroundPresence != shareActivity
        shareForegroundPresence = shareActivity
        if (changed) retirePresenceProbes()
        if (IdentityColorWire.valid(color)) presenceColor = color
    }

    private fun presenceJson(t: String): String = PresenceWire.encode(
        type = t,
        foreground = shareForegroundPresence && foreground,
        timestampMs = System.currentTimeMillis(),
        color = presenceColor,
        wake = backgroundWakeController.handle(),
    )

    /** Worker-only, best-effort advertisement to every currently authorized peer. */
    private fun publishBackgroundWakeCapability(handle: String) {
        val account = accountId ?: return
        val scope = backgroundWakeController.scope()
        if (handle.isEmpty() || handle != backgroundWakeController.handle()) return
        val snapshot = routingSnapshot
        if (snapshot.accountId != account) return
        val peers = buildSet {
            addAll(snapshot.friends.keys)
            snapshot.groups.values.forEach { addAll(it.activeMemberIds) }
        }
        val body = StringMap.toSwig(mapOf(
            PROBE_MIME to PresenceWire.encode(
                type = "wake",
                foreground = shareForegroundPresence && foreground,
                timestampMs = System.currentTimeMillis(),
                color = presenceColor,
                wake = handle,
            ),
        ))
        for (peer in peers) {
            if (!backgroundWakeController.owns(scope, account) || handle != backgroundWakeController.handle()) return
            if (peer == routingSnapshot.selfId || !routingSnapshot.acceptsWakePeer(peer)) continue
            try {
                JamiService.sendAccountTextMessage(account, peer, body, 0)
            } catch (error: Throwable) {
                Log.w(TAG, "Wake capability could not be published: ${error.message}")
            }
        }
    }

    /** An account (non-swarm) message arrived (daemon callback thread). Only our presence MIME matters: a ping
     *  gets a NATIVE auto-pong — the whole point is that a backgrounded phone (Dart frozen) still answers — and
     *  both ping and pong are forwarded to Dart as transport-verified presence evidence. Every gated ping is
     *  answered (no id-dedup: the channel path delivers messages with an EMPTY id — daemon jamiaccount.cpp:4768
     *  passes id="" — and engine retries only redeliver after a failed write, so duplicates are rare + benign). */
    internal fun onAccountMessage(account: String, from: String, payloads: Map<String, String>) {
        payloads[HologramWire.MIME]?.let { body ->
            val packet = HologramWire.decode(body) ?: return
            val sender = bareJamiId(from)
            if (!isActiveAccount(account) || identityRestoreRecoveryFailed ||
                !HologramWire.authorized(routingSnapshot, account, sender, packet.conversation)) return
            if (packet.type != "ready" && !friendHologramsAllowed(account, sender)) return
            synchronized(hologramRateLock) {
                val now = SystemClock.elapsedRealtime()
                if (now - hologramWindow >= 1000) { hologramWindow = now; hologramCount = 0 }
                if (hologramCount >= 64) return
                hologramCount++
            }
            emit(mapOf("type" to "hologramControl", "accountId" to account,
                "fromJamiId" to sender, "payload" to body))
            return
        }
        payloads[CALL_REQUEST_MIME]?.let { body ->
            if (CallRequestWire.decode(body, System.currentTimeMillis()) == null) return
            val bare = bareJamiId(from)
            if (!isActiveAccount(account)) return
            val route = routingSnapshot.friend(bare) ?: return
            val conversationId = route.canonicalConversationId ?: return
            val name = readPeerProfile(cachedPeerProfile(account, bare))?.displayName.orEmpty()
            CallRequestNotifications.show(appContext, bare, conversationId, name)
            return
        }
        payloads[FILE_DECLINED_MIME]?.let { body ->
            val packet = FileThumbnailWire.decodeDeclined(body) ?: return
            val bare = bareJamiId(from)
            if (!isActiveAccount(account) || !routingSnapshot.owns(bare, packet.conversationId)) return
            emit(mapOf(
                "type" to "fileDeclined",
                "accountId" to account,
                "peerJamiId" to bare,
                "conversationId" to packet.conversationId,
                "fileId" to packet.fileId,
            ))
            return
        }
        payloads[FILE_THUMBNAIL_MIME]?.let { body ->
            val packet = FileThumbnailWire.decode(body, System.currentTimeMillis())
                ?: return
            val bare = bareJamiId(from)
            if (!routingSnapshot.owns(bare, packet.conversationId)) return
            emit(mapOf(
                "type" to "fileThumbnail",
                "accountId" to account,
                "peerJamiId" to bare,
                "conversationId" to packet.conversationId,
                "fileId" to packet.fileId,
                "pngBase64" to packet.pngBase64,
            ))
            return
        }
        val body = payloads[PROBE_MIME] ?: return  // not ours (vCard etc.) — ignore
        // Full bare-hex normalization ("jami:<hex>" AND "<hex>@ring.dht" forms — mirrors peerId()/Windows
        // BareJamiId): a decorated sender must not fail the pong gate or Dart's exact peerId equality.
        val bare = bareJamiId(from)
        val presence = PresenceWire.decode(body) ?: return
        if (!isActiveAccount(account)) return
        if (presence.type == "wake") {
            emitWakeCapability(account, bare, presence)
            return
        }
        if (!routingSnapshot.isTrusted(bare)) return
        if (presence.wake.isNotEmpty()) {
            emit(mapOf(
                "type" to "wakeCapability",
                "accountId" to account,
                "fromJamiId" to bare,
                "handle" to presence.wake,
            ))
        }
        val t = presence.type
        val fg = presence.foreground
        val ts = presence.timestampMs
        val probeOwner = capturePresenceProbe()
        if (t == "ping") worker.execute(DaemonOperation.SEND_PONG) {
            try {
                if (!isActiveAccount(account) || !ownsPresenceProbe(probeOwner)) return@execute
                // Pong only YOUR person — never become a reachability oracle for a stranger who has the hex.
                if (bare.isNotEmpty() && isTrustedPeer(account, bare)) {
                    JamiService.sendAccountTextMessage(account, bare, StringMap.toSwig(mapOf(PROBE_MIME to presenceJson("pong"))), 0)
                }
            } catch (e: Throwable) { Log.e(TAG, "pong", e) }
        }
        // The pre-version wire value is only a probe hint: answer it for compatibility, but never let a
        // metadata-free queued message become fresh foreground evidence in Dart.
        if (presence.version == 0 && presence.timestampMs == 0L) return
        emit(mapOf("type" to "presenceMsg", "accountId" to account,
            "fromJamiId" to bare, "v" to presence.version, "t" to t, "fg" to fg, "ts" to ts,
            "platform" to presence.platform, "activity" to presence.activity,
            "color" to presence.color, "wake" to presence.wake))
    }

    /** Wake-only ingress for a non-contact group member (see [classifyAccountMessage]): runs the wake branch and
     *  nothing else, against the routing snapshot current now. */
    internal fun onWakeOnlyMessage(account: String, from: String, payloads: Map<String, String>) {
        val presence = PresenceWire.decode(payloads[PROBE_MIME] ?: return) ?: return
        if (presence.type != "wake") return
        emitWakeCapability(account, bareJamiId(from), presence)
    }

    private fun emitWakeCapability(account: String, bare: String, presence: PresencePacket) {
        if (!isActiveAccount(account) || !routingSnapshot.acceptsWakePeer(bare)) return
        emit(mapOf(
            "type" to "wakeCapability",
            "accountId" to account,
            "fromJamiId" to bare,
            "handle" to presence.wake,
        ))
    }

    /** Zombie-janitor: beacon every connected socket (3 s timeout kills the dead ones → NewBuddyNotification
     *  flips within ~3 s). Off-label lever — it also resets DHT/ICE caches — so Dart rate-limits the calls. */
    fun connectivitySweep() {
        try { JamiService.connectivityChanged() } catch (e: Throwable) { Log.e(TAG, "connectivitySweep", e) }
    }

    /** Best-effort transport goodbye on a REAL app exit: VOLATILE deactivate + shutdown connections, so open
     *  channels close with TLS close_notify and the peer's dot flips in ~1 RTT instead of a zombie timeout.
     *  Never persisted (unlike appear-offline's sendRegister) — the account boots active on the next launch. */
    fun goodbye() {
        backgroundWakeRetryKey = Any()
        AndroidRemoteControlHost.stopLocal("process-teardown")
        if (backgroundWakeEnabled()) {
            activityResumed = false
            backgroundAtMs = SystemClock.elapsedRealtime()
            taskRemovedWithPush = true
            main.post { applyBackgroundWakeLifetime() }
            return
        }
        val acc = accountId ?: return
        setOnlineLifetime(false)
        try { setWakeAccountActive(acc, false) } catch (e: Throwable) { Log.e(TAG, "goodbye", e) }
    }

    /** Undo [goodbye] when the process (and its volatile-deactivated account) survived into a relaunch. */
    fun reviveActive() {
        val acc = accountId ?: return
        try { setWakeAccountActive(acc, true) } catch (e: Throwable) { Log.e(TAG, "reviveActive", e) }
        val enabled = try {
            JamiService.getAccountDetails(acc).toNative()["Account.enable"] != "false"
        } catch (_: Throwable) {
            false
        }
        setOnlineLifetime(enabled)
    }

    /** Call-scoped RTP sender mute. `muteCapture` is ineffective in libjami's Android AAudio callback and its
     * process-global latch leaks into later calls, so never use it for the in-call control. */
    fun setMicMuted(callId: String, muted: Boolean): Boolean {
        if (!muted && (pendingIdentityRestore != null || identityRestoreRecoveryFailed)) return false
        val acc = accountId ?: return false
        if (callId.isEmpty() || activeCallId != callId) return false
        val ok = JamiService.muteLocalMedia(acc, callId, "MEDIA_TYPE_AUDIO", muted)
        if (!ok) return false
        synchronized(callLifecycleLock) {
            if (activeCallId != callId) return false
            micMuted = muted
        }
        Log.i(TAG, "muteLocalMedia($callId, audio, $muted) -> true")
        return true
    }

    /**
     * Select the authoritative CURRENT call's daemon-owned sender gate.
     *
     * Voice activation uses libjami's configured WebRTC/Speex processor and
     * refuses to degrade to an open sender. Explicit mute/PTT stays independent
     * through [setMicMuted].
     */
    fun setAudioTransmissionMode(callId: String, value: String): Boolean {
        if (pendingIdentityRestore != null || identityRestoreRecoveryFailed) return false
        val mode = AudioTransmissionMode.parse(value) ?: return false
        val acc = synchronized(callLifecycleLock) {
            val currentAccount = accountId
            if (currentAccount.isNullOrEmpty() ||
                !ownsAudioTransmissionCall(callId, activeCallId, currentWinnerCallId) ||
                recentTerminalCallIds.contains(callId)
            ) {
                return false
            }
            currentAccount
        }
        val applied = try {
            if (mode == AudioTransmissionMode.VOICE_ACTIVATED) {
                if (!JamiService.getVoiceActivityDetectionState()) {
                    JamiService.setVoiceActivityDetectionState(true)
                }
                if (!JamiService.getVoiceActivityDetectionState()) {
                    Log.w(TAG, "voice activation unavailable: daemon VAD did not enable")
                    return false
                }
            }
            JamiService.setAudioTransmissionMode(acc, callId, mode.daemonValue)
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "setAudioTransmissionMode($callId, ${mode.daemonValue}) failed: " +
                    t.javaClass.simpleName,
            )
            false
        }
        if (!applied) return false
        return synchronized(callLifecycleLock) {
            accountId == acc &&
                ownsAudioTransmissionCall(callId, activeCallId, currentWinnerCallId) &&
                !recentTerminalCallIds.contains(callId)
        }
    }

    /** Diagnostic/display-only capture-ring RMS meter. It is not a transmission authority. */
    fun setAudioMeterEnabled(enabled: Boolean) {
        JamiService.setAudioMeterState("audiolayer_id", enabled)
    }

    fun setSpeaker(on: Boolean) {
        speakerOn = on
        audio?.setSpeaker(on)
    }

    /** M7 "appear offline": disable the account (stop announcing on the DHT) so peers see us offline. Jami
     *  has no connected-but-invisible state, so while dark we are also unreachable. sendRegister toggles the
     *  PERSISTED `Account.enable` (daemon Manager::sendRegister: setEnabled + saveConfig + doRegister/doUnregister,
     *  with a full connection shutdown when disabling) — so a dark account BOOTS dark. The volatile alternative
     *  (setAccountActive) is not persisted: the account would boot active and announce to the DHT for a beat —
     *  and that announcement is proxy-held for ~24 h — leaking "I'm here" on every launch while dark. */
    fun setAppearOffline(on: Boolean) {
        val acc = checkNotNull(accountId) { "No active account" }
        if (on) backgroundWakeController.goOffline()
        JamiService.sendRegister(acc, !on)
        setOnlineLifetime(!on)
        activatePreparedAccount(acc)
        Log.i(TAG, "setAppearOffline($on) -> sendRegister(enable=${!on})")
    }

    /** M7 connection profile: rewrite the account's connection keys for [profile] ('lan' | 'jami' | 'strict') and
     *  setAccountDetails — which doUnregister+doRegister's the account, so the change applies with no explicit
     *  re-register. Read the full map and skip that restart when the requested profile is already applied.
     *  Worker thread only. */
    fun setConnectionProfile(profile: String, dhtBootstrap: String, turnServer: String,
                             turnRealm: String, turnUser: String, turnPassword: String) {
        val acc = checkNotNull(accountId) { "No active account" }
        backgroundWakeController.changeProfile(profile)
        val m = JamiService.getAccountDetails(acc).toNative().toMutableMap()
        val original = m.toMap()
        applyConnectionProfile(m, profile, dhtBootstrap, turnServer, turnRealm, turnUser, turnPassword)
        if (m != original) JamiService.setAccountDetails(acc, StringMap.toSwig(m))
        preparedNetworkOwner = captureAccountScope(acc)
        activatePreparedAccount(acc)
        Log.i(TAG, "setConnectionProfile($profile) -> changed=${m != original}")
    }

    /** Overwrite the connection keys for [profile] on an existing full account-details map. M7.5 (L3): LAN peer
     *  discovery + account publish broadcast our 40-hex + display name in CLEARTEXT over UDP multicast, so enable
     *  them ONLY for the 'lan' profile (where they're functionally required). For 'jami'/'strict', peers are
     *  reached via the DHT, so the LAN identity broadcast is pure leak — keep it off. */
    private fun applyConnectionProfile(m: MutableMap<String, String>, profile: String, dhtBootstrap: String,
                                       turnServer: String, turnRealm: String, turnUser: String, turnPassword: String) {
        val lpd = if (profile == "lan") "true" else "false"
        m["Account.peerDiscovery"] = lpd           // LAN multicast DHT node discovery
        m["Account.accountDiscovery"] = lpd        // LAN multicast account (identity) discovery
        m["Account.accountPublish"] = lpd          // LAN multicast publish of {accountId, displayName}
        // The Jami account details map does not round-trip STUN.enable or Account.bootstrapListUrl.
        // Adding those ignored keys would make every startup look like a profile change.
        when (profile) {
            "lan" -> {
                // Same-LAN only: an empty hostname is forced back to bootstrap.jami.net by the daemon, so use an
                // unreachable RFC-5737 TEST-NET addr; kill proxy/TURN/UPnP. Peers connect
                // only via LAN multicast — cross-network is blocked.
                m["Account.hostname"] = "192.0.2.1"
                m["Account.proxyEnabled"] = "false"
                m["Account.proxyListEnabled"] = "false"
                m["Account.proxyServer"] = ""
                m["TURN.enable"] = "false"
                m["Account.upnpEnabled"] = "false"
            }
            "strict" -> {
                // Zero third-party servers: bootstrap off the configured dhtnode and relay through configured coTURN.
                // The daemon treats an empty hostname as bootstrap.jami.net, so a blank strict host fails closed.
                m["Account.hostname"] = dhtBootstrap.ifBlank { "192.0.2.1" }
                m["Account.proxyEnabled"] = "false"
                m["Account.proxyListEnabled"] = "false"
                m["Account.proxyServer"] = ""
                m["Account.upnpEnabled"] = "true"
                if (turnServer.isNotEmpty()) {
                    m["TURN.enable"] = "true"
                    m["TURN.server"] = turnServer
                    m["TURN.username"] = turnUser
                    m["TURN.password"] = turnPassword
                    m["TURN.realm"] = if (turnRealm.isNotEmpty()) turnRealm else "ring"
                } else {
                    m["TURN.enable"] = "false"
                }
            }
            else -> {   // "jami" — pragmatic v1 default: jami.net bootstrap + DHT proxy + turn.jami.net fallback (LPD off; M7.5 L3).
                m["Account.hostname"] = "bootstrap.jami.net"
                m["Account.proxyEnabled"] = "true"
                m["Account.proxyListEnabled"] = "true"
                m["Account.proxyServer"] = "dhtproxy.jami.net:[80-95]"
                m["Account.dhtProxyListUrl"] = "https://config.jami.net/proxyList"
                m["Account.upnpEnabled"] = "true"
                m["TURN.enable"] = "true"
                m["TURN.server"] = "turn.jami.net"
                m["TURN.username"] = "ring"
                m["TURN.password"] = "ring"
                m["TURN.realm"] = "ring"
            }
        }
    }

    // ---- file transfer (M5): sendFile / downloadFile over the peer's swarm conversation ----

    private fun collectContacts(acc: String): List<Map<String, String>> {
        val result = ArrayList<Map<String, String>>()
        val contacts = JamiService.getContacts(acc)
        for (i in 0 until contacts.size) result += contacts.get(i).toNative()
        return result
    }

    private fun collectConversations(acc: String): Map<String, List<Map<String, String>>> {
        val result = linkedMapOf<String, List<Map<String, String>>>()
        val conversations = JamiService.getConversations(acc)
        for (i in 0 until conversations.size) {
            val id = conversations.get(i)
            val members = JamiService.getConversationMembers(acc, id)
            val converted = ArrayList<Map<String, String>>()
            for (j in 0 until members.size) converted += members.get(j).toNative()
            result[id] = converted
        }
        return result
    }

    internal fun ignoreIncomingCallNotification(callId: String) {
        if (incomingCalls[callId] != null) cancelIncomingCallNotification(callId)
    }

    private fun collectConversationInfos(
        acc: String,
        conversationIds: Collection<String>,
    ): Map<String, Map<String, String>> {
        val result = linkedMapOf<String, Map<String, String>>()
        for (id in conversationIds) {
            result[id] = try {
                JamiService.conversationInfos(acc, id).toNative()
            } catch (_: Throwable) {
                emptyMap()
            }
        }
        return result
    }

    /** Worker-only rebuild from libjami durable truth, published as one immutable volatile reference. */
    private fun refreshRoutingSnapshot(acc: String, forceEvent: Boolean = false) {
        val generation = routingGeneration
        val old = routingSnapshot
        val built = try {
            val conversations = collectConversations(acc)
            buildRoutingSnapshot(
                accountId = acc,
                revision = old.revision + 1,
                selfId = JamiService.getAccountDetails(acc).toNative()["Account.username"].orEmpty(),
                contacts = collectContacts(acc),
                conversations = conversations,
                conversationInfos = collectConversationInfos(acc, conversations.keys),
            )
        } catch (e: Throwable) {
            Log.e(TAG, "refreshRoutingSnapshot", e)
            return
        }
        if (!forceEvent &&
            old.accountId == built.accountId &&
            old.friends == built.friends &&
            old.peerByConversation == built.peerByConversation &&
            old.groups == built.groups
        ) return
        fun wakePeers(snapshot: RoutingSnapshot) = buildSet {
            addAll(snapshot.friends.keys)
            snapshot.groups.values.forEach { addAll(it.activeMemberIds) }
        }
        val authorizationShrank = old.accountId == built.accountId &&
            (wakePeers(old) - wakePeers(built)).isNotEmpty()
        synchronized(routingLock) {
            if (!isActiveAccount(acc) || routingGeneration != generation) return
            if (old.accountId != built.accountId || old.selfId != built.selfId || old.friends != built.friends ||
                old.peerByConversation != built.peerByConversation || old.groups != built.groups) messageActions.clear()
            routingSnapshot = built
            callMessageAuthority.updateRouting(built)
        }
        if (old.accountId == built.accountId) {
            for (peer in old.friends.keys - built.friends.keys) {
                retireControlTrust(acc, peer)
            }
        }
        dmTopicArchives.retainConversations(built.peerByConversation.keys)
        reconcilePresenceSubscriptions(acc, built.friends.keys)
        if (authorizationShrank) {
            backgroundWakeController.rotate()
        } else if (backgroundWakeRequested()) {
            backgroundWakeController.handle().takeIf(String::isNotEmpty)
                ?.let(::publishBackgroundWakeCapability)
        }
        emit(mapOf("type" to "friendsChanged", "accountId" to acc, "revision" to built.revision))
    }

    internal fun requestRoutingRefresh(acc: String, forceEvent: Boolean = false) {
        if (isActiveAccount(acc)) messageActions.clear()
        worker.execute(DaemonOperation.READ_PEER) {
            if (isActiveAccount(acc)) refreshRoutingSnapshot(acc, forceEvent)
        }
    }

    /** Retire native authority immediately, before the queued daemon rebuild. */
    private fun retireControlTrust(acc: String, peer: String): Boolean {
        if (isActiveAccount(acc)) messageActions.clear()
        val retiredRoute = synchronized(routingLock) {
            val snapshot = routingSnapshot
            if (!isActiveAccount(acc) || snapshot.accountId != acc || peer.isEmpty()) return false
            if (snapshot.isTrusted(peer)) {
                routingGeneration += 1
                routingSnapshot = snapshot.copy(
                    revision = snapshot.revision + 1,
                    friends = snapshot.friends - peer,
                    peerByConversation = snapshot.peerByConversation.filterValues { it != peer },
                )
                callMessageAuthority.updateRouting(routingSnapshot)
            }
            snapshot.selfId to (snapshot.acceptsWakePeer(peer) &&
                !routingSnapshot.acceptsWakePeer(peer))
        }
        val call = synchronized(callLifecycleLock) {
            activeCallId?.takeIf { callPeers[it] == peer }.orEmpty()
        }
        val retired = AndroidRemoteControlHost.onTrustReduced(acc, retiredRoute.first, peer, call)
        if (retiredRoute.second) {
            backgroundWakeController.rotate()
        }
        return retired
    }

    private fun reconcilePresenceSubscriptions(acc: String, desired: Collection<String>): Boolean {
        var ok = true
        val trusted = desired.asSequence().map(::bareJamiId).filter(String::isNotEmpty).toSet()
        for (peer in subscribedPeers.toSet() - trusted) {
            try {
                JamiService.subscribeBuddy(acc, peer, false)
                subscribedPeers.remove(peer)
            } catch (e: Throwable) {
                ok = false
                Log.e(TAG, "unsubscribeBuddy", e)
            }
        }
        for (peer in trusted - subscribedPeers) {
            try {
                JamiService.subscribeBuddy(acc, peer, true)
                subscribedPeers += peer
            } catch (e: Throwable) {
                ok = false
                Log.e(TAG, "subscribeBuddy", e)
            }
        }
        return ok
    }

    private fun cachedPeerProfile(accountId: String, peerId: String): File {
        val encoded = Base64.getEncoder().encodeToString(peerId.encodeToByteArray())
        return File(
            File(File(appContext.filesDir, "files"), accountId),
            "profiles/$encoded.vcf",
        )
    }

    private fun readPeerProfile(file: File): ProfileWireBounds.Profile? {
        if (!file.isFile) return null
        return try {
            FileInputStream(file).use { input ->
                val size = input.channel.size()
                if (size < 0 || size > ProfileWireBounds.MAX_VCARD_BYTES) {
                    return@use null
                }
                val bytes = ByteArray(size.toInt())
                var offset = 0
                while (offset < bytes.size) {
                    val read = input.read(bytes, offset, bytes.size - offset)
                    if (read < 0) return@use null
                    offset += read
                }
                if (input.read() != -1) return@use null
                ProfileWireBounds.profileVcard(bytes)
            }
        } catch (_: Throwable) {
            null
        }
    }

    fun listFriends(): Map<String, Any> {
        val acc = accountId ?: return mapOf(
            "revision" to 0L,
            "friends" to emptyList<Any>(),
            "groups" to emptyList<Any>(),
        )
        if (routingSnapshot.accountId != acc) refreshRoutingSnapshot(acc)
        val snapshot = routingSnapshot
        return mapOf(
            "revision" to snapshot.revision,
            "friends" to snapshot.friends.values.map {
                val profile = readPeerProfile(cachedPeerProfile(acc, it.peerId))
                mapOf(
                    "peerJamiId" to it.peerId,
                    "confirmed" to it.confirmed,
                    "conversationId" to it.canonicalConversationId.orEmpty(),
                    "displayName" to profile?.displayName.orEmpty(),
                    "avatarBase64" to profile?.avatarBase64.orEmpty(),
                )
            },
            "groups" to snapshot.groups.values.map { group ->
                val profile = try {
                    JamiService.conversationInfos(acc, group.conversationId).toNative()
                } catch (_: Throwable) {
                    emptyMap()
                }
                mapOf(
                    "conversationId" to group.conversationId,
                    "title" to (
                        ProfileWireBounds.displayName(profile["title"].orEmpty())
                            ?: ""
                        ),
                    "description" to profile["description"].orEmpty(),
                    "memberCount" to group.memberCount,
                    "canManageMembers" to group.canManageMembers,
                    "localRole" to group.localRole,
                    "members" to group.memberIds.map { memberId ->
                        val memberProfile = readPeerProfile(cachedPeerProfile(acc, memberId))
                        mapOf(
                            "peerJamiId" to memberId,
                            "role" to when {
                                group.adminMemberIds.contains(memberId) -> "admin"
                                group.activeMemberIds.contains(memberId) -> "member"
                                group.invitedMemberIds.contains(memberId) -> "invited"
                                else -> "unknown"
                            },
                            "displayName" to memberProfile?.displayName.orEmpty(),
                            "avatarBase64" to memberProfile?.avatarBase64.orEmpty(),
                        )
                    },
                )
            },
        )
    }

    fun listKnownDevices(): List<Map<String, Any>> {
        val acc = accountId ?: return emptyList()
        val known = JamiService.getKnownRingDevices(acc).toNative()
        val currentId = JamiService.getVolatileAccountDetails(acc)
            .toNative()["Account.deviceID"].orEmpty()
        return KnownDeviceWire.project(known, currentId)
    }

    /** Main-thread admission owns the exact channel request before worker queuing. */
    internal fun revokeKnownDevice(
        requestedAccount: String,
        deviceId: String,
        scope: NativeAccountScope?,
        replyOwner: Any,
        reply: (DeviceRevocationResult) -> Unit,
    ) {
        if (scope?.accountId != requestedAccount || !accountAuthority.owns(scope)) {
            reply(DeviceRevocationResult(requestedAccount, deviceId, DeviceRevocationStatus.ACCOUNT_CHANGED))
            return
        }
        if (!started || !deviceRevocationTimerReady) {
            reply(DeviceRevocationResult(requestedAccount, deviceId, DeviceRevocationStatus.UNAVAILABLE))
            return
        }
        val admission = deviceRevocations.begin(requestedAccount, deviceId,
            SystemClock.elapsedRealtime(), replyOwner, reply)
        if (admission.ticket == 0L) {
            reply(DeviceRevocationResult(requestedAccount, deviceId, admission.status))
            return
        }
        // The main timer starts before queuing. A stalled daemon cannot hold the reply forever.
        drainDeviceRevocations()
        if (!deviceRevocations.pending(admission.ticket)) return
        try {
            worker.execute(DaemonOperation.REVOKE_DEVICE) {
                try {
                    if (!deviceRevocations.pending(admission.ticket)) return@execute
                    if (!accountAuthority.owns(scope) || accountId != requestedAccount) {
                        deviceRevocations.refuse(admission.ticket, DeviceRevocationStatus.ACCOUNT_CHANGED)
                        return@execute
                    }
                    val known = JamiService.getKnownRingDevices(requestedAccount).toNative()
                    val currentId = JamiService.getVolatileAccountDetails(requestedAccount)
                        .toNative()["Account.deviceID"].orEmpty()
                    val secret = archiveSecret
                    if (archiveRecoveryBlocked || !archiveProtectionReady ||
                        !ArchiveSecretFormat.isValid(secret) ||
                        !KnownDeviceWire.canRevoke(deviceId, currentId, known.keys)) {
                        deviceRevocations.refuse(admission.ticket, DeviceRevocationStatus.REFUSED)
                    } else {
                        deviceRevocations.invoke(admission.ticket, SystemClock.elapsedRealtime()) {
                            JamiService.revokeDevice(requestedAccount, deviceId, "password", secret)
                        }
                    }
                } catch (error: Throwable) {
                    Log.e(TAG, "device revocation failed", error)
                    deviceRevocations.refuse(admission.ticket, DeviceRevocationStatus.UNAVAILABLE)
                } finally {
                    main.post(deviceRevocationCheck)
                }
            }
        } catch (error: Throwable) {
            Log.e(TAG, "device revocation queue failed", error)
            deviceRevocations.refuse(admission.ticket, DeviceRevocationStatus.UNAVAILABLE)
            drainDeviceRevocations()
        }
    }

    internal fun cancelKnownDeviceRevocations(replyOwner: Any) {
        deviceRevocations.cancelOwner(replyOwner)
        drainDeviceRevocations()
    }

    /** One process-owned timer; an issued unknown result keeps only its callback tombstone. */
    private fun drainDeviceRevocations() {
        main.removeCallbacks(deviceRevocationCheck)
        fun deliver() {
            for (completion in deviceRevocations.takeReady(SystemClock.elapsedRealtime())) {
                try { completion.reply?.invoke(completion.result) }
                catch (error: Throwable) { Log.e(TAG, "device revocation reply failed", error) }
            }
        }
        deliver()
        if (deviceRevocations.hasPendingReplies() && !main.postDelayed(deviceRevocationCheck, 250L)) {
            deviceRevocationTimerReady = false
            deviceRevocations.failPending()
            deliver()
        }
    }

    fun hasEventSink(): Boolean = eventSink != null

    internal fun updateProfile(
        displayName: String,
        avatar: String,
        fileType: String,
        flag: Int,
        scope: NativeAccountScope?,
    ): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val title = ProfileWireBounds.displayName(displayName) ?: return false
        val boundedAvatar = ProfileWireBounds.avatar(avatar) ?: return false
        val valid = when (flag) {
            0 -> fileType.isEmpty() && boundedAvatar.isEmpty()
            1 -> fileType == "JPEG" && boundedAvatar.isNotEmpty()
            2 -> fileType.isEmpty() && boundedAvatar.isEmpty()
            else -> false
        }
        if (!valid) return false
        JamiService.updateProfile(acc, title, boundedAvatar, fileType, flag)
        return true
    }

    /** The friend-request payload carries the sender's display name ONLY (a vCard with FN, the format other Jami
     *  clients send), never the photo. An empty or invalid name sends no payload. */
    private fun friendRequestPayload(acc: String): Blob {
        val raw = JamiService.getAccountDetails(acc).toNative()["Account.displayName"].orEmpty()
        // One vCard line: a newline must not inject PHOTO or other keys.
        val name = ProfileWireBounds.displayName(raw)?.replace('\r', ' ')?.replace('\n', ' ').orEmpty()
        return if (name.isEmpty()) Blob() else Blob.fromString("BEGIN:VCARD\nVERSION:2.1\nFN:$name\nEND:VCARD\n")
    }

    internal fun addFriend(peer: String, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val bare = bareJamiId(peer)
        if (bare.isEmpty()) return false
        // sendTrustRequest is addContact plus the request itself: it starts the 1:1 conversation, adds the
        // unconfirmed contact, puts the request now and caches the payload for the daemon's resend when the peer
        // comes online. A separate addContact first could let that resend race out with no payload.
        JamiService.sendTrustRequest(acc, bare, friendRequestPayload(acc))
        JamiService.subscribeBuddy(acc, bare, true)
        subscribedPeers += bare
        refreshRoutingSnapshot(acc)
        return routingSnapshot.isTrusted(bare)
    }

    internal fun createGroup(title: String, memberIds: Collection<String>, scope: NativeAccountScope?): String {
        if (!accountAuthority.owns(scope)) return ""
        val acc = scope?.accountId ?: return ""
        val normalizedTitle = GroupPolicy.title(title) ?: return ""
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc) refreshRoutingSnapshot(acc)
        val current = routingSnapshot
        if (current.accountId != acc) return ""
        val members = GroupPolicy.newMemberIds(
            memberIds,
            current.selfId,
            current.friends.keys,
        ) ?: return ""
        var conversationId = ""
        return try {
            conversationId = JamiService.startConversation(acc)
            if (conversationId.isEmpty()) return ""
            JamiService.updateConversationInfos(
                acc,
                conversationId,
                StringMap.toSwig(mapOf("title" to normalizedTitle)),
            )
            for (memberId in members) {
                JamiService.addConversationMember(acc, conversationId, memberId)
            }
            refreshRoutingSnapshot(acc)
            conversationId
        } catch (error: Throwable) {
            if (conversationId.isNotEmpty()) {
                try { JamiService.removeConversation(acc, conversationId) } catch (_: Throwable) {}
            }
            Log.e(TAG, "createGroup", error)
            ""
        }
    }

    internal fun addGroupMembers(conversationId: String, memberIds: Collection<String>, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc) return false
        val route = snapshot.group(conversationId) ?: return false
        if (!route.canManageMembers) return false
        val members = GroupPolicy.newMemberIds(
            memberIds,
            snapshot.selfId,
            snapshot.friends.keys,
            route.memberIds.toSet(),
        ) ?: return false
        val added = mutableListOf<String>()
        return try {
            for (memberId in members) {
                JamiService.addConversationMember(acc, conversationId, memberId)
                added += memberId
            }
            refreshRoutingSnapshot(acc)
            true
        } catch (error: Throwable) {
            for (memberId in added.asReversed()) {
                try {
                    JamiService.removeConversationMember(acc, conversationId, memberId)
                } catch (_: Throwable) {
                    // The authoritative refresh below exposes any compensation
                    // failure instead of leaving the bridge on a stale route.
                }
            }
            refreshRoutingSnapshot(acc)
            Log.e(TAG, "addGroupMembers", error)
            false
        }
    }

    internal fun removeGroupMember(conversationId: String, memberId: String, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc) return false
        val route = snapshot.group(conversationId) ?: return false
        val member = bareJamiId(memberId)
        if (!route.canManageMembers || !route.memberIds.contains(member)) return false
        JamiService.removeConversationMember(acc, conversationId, member)
        refreshRoutingSnapshot(acc)
        return true
    }

    internal fun renameGroup(conversationId: String, title: String, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc) return false
        val route = snapshot.group(conversationId) ?: return false
        val normalizedTitle = GroupPolicy.title(title) ?: return false
        if (!route.canManageMembers) return false
        JamiService.updateConversationInfos(
            acc,
            conversationId,
            StringMap.toSwig(mapOf("title" to normalizedTitle)),
        )
        refreshRoutingSnapshot(acc)
        return true
    }

    internal fun updateGroupLayout(conversationId: String, description: String, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc) return false
        val route = snapshot.group(conversationId) ?: return false
        val normalized = GroupPolicy.layout(description) ?: return false
        if (!route.canManageMembers) return false
        JamiService.updateConversationInfos(
            acc,
            conversationId,
            StringMap.toSwig(mapOf("description" to normalized)),
        )
        refreshRoutingSnapshot(acc)
        return true
    }

    internal fun leaveGroup(conversationId: String, scope: NativeAccountScope?): Boolean {
        if (!accountAuthority.owns(scope)) return false
        val acc = scope?.accountId ?: return false
        val snapshot = routingSnapshot
        if (snapshot.accountId != acc || snapshot.group(conversationId) == null) return false
        val removed = JamiService.removeConversation(acc, conversationId)
        refreshRoutingSnapshot(acc)
        return removed
    }

    fun setPresenceSubscriptions(peers: Collection<String>): Boolean {
        val acc = accountId ?: return false
        val normalized = peers.map(::bareJamiId)
        if (normalized.any(String::isEmpty)) {
            throw IllegalArgumentException("Invalid presence subscription peer")
        }
        val desired = normalized.toSet()
        if (desired.any { !routingSnapshot.isTrusted(it) }) {
            throw IllegalArgumentException("Presence subscription requested for an untrusted peer")
        }
        return reconcilePresenceSubscriptions(acc, desired)
    }

    private fun isTrustedPeer(account: String, peer: String): Boolean =
        isActiveAccount(account) && routingSnapshot.isTrusted(peer)

    private fun ownerForConversation(account: String, conversation: String): String? =
        if (isActiveAccount(account)) routingSnapshot.ownerKey(conversation) else null

    private fun normalizeOwnerKey(value: String): String =
        groupConversationId(value)?.let(::groupOwnerKey) ?: bareJamiId(value)

    /** Send a local file to the peer over the CANONICAL swarm conversation (so new files concentrate on one
     *  conversation regardless of the duplicate-swarm residual). Returns false if no conversation / not a file. */
    fun sendFile(
        peer: String,
        conversationId: String,
        path: String,
        name: String,
        topicId: String = "",
    ): Boolean {
        val acc = accountId ?: return false
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) ||
            !DmTopicWire.validOutgoingTopic(topicId)) return false
        val f = File(path)
        if (!f.isFile) { Log.w(TAG, "sendFile: invalid source"); return false }
        val display = if (name.isNotEmpty()) name else f.name
        Log.i(TAG, "sendFile: issuing publication")
        JamiService.sendFile(acc, conversationId, path, display, "", topicId)
        return true
    }

    internal fun captureFileAcceptRoute(scope: NativeAccountScope?, peer: String, conversationId: String): Long? {
        val snapshot = routingSnapshot
        return snapshot.revision.takeIf {
            scope != null && accountAuthority.owns(scope) && snapshot.accountId == scope.accountId &&
                snapshot.owns(normalizeOwnerKey(peer), conversationId)
        }
    }

    /** Accept an offered incoming file into our receive dir. The exact owner tuple must still belong to the
     *  immutable routing snapshot; there is no selected/global-conversation fallback. */
    internal fun acceptFile(peer: String, conversationId: String, interactionId: String, fileId: String,
                   maxBytes: Long, attemptId: String, scope: NativeAccountScope?,
                   expectedRouteRevision: Long, verifiedOffer: FileOffer): Boolean {
        val acc = accountId ?: return false
        if (scope == null || !accountAuthority.owns(scope) || !Regex("^[0-9a-f]{32}$").matches(attemptId)) return false
        val owner = normalizeOwnerKey(peer)
        if (routingSnapshot.revision != expectedRouteRevision ||
            !routingSnapshot.owns(owner, conversationId) || fileId.isEmpty() || interactionId.isEmpty()) return false
        val key = TransferKey(owner, conversationId, fileId)
        if (receiveAttempts.containsKey(key) || receiveAttempts.size >= 64) return false
        // This value came from the exact folded daemon reply, not the evictable
        // history cache or the caller. Carry it across the async handoff.
        val offer = verifiedOffer
        if (offer.outgoing || offer.authorId == myJamiId() ||
            !routingSnapshot.acceptsAuthor(owner, conversationId, offer.authorId)) return false
        val declaredSize = offer.size
        if (maxBytes < 0 || (maxBytes > 0 && (declaredSize < 0 || declaredSize > maxBytes))) {
            Log.w(TAG, "acceptFile: invalid cap or unavailable/excessive declared size")
            return false
        }
        if (declaredSize < 0) return false
        val mediaMetadata = offer.mediaMetadata
        val privateRoot = File(appContext.noBackupFilesDir, "received-media")
        // The display name comes from the SENDER's swarm commit — it is UNTRUSTED. Reduce it to a bare leaf name
        // (no directory components, no ".."/absolute parts) before joining, so a malicious displayName like
        // "../../foo" or "/etc/x" can't write outside the receive dir (path-traversal hardening).
        val dest = if (mediaMetadata != null) {
            val metadata = runCatching { JSONObject(mediaMetadata) }.getOrNull() ?: return false
            val kind = metadata.optString("kind")
            if (metadata.optInt("v") != 1 || kind !in setOf("gif", "voice")) return false
            val cap = if (kind == "gif") 4L * 1024 * 1024 else 2L * 1024 * 1024
            if (declaredSize <= 0 || declaredSize > cap) return false
            synchronized(reservedReceivePaths) {
                receiveDestByFile[key]?.let { prior ->
                    File(prior).takeIf { isPrivateReceivedMediaFile(privateRoot, it) }
                        ?: return false
                } ?: reserveReceivedMediaFile(privateRoot, kind == "gif").also {
                    receiveDestByFile[key] = it.absolutePath
                    reservedReceivePaths.add(it.absolutePath)
                }
            }
        } else {
            // Legacy sdcard FUSE cannot atomically publish without overwriting.
            // Keep new ordinary attachments on private internal storage instead.
            val dir = receivedFilesDirectory(appContext.filesDir)
            reserveUniqueFile(key, dir, safeLeaf(offer.name.ifEmpty { fileId }))
        }
        Log.i(TAG, "downloadFile requested")
        val attempt = ReceiveAttempt(scope, attemptId)
        receiveAttempts[key] = attempt
        // SWIG widens the daemon's bool return (true=accepted) to a long: 1=success, 0=failure — NOT the
        // DataTransferError int. So success is != 0L (matches the verified Windows bool path).
        val ok = try {
            accountAuthority.owns(scope) && routingSnapshot.revision == expectedRouteRevision &&
                JamiService.downloadSybLFile(acc, conversationId, interactionId, fileId, dest.absolutePath, attemptId) != 0L
        } catch (e: Throwable) {
            if (receiveAttempts.remove(key, attempt)) releaseReceiveReservation(key)
            throw e
        }
        if (!ok && receiveAttempts.remove(key, attempt)) releaseReceiveReservation(key)
        return ok
    }

    /** Decline an offered file / cancel an in-flight transfer. */
    internal fun cancelFile(peer: String, conversationId: String, fileId: String, attemptId: String, scope: NativeAccountScope?): Boolean {
        val acc = accountId ?: return false
        if (!accountAuthority.owns(scope)) return false
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) || fileId.isEmpty()) return false
        val key = TransferKey(owner, conversationId, fileId)
        val attempt = receiveAttempts[key]
        if (attemptId.isNotEmpty()) {
            if (attempt?.id != attemptId || !accountAuthority.owns(attempt.account)) return false
            val cancelled = JamiService.cancelSybLFile(acc, conversationId, fileId, attemptId) == 0L
            if (cancelled && receiveAttempts.remove(key, attempt)) releaseReceiveReservation(key)
            return cancelled
        }
        if (attempt != null) return false
        return JamiService.cancelDataTransfer(acc, conversationId, fileId) == 0L
    }

    /** Byte progress for the Dart-side poller: {transferred, total, path}. Worker thread. */
    fun fileInfo(peer: String, conversationId: String, fileId: String): Map<String, Any?> {
        val acc = accountId ?: return emptyMap()
        if (!routingSnapshot.owns(peer, conversationId) || fileId.isEmpty()) return emptyMap()
        val path = arrayOfNulls<String>(1); val total = LongArray(1); val progress = LongArray(1)
        var completed = false
        try {
            JamiService.fileTransferInfo(acc, conversationId, fileId, path, total, progress)
            val verifiedSize = LongArray(1)
            completed = JamiService.fileTransferCompleted(acc, conversationId, fileId, path, verifiedSize)
            if (completed) { total[0] = verifiedSize[0]; progress[0] = verifiedSize[0] }
        } catch (_: Throwable) { path[0] = null }
        return mapOf("transferred" to progress[0], "total" to total[0],
            "completed" to completed, "path" to (if (completed) path[0] ?: "" else ""))
    }

    // ---- file-keeping (M6): rebuild the persistent shared folder from the swarm history ----

    private fun registerConversationLoad(
        account: String,
        fromMessage: String,
        count: Int,
        pending: PendingConversationLoad,
    ): Long = try {
        synchronized(loadRegistrationLock) {
            if (!conversationLoads.canStart()) return@synchronized 0L
            val loadId = JamiService.loadConversation(account, pending.conversationId, fromMessage, count.toLong())
            if (loadId != 0L && conversationLoads.register(loadId, pending)) loadId else 0L
        }
    } catch (e: Throwable) {
        Log.e(TAG, "loadConversation", e)
        0L
    }

    /** Load the canonical conversation's file history → the daemon replies via the swarmLoaded callback, which
     *  emits one 'folderFile' event per data-transfer commit. Fire-and-forget on the worker; safe to re-call. */
    fun loadFolder(peer: String, conversationId: String, n: Int): Long {
        val acc = accountId ?: return 0L
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return 0L
        val keepLast = if (n > 0) n else folderKeepLast
        if (keepLast !in 1..5000) return 0L
        folderKeepLast = keepLast
        Log.i(TAG, "loadFolder($conversationId) n=$keepLast")
        return registerConversationLoad(acc, "", keepLast, FolderConversationLoad(owner, conversationId, keepLast))
    }

    internal fun messageActionCurrent(action: MessageActionOwner): Boolean {
        val snapshot = routingSnapshot
        val group = snapshot.group(action.conversationId)
        return started && accountAuthority.owns(action.account) &&
            action.identity.isNotEmpty() && snapshot.selfId == action.identity &&
            pendingIdentityRestore == null && !identityRestoreRecoveryFailed && !identityRestoreCommitting &&
            snapshot.owns(action.ownerKey, action.conversationId) &&
            (if (group != null) !action.startCall && action.topicId in group.textRooms
             else DmTopicWire.itemTag(action.topicId).tagged && dmTopicArchives.admits(action.conversationId, action.topicId))
    }

    internal fun issueMessageAction(scope: NativeAccountScope, owner: String, conversation: String, topic: String,
                                    startCall: Boolean = false, replyAllowed: Boolean = true): String? {
        val action = MessageActionOwner(scope, routingSnapshot.selfId, owner, conversation, topic, startCall, replyAllowed)
        return if (messageActionCurrent(action)) messageActions.issue(action) else null
    }

    internal fun resolveMessageAction(token: String): MessageActionOwner? =
        messageActions.resolve(token)?.takeIf(::messageActionCurrent)

    internal fun consumeMessageAction(token: String, action: MessageActionOwner): Boolean =
        messageActionCurrent(action) && messageActions.consume(token, action)

    internal fun retireMessageActions(conversation: String) = messageActions.retireConversation(conversation)

    internal fun sendNotificationReply(action: MessageActionOwner, text: String): String {
        if (!messageActionCurrent(action) || !action.replyAllowed || action.startCall) return ""
        val group = groupConversationId(action.ownerKey) != null
        val body = if (group) GroupPolicy.replyBody(action.topicId, text) ?: return "" else text
        return sendChatMessage(action.ownerKey, action.conversationId, body, "", if (group) "" else action.topicId)
    }

    /** Commit a persistent direct-chat message to the friend-owned libjami swarm. */
    fun sendChatMessage(
        peer: String,
        conversationId: String,
        body: String,
        replyTo: String,
        topicId: String = "",
    ): String {
        val acc = accountId ?: return ""
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(body, TimelineWireBounds.MAX_TEXT_CODE_UNITS) ||
            !DmTopicWire.validOutgoingTopic(topicId) ||
            !TimelineWireBounds.optional(
                replyTo,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return ""
        return JamiService.sendMessageWithId(acc, conversationId, body, replyTo, topicId)
    }

    fun sendDmTopicEvent(peer: String, conversationId: String, body: String): String {
        val acc = accountId ?: return ""
        val owner = normalizeOwnerKey(peer)
        if (groupConversationId(owner) != null ||
            !routingSnapshot.owns(owner, conversationId) ||
            body.isEmpty() ||
            body.toByteArray(Charsets.UTF_8).size > DmTopicWire.MAX_EVENT_BYTES ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return ""
        return JamiService.sendSybLTopicEventWithId(acc, conversationId, body)
    }

    internal fun sendOwnedMessage(scope: NativeAccountScope?, peer: String, conversationId: String,
                                  mimeType: String, body: String, replyTo: String,
                                  topicId: String, roomId: String, operationId: String): String {
        val acc = scope?.accountId ?: return "failed-before-commit"
        val owner = normalizeOwnerKey(peer)
        val group = groupConversationId(owner) != null
        if (!accountAuthority.owns(scope) || !keepOnline || pendingIdentityRestore != null ||
            identityRestoreRecoveryFailed || !routingSnapshot.owns(owner, conversationId) ||
            !TimelineWireBounds.required(body, TimelineWireBounds.MAX_TEXT_CODE_UNITS) ||
            !TimelineWireBounds.optional(replyTo, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            (group && topicId.isNotEmpty()) || (!group && roomId.isNotEmpty()) ||
            !DmTopicWire.validOutgoingTopic(topicId)) return "failed-before-commit"
        if (group && mimeType == "application/x-sybl-sticker+json") {
            // A hologram remains direct-chat-only even if a caller bypasses Dart.
            val presentation = runCatching { JSONObject(body).getString("presentation") }.getOrNull()
            if (presentation != "inline") return "failed-before-commit"
        }
        if (!ownedMessageOperations.begin(OwnedMessageOperation(scope, owner, conversationId, operationId))) return "unknown"
        val result = try {
            JamiService.sendSybLMessage(acc, conversationId, mimeType, body, replyTo, topicId, roomId, operationId)
        } catch (_: Throwable) { "unknown" }
        if (result == "failed-before-commit") ownedMessageOperations.complete(acc, conversationId, operationId)
        return result
    }

    internal fun sendOwnedReaction(scope: NativeAccountScope?, peer: String, conversation: String,
                                   message: String, removed: String, emoji: String,
                                   topic: String, room: String, operation: String): String {
        val acc = scope?.accountId ?: return "failed-before-commit"
        val owner = normalizeOwnerKey(peer)
        val group = groupConversationId(owner) != null
        if (!accountAuthority.owns(scope) || !keepOnline || pendingIdentityRestore != null ||
            identityRestoreRecoveryFailed || !routingSnapshot.owns(owner, conversation) ||
            !ReactionProjection.validIdentity(message) || !ReactionProjection.validIdentity(conversation) ||
            (if (removed.isEmpty()) emoji !in ReactionProjection.palette else
                (!ReactionProjection.validIdentity(removed) || removed == message || emoji.isNotEmpty())) ||
            (group && (topic.isNotEmpty() || room.isEmpty())) ||
            (!group && (room.isNotEmpty() || topic.isEmpty())) ||
            !DmTopicWire.validOutgoingTopic(topic)) return "failed-before-commit"
        if (!ownedMessageOperations.begin(OwnedMessageOperation(scope, owner, conversation, operation))) return "unknown"
        val result = try {
            JamiService.sendSybLReaction(acc, conversation, message, removed, emoji, topic, room, operation)
        } catch (_: Throwable) { "unknown" }
        if (result == "failed-before-commit") ownedMessageOperations.complete(acc, conversation, operation)
        return result
    }

    private fun onOwnedMessageCompleted(account: String, conversation: String, operation: String, commit: String) {
        val owned = ownedFileOperations.committed(account, conversation, operation, commit)?.command
            ?: ownedMessageOperations.complete(account, conversation, operation, commit.isNotEmpty()) ?: return
        emit(mapOf("type" to "sendOperationCompleted", "accountId" to account,
            "peerJamiId" to owned.peer, "conversationId" to conversation, "operationId" to operation,
            "status" to if (commit.isEmpty()) "unknown" else "committed", "commitId" to commit))
    }

    internal fun sendOwnedFile(scope: NativeAccountScope?, peer: String, conversation: String,
                               path: String, name: String, topic: String, room: String,
                               media: String, operation: String): String {
        val acc = scope?.accountId ?: return "failed-before-commit"
        // A durable admission from a prior process may already have committed.
        // Neither an absent stage nor a changed online state proves otherwise.
        if (::stageRegistry.isInitialized &&
            (!stageRegistry.healthy || stageRegistry.find(operation) != null)) return "unknown"
        val owner = normalizeOwnerKey(peer)
        val group = groupConversationId(owner) != null
        if (!accountAuthority.owns(scope) || !keepOnline || pendingIdentityRestore != null ||
            identityRestoreRecoveryFailed || !routingSnapshot.owns(owner, conversation) ||
            (group && topic.isNotEmpty()) || (!group && room.isNotEmpty()) ||
            !DmTopicWire.validOutgoingTopic(topic) || !isOutgoingPickerCopy(path) ||
            name.length > 1024 || media.length > 1024) return "failed-before-commit"
        val entry = OwnedFileOperation(OwnedMessageOperation(scope, owner, conversation, operation), path)
        if (!ownedFileOperations.begin(entry)) return "unknown"
        if (!::stageRegistry.isInitialized || !stageRegistry.issue(StageRecord(path, acc, owner, conversation, operation))) {
            ownedFileOperations.removeExact(entry)
            return "failed-before-commit"
        }
        val result = try {
            JamiService.sendSybLFile(acc, conversation, path, name, topic, room, media, operation)
        } catch (_: Throwable) { "unknown" }
        if (result == "failed-before-commit") {
            stageRegistry.forget(path)
            ownedFileOperations.removeExact(entry)
        }
        return result
    }

    private fun onOwnedFileSeed(account: String, conversation: String, operation: String,
                                commit: String, file: String, ready: Boolean) {
        val owned = ownedFileOperations.seeded(account, conversation, operation, commit, file, ready) ?: return
        emit(mapOf("type" to "fileSeedReady", "accountId" to account,
            "peerJamiId" to owned.command.peer, "conversationId" to conversation,
            "operationId" to operation, "commitId" to commit, "fileId" to file,
            "ready" to owned.seedReady))
    }

    internal fun acknowledgeFileSeed(scope: NativeAccountScope?, conversation: String, operation: String, commit: String): Boolean {
        val account = scope?.accountId ?: return false
        if (!accountAuthority.owns(scope) || !::stageRegistry.isInitialized || !stageRegistry.healthy) return false
        val record = stageRegistry.find(operation)
        if (record != null && (record.account != account || record.conversation != conversation)) return false
        val root = File(appContext.filesDir, "outgoing")
        val source = record?.path?.takeIf { isOwnedPickerStagingFile(root, File(it)) } ?: ""
        if (!JamiService.repairSybLFileSeed(account, conversation, operation, commit, source) ||
            !accountAuthority.owns(scope)) return false
        if (record != null) synchronized(stageRegistry) {
            val file = File(record.path)
            if (file.exists() && !deleteOwnedPickerStagingFile(root, file)) return false
            if (!stageRegistry.forget(record.path)) return false
        }
        ownedFileOperations.acknowledgeVerified(account, conversation, operation, commit)
        return true
    }

    fun setMessageDisplayed(peer: String, conversationId: String, messageId: String): Boolean {
        val acc = accountId ?: return false
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) ||
            !TimelineWireBounds.required(messageId, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS)) {
            return false
        }
        return JamiService.setMessageDisplayed(acc, "swarm:$conversationId", messageId, 3)
    }

    /** Start one daemon-correlated history page; [onSwarmLoaded] publishes the atomic result. */
    fun loadChat(
        peer: String,
        conversationId: String,
        fromMessage: String,
        pageSize: Int,
    ): Long {
        val acc = accountId ?: return 0L
        val owner = normalizeOwnerKey(peer)
        if (!routingSnapshot.owns(owner, conversationId) ||
            pageSize !in 1..TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_ITEMS ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.optional(
                fromMessage,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return 0L
        return registerConversationLoad(
            acc, fromMessage, pageSize, ChatConversationLoad(owner, conversationId, fromMessage, pageSize),
        )
    }

    fun loadDmTopicState(
        peer: String,
        conversationId: String,
        fromMessage: String,
        pageSize: Int,
    ): Long {
        val acc = accountId ?: return 0L
        val owner = normalizeOwnerKey(peer)
        if (groupConversationId(owner) != null ||
            !routingSnapshot.owns(owner, conversationId) ||
            pageSize !in 1..DmTopicWire.MAX_STATE_PAGE_ITEMS ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.optional(
                fromMessage,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return 0L
        return registerConversationLoad(
            acc, fromMessage, pageSize, DmTopicStateConversationLoad(owner, conversationId, fromMessage, pageSize),
        )
    }

    /**
     * Retire one Dart-abandoned chat load locally. libjami has no matching
     * cancellation API; a late SwarmLoaded callback is ignored and its random
     * id remains quarantined for this process.
     */
    fun cancelChatLoad(loadId: Long): Boolean =
        loadId > 0L && conversationLoads.cancelChat(loadId)

    // Returned IDs are already registered; cancellation must not wait for
    // an unrelated daemon load that holds the registration barrier.
    fun cancelDmTopicStateLoad(loadId: Long): Boolean =
        loadId > 0L && conversationLoads.cancelDmTopicState(loadId)

    /** Reduce an untrusted display name (the SENDER's swarm-commit displayName) to a safe leaf filename —
     *  Windows-parity hardening (M7.5 f / audit L5). Strip any path; drop control chars + the filesystem-reserved
     *  set (`< > : " | ? *` — `:` matters if the file is later moved to a FAT/exFAT card or shared cross-platform,
     *  where it's an NTFS Alternate-Data-Stream smuggle); cap the length; reject ./.. and empties. The under-receive-
     *  dir join (uniqueFile) backstops traversal. Mirrors the Windows ReceiveDestPath leaf rules. */
    private fun safeLeaf(name: String): String {
        var leaf = name.substringAfterLast('/').substringAfterLast('\\')
        leaf = leaf.filter { it.code >= 0x20 && it.code != 0x7f && it !in "<>:\"|?*" }.trim()
        if (leaf.length > 200) leaf = leaf.take(200).trim()  // leave room for the " (n)" dedup suffix + extension
        return if (leaf.isEmpty() || leaf == "." || leaf == "..") "file" else leaf
    }

    /** Revalidates the native completion receipt, file identity and content hash. */
    private fun isDownloaded(acc: String, conv: String, fileId: String): Boolean = try {
        JamiService.fileTransferCompleted(acc, conv, fileId, arrayOfNulls<String>(1), LongArray(1))
    } catch (_: Throwable) { false }

    /** Normalize libjami's folded swarm interaction without creating another message store. */
    private fun timelineItem(
        acc: String,
        owner: String,
        conv: String,
        msg: SwarmMessage,
        localJamiId: String,
        liveUpdate: Boolean,
    ): TimelineWireItem? {
        val stableId = msg.id ?: return null
        if (!TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(conv, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                stableId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            (msg.type != "text/plain" &&
                msg.type != "application/data-transfer+json" &&
                msg.type != RichTimelineMetadata.STICKER_MIME &&
                msg.type != DmTopicWire.EVENT_MIME)) return null
        val body = msg.body?.toNative() ?: return null
        val richMetadata = RichTimelineMetadata.project(
            body, routingSnapshot.group(conv) != null,
        ) ?: return null
        val semantics = timelineMessageSemantics(
            daemonId = stableId,
            latestEditionId = msg.latestEditionId,
            mimeType = msg.type,
            body = body,
            liveUpdate = liveUpdate,
        ) ?: return null
        if (!TimelineWireBounds.required(
                semantics.versionId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return null
        val rawAuthor = body["author"].orEmpty()
        if (!TimelineWireBounds.required(
                rawAuthor,
                TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
            )) return null
        val author = bareJamiId(rawAuthor)
        val historyRouting = routingSnapshot
        if (historyRouting.accountId != acc || !historyRouting.owns(owner, conv)) return null
        val authenticatedGroupHistory = historyRouting.group(conv) != null
        if (!TimelineWireBounds.required(
                author,
                TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(
                localJamiId,
                TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
            ) ||
            (author != localJamiId &&
                !authenticatedGroupHistory &&
                !historyRouting.acceptsAuthor(owner, conv, author))) return null
        val linearizedParent = msg.linearizedParent.orEmpty()
        if (!TimelineWireBounds.optional(
                linearizedParent,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            )) return null
        val timestamp = body["timestamp"] ?: return null
        if (!TimelineWireBounds.required(timestamp, 64)) return null
        val seconds = timestamp.toLongOrNull()?.takeIf { it >= 0 } ?: return null
        val result = linkedMapOf<String, Any?>(
            "accountId" to acc,
            "peerId" to owner,
            "conversationId" to conv,
            "daemonId" to stableId,
            "versionId" to semantics.versionId,
            "mimeType" to msg.type,
            "authorId" to author,
            "timestampSeconds" to seconds,
            "linearizedParent" to linearizedParent,
            // Jami already validated signature and membership at commit time.
            // Current membership remains authoritative for new actions.
            "authenticatedGroupHistory" to authenticatedGroupHistory,
        )
        val topic = DmTopicWire.itemTag(body[DmTopicWire.ITEM_FIELD])
        result.putAll(richMetadata)
        if (msg.type != DmTopicWire.EVENT_MIME) {
            val reactions = msg.reactions
            result["reactions"] = ReactionProjection.project(
                stableId, reactions?.size ?: 0,
                read = { index ->
                    val reaction = reactions!![index]
                    mapOf(
                        "id" to (reaction["id"] ?: ""),
                        "author" to bareJamiId(reaction["author"] ?: ""),
                        "body" to (reaction["body"] ?: ""),
                        "react-to" to (reaction["react-to"] ?: ""),
                    )
                },
                acceptsAuthor = { reactionAuthor ->
                    authenticatedGroupHistory || reactionAuthor == localJamiId ||
                        historyRouting.acceptsAuthor(owner, conv, reactionAuthor)
                },
            )
        }
        result["topicId"] = topic.topicId
        result["topicTagged"] = topic.tagged
        var groupReaders = emptySet<String>()
        if (author == localJamiId) {
            val statuses = msg.status
            val group = routingSnapshot.group(conv)
            if (group != null) {
                val receipt = foldGroupReceipt(
                    group,
                    statuses?.entries?.associate { it.key to it.value }.orEmpty(),
                )
                groupReaders = receipt.readBy
                result["deliveryState"] = receipt.deliveryState
                result["readByMemberIds"] = groupReaders.toList()
            } else {
                val direct = statuses?.entries?.firstOrNull {
                    bareJamiId(it.key) == bareJamiId(owner)
                }?.value
                val delivery = direct ?: statuses?.entries
                    ?.filter { bareJamiId(it.key) != localJamiId }
                    ?.maxOfOrNull { it.value } ?: 1
                result["deliveryState"] = delivery.coerceIn(1, 3)
            }
        }
        semantics.operation?.let { result["operation"] = it }
        result["deleted"] = semantics.deleted
        if (msg.type == DmTopicWire.EVENT_MIME) {
            val event = DmTopicWire.stateEnvelope(
                stableId,
                msg.type,
                linearizedParent,
                body,
            ) ?: return null
            result["eventBody"] = event.eventBody ?: return null
        } else if (msg.type == RichTimelineMetadata.STICKER_MIME) {
            result["body"] = body["body"] ?: return null
        } else if (msg.type == "text/plain") {
            val text = body["body"] ?: return null
            if (!TimelineWireBounds.optional(
                    text,
                    TimelineWireBounds.MAX_TEXT_CODE_UNITS,
                )) return null
            result["body"] = text
        } else {
            if (semantics.deleted) {
                result["body"] = emptyMap<String, Any?>()
            } else {
                val fileId = body["fileId"].orEmpty()
                val displayName = body["displayName"] ?: "file"
                val sha3 = body["sha3sum"].orEmpty()
                if (!TimelineWireBounds.required(
                        fileId,
                        TimelineWireBounds.MAX_FILE_ID_CODE_UNITS,
                    ) ||
                    !TimelineWireBounds.required(
                        displayName,
                        TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
                    ) ||
                    !TimelineWireBounds.optional(
                        sha3,
                        TimelineWireBounds.MAX_HASH_CODE_UNITS,
                    )) return null
                val totalSizeText = body["totalSize"]
                val totalBytes = totalSizeText?.let {
                    if (!TimelineWireBounds.required(it, 64)) return null
                    it.toLongOrNull()?.takeIf { size -> size >= 0 } ?: return null
                }
                if (accountId != acc) return null
                val offerKey = FileOfferKey(acc, owner, conv, stableId, fileId)
                fileOffers.putIfAbsent(offerKey, FileOffer(
                    totalBytes ?: -1L, displayName, author, author == localJamiId,
                    body["sybl-media-v1"]?.let { if (RichTimelineMetadata.boundedBody(it)) it else "" },
                ))
                result["body"] = mapOf(
                    "fileId" to fileId,
                    "displayName" to displayName,
                    "totalBytes" to totalBytes,
                    "sha3" to sha3.takeIf(String::isNotEmpty),
                    "downloaded" to isDownloaded(acc, conv, fileId),
                )
            }
        }

        // StandardMessageCodec has fixed map/type overhead in addition to
        // strings. A conservative allowance keeps the same 8 MiB page budget
        // as Windows without allocating a second JSON representation.
        var encodedBytes = 256L
        fun add(value: String, maxCodeUnits: Int): Boolean {
            val bytes = TimelineWireBounds.utf8Bytes(value, maxCodeUnits) ?: return false
            encodedBytes += bytes
            return encodedBytes <= TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_BYTES
        }
        if (!add(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !add(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !add(conv, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !add(stableId, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !add(semantics.versionId, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !add(author, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !add(linearizedParent, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !add(topic.topicId, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS)) return null
        for (reader in groupReaders) {
            if (!add(reader, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS)) return null
        }
        for (field in richMetadata.values) {
            if (!add(field, 1024)) return null
        }
        if (msg.type == DmTopicWire.EVENT_MIME) {
            if (!add(body["body"].orEmpty(), DmTopicWire.MAX_EVENT_BYTES)) return null
        } else if (msg.type == RichTimelineMetadata.STICKER_MIME) {
            if (!add(body["body"].orEmpty(), 1024)) return null
        } else if (msg.type == "text/plain") {
            if (!add(body["body"].orEmpty(), TimelineWireBounds.MAX_TEXT_CODE_UNITS)) return null
        } else if (!semantics.deleted) {
            if (!add(body["fileId"].orEmpty(), TimelineWireBounds.MAX_FILE_ID_CODE_UNITS) ||
                !add(
                    body["displayName"] ?: "file",
                    TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
                ) ||
                !add(body["sha3sum"].orEmpty(), TimelineWireBounds.MAX_HASH_CODE_UNITS)) return null
        }
        return TimelineWireItem(result, encodedBytes.toInt())
    }

    /** swarmLoaded reply: turn the conversation's data-transfer commits into persistent shared-folder items.
     *  Worker thread (the SWIG director marshals here? no — runs on a daemon thread, but only touches the daemon
     *  + emit, which is main-marshaled). Keep the newest [folderKeepLast]. */
    internal fun onSwarmLoaded(loadId: Long, acc: String, conv: String, messages: SwarmMessageVect) {
        val pendingLoad = synchronized(loadRegistrationLock) {
            conversationLoads.take(loadId)
        } ?: return
        if (pendingLoad is SearchMessageConversationLoad) {
            completeSearchMessage(pendingLoad, acc, conv, messages)
            return
        }
        if (pendingLoad.conversationId != conv ||
            !TimelineWireBounds.required(acc, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(conv, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                pendingLoad.peerId,
                TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
            )) return
        if (pendingLoad is DmTopicStateConversationLoad) {
            val load = pendingLoad
            if (groupConversationId(load.peerId) != null ||
                !routingSnapshot.owns(load.peerId, conv)) return
            val me = myJamiId()
            val items = ArrayList<Map<String, Any?>>()
            var inspectedCount = 0
            var nextCursor = ""
            for (i in 0 until messages.size) {
                if (inspectedCount >= load.pageSize) break
                val message = messages.get(i)
                val daemonId = message.id.orEmpty()
                if (!TimelineWireBounds.required(
                        daemonId,
                        TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                    )) return
                val body = message.body?.toNative().orEmpty()
                val daemonRead = message.status?.entries?.any {
                    bareJamiId(it.key) == me && it.value >= 3
                } ?: false
                val envelope = DmTopicWire.stateEnvelope(
                    daemonId,
                    message.type.orEmpty(),
                    message.linearizedParent.orEmpty(),
                    body,
                    daemonRead,
                )
                if (envelope != null) {
                    val authorId = bareJamiId(envelope.authorId)
                    if (authorId == me ||
                        routingSnapshot.acceptsAuthor(load.peerId, conv, authorId)) {
                        items.add(envelope.toMap() + ("authorId" to authorId))
                        if (envelope.mimeType == DmTopicWire.EVENT_MIME &&
                            envelope.eventBody != null) {
                            val changed = dmTopicArchives.apply(
                                conv,
                                envelope.commitId,
                                authorId,
                                me,
                                envelope.eventBody,
                            )
                            if (changed) {
                                dmTopicArchives.archivedTopics(conv).forEach { topicId ->
                                    MessageNotifications.cancelTopic(appContext, conv, topicId)
                                }
                            }
                        }
                    }
                }
                nextCursor = daemonId
                inspectedCount += 1
            }
            val hasMore = messages.size >= load.pageSize &&
                nextCursor.isNotEmpty() && nextCursor != load.fromMessage
            if (!hasMore) nextCursor = ""
            emit(mapOf(
                "type" to "dmTopicStatePage",
                "accountId" to acc,
                "peerJamiId" to load.peerId,
                "conversationId" to conv,
                "loadId" to loadId,
                "requestedCursor" to load.fromMessage,
                "nextCursor" to nextCursor,
                "hasMore" to hasMore,
                "items" to items,
            ))
            return
        }
        if (pendingLoad is ChatConversationLoad) {
            val chatLoad = pendingLoad
            if (chatLoad.conversationId != conv || !routingSnapshot.owns(chatLoad.peerId, conv)) return
            val me = myJamiId()
            val items = ArrayList<Map<String, Any?>>()
            var encodedBytes = 1
            var inspectedCount = 0
            var bounded = false
            var nextCursor = ""
            for (i in 0 until messages.size) {
                if (inspectedCount >= TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_ITEMS) {
                    bounded = true
                    break
                }
                val message = messages.get(i)
                val daemonId = message.id.orEmpty()
                if (!TimelineWireBounds.required(
                        daemonId,
                        TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                    )) return
                val item = timelineItem(acc, chatLoad.peerId, conv, message, me, false)
                if (item != null) {
                    if (!TimelineWireBounds.canAppendTimelineItem(
                            items.size,
                            encodedBytes,
                            item.encodedBytes,
                        )) {
                        bounded = true
                        break
                    }
                    if (items.isNotEmpty()) encodedBytes += 1
                    encodedBytes += item.encodedBytes
                    items.add(item.value)
                }
                nextCursor = daemonId
                inspectedCount += 1
            }
            val hasMore = (bounded || messages.size >= chatLoad.pageSize) &&
                nextCursor.isNotEmpty() && nextCursor != chatLoad.fromMessage
            if (!hasMore) nextCursor = ""
            emit(mapOf(
                "type" to "chatSnapshot",
                "accountId" to acc,
                "peerJamiId" to chatLoad.peerId,
                "conversationId" to conv,
                "loadId" to loadId,
                "requestedCursor" to chatLoad.fromMessage,
                "nextCursor" to nextCursor,
                "hasMore" to hasMore,
                "items" to items,
            ))
            return
        }
        val load = pendingLoad as? FolderConversationLoad ?: return
        if (load.conversationId != conv || !routingSnapshot.owns(load.peerId, conv)) return
        data class Item(
            val fileId: String,
            val iid: String,
            val name: String,
            val size: Long,
            val sha3: String,
            val outgoing: Boolean,
            val authorId: String,
            val topicId: String,
            val topicTagged: Boolean,
            val roomId: String,
            val ts: Long,
            val encodedBytes: Int,
        )
        val items = ArrayList<Item>()
        val me = myJamiId()
        for (i in 0 until messages.size) {
            if (items.size >= load.keepLast) break
            val m = messages.get(i)
            if (m.type != "application/data-transfer+json") continue
            val body = m.body?.toNative() ?: continue
            val fileId = body["fileId"] ?: ""
            if (fileId.isEmpty()) continue
            val name = body["displayName"] ?: "file"
            val sizeText = body["totalSize"]
            if (sizeText != null && !TimelineWireBounds.required(sizeText, 64)) continue
            val size = if (sizeText == null) {
                -1L
            } else {
                sizeText.toLongOrNull()?.takeIf { it >= 0 } ?: continue
            }
            val sha3 = body["sha3sum"] ?: ""
            val timestamp = body["timestamp"] ?: ""
            val author = body["author"] ?: ""
            if (!TimelineWireBounds.required(
                    fileId,
                    TimelineWireBounds.MAX_FILE_ID_CODE_UNITS,
                ) ||
                !TimelineWireBounds.required(
                    m.id.orEmpty(),
                    TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                ) ||
                !TimelineWireBounds.required(
                    name,
                    TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
                ) ||
                !TimelineWireBounds.optional(
                    sha3,
                    TimelineWireBounds.MAX_HASH_CODE_UNITS,
                ) ||
                !TimelineWireBounds.required(
                    author,
                    TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
                ) ||
                !TimelineWireBounds.required(timestamp, 64)) continue
            val ts = timestamp.toLongOrNull()?.takeIf { it >= 0 } ?: continue
            val authorId = bareJamiId(author)
            if (authorId.isEmpty()) continue
            val outgoing = authorId == me
            if (!outgoing &&
                !routingSnapshot.acceptsAuthor(load.peerId, conv, authorId)
            ) continue
            val offerKey = FileOfferKey(acc, load.peerId, conv, m.id, fileId)
            fileOffers.putIfAbsent(offerKey, FileOffer(
                size, name, authorId, outgoing,
                body["sybl-media-v1"]?.let { if (RichTimelineMetadata.boundedBody(it)) it else "" },
            ))
            val rich = RichTimelineMetadata.project(body, routingSnapshot.group(conv) != null) ?: continue
            val roomId = rich["roomId"].orEmpty()
            val topic = DmTopicWire.itemTag(body[DmTopicWire.ITEM_FIELD])
            xfers.putIfAbsent(offerKey, FileXfer(fileId, m.id, name, size, outgoing, authorId,
                topic.topicId, topic.tagged, roomId))
            val itemBytes = 240L +
                TimelineWireBounds.utf8Bytes(
                    fileId,
                    TimelineWireBounds.MAX_FILE_ID_CODE_UNITS,
                )!! +
                TimelineWireBounds.utf8Bytes(
                    m.id,
                    TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                )!! +
                TimelineWireBounds.utf8Bytes(
                    name,
                    TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
                )!! +
                TimelineWireBounds.utf8Bytes(
                    sha3,
                    TimelineWireBounds.MAX_HASH_CODE_UNITS,
                )!! +
                TimelineWireBounds.utf8Bytes(
                    authorId,
                    TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
                )!!
            if (itemBytes > Int.MAX_VALUE) continue
            items.add(
                Item(
                    fileId,
                    m.id,
                    name,
                    size,
                    sha3,
                    outgoing,
                    authorId,
                    topic.topicId,
                    topic.tagged,
                    roomId,
                    ts,
                    itemBytes.toInt(),
                ),
            )
        }
        items.sortByDescending { it.ts }
        val files = ArrayList<Map<String, Any?>>()
        var folderBytes = 1L
        for (item in items) {
            val separator = if (files.isEmpty()) 0 else 1
            if (folderBytes + separator + item.encodedBytes + 1 >
                TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_BYTES) break
            files.add(mapOf(
                "fileId" to item.fileId,
                "interactionId" to item.iid,
                "name" to item.name,
                "size" to item.size,
                "sha3" to item.sha3,
                "outgoing" to item.outgoing,
                "authorId" to item.authorId,
                "topicId" to item.topicId,
                "topicTagged" to item.topicTagged,
                "roomId" to item.roomId,
                "downloaded" to isDownloaded(acc, conv, item.fileId),
                "timestamp" to item.ts,
            ))
            folderBytes += separator + item.encodedBytes
        }
        emit(mapOf(
            "type" to "folderSnapshot",
            "accountId" to acc,
            "peerJamiId" to load.peerId,
            "conversationId" to conv,
            "loadId" to loadId,
            "files" to files,
        ))
        Log.i(TAG, "swarmLoaded($conv) ${items.size} file(s) -> folder")
    }

    /** Pick a non-clobbering filename in [dir] (append " (1)", " (2)", … before the extension). */
    private fun reserveUniqueFile(key: TransferKey, dir: File, name: String): File {
        receiveDestByFile[key]?.let { return File(it) }
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        synchronized(reservedReceivePaths) {
            var dest = File(dir, name)
            var n = 1
            while (dest.exists() || !reservedReceivePaths.add(dest.absolutePath)) {
                dest = File(dir, "$base ($n)$ext")
                n++
            }
            receiveDestByFile[key] = dest.absolutePath
            return dest
        }
    }

    private fun releaseReceiveReservation(key: TransferKey) {
        receiveDestByFile.remove(key)?.let { reservedReceivePaths.remove(it) }
    }

    /** True only for a regular leaf in a generated app-private picker directory. */
    private fun isOutgoingPickerCopy(path: String): Boolean =
        isOwnedPickerStagingFile(File(appContext.filesDir, "outgoing"), File(path))

    // libjami DataTransferEventCode → a UI status string (see datatransfer_interface.h).
    private fun codeToStatus(code: Int): String = when (code) {
        1, 3, 4 -> "waiting"     // created / wait_peer_acceptance / wait_host_acceptance
        5 -> "ongoing"
        6 -> "finished"
        7 -> "canceled"          // closed_by_host
        8 -> "declined"          // closed_by_peer
        else -> "error"          // invalid / unsupported / invalid_pathname / unjoinable_peer / timeout_expired
    }

    // ---- DataTransfer + Conversation callbacks (daemon thread → marshal via emit) ----

    /** A transfer changed state: query bytes + forward status/progress to Dart (labeled by the cached xfer info). */
    internal fun onDataTransferEvent(acc: String, conversationId: String, interactionId: String, fileId: String, code: Int, attemptId: String = "") {
        // Sender-side CREATED/INVALID use fileId for the original source path, not a transfer id. libjami has
        // handed successful sends to an independent conversation_data seed. INVALID
        // retains the source for repair of the already-committed transfer. A callback may follow
        // account replacement, while the exact generated app-private child check remains sufficient authority.
        if (code == 1 || code == 2) {
            if (!isOutgoingPickerCopy(fileId)) return
            // Owned publications await the durable command-journal acknowledgement.
            if (ownedFileOperations.ownsPath(fileId)) return
            if (!::stageRegistry.isInitialized || stageRegistry.ownsIssued(fileId)) return
            if (code != 1) {
                Log.w(TAG, "outgoing seed handoff failed; source retained")
                return
            }
            val source = File(fileId)
            if (!deleteOwnedPickerStagingFile(File(appContext.filesDir, "outgoing"), source)) {
                Log.e(TAG, "outgoing picker handoff cleanup failed")
            }
            return
        }
        val owner = ownerForConversation(acc, conversationId) ?: return
        val key = TransferKey(owner, conversationId, fileId)
        val offerKey = FileOfferKey(acc, owner, conversationId, interactionId, fileId)
        val scope = captureAccountScope(acc) ?: return
        val attempt = receiveAttempts[key]
        if (attemptId.isNotEmpty() && (attempt?.id != attemptId || !accountAuthority.owns(attempt.account))) return
        worker.execute(DaemonOperation.FILE_PROGRESS) {
            if (!accountAuthority.owns(scope) || !routingSnapshot.owns(owner, conversationId) ||
                (attemptId.isNotEmpty() && receiveAttempts[key] != attempt)) return@execute
            val info = xfers.get(offerKey)
            val path = arrayOfNulls<String>(1); val total = LongArray(1); val progress = LongArray(1)
            var completed = false
            try {
                JamiService.fileTransferInfo(acc, conversationId, fileId, path, total, progress)
                val verifiedSize = LongArray(1)
                completed = JamiService.fileTransferCompleted(acc, conversationId, fileId, path, verifiedSize)
                if (completed) { total[0] = verifiedSize[0]; progress[0] = verifiedSize[0] }
            } catch (_: Throwable) { path[0] = null }
            if (!accountAuthority.owns(scope) ||
                (attemptId.isNotEmpty() && receiveAttempts[key] != attempt)) return@execute
            emit(mapOf("type" to "fileProgress", "accountId" to acc,
                "attemptId" to attemptId,
                "peerJamiId" to owner, "conversationId" to conversationId,
                "fileId" to fileId, "interactionId" to interactionId,
                "metadataKnown" to (info != null),
                "outgoing" to (info?.outgoing ?: attemptId.isEmpty()), "name" to (info?.name ?: ""),
                "authorId" to (info?.authorId ?: ""),
                "topicId" to (info?.topicId ?: DmTopicWire.MAIN),
                "topicTagged" to (info?.topicTagged ?: false),
                "roomId" to info?.roomId.orEmpty(),
                "status" to (if (code == 6 && !completed) "error" else codeToStatus(code)),
                "completed" to completed, "transferred" to progress[0], "total" to total[0],
                "path" to (if (completed) path[0] ?: "" else "")))
            // Release the metadata once the transfer is terminal (not created/wait/ongoing) so xfers stays bounded.
            if (code != 1 && code != 3 && code != 4 && code != 5) {
                if (info != null) xfers.remove(offerKey, info)
                if (attempt != null && receiveAttempts.remove(key, attempt)) releaseReceiveReservation(key)
            }
        }
    }

    /** A new swarm message: if it's a file (data-transfer commit), record it + (incoming only) offer it to the UI.
     *  Read msg fields synchronously — the daemon-owned SwarmMessage is only valid for this callback. */
    private fun onReaction(accountId: String, conversationId: String, messageId: String,
                           reaction: StringMap? = null, removedId: String? = null) {
        val owner = ownerForConversation(accountId, conversationId) ?: return
        val historyRouting = routingSnapshot
        if (historyRouting.accountId != accountId || !historyRouting.owns(owner, conversationId) ||
            !ReactionProjection.validIdentity(messageId)) return
        val group = historyRouting.group(conversationId) != null
        val item = mutableMapOf<String, Any>("accountId" to accountId, "peerId" to owner,
            "conversationId" to conversationId, "messageId" to messageId,
            "authenticatedGroupHistory" to group)
        if (reaction != null) {
            val me = myJamiId()
            val projection = ReactionProjection.project(messageId, 1, {
                mapOf("id" to (reaction["id"] ?: ""),
                    "author" to bareJamiId(reaction["author"] ?: ""),
                    "body" to (reaction["body"] ?: ""),
                    "react-to" to (reaction["react-to"] ?: ""))
            }) { author -> group || author == me || historyRouting.acceptsAuthor(owner, conversationId, author) }
            val entry = (projection["entries"] as? List<*>)?.singleOrNull() as? Map<*, *> ?: return
            item["reaction"] = entry
        } else {
            if (removedId == null || !ReactionProjection.validIdentity(removedId) || removedId == messageId) return
            item["removedId"] = removedId
        }
        emit(mapOf("type" to "chatReaction", "accountId" to accountId,
            "peerJamiId" to owner, "conversationId" to conversationId, "item" to item))
    }

    internal fun onSwarmMessage(accountId: String, conversationId: String, msg: SwarmMessage) {
        val owner = ownerForConversation(accountId, conversationId) ?: return
        val me = myJamiId()
        val item = timelineItem(accountId, owner, conversationId, msg, me, false)
        val fresh = item?.let { liveMessageEffects.admit(accountId, conversationId, it.value) } == true
        item?.let {
            emit(mapOf(
                "type" to "chatMessage",
                "accountId" to accountId,
                "peerJamiId" to owner,
                "conversationId" to conversationId,
                "item" to it.value,
            ))
        }
        if (msg.type == DmTopicWire.EVENT_MIME && item != null) {
            val value = item.value
            val author = value["authorId"] as? String
            val eventBody = value["eventBody"] as? String
            if (author != null && eventBody != null) {
                val changed = dmTopicArchives.apply(
                    conversationId,
                    value["daemonId"] as String,
                    author,
                    me,
                    eventBody,
                )
                if (changed) {
                    dmTopicArchives.archivedTopics(conversationId).forEach { topicId ->
                        MessageNotifications.cancelTopic(appContext, conversationId, topicId)
                    }
                }
            }
        }
        if (fresh && !activityResumed &&
            msg.type in setOf("text/plain", RichTimelineMetadata.STICKER_MIME) && item != null) {
            val value = item.value
            val author = value["authorId"] as? String
            val body = (value["body"] as? String)?.let {
                if (msg.type == RichTimelineMetadata.STICKER_MIME) RichTimelineMetadata.stickerNotification(it) else it
            }
            val seconds = value["timestampSeconds"] as? Long
            val groupRoute = routingSnapshot.group(conversationId)
            val topicId = if (groupRoute != null && body != null)
                GroupPolicy.messageRoom(body, value["roomId"] as? String)
                else value["topicId"] as? String
            if (author != null &&
                body != null &&
                seconds != null &&
                topicId != null &&
                author != me &&
                value["deleted"] != true &&
                value["operation"] == null &&
                (if (groupRoute != null) topicId in groupRoute.textRooms
                    else dmTopicArchives.admits(conversationId, topicId))) {
                val senderName = readPeerProfile(
                    cachedPeerProfile(accountId, author),
                )?.displayName?.takeIf { it.isNotBlank() } ?: "Someone"
                val group = groupConversationId(owner) != null
                val title = if (group) groupNotificationTitle(accountId, conversationId) else senderName
                MessageNotifications.showMessage(
                    appContext,
                    MessageNotificationInput(
                        accountScope = captureAccountScope(accountId) ?: return,
                        ownerKey = owner,
                        conversationId = conversationId,
                        conversationTitle = title,
                        group = group,
                        senderId = author,
                        senderName = senderName,
                        body = body,
                        timestampMs = seconds.coerceAtMost(Long.MAX_VALUE / 1000) * 1000,
                        topicId = topicId,
                    ),
                )
            }
        }
        if (msg.type != "application/data-transfer+json" || item == null) return
        val body = msg.body?.toNative() ?: return
        val fileId = body["fileId"] ?: ""
        if (fileId.isEmpty()) return                  // a delete/edit commit carries an empty fileId — ignore
        val interactionId = msg.id
        val name = body["displayName"] ?: "file"
        val sizeText = body["totalSize"]
        if (sizeText != null && !TimelineWireBounds.required(sizeText, 64)) return
        val size = if (sizeText == null) {
            -1L
        } else {
            sizeText.toLongOrNull()?.takeIf { it >= 0 } ?: return
        }
        val sha3 = body["sha3sum"] ?: ""
        val timestamp = body["timestamp"] ?: return
        val rawAuthor = body["author"].orEmpty()
        if (!TimelineWireBounds.required(
                accountId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(owner, TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS) ||
            !TimelineWireBounds.required(
                conversationId,
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(
                msg.id.orEmpty(),
                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(
                fileId,
                TimelineWireBounds.MAX_FILE_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(
                name,
                TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
            ) ||
            !TimelineWireBounds.optional(
                sha3,
                TimelineWireBounds.MAX_HASH_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(
                rawAuthor,
                TimelineWireBounds.MAX_AUTHOR_ID_CODE_UNITS,
            ) ||
            !TimelineWireBounds.required(timestamp, 64)) return
        val ts = timestamp.toLongOrNull()?.takeIf { it >= 0 } ?: return
        val authorId = bareJamiId(rawAuthor)
        if (authorId.isEmpty()) return
        val outgoing = authorId == me
        if (!outgoing &&
            !routingSnapshot.acceptsAuthor(owner, conversationId, rawAuthor)
        ) {
            return
        }
        val offerKey = FileOfferKey(accountId, owner, conversationId, interactionId, fileId)
        fileOffers.putIfAbsent(offerKey, FileOffer(
            size, name, authorId, outgoing,
            body["sybl-media-v1"]?.let { if (RichTimelineMetadata.boundedBody(it)) it else "" },
        ))
        val roomId = item.value["roomId"] as? String ?: ""
        val topic = DmTopicWire.itemTag(body[DmTopicWire.ITEM_FIELD])
        xfers.putIfAbsent(offerKey, FileXfer(
            fileId,
            interactionId,
            name,
            size,
            outgoing,
            authorId,
            topic.topicId,
            topic.tagged,
            roomId,
        ))
        if (!outgoing) {
            emit(mapOf("type" to "incomingFile", "accountId" to accountId,
                "peerJamiId" to owner, "conversationId" to conversationId,
                "fileId" to fileId, "interactionId" to interactionId,
                "name" to name, "size" to size, "authorId" to authorId,
                "roomId" to roomId, "topicId" to topic.topicId, "topicTagged" to topic.tagged))
            val groupRoute = routingSnapshot.group(conversationId)
            val notificationTopic = if (groupRoute != null) body["sybl-room-v1"] ?: "general" else topic.topicId
            if (fresh && !activityResumed &&
                (if (groupRoute != null) notificationTopic in groupRoute.textRooms
                    else dmTopicArchives.admits(conversationId, notificationTopic))) {
                val senderName = readPeerProfile(
                    cachedPeerProfile(accountId, authorId),
                )?.displayName?.takeIf { it.isNotBlank() } ?: "Someone"
                val group = groupConversationId(owner) != null
                MessageNotifications.showMessage(
                    appContext,
                    MessageNotificationInput(
                        ownerKey = owner,
                        accountScope = captureAccountScope(accountId) ?: return,
                        conversationId = conversationId,
                        conversationTitle = if (group) {
                            groupNotificationTitle(accountId, conversationId)
                        } else {
                            senderName
                        },
                        group = group,
                        senderId = authorId,
                        senderName = senderName,
                        body = "Sent a file: $name",
                        timestampMs = ts.coerceAtMost(Long.MAX_VALUE / 1000) * 1000,
                        topicId = notificationTopic,
                    ),
                )
            }
        }
        // Also surface it in the persistent shared folder (M6) so a file shared THIS session is kept without a
        // restart. downloaded is computed on the worker (fileTransferInfo touches the daemon).
        worker.execute(DaemonOperation.FOLDER_UPDATE) {
            emit(mapOf("type" to "folderFile", "accountId" to accountId,
                "peerJamiId" to owner,
                "fileId" to fileId, "interactionId" to interactionId,
                "conversationId" to conversationId, "name" to name, "size" to size, "sha3" to sha3,
                "outgoing" to outgoing, "authorId" to authorId,
                "roomId" to roomId, "topicId" to topic.topicId, "topicTagged" to topic.tagged,
                "downloaded" to isDownloaded(accountId, conversationId, fileId),
                "timestamp" to ts, "live" to true))   // live=true → optimistic; a reload (live absent) is authoritative
        }
        Log.i(TAG, "Authenticated swarm file projected")
    }

    private fun groupNotificationTitle(accountId: String, conversationId: String): String {
        val raw = try {
            JamiService.conversationInfos(accountId, conversationId)
                .toNative()["title"].orEmpty()
        } catch (_: Throwable) {
            ""
        }
        return ProfileWireBounds.displayName(raw)?.takeIf { it.isNotBlank() } ?: "Group"
    }

    internal fun onSwarmMessageUpdated(accountId: String, conversationId: String, msg: SwarmMessage) {
        val owner = ownerForConversation(accountId, conversationId) ?: return
        val item = timelineItem(accountId, owner, conversationId, msg, myJamiId(), true)
        if (item != null) {
            emit(mapOf(
                "type" to "chatMessage",
                "accountId" to accountId,
                "peerJamiId" to owner,
                "conversationId" to conversationId,
                "item" to item.value,
            ))
        }
    }

    internal fun onConversationProfile(
        accountId: String,
        conversationId: String,
        @Suppress("UNUSED_PARAMETER") profile: Map<String, String>,
    ) {
        val owner = ownerForConversation(accountId, conversationId) ?: return
        if (groupConversationId(owner) != null) {
            requestRoutingRefresh(accountId, forceEvent = true)
        }
    }

    internal fun onPeerProfile(
        accountId: String,
        peerId: String,
    ) {
        val peer = bareJamiId(peerId)
        val snapshot = routingSnapshot
        if (!isActiveAccount(accountId) || snapshot.accountId != accountId) return
        val route = snapshot.friend(peer) ?: return
        val conversationId = route.canonicalConversationId ?: return
        val profile = readPeerProfile(cachedPeerProfile(accountId, peer)) ?: return
        emit(mapOf(
            "type" to "friendProfile",
            "accountId" to accountId,
            "peerJamiId" to peer,
            "conversationId" to conversationId,
            "displayName" to profile.displayName,
            "avatarBase64" to profile.avatarBase64,
        ))
    }

    internal fun onConversationReady(account: String, conversationId: String) {
        if (!isActiveAccount(account)) return
        Log.i(TAG, "conversationReady($conversationId)")
        // Conversation readiness can publish/change the contact's canonical route. Rebuild routing and notify Dart;
        // Dart starts the folder load so it can correlate the returned load ID before accepting the snapshot.
        worker.execute(DaemonOperation.CONVERSATION_READY) {
            refreshRoutingSnapshot(account)
        }
    }

    // Jami auto-clones a trusted contact's one-to-one request before this callback. Group invitations still arrive
    // here even when sent by an existing friend, so every callback is an explicit user decision.
    internal data class PendingConnect(
        val accountId: String,
        val from: String,
        val isGroup: Boolean,
        /** Unverified 1:1 request vCard FN; Dart strips controls/bidi and caps it before display. */
        val name: String = "",
    )
    private data class RejectedConnect(val accountId: String, val conversationId: String)
    private val pendingConnectLock = Any()
    private val pendingConnect = java.util.concurrent.ConcurrentHashMap<String, PendingConnect>()
    private val pendingConnectGate = PendingRequestGate()
    private val rejectedConnectQueue = ArrayDeque<RejectedConnect>()
    private val rejectedConnectKeys = HashSet<RejectedConnect>()
    private val rejectedConnectRescanAccounts = LinkedHashSet<String>()
    private val rejectedConnectRescanFailures = HashMap<String, Int>()
    private val rejectedConnectTombstones = LinkedHashSet<RejectedConnect>()
    private var rejectedConnectDrainScheduled = false
    private const val MAX_REJECTED_CONNECT_QUEUE = 64
    private const val MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS = 16
    private const val MAX_REJECTED_CONNECT_RESCAN_RETRIES = 3
    private const val MAX_REJECTED_CONNECT_TOMBSTONES = 128

    private fun rememberRejectedConnect(request: RejectedConnect) {
        synchronized(pendingConnectLock) {
            rejectedConnectTombstones += request
            while (rejectedConnectTombstones.size > MAX_REJECTED_CONNECT_TOMBSTONES) {
                rejectedConnectTombstones.remove(rejectedConnectTombstones.first())
            }
        }
    }

    private fun declineUnadmittedRequest(account: String, conversationId: String) {
        if (account.isEmpty() || conversationId.isEmpty() ||
            conversationId.length > TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS
        ) return
        val request = RejectedConnect(account, conversationId)
        synchronized(pendingConnectLock) {
            if (request in rejectedConnectTombstones) {
                return
            } else if (request in rejectedConnectKeys) {
                // A previous drain may have failed after this exact request was queued. Leave it in place and
                // re-arm the worker below if that failure made the drain idle.
            } else if (rejectedConnectQueue.size >= MAX_REJECTED_CONNECT_QUEUE) {
                if (rejectedConnectRescanAccounts.size < MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS) {
                    rejectedConnectRescanAccounts += account
                }
            } else {
                rejectedConnectKeys += request
                rejectedConnectQueue += request
            }
        }
        scheduleRejectedConnectDrain()
    }

    private fun scheduleRejectedConnectDrain() {
        val schedule = synchronized(pendingConnectLock) {
            if (rejectedConnectDrainScheduled ||
                (rejectedConnectQueue.isEmpty() && rejectedConnectRescanAccounts.isEmpty())
            ) {
                false
            } else {
                rejectedConnectDrainScheduled = true
                true
            }
        }
        if (!schedule) return
        try {
            worker.execute(DaemonOperation.DECLINE_CONNECT) {
                try {
                    drainRejectedConnects()
                } catch (e: Throwable) {
                    synchronized(pendingConnectLock) {
                        rejectedConnectDrainScheduled = false
                    }
                    Log.e(TAG, "drain unadmitted conversation requests", e)
                }
            }
        } catch (e: Throwable) {
            synchronized(pendingConnectLock) {
                rejectedConnectDrainScheduled = false
            }
            Log.e(TAG, "queue unadmitted conversation decline", e)
        }
    }

    private fun drainRejectedConnects() {
        while (true) {
            var rescanAccount: String? = null
            val next = synchronized(pendingConnectLock) {
                if (rejectedConnectQueue.isEmpty()) {
                    rescanAccount = rejectedConnectRescanAccounts.firstOrNull()
                    if (rescanAccount == null) rejectedConnectDrainScheduled = false
                    null
                } else {
                    rejectedConnectQueue.removeFirst()
                }
            }
            if (next == null) {
                val owner = rescanAccount ?: return
                var complete = true
                try {
                    val requests = JamiService.getConversationRequests(owner)
                    for (index in 0 until requests.size) {
                        val conversationId = requests.get(index).toNative()["id"].orEmpty()
                        if (!TimelineWireBounds.required(
                                conversationId,
                                TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
                            )) {
                            complete = false
                            continue
                        }
                        val admitted = synchronized(pendingConnectLock) {
                            pendingConnect[conversationId]?.accountId == owner ||
                                (accountId == owner && pendingConnectGate.contains(conversationId))
                        }
                        if (admitted) continue
                        try {
                            JamiService.declineConversationRequest(owner, conversationId)
                            rememberRejectedConnect(RejectedConnect(owner, conversationId))
                        } catch (e: Throwable) {
                            complete = false
                            Log.e(TAG, "decline rescanned conversation request", e)
                        }
                    }
                } catch (e: Throwable) {
                    complete = false
                    Log.e(TAG, "rescan unadmitted conversation requests", e)
                }
                val retry = synchronized(pendingConnectLock) {
                    if (complete) {
                        rejectedConnectRescanAccounts.remove(owner)
                        rejectedConnectRescanFailures.remove(owner)
                        false
                    } else {
                        val failures = (rejectedConnectRescanFailures[owner] ?: 0) + 1
                        rejectedConnectRescanFailures[owner] = failures
                        rejectedConnectDrainScheduled = false
                        failures <= MAX_REJECTED_CONNECT_RESCAN_RETRIES
                    }
                }
                if (!complete) {
                    if (retry) {
                        main.postDelayed(::scheduleRejectedConnectDrain, 250L)
                    }
                    return
                }
                continue
            }
            try {
                JamiService.declineConversationRequest(next.accountId, next.conversationId)
                synchronized(pendingConnectLock) { rejectedConnectKeys.remove(next) }
                rememberRejectedConnect(next)
            } catch (e: Throwable) {
                synchronized(pendingConnectLock) {
                    rejectedConnectKeys.remove(next)
                    if (rejectedConnectRescanAccounts.size < MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS) {
                        rejectedConnectRescanAccounts += next.accountId
                    }
                }
                Log.e(TAG, "decline unadmitted conversation request", e)
            }
        }
    }

    internal fun onConversationRequest(
        account: String,
        conversationId: String,
        fromValue: String,
        modeValue: String,
        title: String = "",
    ) {
        val from = bareJamiId(fromValue)
        val validConversation = TimelineWireBounds.required(
            conversationId,
            TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS,
        )
        val mode = modeValue.singleOrNull()?.takeIf { it in '0'..'3' }?.let { it - '0' }
        if (!validConversation || from.isEmpty() || mode == null) {
            declineUnadmittedRequest(account, conversationId)
            return
        }
        val isGroup = mode != 0
        // The daemon's projection of the request vCard FN: a peer claim, forwarded only for 1:1 and only when
        // it is valid bounded UTF-8.
        val name = if (isGroup) "" else ProfileWireBounds.displayName(title).orEmpty()
        val admission = synchronized(pendingConnectLock) {
            if (!isActiveAccount(account) ||
                RejectedConnect(account, conversationId) in rejectedConnectTombstones ||
                account in rejectedConnectRescanAccounts
            ) return@synchronized PendingRequestAdmission.REJECTED
            pendingConnectGate.admit(conversationId, monotonicMs()).also {
                if (it == PendingRequestAdmission.NEW) {
                    pendingConnect[conversationId] = PendingConnect(account, from, isGroup, name)
                }
            }
        }
        if (admission == PendingRequestAdmission.REJECTED) {
            declineUnadmittedRequest(account, conversationId)
            return
        }
        if (admission == PendingRequestAdmission.DUPLICATE) return
        Log.i(TAG, "conversationRequest($conversationId) from=$from group=$isGroup -> gate")
        emit(mapOf("type" to "connectRequest", "accountId" to account,
            "conversationId" to conversationId, "fromJamiId" to from,
            "isGroup" to isGroup, "name" to name))
    }

    /** Remove + return the pending requester uri for [conversationId], SYNCHRONOUSLY (called on the main thread by
     *  MainActivity BEFORE the daemon op is queued on the worker) so a racing SetEventSink replay can't re-surface a
     *  request that's already being accepted/declined — the ghost-card race the Windows bridge erases against too.
     *  ConcurrentHashMap.remove is thread-safe. */
    internal fun takePending(conversationId: String): PendingConnect? {
        return synchronized(pendingConnectLock) {
            val pending = pendingConnect[conversationId] ?: return@synchronized null
            if (!isActiveAccount(pending.accountId) || !pendingConnect.remove(conversationId, pending)) {
                return@synchronized null
            }
            // Keep the gate slot reserved while the daemon decision is in flight. A failure can then restore the
            // card without racing a newly admitted request for the last bounded slot.
            pending
        }
    }

    /** Put a request back when its worker command failed, so EventChannel replay and a Dart retry stay coherent. */
    internal fun restorePending(
        conversationId: String,
        pending: PendingConnect,
    ) {
        val restored = synchronized(pendingConnectLock) {
            isActiveAccount(pending.accountId) && pendingConnectGate.restore(conversationId) &&
                pendingConnect.putIfAbsent(conversationId, pending) == null
        }
        if (!restored) declineUnadmittedRequest(pending.accountId, conversationId)
    }

    /** Accept a gated request. Friend requests add contact trust; group invitations only join the group.
     *  [from] = the requester uri, already removed from pendingConnect by the caller (sync, on the main thread). */
    fun acceptConnect(account: String, conversationId: String, from: String?, isGroup: Boolean = false) {
        check(isActiveAccount(account)) { "Connection request changed account" }
        val acc = account
        Log.i(TAG, "acceptConnect($conversationId) from=$from")
        if (!isGroup && !from.isNullOrEmpty()) {
            // No addContact: acceptConversationRequest already confirms the trust request and clones the peer's
            // conversation. addContact ran first would find no 1:1 conversation yet and start a second, empty one.
            JamiService.subscribeBuddy(acc, from, true)
        }
        // Keep the primary accept last: once it returns the request no longer exists and must never be restored
        // merely because later bookkeeping/logging failed.
        JamiService.acceptConversationRequest(acc, conversationId)
        synchronized(pendingConnectLock) { pendingConnectGate.remove(conversationId) }
        try { refreshRoutingSnapshot(acc) } catch (e: Throwable) {
            Log.e(TAG, "refresh routing after accept", e)
        }
    }

    /** Decline a gated request. Only friend requests have a corresponding trust request to discard.
     *  [from] = the requester uri (resolved + removed from pendingConnect by the caller, sync, on the main thread). */
    fun declineConnect(account: String, conversationId: String, from: String, isGroup: Boolean = false) {
        check(isActiveAccount(account)) { "Connection request changed account" }
        val acc = account
        val bare = from.removePrefix("jami:").substringBefore("@")
        Log.i(TAG, "declineConnect($conversationId) from=$bare")
        // Everything after this primary decision is best-effort; a completed decline cannot be retried/restored.
        JamiService.declineConversationRequest(acc, conversationId)
        synchronized(pendingConnectLock) { pendingConnectGate.remove(conversationId) }
        // The request is already declined at this point. Trust cleanup is best-effort: reporting failure would
        // restore a Dart/native card for a conversation request that no longer exists.
        if (!isGroup && bare.isNotEmpty()) try {
            JamiService.discardTrustRequest(acc, bare)
        } catch (e: Throwable) {
            Log.e(TAG, "discardTrustRequest", e)
        }
    }

    /** Remove (ban=true → BLOCK) a contact — the remove/block control. Block also bans future trust requests. */
    fun removeContact(uri: String, ban: Boolean): Boolean {
        val acc = accountId ?: return false
        val bare = bareJamiId(uri)
        if (bare.isEmpty()) return false
        Log.i(TAG, "removeContact($uri) ban=$ban")
        // Unsubscription is cleanup; it must never prevent the primary
        // remove/block mutation from being attempted.
        try {
            JamiService.subscribeBuddy(acc, bare, false)
            subscribedPeers.remove(bare)
        } catch (e: Throwable) {
            Log.e(TAG, "unsubscribe before removeContact", e)
        }
        try {
            JamiService.removeContact(acc, bare, ban)
        } catch (e: Throwable) {
            Log.e(TAG, "removeContact", e)
            return false
        }
        val controlRetired = retireControlTrust(acc, bare)
        refreshRoutingSnapshot(acc, forceEvent = true)
        return !routingSnapshot.isTrusted(bare) && controlRetired
    }

    // ---- identity backup / restore (M7.5 a) ----

    /** Export the identity to a temp cache file, password-protected when [passphrase] is non-empty; returns its path (null on
     *  failure). The daemon reads one serialized snapshot with the device-bound working secret and atomically writes
     *  only the destination with [passphrase]; the live archive is never re-keyed. MainActivity then copies this temp
     *  file to the user-chosen SAF document and deletes it. Worker thread. */
    internal fun exportToTempFile(passphrase: String, settingsDocument: String, scope: NativeAccountScope?): String? {
        if (!accountAuthority.owns(scope)) return null
        val acc = scope?.accountId ?: return null
        if (passphrase.length > MAX_ARCHIVE_PASSPHRASE_CHARS ||
            settingsDocument.toByteArray(Charsets.UTF_8).size > MAX_SETTINGS_DOCUMENT_BYTES ||
            archiveRecoveryBlocked ||
            !archiveProtectionReady
        ) return null
        val backupDocument = try { BackupSettingsOwner.stamp(settingsDocument, acc) }
            catch (_: Exception) { return null }
        val current = archiveSecret
        val previousDetails = try {
            JamiService.getAccountDetails(acc).toNative()
        } catch (e: Throwable) {
            Log.e(TAG, "read UI customization for backup", e)
            return null
        }
        val exportDetails = previousDetails.toMutableMap()
        exportDetails["Account.uiCustomization"] = backupDocument
        return try {
            exportTemporaryArchiveSnapshot(File(appContext.cacheDir, "backup")) { dest ->
                exportWithRestoredAccountDetails(previousDetails, exportDetails,
                    setDetails = { JamiService.setAccountDetails(acc, StringMap.toSwig(it)) },
                    export = {
                        exportArchiveSnapshot(acc, dest.absolutePath, current, passphrase) {
                                account, path, inputScheme, inputPassword, outputScheme, outputPassword ->
                            JamiService.exportToFileWithCredentials(
                                account, path, inputScheme, inputPassword, outputScheme, outputPassword,
                            )
                        }
                    },
                )
            }?.absolutePath
        } catch (e: Throwable) {
            Log.e(TAG, "identity snapshot export failed", e)
            null
        }
    }

    private class PairingEntry(val owner: NativeAccountScope, val flow: DevicePairingFlow, val epoch: Long) {
        @Volatile var admitting = true
        var cancelIssued = false // Serial daemon worker only.
    }
    @Volatile private var pairingEntry: PairingEntry? = null
    private val pairingVisits = DevicePairingVisits()

    /** URI/code material exists only in the one live visit, never in a journal. */
    internal fun retireDevicePairing() {
        pairingVisits.retireAll()
        val entry = pairingEntry ?: return
        entry.flow.retire() // Hide private material before a queued callback can reach Flutter.
        worker.execute(DaemonOperation.PAIR_DEVICE) {
            if (pairingEntry === entry) cancelPairingEntry(entry)
        }
    }

    private fun cancelPairingEntry(entry: PairingEntry) {
        if (entry.flow.terminal) {
            if (entry.flow.retired && !entry.flow.destination && pairingEntry === entry) pairingEntry = null
            return
        }
        val operation = entry.flow.operation
        if (operation == 0L || entry.cancelIssued) return
        entry.cancelIssued = true
        // A cancellation request is not a completion acknowledgement. Keep the
        // bounded native lease until DONE, or until this exact candidate is removed.
        try { JamiService.cancelAddDevice(entry.flow.account, operation) } catch (_: Throwable) { }
    }

    private fun pairingForeground(): Boolean = activityResumed &&
        appContext.getSystemService(android.app.KeyguardManager::class.java)?.isDeviceLocked == false

    private fun savePairingRecord(record: IdentityRestoreRecord): Boolean {
        if (record.pairingOperation == null || !IdentityRestoreJournal.save(appContext, record) ||
            IdentityRestoreJournal.load(appContext) != record) return false
        pendingIdentityRestore = record
        return true
    }

    private fun pairingRecovery(record: IdentityRestoreRecord): Map<String, Any?> = mapOf(
        "flowToken" to record.token, "accountId" to record.accountId, "role" to "destination",
        "ownerAccountId" to accountId.orEmpty(),
        "operation" to (record.pairingOperation ?: 0L), "status" to "unconfirmed",
        "terminal" to false, "recovery" to true,
        "uri" to "", "code" to "", "peerId" to "", "peerDeviceId" to "", "deviceId" to "",
        "invalidCode" to false, "error" to "",
    )

    private fun pairingProjection(entry: PairingEntry): Map<String, Any?> {
        val value = entry.flow.projection().toMutableMap<String, Any?>()
        value["ownerAccountId"] = entry.owner.accountId.orEmpty()
        val record = pendingIdentityRestore
        if (entry.flow.destination && record?.token == entry.flow.token) {
            value["recovery"] = entry.flow.retired || entry.flow.terminal && !record.pairingAcknowledged
            if (entry.flow.status == "ready" && !entry.flow.retired && record.pairingAcknowledged) {
                value["preparedIdentity"] = pendingRestoreResult(record)
            }
        }
        return value
    }

    internal fun devicePairingCommand(
        action: String, token: String, targetAccount: String, uri: String, code: String,
        document: String, network: Map<String, String>, appearOffline: Boolean,
        scope: NativeAccountScope?, reply: (Map<String, Any?>) -> Unit,
    ) {
        val visitEpoch = pairingVisits.capture()
        val captured = pairingEntry
        if (action == "retire" && accountAuthority.owns(scope)) pairingVisits.retire(token)
        if (action == "retire" && captured?.flow?.token == token &&
            (targetAccount.isEmpty() || captured.flow.account == targetAccount) && accountAuthority.owns(scope)) captured.flow.retire()
        worker.execute(DaemonOperation.PAIR_DEVICE) {
            val unavailable = mapOf<String, Any?>("status" to "unavailable")
            var replyEntry: PairingEntry? = null
            val result = try {
                if (!accountAuthority.owns(scope)) unavailable
                else if (action == "begin" || action == "connect") {
                    val entry = beginDevicePairing(action == "begin", token, visitEpoch, uri, network, appearOffline, scope!!)
                    replyEntry = entry
                    entry?.let(::pairingProjection) ?: unavailable
                } else {
                    val entry = pairingEntry?.takeIf {
                        it.flow.token == token && (it.flow.account == targetAccount ||
                            targetAccount.isEmpty() && action in setOf("read", "retire")) && accountAuthority.owns(it.owner)
                    }
                    replyEntry = entry
                    val record = pendingIdentityRestore?.takeIf {
                        it.pairingOperation != null && it.token == token && it.accountId == targetAccount
                    }
                    when {
                        action == "discard" && record != null -> discardDevicePairing(record, entry)
                        action == "read" && entry == null && record != null -> pairingRecovery(record)
                        entry == null -> unavailable
                        action == "retire" -> { entry.flow.retire(); cancelPairingEntry(entry); pairingProjection(entry) }
                        action == "read" -> pairingProjection(entry)
                        !pairingForeground() || entry.flow.retired || identityRestoreRecoveryFailed -> unavailable
                        action == "approve" && !entry.flow.destination && entry.flow.status == "consent" &&
                            isActiveAccount(entry.flow.account) -> {
                            val issued = JamiService.confirmAddDeviceWithCode(
                                entry.flow.account, entry.flow.operation, archiveSecret)
                            if (!entry.flow.issuedCode(issued)) entry.flow.unconfirmed()
                            pairingProjection(entry)
                        }
                        action == "code" && entry.flow.destination && DevicePairingFlow.validCode(code) &&
                            entry.flow.submittingCode() -> {
                            if (!JamiService.provideAccountAuthentication(entry.flow.account, code, "doorlight-code-v1"))
                                entry.flow.unconfirmed()
                            pairingProjection(entry)
                        }
                        action == "prepare" && entry.flow.destination -> {
                            if (!prepareDevicePairingPrivacy(entry, document)) entry.flow.unconfirmed()
                            pairingProjection(entry)
                        }
                        else -> unavailable
                    }
                }
            } catch (_: Throwable) {
                // Never log the call arguments or retry an uncertain admission,
                // publication, code issuance, proof, or canonical write.
                replyEntry?.flow?.unconfirmed()
                replyEntry?.flow?.projection() ?: mapOf("status" to "unconfirmed")
            }
            main.post {
                val entry = replyEntry
                reply(when {
                    !accountAuthority.owns(scope) -> unavailable
                    entry != null && (!pairingVisits.allows(entry.flow.token, entry.epoch) || entry.flow.retired) &&
                        result["status"] != "discarded" -> mapOf("status" to "retired")
                    !pairingForeground() && result["status"] != "discarded" -> unavailable
                    else -> result
                })
            }
        }
    }

    private fun beginDevicePairing(destination: Boolean, token: String, epoch: Long, uri: String, network: Map<String, String>,
                                   appearOffline: Boolean, owner: NativeAccountScope): PairingEntry? {
        if ((destination && !owner.accountId.isNullOrEmpty()) ||
            !started || !pairingForeground() || !pairingVisits.allows(token, epoch) || identityRestoreRecoveryFailed ||
            archiveRecoveryBlocked || !archiveProtectionReady ||
            !accountAuthority.owns(owner) || network.values.any { it.length > 4096 }) return null
        pairingEntry?.let {
            if (it.flow.token == token && it.flow.destination == destination && accountAuthority.owns(it.owner)) return it
            if (!it.flow.terminal) return null else pairingEntry = null
        }
        if (pendingIdentityRestore != null) return null
        if (!destination) {
            val account = owner.accountId ?: return null
            if (!isActiveAccount(account) || !DevicePairingFlow.validOffer(uri) ||
                JamiService.getAccountDetails(account).toNative()["Account.enable"] != "true") return null
            val entry = PairingEntry(owner, DevicePairingFlow(token, account, false), epoch)
            pairingEntry = entry
            try {
                val operation = JamiService.addDevice(account, uri).toLong()
                if (!entry.flow.bindOperation(operation)) entry.flow.unconfirmed()
            } catch (_: Throwable) { entry.flow.unconfirmed() }
            finally { entry.admitting = false }
            return entry
        }
        val accounts = JamiService.getAccountList()
        val previous = (0 until accounts.size).map { accounts.get(it) }.toSet()
        val reserved = java.util.UUID.randomUUID().toString().replace("-", "")
        if (reserved in previous) return null
        val policy = mutableMapOf(
            "Account.type" to "RING", "Account.enable" to "false", "Account.proxyEnabled" to "true",
            DENY_SECOND_CALL_KEY to "true", "DHT.PublicInCalls" to "false",
            "Account.peerDiscovery" to "false", "Account.accountDiscovery" to "false",
            "Account.accountPublish" to "false", "Account.uiCustomization" to "",
        )
        applyConnectionProfile(policy, network["connectionProfile"].orEmpty().takeIf {
            it in setOf("jami", "lan", "strict") } ?: "jami", network["dhtBootstrap"].orEmpty(),
            network["turnServer"].orEmpty(), network["turnRealm"].orEmpty(),
            network["turnUser"].orEmpty(), network["turnPassword"].orEmpty())
        val record = IdentityRestoreRecord(token, reserved,
            owner.accountId.orEmpty(), previous, appearOffline, policy.toMap(), "", pairingOperation = 0L)
        synchronized(callLifecycleLock) {
            if (activeCallId != null || activeGroupConferenceId != null || pendingGroupConferenceId != null ||
                reservedCallPeerId != null || placingOutgoing) return null
            pendingIdentityRestore = record // Retire racing notification/call admission first.
        }
        if (!stopRecorderBeforeCall()) { pendingIdentityRestore = null; return null }
        pendingIdentityRestoreOwner = owner
        if (!savePairingRecord(record)) { identityRestoreRecoveryFailed = true; return null }
        val entry = PairingEntry(owner, DevicePairingFlow(record.token, reserved, true), epoch)
        pairingEntry = entry
        try {
            val details = policy + mapOf("Account.archiveURL" to "jami-auth",
                "Account.archivePassword" to archiveSecret, "Account.deviceName" to android.os.Build.MODEL)
            // This overload is generated from the same native candidate. The
            // exact ID is durable before libjami can create any identity data.
            if (JamiService.addAccount(StringMap.toSwig(details), reserved) != reserved) entry.flow.unconfirmed()
        } catch (_: Throwable) { entry.flow.unconfirmed() }
        finally { entry.admitting = false }
        return entry
    }

    private fun prepareDevicePairingPrivacy(entry: PairingEntry, document: String): Boolean {
        val record = pendingIdentityRestore ?: return false
        val projection = entry.flow.projection()
        if (entry.flow.status != "prepared" || entry.flow.retired || record.token != entry.flow.token ||
            record.accountId != entry.flow.account || record.pairingOperation != entry.flow.operation ||
            record.pairingAcknowledged || !accountAuthority.owns(entry.owner) ||
            !pairingVisits.allows(entry.flow.token, entry.epoch) ||
            !accountAuthority.owns(pendingIdentityRestoreOwner) ||
            incomingMicrophoneSettings.currentDocument() != document) return false
        disablePendingRestoredAccount(record.accountId)
        val details = JamiService.getAccountDetails(record.accountId).toNative()
        val volatile = JamiService.getVolatileAccountDetails(record.accountId).toNative()
        if (bareJamiId(details["Account.username"].orEmpty()) != projection["peerId"] ||
            volatile["Account.deviceID"] != projection["deviceId"] ||
            details["Account.archiveHasPassword"] != "true" ||
            !JamiService.isPasswordValid(record.accountId, archiveSecret)) return false
        val local = details.toMutableMap().apply { putAll(record.accountPolicy); put("Account.enable", "false") }
        JamiService.setAccountDetails(record.accountId, StringMap.toSwig(local))
        disablePendingRestoredAccount(record.accountId)
        val localLock = restoredLocalAppLock()
        return commitRestoredPrivacy(document, localLock, incomingMicrophoneSettings.prepareSave(document),
            { show, lock -> MessageNotifications.setPolicy(appContext, show, lock) &&
                MessageNotifications.retireRestoredAccountNotifications(appContext) }) {
            incomingMicrophoneSettings.withCurrentDocument(document) {
                if (restoredLocalAppLock() != localLock || entry.flow.retired ||
                    !pairingForeground() || !accountAuthority.owns(entry.owner)) return@withCurrentDocument false
                val prepared = record.copy(normalizedDocument = document, settingsAlreadyNormalized = true)
                if (!savePairingRecord(prepared) || !entry.flow.preparedPrivacy()) return@withCurrentDocument false
                // This sends the prepared-device proof only. Account.enable stays
                // false until DONE is durably recorded and Dart finalizes adoption.
                JamiService.completeDeviceLinkPreparation(record.accountId, entry.flow.operation)
            } ?: false
        }
    }

    private fun discardDevicePairing(record: IdentityRestoreRecord, entry: PairingEntry?): Map<String, Any?> {
        // Explicit UI cancellation owns only this newly reserved, unactivated
        // local candidate. Existing independent identities and signer data remain.
        if (record.pairingOperation == null || record.accountId in record.previousAccounts ||
            accountId == record.accountId || !accountAuthority.owns(pendingIdentityRestoreOwner))
            return mapOf("status" to "unavailable")
        val sealed = IdentityRestoreJournal.load(appContext)
        if (sealed?.token != record.token || sealed.accountId != record.accountId) return mapOf("status" to "unconfirmed")
        entry?.flow?.retire()
        if (entry != null) cancelPairingEntry(entry)
        if (JamiService.getAccountList().contains(record.accountId)) {
            disablePendingRestoredAccount(record.accountId)
            JamiService.removeAccount(record.accountId)
        }
        if (JamiService.getAccountList().contains(record.accountId) || !IdentityRestoreJournal.clear(appContext) ||
            IdentityRestoreJournal.load(appContext) != null) return mapOf("status" to "unconfirmed")
        pendingIdentityRestore = null
        pendingIdentityRestoreOwner = null
        identityRestoreRecoveryFailed = false
        if (pairingEntry === entry) pairingEntry = null
        accountId?.let(::activatePreparedAccount)
        return mapOf("status" to "discarded", "flowToken" to record.token, "accountId" to record.accountId,
            "peerOutcome" to "unconfirmed")
    }

    private fun onDevicePairingSignal(account: String, sourceOperation: Long?, state: Int,
                                      details: StringMap, destination: Boolean) {
        val entry = pairingEntry ?: return
        if (entry.flow.account != account || entry.flow.destination != destination || state !in 1..5 || details.size > 12) return
        val copied = details.toNative().filterKeys { it in setOf("token", "operation", "auth_scheme", "auth_error",
            "prepared", "error", "peer_id", "peer_device", "device_id") }
        if (copied.values.any { it.length > 128 }) return
        val operation = sourceOperation ?: copied[if (state == 1) "operation" else "token"]?.toLongOrNull() ?: return
        val admittedCallback = entry.admitting
        worker.execute(DaemonOperation.PAIR_DEVICE) {
            if (pairingEntry !== entry) return@execute
            try {
                if (entry.flow.operation == 0L) {
                    if (!destination && !admittedCallback) return@execute
                    if (!entry.flow.bindOperation(operation)) return@execute
                    if (destination) {
                        val record = pendingIdentityRestore
                        if (record?.token != entry.flow.token || record.accountId != account ||
                            !savePairingRecord(record.copy(pairingOperation = operation))) {
                            identityRestoreRecoveryFailed = true
                            entry.flow.retire(); cancelPairingEntry(entry)
                            return@execute
                        }
                    }
                }
                if (!accountAuthority.owns(entry.owner) || !pairingForeground() ||
                    !pairingVisits.allows(entry.flow.token, entry.epoch)) entry.flow.retire()
                if (!entry.flow.accept(operation, state, copied)) {
                    if (entry.flow.retired) cancelPairingEntry(entry)
                    return@execute
                }
                if (state == 5 && destination && entry.flow.nativeSucceeded && entry.flow.privacyCommitted && !entry.flow.retired) {
                    val record = pendingIdentityRestore
                    if (record?.token == entry.flow.token && record.accountId == account &&
                        record.pairingOperation == operation && record.normalizedDocument.isNotEmpty() &&
                        savePairingRecord(record.copy(phase = "prepared", pairingAcknowledged = true))) {
                        check(entry.flow.acknowledgedDurably())
                    } else {
                        identityRestoreRecoveryFailed = true
                        entry.flow.unconfirmed()
                    }
                }
                if (entry.flow.retired) cancelPairingEntry(entry)
            } catch (_: Throwable) {
                entry.flow.unconfirmed()
                if (destination) identityRestoreRecoveryFailed = true
            }
        }
    }

    /** Worker-only. The sealed journal, never a UI-supplied ID, owns all cleanup. */
    private fun completeArchiveRestoreRollback(record: IdentityRestoreRecord): Boolean = try {
        val sealed = IdentityRestoreJournal.load(appContext)
        if (sealed != record || !canDiscardArchiveRestore(record, accountId)) false
        else {
            rollbackArchiveRestore(record, accountId,
                saveRollback = { rollback ->
                    if (!IdentityRestoreJournal.save(appContext, rollback) ||
                        IdentityRestoreJournal.load(appContext) != rollback) false
                    else { pendingIdentityRestore = rollback; true }
                },
                removeCandidate = {
                    val rekey = ArchiveRecoveryJournal.load(appContext)
                    check(rekey == null || rekey.accountId == record.accountId) { "Restore rekey ownership is unresolved" }
                    val accounts = JamiService.getAccountList()
                    check((0 until accounts.size).all {
                        accounts.get(it) == record.accountId || accounts.get(it) in record.previousAccounts
                    }) { "Restore cleanup met an unexplained account" }
                    if (JamiService.getAccountList().contains(record.accountId)) {
                        disablePendingRestoredAccount(record.accountId)
                        JamiService.removeAccount(record.accountId)
                    }
                    !JamiService.getAccountList().contains(record.accountId) && listOf("files", "cache").all {
                        !java.nio.file.Files.exists(File(File(appContext.filesDir, it), record.accountId).toPath(),
                            java.nio.file.LinkOption.NOFOLLOW_LINKS)
                    }
                },
                clearJournals = {
                    ArchiveRecoveryJournal.clear(appContext) && ArchiveRecoveryJournal.load(appContext) == null &&
                        IdentityRestoreJournal.clear(appContext) && IdentityRestoreJournal.load(appContext) == null
                },
            ).also { cleared ->
                if (cleared) {
                    pendingIdentityRestore = null
                    pendingIdentityRestoreOwner = null
                    identityRestoreRecoveryFailed = false
                    archiveRecoveryBlocked = false
                }
            }
        }
    } catch (error: Throwable) {
        Log.e(TAG, "restore cleanup remains unresolved", error)
        false
    }

    /** Worker-only, with the account lifetime captured before the channel operation was queued. */
    internal fun discardIdentityRestore(restoredAccountId: String, token: String, scope: NativeAccountScope?): Boolean {
        if (!daemonStartSucceeded || !accountAuthority.owns(scope) || identityRestoreCommitting) return false
        val record = try { IdentityRestoreJournal.load(appContext) } catch (_: Throwable) { return false }
            ?: return false
        if (record.accountId != restoredAccountId || record.token != token ||
            !canDiscardArchiveRestore(record, accountId)) return false
        synchronized(callLifecycleLock) {
            if (activeCallId != null || activeGroupConferenceId != null || pendingGroupConferenceId != null ||
                reservedCallPeerId != null || placingOutgoing) return false
            identityRestoreCommitting = true
        }
        val cleared = try {
            stopRecorderBeforeCall() && completeArchiveRestoreRollback(record)
        } finally { identityRestoreCommitting = false }
        if (cleared) {
            archiveProtectionReady = initializeArchiveProtection(JamiService.getAccountList())
            if (!started) start() else accountId?.let(::activatePreparedAccount)
        }
        return cleared
    }

    private fun discardFailedRestore(id: String, previousAccount: String?) {
        val record = pendingIdentityRestore?.takeIf {
            it.accountId == id && it.previousAccountId == previousAccount.orEmpty()
        } ?: return
        if (!completeArchiveRestoreRollback(record)) {
            archiveRecoveryBlocked = true
            archiveProtectionReady = false
        }
    }

    /** Restore an identity from an exported backup file via addAccount{archivePath, archivePassword} → the daemon
     *  re-imports the archive's master keypair → IDENTICAL 40-hex. Returns {accountId, jamiId, displayName}; an
     *  empty jamiId means the passphrase/file was wrong (the broken account is removed). Worker thread. */
    internal fun restoreAccount(
        filePath: String,
        passphrase: String,
        connectionProfile: String,
        dhtBootstrap: String,
        turnServer: String,
        turnRealm: String,
        turnUser: String,
        turnPassword: String,
        appearOffline: Boolean,
        expectedJamiId: String,
        scope: NativeAccountScope?,
    ): Map<String, Any?> {
        val fail = mapOf("status" to "error", "accountId" to "", "jamiId" to "", "displayName" to "")
        if (!accountAuthority.owns(scope)) return fail
        if (pendingIdentityRestore != null) return getPendingIdentityRestore()
        if (filePath.isEmpty() ||
            expectedJamiId.isEmpty() ||
            bareJamiId(expectedJamiId) != expectedJamiId ||
            passphrase.length > MAX_ARCHIVE_PASSPHRASE_CHARS ||
            !started ||
            archiveRecoveryBlocked ||
            !archiveProtectionReady
        ) return fail
        val localPolicy = mutableMapOf(
            "Account.type" to "RING",
            // Keep import dark until the archive has authenticated and this
            // installation's complete policy has been re-applied below.
            "Account.enable" to "false",
            // Mirror createAccount's reachability/privacy pins — restore IS the fresh-install path, so the restored
            // identity must boot reachable (DHT proxy ON → reachable while backgrounded) with the LAN-broadcast /
            // public-call leaks OFF, exactly like a freshly-onboarded one. Without proxyEnabled the daemon default
            // (proxy OFF) leaves it unreachable in the background — the precise lost-phone case this feature exists for.
            "Account.proxyEnabled" to "true",
            DENY_SECOND_CALL_KEY to "true",
            "DHT.PublicInCalls" to "false",
            "Account.peerDiscovery" to "false",
            "Account.accountDiscovery" to "false",
            "Account.accountPublish" to "false")
        applyConnectionProfile(localPolicy,
            connectionProfile.takeIf { it == "lan" || it == "jami" || it == "strict" } ?: "jami",
            dhtBootstrap, turnServer, turnRealm, turnUser, turnPassword)
        val previousAccount = accountId
        // The exact ID is reserved and durable before libjami can create any identity data; an unbound
        // journal is never written, so boot never has to infer ownership from the account list.
        val details = StringMap.toSwig(localPolicy + mapOf(
            "Account.archivePath" to filePath, "Account.archivePassword" to passphrase,
        ))
        val imported = runReservedRestoreImport(
            listAccounts = {
                val accounts = JamiService.getAccountList()
                (0 until accounts.size).map { accounts.get(it) }.toSet()
            },
            newId = { java.util.UUID.randomUUID().toString().replace("-", "") },
            buildRecord = { reserved, previous ->
                IdentityRestoreRecord(
                    java.util.UUID.randomUUID().toString(), reserved, previousAccount.orEmpty(),
                    // The import gate overwrites Account.enable before activation, so
                    // legacy archives cannot prove their original online choice. Keep
                    // archive restores offline until the user explicitly goes online.
                    previous, true, localPolicy.toMap(), passphrase,
                    expectedJamiId = expectedJamiId,
                )
            },
            admit = { candidate ->
                // Admission is retired before persistence/import, including a ring that raced the Dart preflight.
                val admitted = synchronized(callLifecycleLock) {
                    if (activeCallId != null || activeGroupConferenceId != null || pendingGroupConferenceId != null ||
                        reservedCallPeerId != null || placingOutgoing) false
                    else { pendingIdentityRestore = candidate; true }
                }
                if (admitted && !stopRecorderBeforeCall()) { pendingIdentityRestore = null; false } else admitted
            },
            saveJournal = { IdentityRestoreJournal.save(appContext, it) },
            nativeImport = { reserved -> JamiService.addAccount(details, reserved) },
        )
        when (imported) {
            is RestoreImportOutcome.NothingCreated -> return fail
            is RestoreImportOutcome.JournalNotSaved -> {
                if (IdentityRestoreJournal.clear(appContext)) pendingIdentityRestore = null
                return fail
            }
            is RestoreImportOutcome.ImportRejected -> {
                pendingIdentityRestoreOwner = scope
                Log.e(TAG, "restoreAccount: import was not admitted under its reserved id")
                identityRestoreRecoveryFailed = true
                return fail
            }
            is RestoreImportOutcome.Imported -> pendingIdentityRestoreOwner = scope
        }
        val bound = imported.record
        val id = bound.accountId
        val current = archiveSecret
        try {
            check(ArchiveRecoveryJournal.save(
                appContext,
                ArchiveRecoveryRecord(id, current, passphrase),
            )) { "recovery journal could not be saved" }
            val jamiId = awaitRestoredUsername(id)
            check(bareJamiId(jamiId) == expectedJamiId) {
                "archive identity does not match the expected Friend ID"
            }
            // The daemon re-saved the imported archive with `passphrase`.
            // Normalize it to this installation's Keystore-sealed device
            // secret. The durable journal resolves an uncertain failure.
            try {
                JamiService.changeAccountPassword(id, passphrase, current)
            } catch (_: Throwable) {
                false
            }
            if (!recoverInterruptedArchiveRekey(JamiService.getAccountList())) {
                error("at-rest normalization remains unresolved")
            }
            completePendingRestorePreparation(bound)
            return pendingRestoreResult(checkNotNull(pendingIdentityRestore))
        } catch (e: Throwable) {
            Log.e(TAG, "restoreAccount failed before commit", e)
            discardFailedRestore(id, previousAccount)
            return fail
        }
    }

    private fun disablePendingRestoredAccount(id: String) {
        check(id.isNotEmpty() && JamiService.getAccountList().contains(id)) { "Restored account is unavailable" }
        val details = JamiService.getAccountDetails(id).toNative().toMutableMap()
        details["Account.enable"] = "false"
        JamiService.setAccountDetails(id, StringMap.toSwig(details))
        JamiService.sendRegister(id, false)
        JamiService.setAccountActive(id, false, false)
        check(preparedIdentityClosed(
            JamiService.getAccountDetails(id).toNative()["Account.enable"],
            JamiService.getVolatileAccountDetails(id).toNative()["Account.active"],
        )) { "Restored account disable and inactivity were not acknowledged" }
    }

    private fun completePendingRestorePreparation(record: IdentityRestoreRecord) {
        check(record.phase != "rollingBack" && pendingIdentityRestore?.phase != "rollingBack") {
            "Restore cleanup must finish before preparation"
        }
        check(record.pairingOperation == null || record.pairingAcknowledged) {
            "Device link acknowledgement remains unresolved"
        }
        check(awaitRestoredUsername(record.accountId).isNotEmpty()) { "Restored identity is unavailable" }
        val details = JamiService.getAccountDetails(record.accountId).toNative().toMutableMap()
        details.putAll(record.accountPolicy)
        details["Account.enable"] = "false"
        JamiService.setAccountDetails(record.accountId, StringMap.toSwig(details))
        disablePendingRestoredAccount(record.accountId)
        val prepared = record.copy(phase = "prepared", transientPassphrase = "",
            settingsAlreadyNormalized = record.settingsAlreadyNormalized ||
                (record.phase == "privacyCommitted" && record.normalizedDocument.isNotEmpty()))
        check(IdentityRestoreJournal.save(appContext, prepared)) { "Prepared restore could not be saved" }
        pendingIdentityRestore = prepared
    }

    private fun pendingRestoreResult(record: IdentityRestoreRecord): Map<String, Any?> {
        val details = JamiService.getAccountDetails(record.accountId).toNative()
        check(preparedIdentityClosed(details["Account.enable"],
            JamiService.getVolatileAccountDetails(record.accountId).toNative()["Account.active"])) {
            "Prepared restore is not disabled and inactive"
        }
        val jamiId = bareJamiId(details["Account.username"].orEmpty())
        check(jamiId.isNotEmpty()) { "Restored identity is unavailable" }
        check(record.pairingOperation != null ||
            (record.expectedJamiId.isNotEmpty() && jamiId == record.expectedJamiId)) {
            "Restored identity does not match the expected Friend ID"
        }
        val document = if (record.settingsAlreadyNormalized) record.normalizedDocument
            else details["Account.uiCustomization"]
                ?.takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_SETTINGS_DOCUMENT_BYTES }.orEmpty()
        return mapOf(
            "status" to "prepared", "restoreToken" to record.token, "accountId" to record.accountId,
            "recoveryOwnerAccountId" to accountId.orEmpty(),
            "canDiscard" to restoreRecoveryResult(record, "preparationFailed")["canDiscard"],
            "jamiId" to jamiId,
            "displayName" to ProfileWireBounds.displayName(details["Account.displayName"].orEmpty()).orEmpty(),
            "avatarBase64" to readPeerProfile(
                File(File(File(appContext.filesDir, "files"), record.accountId), "profile.vcf"),
            )?.avatarBase64.orEmpty(),
            "settingsDocument" to document,
            "settingsAlreadyNormalized" to record.settingsAlreadyNormalized,
            "devicePairing" to (record.pairingOperation != null && record.pairingAcknowledged),
            "pairing" to if (record.pairingOperation != null) pairingRecovery(record) else null,
            "backupSourceAccountId" to if (record.settingsAlreadyNormalized) record.accountId
                else BackupSettingsOwner.read(document),
            "enabled" to false, "announced" to false,
            "registration" to (registrationByAccount[record.accountId] ?: "UNREGISTERED"),
        )
    }

    private fun restoreRecoveryResult(record: IdentityRestoreRecord?, reason: String): Map<String, Any?> {
        val archive = record?.takeIf { it.pairingOperation == null }
        val restartRequired = daemonStartAttempted && !daemonStartSucceeded ||
            daemonInitAttempted && !daemonInitSucceeded
        val rekeyOwned = archive != null && try {
            val rekey = ArchiveRecoveryJournal.load(appContext)
            rekey == null || rekey.accountId == archive.accountId
        } catch (_: Throwable) { false }
        val accountsOwned = archive != null && daemonStartSucceeded && try {
            val accounts = JamiService.getAccountList()
            (0 until accounts.size).all {
                accounts.get(it) == archive.accountId || accounts.get(it) in archive.previousAccounts
            }
        } catch (_: Throwable) { false }
        return mapOf(
            "status" to if (reason == "engineUnavailable") "engineUnavailable" else "recoveryRequired",
            "recoveryReason" to if (reason == "engineUnavailable" && restartRequired) "restartRequired" else reason,
            "accountId" to archive?.accountId.orEmpty(), "restoreToken" to archive?.token.orEmpty(),
            "recoveryOwnerAccountId" to accountId.orEmpty(),
            "canDiscard" to (archive != null && rekeyOwned && accountsOwned && canDiscardArchiveRestore(archive, accountId)),
            "restartRequired" to restartRequired,
        )
    }

    fun getPendingIdentityRestore(): Map<String, Any?> {
        val record = try { IdentityRestoreJournal.load(appContext) }
        catch (error: Throwable) {
            Log.e(TAG, "restore journal could not be read", error)
            return restoreRecoveryResult(null, "journalUnreadable")
        }
        if (record == null) return when {
            pendingIdentityRestore != null || identityRestoreRecoveryFailed ->
                restoreRecoveryResult(null, "ownershipUnclear")
            !started -> restoreRecoveryResult(null, "engineUnavailable")
            else -> mapOf("status" to "none")
        }
        pendingIdentityRestore = record
        if (record.pairingOperation != null && !record.pairingAcknowledged)
            return mapOf("status" to "pairing", "pairing" to pairingRecovery(record))
        if (record.accountId.isEmpty()) return restoreRecoveryResult(record, "ownershipUnclear")
        if (!daemonStartSucceeded) return restoreRecoveryResult(record, "preparationFailed")
        return try {
            if (record.phase == "rollingBack") {
                if (!completeArchiveRestoreRollback(record)) restoreRecoveryResult(record, "rollbackPending")
                else {
                    archiveProtectionReady = initializeArchiveProtection(JamiService.getAccountList())
                    if (!started) start() else accountId?.let(::activatePreparedAccount)
                    mapOf("status" to "none")
                }
            } else if (!started) {
                restoreRecoveryResult(record, if (record.phase == "importing") "importIncomplete" else "preparationFailed")
            } else {
                disablePendingRestoredAccount(record.accountId)
                check(record.pairingOperation != null || record.expectedJamiId.isNotEmpty()) {
                    "Legacy restore needs independent identity confirmation"
                }
                if (record.pairingOperation == null) {
                    check(bareJamiId(awaitRestoredUsername(record.accountId)) == record.expectedJamiId) {
                        "Restore identity mismatch"
                    }
                }
                if (record.phase == "importing") {
                    check(initializeArchiveProtection(JamiService.getAccountList())) { "Restore protection remains unresolved" }
                }
                completePendingRestorePreparation(record)
                pendingIdentityRestoreOwner = accountAuthority.capture()
                identityRestoreRecoveryFailed = false
                pendingRestoreResult(checkNotNull(pendingIdentityRestore))
            }
        } catch (error: Throwable) {
            Log.e(TAG, "pending identity restore could not be recovered", error)
            restoreRecoveryResult(record, when (record.phase) {
                "rollingBack" -> "rollbackPending"
                "importing" -> "importIncomplete"
                else -> "preparationFailed"
            })
        }
    }

    /** Worker-only: Account.enable remains persisted; only volatile activation is released. */
    private fun activatePreparedAccount(account: String): Boolean = try {
        val owner = captureAccountScope(account)
        val document = incomingMicrophoneSettings.currentDocument()
        if (owner == null || !accountAuthority.owns(preparedNetworkOwner) || document == null || pendingIdentityRestore != null ||
            identityRestoreRecoveryFailed || identityRestoreCommitting) false
        else incomingMicrophoneSettings.withCurrentDocument(document) {
            val localLock = restoredLocalAppLock()
            commitRestoredPrivacy(document, localLock, saveDocument = { true },
                saveNotificationPolicy = { preview, locked -> MessageNotifications.setPolicy(appContext, preview, locked) },
                activateWithCurrentDocument = {
                    if (!accountAuthority.owns(owner) || restoredLocalAppLock() != localLock) false
                    else {
                        val preferences = appContext.getSharedPreferences(
                            CanonicalIncomingCallMicrophonePolicy.PREFERENCES_NAME, Context.MODE_PRIVATE)
                        val offline = if (preferences.contains("flutter.appearOffline"))
                            preferences.all["flutter.appearOffline"] as? Boolean ?: error("Invalid offline policy")
                        else false
                        if (offline) JamiService.sendRegister(account, false)
                        val enabled = !offline &&
                            JamiService.getAccountDetails(account).toNative()["Account.enable"] == "true"
                        if (keepOnline != enabled) setOnlineLifetime(enabled)
                        JamiService.setAccountActive(account, true, false)
                        JamiService.getVolatileAccountDetails(account).toNative()["Account.active"] == "true"
                    }
                })
        }
    } catch (_: Exception) { false }

    private fun restoredLocalAppLock(): Boolean? = try {
        val preferences = appContext.getSharedPreferences(
            CanonicalIncomingCallMicrophonePolicy.PREFERENCES_NAME, Context.MODE_PRIVATE,
        )
        if (!preferences.contains("flutter.appLockEnabled.v1")) null
        else preferences.getBoolean("flutter.appLockEnabled.v1", true)
    } catch (_: Exception) { null }

    internal fun finalizeIdentityRestore(
        restoredAccountId: String,
        token: String,
        document: String,
        scope: NativeAccountScope?,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        val admittedRecord = pendingIdentityRestore
        val pairingEpoch = pairingVisits.capture()
        fun pairingCurrent() = admittedRecord?.pairingOperation == null ||
            (pairingVisits.allows(token, pairingEpoch) && pairingForeground())
        if (!pairingCurrent() || !accountAuthority.owns(scope) || !accountAuthority.owns(pendingIdentityRestoreOwner) ||
            admittedRecord == null || admittedRecord.accountId != restoredAccountId || admittedRecord.token != token ||
            admittedRecord.phase != "prepared" ||
            (admittedRecord.pairingOperation == null && admittedRecord.expectedJamiId.isEmpty()) ||
            (admittedRecord.pairingOperation != null && (!admittedRecord.pairingAcknowledged ||
                admittedRecord.normalizedDocument != document))) {
            callback(mapOf("status" to "error"))
            return
        }
        // Admit the canonical write before queuing so a queued notification answer cannot use older Open intent.
        val save = incomingMicrophoneSettings.prepareSave(document)
        submit(DaemonOperation.RESTORE_IDENTITY, block = {
            val failed = mapOf<String, Any?>("status" to "error")
            val record = pendingIdentityRestore ?: return@submit failed
            if (!started || !pairingCurrent() || !accountAuthority.owns(scope) || !accountAuthority.owns(pendingIdentityRestoreOwner) ||
                record.accountId != restoredAccountId || record.token != token || record.phase != "prepared" ||
                (record.pairingOperation == null &&
                    bareJamiId(awaitRestoredUsername(record.accountId)) != record.expectedJamiId) ||
                (record.pairingOperation != null && (!record.pairingAcknowledged || record.normalizedDocument != document))
            ) return@submit failed
            val admitted = synchronized(callLifecycleLock) {
                if (activeCallId != null || activeGroupConferenceId != null ||
                    pendingGroupConferenceId != null || reservedCallPeerId != null || placingOutgoing) false
                else { identityRestoreCommitting = true; true }
            }
            if (!admitted) return@submit failed
            completeRestoreRoutingPublication(
                retireBarrier = { identityRestoreCommitting = false },
                publish = { refreshRoutingSnapshot(record.accountId) },
            ) {
                val localLock = restoredLocalAppLock()
                var finalResult: Map<String, Any?> = failed
                val committed = commitRestoredPrivacy(document, localLock, save,
                    { showMessage, lock ->
                        MessageNotifications.setPolicy(appContext, showMessage, lock) &&
                            MessageNotifications.retireRestoredAccountNotifications(appContext)
                    },
                ) {
                    incomingMicrophoneSettings.withCurrentDocument(document) {
                        if (!pairingCurrent() || !accountAuthority.owns(scope) ||
                            restoredLocalAppLock() != localLock) return@withCurrentDocument false
                        try {
                            val preparedResult = pendingRestoreResult(record)
                            val committedRecord = record.copy(phase = "privacyCommitted", normalizedDocument = document)
                            check(IdentityRestoreJournal.save(appContext, committedRecord)) {
                                "Restored privacy commit could not be saved"
                            }
                            pendingIdentityRestore = committedRecord
                            val details = JamiService.getAccountDetails(record.accountId).toNative().toMutableMap()
                            check(pairingCurrent() && accountAuthority.owns(scope)) { "Device-link activation retired" }
                            details["Account.enable"] = (!record.appearOffline).toString()
                            JamiService.setAccountDetails(record.accountId, StringMap.toSwig(details))
                            check(JamiService.getAccountDetails(record.accountId).toNative()["Account.enable"] ==
                                (!record.appearOffline).toString()) { "Restored activation was not acknowledged" }
                            JamiService.sendRegister(record.accountId, !record.appearOffline)
                            JamiService.setAccountActive(record.accountId, true, false)
                            check(pairingCurrent() && accountAuthority.owns(scope)) { "Device-link activation retired" }
                            selectAccount(record.accountId)
                            preparedNetworkOwner = captureAccountScope(record.accountId)
                            setOnlineLifetime(!record.appearOffline)
                            val announced = !record.appearOffline && JamiService.getVolatileAccountDetails(
                                record.accountId,
                            ).toNative()["Account.deviceAnnounced"] == "true"
                            announcedByAccount[record.accountId] = announced
                            check(record.pairingOperation == null || (pairingForeground() && accountId == record.accountId)) { "Device-link activation retired" }
                            check(IdentityRestoreJournal.clear(appContext)) { "Restored commit could not be retired" }
                            pendingIdentityRestore = null
                            pendingIdentityRestoreOwner = null
                            finalResult = preparedResult + mapOf(
                                "status" to "ok", "settingsDocument" to document,
                                "canDiscard" to false,
                                "enabled" to !record.appearOffline,
                                "announced" to announced,
                                "registration" to (registrationByAccount[record.accountId] ?: "UNREGISTERED"),
                            )
                            true
                        } catch (error: Throwable) {
                            Log.e(TAG, "restored identity activation failed", error)
                            try { disablePendingRestoredAccount(record.accountId) }
                            catch (disableError: Throwable) { Log.e(TAG, "restored identity disable failed", disableError) }
                            if (accountId == record.accountId) {
                                val previous = record.previousAccountId.takeIf {
                                    it.isNotEmpty() && JamiService.getAccountList().contains(it)
                                }
                                selectAccount(previous.orEmpty())
                                if (previous == null) {
                                    accountAuthority.select(null)
                                    accountId = null
                                }
                                setOnlineLifetime(previous != null &&
                                    JamiService.getAccountDetails(previous).toNative()["Account.enable"] != "false")
                                pendingIdentityRestoreOwner = accountAuthority.capture()
                            }
                            false
                        }
                    }
                }
                if (committed) finalResult else failed
            }
        }) { callback(it ?: mapOf("status" to "error")) }
    }

    /** Restore variant of awaitUsername: poll Account.username AND account-existence. A wrong passphrase makes the
     *  daemon auth-fail + auto-remove the account → fast empty return (instead of destroying a still-importing valid
     *  account with a 5s timeout). A valid import only needs local Argon2+keygen but can be slow on a cold/large
     *  archive, so allow a generous ~25s. Worker thread. */
    private fun awaitRestoredUsername(id: String): String {
        repeat(250) {
            if (!JamiService.getAccountList().contains(id)) return ""  // daemon removed it → auth failed
            val u = JamiService.getAccountDetails(id).toNative()["Account.username"] ?: ""
            if (u.isNotEmpty()) return u
            Thread.sleep(100)
        }
        return ""
    }

    /** One audio media entry (UPPERCASE keys) wrapped in a VectMap — no video entry for M1. */
    private fun audioMedia(muted: Boolean): VectMap {
        val m = StringMap.toSwig(
            mapOf(
                "MEDIA_TYPE" to "MEDIA_TYPE_AUDIO",
                "ENABLED" to "true",
                "MUTED" to muted.toString(),
                "LABEL" to "audio_0",
                "SOURCE" to "",
                "HOLD" to "false"
            )
        )
        return VectMap().apply { add(m) }
    }

    // ---- video (M2): camera on/off mid-call via requestMediaChange ----

    /** Arm the intent-first camera lease: pick + register + default the device (cheap characteristic
     *  queries — no Camera2 open, no wait), predict the sink id, and request the camera-typed
     *  foreground promotion. addVideoDevice/setDefaultDevice return void, so the daemon's default is
     *  VALIDATED via getDefaultDevice — empty-SOURCE resolution depends on it; an unconfirmed
     *  default places audio-only instead of dialing a silently sourceless video stream. */
    private fun prepareCameraLease(displayRotationDeg: Int, ownerCallId: String?): Boolean {
        val uiOwner = captureCommandOwner.get() ?: captureUiAuthority.capture()
        if (!captureUiAuthority.owns(uiOwner)) return false
        displayDeg = displayRotationDeg
        return try {
            val cam = pickCamera() ?: run { Log.e(TAG, "prepareCameraLease: no camera"); return false }
            camId = cam
            camFacing = camManager.getCameraCharacteristics(cam).get(CameraCharacteristics.LENS_FACING)
                ?: CameraCharacteristics.LENS_FACING_FRONT
            emit(mapOf("type" to "cameraFacing", "accountId" to (accountId ?: ""),
                "callId" to (ownerCallId ?: activeMediaTarget() ?: ""),
                "front" to (camFacing == CameraCharacteristics.LENS_FACING_FRONT)))
            JamiService.addVideoDevice(cam)          // → getCameraInfo (we report size/rate + sensor orientation)
            JamiService.setDefaultDevice(cam)
            val confirmed = try { JamiService.getDefaultDevice() } catch (e: Throwable) { "" }
            if (confirmed != cam) {
                Log.e(TAG, "prepareCameraLease: daemon default device not confirmed")
                return false
            }
            var epoch = -1L
            executeVideoDecisions(transitionVideo { phase ->
                if (!captureUiAuthority.owns(uiOwner)) return@transitionVideo LocalVideoPolicy.revoke(phase)
                epoch = nextVideoSeq()
                LocalVideoPolicy.arm(phase, epoch, registeredDeviceId = cam, physicalCameraId = cam, ownerCallId = ownerCallId)
            })
            if (epoch < 0L) return false
            requestCaptureFgs(epoch, CallForegroundService.CaptureType.CAMERA)
            Log.i(TAG, "prepareCameraLease cam=$cam sink='$localInputId' facing=$camFacing owner=$ownerCallId")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "prepareCameraLease", e)
            revokeLease()
            false
        }
    }

    /** Ask for the capture-typed foreground promotion for lease [epoch]. Capture may not open until
     *  the service confirms ([onCallForegroundPromoted]); audio focus is NOT taken here — that stays
     *  with startCallAudio/CallAudioController exactly as before. */
    private fun requestCaptureFgs(epoch: Long, type: CallForegroundService.CaptureType) {
        postMainAfterCameraQueue fgs@{
            val stillWanted = synchronized(callLifecycleLock) {
                videoPhase.currentLease()?.let {
                    it.epoch == epoch &&
                        (type != CallForegroundService.CaptureType.SCREEN || it.kind == LocalVideoKind.SCREEN)
                } == true
            }
            if (!stillWanted) return@fgs
            if (!CallForegroundService.showCallIfRunning(type, promotionEpoch = epoch)) {
                // Feed launch failures back to the exact lease, including screen rollback.
                val launched = startForegroundLifetime(
                    CallForegroundService.callIntent(appContext, type, promotionEpoch = epoch),
                )
                if (!launched) onCallForegroundPromotionFailed(epoch)
            }
        }
    }

    fun reserveScreenConsent(expectedCallId: String): Long {
        val epoch = synchronized(callLifecycleLock) {
            if (expectedCallId.isEmpty() || activeMediaTarget() != expectedCallId ||
                pendingProjectionConsent != null || recentTerminalCallIds.contains(expectedCallId)
            ) {
                return@synchronized -1L
            }
            nextVideoSeq().also { pendingProjectionConsent = expectedCallId to it }
        }
        if (epoch > 0) {
            AndroidRemoteControlPolicy.sourceAnnouncement(myJamiId(), epoch, "screen")
                ?.let { sendCallMessage(expectedCallId, it) }
        }
        return epoch
    }

    fun cancelScreenConsent(expectedCallId: String, epoch: Long) {
        synchronized(callLifecycleLock) {
            if (pendingProjectionConsent == (expectedCallId to epoch)) {
                pendingProjectionConsent = null
            }
        }
    }

    fun startScreenShare(
        expectedCallId: String,
        epoch: Long,
        resultCode: Int,
        data: Intent,
        width: Int,
        height: Int,
        densityDpi: Int,
    ): Boolean {
        val uiOwner = captureCommandOwner.get() ?: captureUiAuthority.capture()
        if (!captureUiAuthority.owns(uiOwner)) {
            cancelScreenConsent(expectedCallId, epoch)
            return false
        }
        val acc = accountId ?: run {
            cancelScreenConsent(expectedCallId, epoch)
            return false
        }
        val valid = synchronized(callLifecycleLock) {
            if (pendingProjectionConsent != (expectedCallId to epoch)) {
                false
            } else if (
                activeMediaTarget() != expectedCallId ||
                recentTerminalCallIds.contains(expectedCallId)
            ) {
                pendingProjectionConsent = null
                false
            } else {
                pendingProjectionConsent = null
                projectionConsents[epoch] = ProjectionConsent(
                    expectedCallId,
                    epoch,
                    resultCode,
                    Intent(data),
                    width,
                    height,
                    densityDpi,
                )
                true
            }
        }
        if (!valid) return false
        fun failArmedScreen() {
            val cleanup = synchronized(callLifecycleLock) {
                projectionConsents.remove(epoch)
                val armed = videoPhase.currentLease()?.let {
                    it.epoch == epoch &&
                        it.kind == LocalVideoKind.SCREEN &&
                        it.ownerCallId == expectedCallId
                } == true
                val restore = armed && projectionRollbacks.containsKey(epoch)
                if (!armed) projectionRollbacks.remove(epoch)
                armed to restore
            }
            if (!cleanup.first) return
            revokeLease()
            if (cleanup.second) {
                rollbackProjectionFailure(epoch)
            } else {
                emitCameraStateIfAuthoritative(
                    expectedCallId,
                    false,
                    epoch,
                    SCREEN_MRL,
                )
            }
            reconcileFgsAfterLeaseRevoke()
        }
        return try {
            JamiService.addVideoDevice(SCREEN_DEVICE_ID)
            executeVideoDecisions(transitionVideo { phase ->
                if (!captureUiAuthority.owns(uiOwner)) return@transitionVideo LocalVideoPolicy.revoke(phase)
                phase.currentLease()?.takeIf {
                    it.kind == LocalVideoKind.CAMERA &&
                        it.ownerCallId == expectedCallId
                }?.let {
                    projectionRollbacks[epoch] = CameraRollback(
                        expectedCallId,
                        displayDeg,
                    )
                }
                LocalVideoPolicy.arm(
                    phase,
                    epoch,
                    SCREEN_DEVICE_ID,
                    SCREEN_DEVICE_ID,
                    expectedCallId,
                    kind = LocalVideoKind.SCREEN,
                    width = width,
                    height = height,
                )
            })
            if (!captureUiAuthority.owns(uiOwner)) return false
            requestCaptureFgs(epoch, CallForegroundService.CaptureType.SCREEN)
            val mediaTarget = mediaSignalingTarget(expectedCallId)
            val live = currentMediaSnapshot(acc, mediaTarget)
            val ok = live != null && JamiService.requestMediaChange(
                acc,
                mediaTarget,
                sourceMediaList(live, enabled = true, source = SCREEN_MRL),
            )
            if (!ok || activeMediaTarget() != expectedCallId) {
                failArmedScreen()
                false
            } else {
                emitOutgoingVideoSnapshot()
                true
            }
        } catch (e: Throwable) {
            Log.e(TAG, "startScreenShare", e)
            failArmedScreen()
            false
        }
    }

    /** CallForegroundService reports a successful camera-typed startForeground for the exact
     * request epoch; the coordinator discards delayed callbacks from superseded leases. */
    internal fun onCallForegroundPromoted(epoch: Long) {
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.fgsConfirmed(it, epoch, nextVideoSeq()) })
    }

    /** Promotion failed: capture is impossible — the coordinator downgrades the call's video. */
    internal fun onCallForegroundPromotionFailed(epoch: Long) {
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.fgsFailed(it, epoch) })
        rollbackProjectionFailure(epoch)
    }

    private fun rollbackProjectionFailure(epoch: Long) {
        val rollback = synchronized(callLifecycleLock) {
            projectionConsents.remove(epoch)
            projectionRollbacks.remove(epoch)
        } ?: return
        worker.execute(
            DaemonOperation.START_VIDEO,
            diagnosticCallToken(rollback.callId),
        ) {
            if (activeMediaTarget() == rollback.callId) {
                startVideo(rollback.callId, rollback.displayRotation)
            }
        }
    }

    /** Re-assert the foreground CAMERA type from current truth (type only — never audio focus). */
    private fun syncCallFgsVideo() {
        val inCall = activeCallId != null || activeGroupConferenceId != null ||
            synchronized(callLifecycleLock) { placingOutgoing }
        if (inCall) CallForegroundService.showCallIfRunning(currentCaptureType())
    }

    private fun currentCaptureType() = when (outgoingVideo.kind) {
        LocalVideoKind.CAMERA -> CallForegroundService.CaptureType.CAMERA
        LocalVideoKind.SCREEN -> CallForegroundService.CaptureType.SCREEN
        null -> CallForegroundService.CaptureType.NONE
    }

    /** A promoted-for-placement service whose placement died must not stay call-typed. */
    private fun demoteCallFgsIfIdle() {
        postMainAfterCameraQueue demote@{
            if (activeCallId != null || activeGroupConferenceId != null) return@demote
            applyBackgroundWakeLifetime()
        }
    }

    /** Reconcile a revoked lease after Camera2 closes: another live/placing call keeps its call
     * notification with current video truth; otherwise return to online lifetime or stop. */
    private fun reconcileFgsAfterLeaseRevoke() {
        postMainAfterCameraQueue {
            val inCall = activeCallId != null || activeGroupConferenceId != null ||
                synchronized(callLifecycleLock) { placingOutgoing }
            if (inCall) syncCallFgsVideo()
            else applyBackgroundWakeLifetime()
        }
    }

    /** Turn our camera ON mid-call: arm the lease and re-invite with audio+video (SOURCE = the
     *  exact predicted sink). Returns "intent accepted": capture follows the daemon's StartCapture;
     *  a later capture failure reconciles through cameraState instead of blocking here. */
    fun startVideo(expectedCallId: String, displayRotationDeg: Int): Boolean {
        val acc = accountId ?: return false
        val call = activeMediaTarget() ?: return false
        if (expectedCallId.isEmpty() || call != expectedCallId) return false
        if (!prepareCameraLease(displayRotationDeg, ownerCallId = call)) return false
        val armed = synchronized(callLifecycleLock) {
            videoPhase.currentLease()?.takeIf {
                it.kind == LocalVideoKind.CAMERA &&
                    it.ownerCallId == expectedCallId
            }
        }
        if (activeMediaTarget() != expectedCallId) {
            revokeLease()
            reconcileFgsAfterLeaseRevoke()
            return false
        }
        val mediaTarget = mediaSignalingTarget(call)
        val live = currentMediaSnapshot(acc, mediaTarget)
        val ok = live != null && JamiService.requestMediaChange(
            acc,
            mediaTarget,
            sourceMediaList(live, enabled = true, source = localInputId ?: ""),
        )
        Log.i(TAG, "requestMediaChange(+video) -> $ok (local acceptance only)")
        if (!ok || activeMediaTarget() != expectedCallId) {
            revokeLease()
            if (activeMediaTarget() == expectedCallId && armed != null) {
                emitCameraStateIfAuthoritative(
                    expectedCallId,
                    false,
                    armed.epoch,
                    armed.sinkId,
                )
            }
            if (!ok) Log.w(TAG, "startVideo: re-invite rejected → lease revoked (FGS NOT kept camera-typed)")
            reconcileFgsAfterLeaseRevoke()
            return false
        }
        main.post { startCallAudio(video = true) } // FGS re-assert; audio focus is already held for the call
        emitOutgoingVideoSnapshot()
        return true
    }

    /** Turn our camera OFF: re-invite with the video entry MUTED=true naming the exact live source,
     *  and release the hardware immediately (the daemon stops its sender locally before the
     *  re-invite goes out, so the proactive close never races a live sender). */
    fun stopVideo(expectedCallId: String): Boolean {
        val acc = accountId ?: return false
        val call = activeMediaTarget() ?: return false
        if (expectedCallId.isEmpty() || call != expectedCallId) return false
        var stoppedEpoch = -1L
        var source = ""
        executeVideoDecisions(transitionVideo { phase ->
            val lease = phase.currentLease()
            val transition = LocalVideoPolicy.userStop(phase, call)
            if (lease != null && transition.phase != phase) {
                stoppedEpoch = lease.epoch
                source = lease.sinkId
                projectionConsents.remove(lease.epoch)
                projectionRollbacks.remove(lease.epoch)
                // PendingReplacement still names the losing owner. If its CURRENT winner turns
                // video off, authorize that winner's off effect before the policy drops the lease.
                val old = videoEffectAuthority[call]
                if (old == null || lease.epoch >= old.epoch) {
                    videoEffectAuthority[call] = VideoEffectAuthority(lease.epoch, lease.sinkId)
                }
            }
            transition
        })
        if (stoppedEpoch < 0L) return false
        val mediaTarget = mediaSignalingTarget(call)
        val live = currentMediaSnapshot(acc, mediaTarget)
        val ok = live != null && JamiService.requestMediaChange(
            acc,
            mediaTarget,
            sourceMediaList(live, enabled = false, source = ""),
        )
        // Release the camera FIRST, THEN downgrade the FGS — never drop the CAMERA service type while
        // capture is still physically live (the close above is queued on camHandler ahead of this).
        postMainAfterCameraQueue {
            if (isVideoEffectCurrent(call, stoppedEpoch, source)) startCallAudio(video = false)
        }
        Log.i(TAG, "stopVideo negotiation=$ok (local acceptance only; camera released)")
        emitCameraStateIfAuthoritative(call, false, stoppedEpoch, source)
        // Privacy wins over re-invite bookkeeping: capture is physically closed even when the daemon
        // rejects the media update, so the type-correct result reports the local camera state.
        return true
    }

    /** Flip front/back by swapping the Camera2 device UNDERNEATH the same daemon input. On Android WE push the
     *  frames (ManagedByClient), so there is NO closeVideoInput/requestMediaChange and NO sink change: the self
     *  window stays bound and the peer's decoder never restarts. Only the source pixels + rotation change.
     *  (The old close-input/re-invite approach black-screened both sides during the renegotiation.)
     *  While the lease is merely armed (capture not demanded/open yet), the flip changes ONLY the
     *  selected physical device — the eventual StartCapture-time open uses the new selection. */
    fun switchCamera(expectedCallId: String): Boolean {
        if (!cameraOn) return false
        if (expectedCallId.isEmpty() || activeMediaTarget() != expectedCallId) return false
        val flippable = synchronized(callLifecycleLock) {
            videoPhase.currentLease() != null && videoPhase !is VideoPhase.PendingReplacement
        }
        if (!flippable) return false
        val other = otherCamera() ?: return false
        camId = other
        val cc = camManager.getCameraCharacteristics(other)
        camFacing = cc.get(CameraCharacteristics.LENS_FACING) ?: camFacing
        sensorOrientation = cc.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: sensorOrientation
        recomputeRotation()                          // no getCameraInfo callback fires here — recompute ourselves
        val front = camFacing == CameraCharacteristics.LENS_FACING_FRONT
        emit(mapOf("type" to "cameraFacing", "accountId" to (accountId ?: ""),
            "callId" to expectedCallId, "front" to front))
        // Orientation always addresses the REGISTERED device — the only identity the daemon knows.
        val registered = synchronized(callLifecycleLock) { videoPhase.currentLease()?.registeredDeviceId }
        if (registered != null) {
            try { JamiService.setDeviceOrientation(registered, capRotation) } catch (_: Throwable) {}
        }
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.flip(it, other, nextVideoSeq()) })
        Log.i(TAG, "switchCamera -> $other facing=$camFacing rot=$capRotation (same input '$localInputId')")
        return true
    }

    /** Feed the current display rotation (from MainActivity) so the peer sees upright video. */
    fun setDisplayRotation(deg: Int) {
        val changed = displayDeg != deg
        displayDeg = deg
        if (changed && sharingScreen) retireRemoteControlSource()
        if (cameraOn) {
            recomputeRotation()
            val registered = synchronized(callLifecycleLock) {
                videoPhase.currentLease()?.registeredDeviceId
            }
            registered?.let { try { JamiService.setDeviceOrientation(it, capRotation) } catch (_: Throwable) {} }
        }
    }

    /** audio_0 + video_0 entries (UPPERCASE keys) wrapped in a VectMap. Placement offers video with
     *  an EMPTY source (the daemon resolves the registered default); re-invites name the exact live
     *  sink so the daemon never reads them as a source change. */
    private fun videoMediaList(micMuted: Boolean, videoMuted: Boolean, source: String): VectMap {
        val audio = StringMap.toSwig(mapOf(
            "MEDIA_TYPE" to "MEDIA_TYPE_AUDIO", "ENABLED" to "true", "MUTED" to micMuted.toString(),
            "LABEL" to "audio_0", "SOURCE" to "", "HOLD" to "false"))
        val video = StringMap.toSwig(mapOf(
            "MEDIA_TYPE" to "MEDIA_TYPE_VIDEO", "ENABLED" to "true", "MUTED" to videoMuted.toString(),
            "LABEL" to "video_0", "SOURCE" to source, "HOLD" to "false"))
        return VectMap().apply { add(audio); add(video) }
    }

    private fun sourceMediaList(
        live: List<Map<String, String>>,
        enabled: Boolean,
        source: String,
    ): VectMap {
        val transformed = live.map { HashMap(it) }.toMutableList()
        var found = false
        transformed.forEach { media ->
            if (media["MEDIA_TYPE"] == "MEDIA_TYPE_VIDEO") {
                media["ENABLED"] = enabled.toString()
                media["MUTED"] = (!enabled).toString()
                media["SOURCE"] = if (enabled) source else ""
                media["HOLD"] = "false"
                found = true
            }
        }
        if (!found) {
            transformed += hashMapOf(
                "MEDIA_TYPE" to "MEDIA_TYPE_VIDEO",
                "ENABLED" to enabled.toString(),
                "MUTED" to (!enabled).toString(),
                "LABEL" to "video_0",
                "SOURCE" to if (enabled) source else "",
                "HOLD" to "false",
            )
        }
        return VectMap().apply {
            transformed.forEach { add(StringMap.toSwig(it)) }
        }
    }

    /** Read libjami's call-owned media topology through the small typed adapter for its SWIG typedef gap.
     * Query failure is null, distinct from a valid empty/audio-only topology. */
    private fun currentMediaSnapshot(accountId: String, callId: String): List<Map<String, String>>? = try {
        val native = CurrentMediaListAdapter.get(accountId, callId)
        try { snapshot(native) } finally { native.delete() }
    } catch (e: Throwable) {
        Log.e(TAG, "currentMediaList($callId)", e)
        null
    }

    /** Token captured from a NEGOTIATION_SUCCESS notification; live topology is read on the worker. */
    private data class VideoNegotiationSignal(
        val callId: String,
        val leaseEpoch: Long,
        val sinkId: String,
        val ownerAtCallback: String?,
        val replacementQueryEpoch: Long?,
        val followsPeerAnswer: Boolean,
    )

    /** Capture the lease token while handling the tokenless daemon signal. An unbound placement is
     * retained: placeCall occupies the same worker, so the live query below runs after its returned
     * call id has been bound and can correlate it without a timer. */
    private fun videoNegotiationSignal(callId: String): VideoNegotiationSignal? =
        synchronized(callLifecycleLock) {
            val lease = videoPhase.currentLease() ?: return@synchronized null
            val ownerCallId = groupCallLegs.entries.firstOrNull { it.value == callId }?.key ?: callId
            val pending = videoPhase as? VideoPhase.PendingReplacement
            val queryEpoch = pending?.takeIf { it.winnerCallId == ownerCallId }?.queryEpoch
            if (lease.ownerCallId != null && lease.ownerCallId != ownerCallId && queryEpoch == null) {
                return@synchronized null
            }
            VideoNegotiationSignal(
                ownerCallId,
                lease.epoch,
                lease.sinkId,
                lease.ownerCallId,
                queryEpoch,
                peerMediaAnswersPending.remove(callId),
            )
        }

    /** Worker-side NEGOTIATION_SUCCESS reconcile. The callback's VectMap is only a notification:
     * libjami provides no transaction id, so currentMediaList is re-read and an off result applies
     * only while the exact callback-time lease epoch/source/owner remains authoritative. */
    private fun onMediaNegotiated(signal: VideoNegotiationSignal) {
        val acc = accountId ?: return
        val mediaTarget = mediaSignalingTarget(signal.callId)
        val live = currentMediaSnapshot(acc, mediaTarget) ?: return
        val owns = mediaOwnsLocalCamera(live, signal.sinkId)
        val shouldReassert = synchronized(callLifecycleLock) {
            LocalVideoPolicy.shouldReassertAfterPeerAnswer(
                videoPhase,
                signal.callId,
                signal.leaseEpoch,
                signal.sinkId,
                signal.followsPeerAnswer,
                owns,
                activeMediaTarget() == signal.callId &&
                    !recentTerminalCallIds.contains(signal.callId),
            )
        }
        if (shouldReassert) {
            val accepted = JamiService.requestMediaChange(
                acc,
                mediaTarget,
                sourceMediaList(live, enabled = true, source = signal.sinkId),
            )
            Log.i(
                TAG,
                "peer media change dropped local source; reassert(${signal.callId}) -> $accepted",
            )
            if (accepted) return
        }
        executeVideoDecisions(transitionVideo { phase ->
            val lease = phase.currentLease()
            val sameToken = lease?.epoch == signal.leaseEpoch && lease.sinkId == signal.sinkId
            val sameOwner = if (signal.replacementQueryEpoch != null) {
                val pending = phase as? VideoPhase.PendingReplacement
                (pending?.queryEpoch == signal.replacementQueryEpoch &&
                    pending.winnerCallId == signal.callId) ||
                    (pending == null && lease?.ownerCallId == signal.callId)
            } else {
                lease?.ownerCallId == signal.callId &&
                    (signal.ownerAtCallback == null || signal.ownerAtCallback == signal.callId)
            }
            val authoritativeCall = activeMediaTarget() == signal.callId &&
                !recentTerminalCallIds.contains(signal.callId)
            if (!sameToken || !sameOwner || !authoritativeCall) VideoTransition(phase)
            else LocalVideoPolicy.negotiated(phase, signal.callId, owns)
        })
    }

    /** Retain a placement camera only when the established winner already owns that exact active source.
     * We deliberately do not start a speculative media renegotiation in this glare-cleanup path. */
    private fun adoptPlacementCameraIfOwned(accountId: String, winnerCallId: String, source: String): Boolean {
        fun stillWinner(): Boolean = synchronized(callLifecycleLock) {
            activeCallId == winnerCallId && currentWinnerCallId == winnerCallId &&
                !recentTerminalCallIds.contains(winnerCallId)
        }
        if (!stillWinner()) return false
        val current = currentMediaSnapshot(accountId, winnerCallId) ?: return false
        return mediaOwnsLocalCamera(current, source) && stillWinner()
    }

    /** Camera truth is a call-scoped event, not an inference from a losing placement result. Serialize it with daemon
     * call signals so a terminal callback cannot be followed by a stale camera-on update. */
    private fun emitCameraStateIfAuthoritative(
        callId: String,
        on: Boolean,
        epoch: Long,
        sinkId: String? = null,
    ) {
        synchronized(callSignalDispatchLock) {
            val snapshot = synchronized(callLifecycleLock) {
                if (!isVideoEffectCurrent(
                        callId,
                        epoch,
                        sinkId,
                        requiresLiveIntent = on,
                    )) return@synchronized null
                mapOf(
                    "type" to "outgoingVideoSource",
                    "accountId" to (accountId ?: ""),
                    "callId" to callId,
                    "cameraOn" to (on && outgoingVideo.kind == LocalVideoKind.CAMERA),
                    "outgoingVideoKind" to if (on) {
                        when (outgoingVideo.kind) {
                            LocalVideoKind.CAMERA -> "camera"
                            LocalVideoKind.SCREEN -> "screen"
                            null -> "off"
                        }
                    } else "off",
                    "outgoingVideoUri" to if (on) outgoingVideo.uri else "",
                    "outgoingVideoRevision" to epoch,
                    "outgoingVideoWidth" to if (on) outgoingVideo.width else 0,
                    "outgoingVideoHeight" to if (on) outgoingVideo.height else 0,
                )
            }
            if (snapshot != null) emit(snapshot)
        }
    }

    /** Copy a daemon-owned media VectMap into plain Kotlin (the reference is only valid during the callback). */
    internal fun snapshot(list: VectMap): List<Map<String, String>> {
        val out = ArrayList<Map<String, String>>(list.size)
        for (i in 0 until list.size) out.add(HashMap(list.get(i).toNative()))
        return out
    }

    internal fun listHasActiveVideo(offer: List<Map<String, String>>): Boolean =
        offer.any { it["MEDIA_TYPE"] == "MEDIA_TYPE_VIDEO" && it["MUTED"] != "true" && it["ENABLED"] != "false" }

    /** Echo an offered media list back as our answer. Local video is call-scoped lease ownership,
     * never the process-global mirrors: a pending glare lease for another leg must stay receive-only. */
    internal fun mirrorOffer(callId: String, offer: List<Map<String, String>>, micMuted: Boolean): VectMap {
        val localSource = synchronized(callLifecycleLock) {
            val lease = when (val phase = videoPhase) {
                is VideoPhase.Armed -> phase.lease
                is VideoPhase.Opening -> phase.lease
                is VideoPhase.Capturing -> phase.lease
                else -> null
            }
            lease?.sinkId?.takeIf {
                lease.ownerCallId == callId && activeCallId == callId &&
                    !recentTerminalCallIds.contains(callId)
            }
        }
        val sendsVideo = localSource != null
        val out = VectMap()
        for (src in offer) {
            val type = src["MEDIA_TYPE"] ?: ""
            val muted = when (type) {
                "MEDIA_TYPE_AUDIO" -> micMuted
                "MEDIA_TYPE_VIDEO" -> !sendsVideo
                else -> (src["MUTED"] == "true")
            }
            val source = if (type == "MEDIA_TYPE_VIDEO" && sendsVideo) localSource else (src["SOURCE"] ?: "")
            out.add(StringMap.toSwig(mapOf(
                "MEDIA_TYPE" to type, "ENABLED" to "true", "MUTED" to muted.toString(),
                "LABEL" to (src["LABEL"] ?: ""), "SOURCE" to source, "HOLD" to (src["HOLD"] ?: "false"))))
        }
        return out
    }

    internal fun postAnswerMediaChange(callId: String, offer: List<Map<String, String>>) {
        worker.execute(DaemonOperation.ANSWER_MEDIA_CHANGE, diagnosticCallToken(callId)) {
            val acc = accountId ?: return@execute
            // Build the answer on the same serialized worker as setMicMuted. Snapshotting micMuted on the daemon
            // callback thread can otherwise apply stale audio media after a newer mute/unmute command.
            if (activeCallId != callId) return@execute
            val answer = mirrorOffer(callId, offer, micMuted)
            synchronized(callLifecycleLock) {
                peerMediaAnswersPending += callId
            }
            val ok = JamiService.answerMediaChangeRequest(acc, callId, answer)
            if (!ok) {
                synchronized(callLifecycleLock) {
                    peerMediaAnswersPending.remove(callId)
                }
            }
            Log.i(TAG, "answerMediaChangeRequest($callId) -> $ok")
        }
    }

    internal fun onConversationMembershipChanged(account: String) {
        if (!isActiveAccount(account)) return
        requestRoutingRefresh(account)
    }

    private fun teardownVideo(terminalCallId: String) {
        synchronized(callLifecycleLock) {
            peerMediaAnswersPending.remove(terminalCallId)
            if (pendingProjectionConsent?.first == terminalCallId) {
                pendingProjectionConsent = null
            }
            projectionConsents.entries.removeIf { it.value.callId == terminalCallId }
            projectionRollbacks.entries.removeIf { it.value.callId == terminalCallId }
        }
        // Camera release is generation-scoped: only the owning call's terminal revokes the lease
        // (an unrelated terminal must not close an in-flight placement's capture, and a loser's
        // terminal during a pending replacement holds for the adoption verdict).
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.terminal(it, terminalCallId) })
        // Always release the binder: a RECEIVE-ONLY call has the remote sink bound while cameraOn=false and
        // localInputId=null, so an early-return on those would leak the remote native window on hangup.
        main.post { videoBinder?.releaseAll() }
    }

    // ---- Camera2 capture (client-managed: we push frames to the daemon via captureVideoFrame) ----

    private fun pickCamera(): String? = try {
        val ids = camManager.cameraIdList
        ids.firstOrNull {
            camManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT
        } ?: ids.firstOrNull()
    } catch (e: Throwable) { Log.e(TAG, "pickCamera", e); null }

    private fun otherCamera(): String? = try {
        // Pick by OPPOSITE facing (not just "first different id" — multi-lens phones expose several ids per side).
        val wantFront = camFacing != CameraCharacteristics.LENS_FACING_FRONT
        camManager.cameraIdList.firstOrNull {
            val f = camManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
            if (wantFront) f == CameraCharacteristics.LENS_FACING_FRONT else f == CameraCharacteristics.LENS_FACING_BACK
        } ?: camManager.cameraIdList.firstOrNull { it != camId }
    } catch (e: Throwable) { Log.e(TAG, "otherCamera", e); null }

    private fun startCamThread(): Handler {
        val t = HandlerThread("sybl-cam").apply { start() }
        camThread = t
        return Handler(t.looper).also { camHandler = it }
    }

    /** jami-android's getCameraDisplayRotation: combine fixed sensor orientation + live display rotation + facing. */
    private fun recomputeRotation() {
        val r = if (camFacing == CameraCharacteristics.LENS_FACING_FRONT)
            (sensorOrientation + displayDeg + 360) % 360
        else (sensorOrientation - displayDeg + 360) % 360
        capRotation = (360 - r) % 360
    }

    /** Open [cam] as attempt [generation]. camHandler-confined. Every callback re-checks the live
     *  generation and a stale one closes ONLY its own attempt's resources. Success is reported only
     *  after setRepeatingRequest succeeds; a later disconnect/error is a runtime capture loss. */
    @Suppress("MissingPermission")
    private fun openCamera(cam: String, generation: Long) {
        if (liveAttemptGen != generation) return
        currentAttempt?.close() // an OpenCamera decision always follows its CloseCamera; belt only
        val attempt = CameraAttempt(generation)
        currentAttempt = attempt
        try {
            val reader = ImageReader.newInstance(capW, capH, ImageFormat.YUV_420_888, 8)
            attempt.reader = reader
            reader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                val id = localInputId
                if (id != null && liveAttemptGen == generation) {
                    // Do NOT image.close(): the daemon JNI (videomanager.i) takes a global ref and closes the
                    // Image itself once the encoder is done. Closing here races into a double-free.
                    JamiService.captureVideoFrame(id, image, capRotation)
                } else image.close()
            }, camHandler)
            camManager.openCamera(cam, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    if (liveAttemptGen != generation || currentAttempt !== attempt) {
                        try { device.close() } catch (_: Throwable) {}
                        attempt.close()
                        return
                    }
                    attempt.device = device
                    val target = reader.surface
                    val req = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(target) }
                    device.createCaptureSession(listOf(target), object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            if (liveAttemptGen != generation || currentAttempt !== attempt) {
                                try { session.close() } catch (_: Throwable) {}
                                attempt.close()
                                return
                            }
                            attempt.session = session
                            val streaming = try {
                                session.setRepeatingRequest(req.build(), null, camHandler)
                                true
                            } catch (e: Throwable) {
                                Log.e(TAG, "setRepeatingRequest", e)
                                false
                            }
                            if (streaming) Log.i(TAG, "camera streaming ${capW}x$capH rot=$capRotation gen=$generation")
                            else attempt.close()
                            executeVideoDecisions(transitionVideo {
                                LocalVideoPolicy.openResult(it, generation, ok = streaming)
                            })
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.e(TAG, "cam session configure failed gen=$generation")
                            try { session.close() } catch (_: Throwable) {}
                            attempt.close()
                            executeVideoDecisions(transitionVideo {
                                LocalVideoPolicy.openResult(it, generation, ok = false)
                            })
                        }
                    }, camHandler)
                }
                override fun onDisconnected(device: CameraDevice) {
                    Log.e(TAG, "camera disconnected gen=$generation")
                    try { device.close() } catch (_: Throwable) {}
                    attempt.close()
                    executeVideoDecisions(transitionVideo {
                        LocalVideoPolicy.openResult(it, generation, ok = false)
                    })
                }
                override fun onError(device: CameraDevice, error: Int) {
                    Log.e(TAG, "camera error $error gen=$generation")
                    try { device.close() } catch (_: Throwable) {}
                    attempt.close()
                    executeVideoDecisions(transitionVideo {
                        LocalVideoPolicy.openResult(it, generation, ok = false)
                    })
                }
            }, camHandler)
        } catch (e: Throwable) {
            Log.e(TAG, "openCamera", e)
            attempt.close()
            if (currentAttempt === attempt) currentAttempt = null
            executeVideoDecisions(transitionVideo { LocalVideoPolicy.openResult(it, generation, ok = false) })
        }
    }

    private fun openProjection(lease: VideoLease, generation: Long) {
        if (liveAttemptGen != generation || lease.kind != LocalVideoKind.SCREEN) return
        // Duplicate StartCapture never spends the one-shot consent twice. A StopCapture/StartCapture
        // reinitialization is handled in LocalVideoPolicy by parking this exact attempt.
        currentProjectionAttempt?.let {
            if (it.generation == generation && it.epoch == lease.epoch && it.display != null) return
        }
        val consent = synchronized(callLifecycleLock) {
            projectionConsents.remove(lease.epoch)
        } ?: run {
            executeVideoDecisions(transitionVideo {
                LocalVideoPolicy.openResult(it, generation, ok = false)
            })
            return
        }
        // Encoder dimensions must be even; a VirtualDisplay scales the mirror to whatever size we ask for,
        // so rounding here keeps captured == encoded == sent rather than cropping the geometry.
        val encW = consent.width and 1.inv()
        val encH = consent.height and 1.inv()
        val rawConferenceFrames = GroupCallWire.screenShareNeedsRawFrames(
            activeGroupConferenceId.orEmpty(),
            activeGroupHosting,
        )
        val mime = if (rawConferenceFrames) "" else screenMime(consent.callId) ?: run {
            executeVideoDecisions(transitionVideo {
                LocalVideoPolicy.openResult(it, generation, ok = false)
            })
            rollbackProjectionFailure(lease.epoch)
            return
        }
        val attempt = ProjectionAttempt(
            consent.callId,
            generation,
            lease.epoch,
            mime,
            encW,
            encH,
            consent.densityDpi,
            if (Build.VERSION.SDK_INT >= 34) 0 else consent.width,
            if (Build.VERSION.SDK_INT >= 34) 0 else consent.height,
            rawConferenceFrames,
        )
        currentProjectionAttempt?.let {
            retireProjectionPreview(it)
            it.close()
        }
        currentProjectionAttempt = attempt
        try {
            val encoder = if (attempt.rawConferenceFrames) null else openScreenEncoder(attempt, encW, encH)
            if (!attempt.rawConferenceFrames && encoder == null) {
                throw IllegalStateException("no ${attempt.mime} encoder for ${encW}x$encH")
            }
            attempt.encoder = encoder
            if (encoder != null) {
                attempt.width = encoder.width
                attempt.height = encoder.height
            }
            val conferenceReader = if (attempt.rawConferenceFrames) {
                openConferenceReader(attempt, attempt.width, attempt.height).also {
                    attempt.conferenceReader = it
                }
            } else null
            val manager = appContext.getSystemService(
                Context.MEDIA_PROJECTION_SERVICE,
            ) as MediaProjectionManager
            val projection = manager.getMediaProjection(consent.resultCode, consent.data)
                ?: throw IllegalStateException("MediaProjection unavailable")
            attempt.projection = projection
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    (camHandler ?: startCamThread()).post {
                        failProjectionAttempt(attempt, restorePreviousCamera = false)
                    }
                }

                override fun onCapturedContentResize(width: Int, height: Int) {
                    (camHandler ?: startCamThread()).post {
                        resizeProjectionAttempt(attempt, width, height, attempt.densityDpi)
                    }
                }
            }, camHandler)
            attempt.display = projection.createVirtualDisplay(
                "Doorlight screen",
                attempt.width,
                attempt.height,
                consent.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                conferenceReader?.surface ?: encoder?.input,
                null,
                camHandler,
            ) ?: throw IllegalStateException("VirtualDisplay unavailable")
            publishProjectionGeometry(attempt)
            emitOutgoingVideoSnapshot()
            if (!attempt.rawConferenceFrames) prepareProjectionPreview(attempt)
            scheduleProjectionStartupTimeout(attempt)
        } catch (e: Throwable) {
            Log.e(TAG, "openProjection", e)
            failProjectionAttempt(attempt, restorePreviousCamera = true)
        }
    }

    /** Request the existing Flutter self texture without creating another
     * MediaProjection or VirtualDisplay. The callback returns to camHandler. */
    private fun prepareProjectionPreview(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt || attempt.preview != null) return
        main.post {
            val binder = videoBinder ?: return@post
            binder.prepareProjectionPreview(attempt.width, attempt.height) { surface ->
                (camHandler ?: startCamThread()).post {
                    if (currentProjectionAttempt !== attempt) return@post
                    attempt.previewSurface = surface?.takeIf { it.isValid }
                    openProjectionPreviewIfReady(attempt)
                }
            }
        }
    }

    private fun openProjectionPreviewIfReady(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt || attempt.preview != null) return
        val surface = attempt.previewSurface ?: return
        val format = attempt.previewFormat ?: return
        val preview = ScreenPreviewDecoder.open(
            attempt.mime,
            attempt.width,
            attempt.height,
            format,
            surface,
        ) ?: return
        attempt.preview = preview
        requestScreenKeyFrame(attempt)
    }

    /** Jami's local conference mixer consumes raw frames. A direct VirtualDisplay reader avoids
     * the vendor-private decoder output that Android ImageReader cannot expose to the CPU. */
    private fun openConferenceReader(
        attempt: ProjectionAttempt,
        width: Int,
        height: Int,
    ): ImageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3).also { reader ->
        reader.setOnImageAvailableListener({ source ->
            val image = try { source.acquireLatestImage() } catch (e: Throwable) {
                Log.e(TAG, "conference screen frame", e)
                null
            } ?: return@setOnImageAvailableListener
            if (attempt.conferenceReader !== source || !projectionFrameIsLive(attempt)) {
                image.close()
                return@setOnImageAvailableListener
            }
            try {
                JamiService.captureVideoFrame(SCREEN_MRL, image, 0)
                markProjectionPacketPublished(attempt)
            } catch (e: Throwable) {
                image.close()
                Log.e(TAG, "publish conference screen frame", e)
            }
        }, camHandler)
    }

    private fun markProjectionPreviewFrameRendered(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt ||
            attempt.preview == null ||
            attempt.previewActive) return
        attempt.previewActive = true
        emit(
            mapOf(
                "type" to "video",
                "accountId" to (accountId ?: ""),
                "callId" to attempt.callId,
                "role" to "self",
                "active" to true,
                "width" to attempt.width,
                "height" to attempt.height,
            ),
        )
    }

    private fun retireProjectionPreview(attempt: ProjectionAttempt) {
        attempt.preview?.close()
        attempt.preview = null
        attempt.previewSurface = null
        attempt.previewFormat = null
        if (!attempt.previewActive) return
        attempt.previewActive = false
        emit(
            mapOf(
                "type" to "video",
                "accountId" to (accountId ?: ""),
                "callId" to attempt.callId,
                "role" to "self",
                "active" to false,
            ),
        )
    }

    /** The daemon passes our packets through untouched, so a known negotiated codec is mandatory.
     *  Empty means negotiation has not published a codec yet and uses the daemon's AVC default;
     *  lookup failure or a nonempty unknown value fails closed rather than mislabeling AVC bytes. */
    private fun screenMime(callId: String): String? {
        val acc = accountId ?: return null
        val negotiated = try {
            JamiService.getCallDetails(acc, callId).toNative()["VIDEO_CODEC"].orEmpty()
        } catch (e: Throwable) {
            Log.e(TAG, "screenMime($callId)", e)
            return null
        }
        val mime = when (negotiated) {
            "" -> MediaFormat.MIMETYPE_VIDEO_AVC
            "H264" -> MediaFormat.MIMETYPE_VIDEO_AVC
            "H265" -> MediaFormat.MIMETYPE_VIDEO_HEVC
            "VP8" -> MediaFormat.MIMETYPE_VIDEO_VP8
            "VP9" -> MediaFormat.MIMETYPE_VIDEO_VP9
            "MP4V-ES" -> MediaFormat.MIMETYPE_VIDEO_MPEG4
            "H263-1998" -> MediaFormat.MIMETYPE_VIDEO_H263
            else -> null
        }
        if (mime == null) {
            Log.e(TAG, "unsupported negotiated screen codec")
        } else {
            Log.i(TAG, "screen encoder: negotiated='$negotiated' mime=$mime")
        }
        return mime
    }

    /** Try complete encoder creation at progressively smaller sizes. Discovery is not acceptance:
     *  a vendor codec that advertises a size but rejects configure/start is retried smaller too. */
    private fun openScreenEncoder(
        attempt: ProjectionAttempt,
        width: Int,
        height: Int,
    ): ScreenEncoder? {
        var w = (width and 1.inv()).coerceAtLeast(2)
        var h = (height and 1.inv()).coerceAtLeast(2)
        while (true) {
            tryOpenScreenEncoder(attempt, w, h)?.let { return it }
            if (minOf(w, h) <= 240) return null
            val nextW = ((w / 2) and 1.inv()).coerceAtLeast(2)
            val nextH = ((h / 2) and 1.inv()).coerceAtLeast(2)
            if (nextW == w && nextH == h || minOf(nextW, nextH) < 240) return null
            w = nextW
            h = nextH
        }
    }

    private fun tryOpenScreenEncoder(
        attempt: ProjectionAttempt,
        width: Int,
        height: Int,
    ): ScreenEncoder? {
        var candidate: ScreenEncoder? = null
        try {
            val format = MediaFormat.createVideoFormat(attempt.mime, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, SCREEN_BITRATE_BPS)
                setInteger(MediaFormat.KEY_FRAME_RATE, SCREEN_FPS)
                // A still screen produces no new frames; without this the peer's picture just freezes.
                setInteger(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000 / SCREEN_FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
            }
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
                ?: return null
            val codec = MediaCodec.createByCodecName(name)
            candidate = ScreenEncoder(codec, width, height)
            codec.setCallback(screenEncoderCallback(attempt, candidate), camHandler)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            candidate.input = codec.createInputSurface()
            codec.start()
            return candidate
        } catch (e: Throwable) {
            Log.e(TAG, "screen encoder rejected ${width}x$height", e)
            candidate?.close()
            return null
        }
    }

    private fun screenEncoderCallback(
        attempt: ProjectionAttempt,
        encoder: ScreenEncoder,
    ): MediaCodec.Callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) {}

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            Log.e(TAG, "screen encoder error", e)
            // Return from the codec callback before releasing the codec itself.
            (camHandler ?: startCamThread()).post {
                if (attempt.encoder === encoder && c === encoder.codec) {
                    failProjectionAttempt(attempt, restorePreviousCamera = true)
                }
            }
        }

        override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {
            if (attempt.encoder !== encoder || c !== encoder.codec) return
            attempt.previewFormat = f
            openProjectionPreviewIfReady(attempt)
            // Some codecs expose initialization data only in the output format instead of a
            // BUFFER_FLAG_CODEC_CONFIG buffer. Preserve every standard CSD block in order so the
            // next recovery frame remains independently decodable across vendor implementations.
            try {
                val blocks = (0..2).mapNotNull { index ->
                    f.getByteBuffer("csd-$index")?.duplicate()?.takeIf { it.hasRemaining() }
                }
                val total = blocks.sumOf { it.remaining() }
                if (total > 0) {
                    encoder.codecData = ByteBuffer.allocateDirect(total).apply {
                        blocks.forEach { put(it) }
                        rewind()
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "screen codec config", e)
            }
        }

        override fun onOutputBufferAvailable(
            c: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo,
        ) {
            var packetFailure: Throwable? = null
            try {
                if (attempt.encoder !== encoder || c !== encoder.codec) return
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                val buffer = c.getOutputBuffer(index) ?: return
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    encoder.codecData = ByteBuffer.allocateDirect(info.size).apply {
                        put(buffer)
                        rewind()
                    }
                } else if (projectionPacketIsLive(attempt, encoder)) {
                    val keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    if (keyframe) {
                        encoder.codecData?.let { config ->
                            JamiService.captureVideoPacket(
                                SCREEN_MRL,
                                config,
                                config.capacity(),
                                0,
                                false,
                                info.presentationTimeUs,
                                0,
                            )
                        }
                    }
                    JamiService.captureVideoPacket(
                        SCREEN_MRL,
                        buffer,
                        info.size,
                        info.offset,
                        keyframe,
                        info.presentationTimeUs,
                        0,
                    )
                    attempt.preview?.let { preview ->
                        try {
                            if (preview.offer(buffer, info)) {
                                markProjectionPreviewFrameRendered(attempt)
                            }
                        } catch (e: Throwable) {
                            Log.e(TAG, "screen preview packet", e)
                            retireProjectionPreview(attempt)
                        }
                    }
                    encoder.firstPacketPublished = true
                    markProjectionPacketPublished(attempt)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "screen packet", e)
                packetFailure = e
            } finally {
                try { c.releaseOutputBuffer(index, false) } catch (_: Throwable) {}
            }
            if (packetFailure != null) {
                (camHandler ?: startCamThread()).post {
                    if (attempt.encoder === encoder) {
                        failProjectionAttempt(attempt, restorePreviousCamera = true)
                    }
                }
            }
        }
    }

    private fun projectionPacketIsLive(
        attempt: ProjectionAttempt,
        encoder: ScreenEncoder,
    ): Boolean = attempt.encoder === encoder && projectionFrameIsLive(attempt)

    private fun projectionFrameIsLive(attempt: ProjectionAttempt): Boolean =
        currentProjectionAttempt === attempt &&
            liveAttemptGen == attempt.generation &&
            localInputId == SCREEN_MRL &&
            synchronized(callLifecycleLock) {
            val lease = videoPhase.currentLease()
            lease?.epoch == attempt.epoch &&
                lease.kind == LocalVideoKind.SCREEN &&
                lease.captureDemanded
        }

    private fun markProjectionPacketPublished(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt) return
        if (attempt.firstPacketPublished) {
            if ((attempt.rawConferenceFrames || attempt.encoder?.firstPacketPublished == true) &&
                remoteControlAttemptGeneration != attempt.generation) {
                activateRemoteControlSource(attempt)
                emitOutgoingVideoSnapshot()
            }
            return
        }
        attempt.firstPacketPublished = true
        executeVideoDecisions(transitionVideo {
            LocalVideoPolicy.openResult(it, attempt.generation, ok = true)
        })
        publishProjectionGeometry(attempt)
        activateRemoteControlSource(attempt)
        synchronized(callLifecycleLock) {
            projectionRollbacks.remove(attempt.epoch)
        }
        emitOutgoingVideoSnapshot()
    }

    private fun scheduleProjectionStartupTimeout(attempt: ProjectionAttempt) {
        (camHandler ?: startCamThread()).postDelayed({
            if (currentProjectionAttempt !== attempt ||
                attempt.firstPacketPublished) {
                return@postDelayed
            }
            if (!projectionCaptureDemanded(attempt)) {
                return@postDelayed
            }
            Log.e(TAG, "screen capture produced no frame")
            failProjectionAttempt(attempt, restorePreviousCamera = true)
        }, SCREEN_START_TIMEOUT_MS)
    }

    private fun projectionCaptureDemanded(attempt: ProjectionAttempt): Boolean =
        synchronized(callLifecycleLock) {
            val lease = videoPhase.currentLease()
            lease?.epoch == attempt.epoch &&
                lease.kind == LocalVideoKind.SCREEN &&
                lease.captureDemanded
        }

    private fun publishProjectionGeometry(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt) return
        executeVideoDecisions(transitionVideo {
            LocalVideoPolicy.resize(it, attempt.epoch, attempt.width, attempt.height)
        })
    }

    /** camHandler-confined exact-attempt failure. Runtime failures have no rollback entry after
     *  first packet; startup failures can restore the previous camera intent. */
    private fun failProjectionAttempt(
        attempt: ProjectionAttempt,
        restorePreviousCamera: Boolean,
    ) {
        if (currentProjectionAttempt !== attempt ||
            liveAttemptGen != attempt.generation) {
            return
        }
        retireProjectionPreview(attempt)
        currentProjectionAttempt = null
        attempt.close()
        executeVideoDecisions(transitionVideo {
            LocalVideoPolicy.openResult(it, attempt.generation, ok = false)
        })
        if (restorePreviousCamera) {
            rollbackProjectionFailure(attempt.epoch)
        } else {
            synchronized(callLifecycleLock) {
                projectionRollbacks.remove(attempt.epoch)
            }
        }
    }

    // ---- daemon encoder control (screen path only: the camera path hands the daemon raw frames,
    //      so the daemon owns that encoder itself and these callbacks have no camera meaning) ----

    private fun requestScreenKeyFrame(attempt: ProjectionAttempt) {
        val codec = attempt.encoder?.codec ?: return
        try {
            codec.setParameters(
                Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) },
            )
            if (attempt.encoder?.firstPacketPublished == false) {
                scheduleProjectionStartupTimeout(attempt)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "requestKeyFrame", e)
        }
    }

    internal fun onRequestKeyFrame(device: String) {
        if (device != SCREEN_DEVICE_ID && device != SCREEN_MRL) return
        (camHandler ?: return).post {
            val attempt = currentProjectionAttempt ?: return@post
            requestScreenKeyFrame(attempt)
        }
    }

    internal fun onSetBitrate(device: String, bitrate: Int) {
        if (device != SCREEN_DEVICE_ID && device != SCREEN_MRL) return
        if (bitrate <= 0) return
        (camHandler ?: return).post {
            val codec = currentProjectionAttempt?.encoder?.codec ?: return@post
            try {
                // The daemon sends kbit/s — same convention jami-client-android multiplies by 1024.
                val bitsPerSecond = bitrate.coerceAtMost(Int.MAX_VALUE / 1024) * 1024
                codec.setParameters(
                    Bundle().apply {
                        putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitsPerSecond)
                    },
                )
            } catch (e: Throwable) {
                Log.e(TAG, "setBitrate", e)
            }
        }
    }

    private fun emitOutgoingVideoSnapshot() {
        reconcileRemoteControlSource()
        val snapshot = outgoingVideo
        if (snapshot.callId.isEmpty()) return
        emit(
            mapOf(
                "type" to "outgoingVideoSource",
                "accountId" to (accountId ?: ""),
                "callId" to snapshot.callId,
                "cameraOn" to (snapshot.kind == LocalVideoKind.CAMERA),
                "outgoingVideoKind" to when (snapshot.kind) {
                    LocalVideoKind.CAMERA -> "camera"
                    LocalVideoKind.SCREEN -> "screen"
                    null -> "off"
                },
                "outgoingVideoUri" to snapshot.uri,
                "outgoingVideoRevision" to snapshot.epoch,
                "remoteControlSourceRevision" to remoteControlSourceRevision,
                "outgoingVideoWidth" to snapshot.width,
                "outgoingVideoHeight" to snapshot.height,
            ),
        )
    }

    internal fun updateRemoteControlDisplayGeometry(
        width: Int,
        height: Int,
        safeBounds: Rect,
    ) {
        val next = if (width <= 0 || height <= 0 ||
            safeBounds.left < 0 || safeBounds.top < 0 ||
            safeBounds.right > width || safeBounds.bottom > height ||
            safeBounds.width() <= 0 || safeBounds.height() <= 0
        ) {
            RemoteControlDisplayGeometry()
        } else {
            RemoteControlDisplayGeometry(
                width,
                height,
                safeBounds.left,
                safeBounds.top,
                safeBounds.right,
                safeBounds.bottom,
            )
        }
        val changed = remoteControlDisplayGeometry != next
        remoteControlDisplayGeometry = next
        if (changed && sharingScreen) {
            retireRemoteControlSource()
            currentProjectionAttempt?.let(::activateRemoteControlSource)
            emitOutgoingVideoSnapshot()
        }
    }

    private fun projectionOwnsFullDisplay(attempt: ProjectionAttempt): Boolean {
        val geometry = remoteControlDisplayGeometry
        return AndroidRemoteControlPolicy.ownsFullDisplay(
            attempt.capturedContentWidth,
            attempt.capturedContentHeight,
            geometry.width,
            geometry.height,
        )
    }

    internal fun remoteControlAuthorityCurrent(binding: AndroidRemoteControlBinding): Boolean =
        synchronized(callLifecycleLock) {
            !identityRestoreCommitting && pendingIdentityRestore == null && !identityRestoreRecoveryFailed &&
            RemoteControlAuthority.current(
                binding, accountId, activeCallId, currentWinnerCallId,
                callPeers[binding.callId], recentTerminalCallIds.contains(binding.callId),
                routingSnapshot,
            )
        }

    internal fun remoteHelpPeerName(binding: AndroidRemoteControlBinding): String {
        if (!remoteControlAuthorityCurrent(binding)) return "Your friend"
        val name = readPeerProfile(
            cachedPeerProfile(binding.localAccount, binding.controllerAccount),
        )?.displayName.orEmpty()
        return if (remoteControlAuthorityCurrent(binding) && name.isNotBlank()) name
        else "Your friend"
    }

    private data class VerifiedRemoteAuthority(
        val binding: AndroidRemoteControlBinding,
        val account: NativeAccountScope,
        val trust: CallMessageScope,
    )
    private val remoteAuthorityLease = NativeAuthorityLease<VerifiedRemoteAuthority>(SystemClock::elapsedRealtime)
    private val remoteAuthorityRefreshPending = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Worker query at local consent and bounded refresh, never during OS submission. */
    internal fun revalidateRemoteControlBinding(binding: AndroidRemoteControlBinding): Boolean {
        val started = SystemClock.elapsedRealtime()
        val owner = captureAccountScope(binding.localAccount) ?: return false
        val trust = captureCallMessage(binding.callId) ?: return false
        if (!remoteControlAuthorityCurrent(binding)) return false
        val details = try {
            JamiService.getCallDetails(binding.localAccount, binding.callId).toNative()
        } catch (_: Throwable) {
            remoteAuthorityLease.clear()
            return false
        }
        if (!RemoteControlAuthority.authenticated(binding, details) ||
            !accountAuthority.owns(owner) || !callMessageAuthority.current(trust) ||
            !remoteControlAuthorityCurrent(binding) ||
            remoteControlSource()?.let(AndroidRemoteControlHost::sourceIdentity) != binding.source) {
            remoteAuthorityLease.clear()
            return false
        }
        return remoteAuthorityLease.publish(VerifiedRemoteAuthority(binding, owner, trust), started)
    }

    internal fun remoteControlLeaseCurrent(binding: AndroidRemoteControlBinding): Boolean {
        val verified = remoteAuthorityLease.current()
        val current = verified?.binding == binding && accountAuthority.owns(verified.account) &&
            callMessageAuthority.current(verified.trust) && remoteControlAuthorityCurrent(binding)
        if (current && remoteAuthorityLease.refreshDue() &&
            remoteAuthorityRefreshPending.compareAndSet(false, true)) {
            try {
                worker.execute(DaemonOperation.READ_PEER) {
                    try { revalidateRemoteControlBinding(binding) }
                    finally { remoteAuthorityRefreshPending.set(false) }
                }
            } catch (_: Throwable) { remoteAuthorityRefreshPending.set(false) }
        }
        return current
    }

    internal fun remoteControlSource(): AndroidRemoteControlHost.Source? {
        val source = outgoingVideo
        val attempt = currentProjectionAttempt ?: return null
        val revision = remoteControlSourceRevision
        val geometry = remoteControlDisplayGeometry
        val displayWidth = geometry.width
        val displayHeight = geometry.height
        val safe = geometry.safeBounds()
        val authoritative = synchronized(callLifecycleLock) {
            source.kind == LocalVideoKind.SCREEN &&
                source.callId.isNotEmpty() &&
                activeCallId == source.callId &&
                currentWinnerCallId == source.callId &&
                !recentTerminalCallIds.contains(source.callId) &&
                attempt.firstPacketPublished &&
                projectionOwnsFullDisplay(attempt) &&
                attempt.generation == remoteControlAttemptGeneration &&
                revision > 0
        }
        if (!authoritative ||
            attempt.encoder?.firstPacketPublished != true ||
            attempt.width <= 0 || attempt.height <= 0 ||
            displayWidth <= 0 || displayHeight <= 0 ||
            safe.width() <= 0 || safe.height() <= 0) {
            return null
        }
        // The projection is constrained to the default display. Until the
        // encoder and display agree on orientation, the coordinate origin is
        // ambiguous and control remains unavailable.
        val sameOrientation =
            (attempt.width >= attempt.height) == (displayWidth >= displayHeight)
        if (!sameOrientation) return null
        return AndroidRemoteControlHost.Source(
            callId = source.callId,
            revision = revision,
            frameWidth = attempt.width,
            frameHeight = attempt.height,
            displayWidth = displayWidth,
            displayHeight = displayHeight,
            safeBounds = safe,
            rotation = displayDeg,
        )
    }

    private fun activateRemoteControlSource(attempt: ProjectionAttempt) {
        if (currentProjectionAttempt !== attempt ||
            !attempt.firstPacketPublished ||
            attempt.encoder?.firstPacketPublished != true ||
            !projectionOwnsFullDisplay(attempt) ||
            !AndroidRemoteControlPolicy.needsSourceActivation(
                remoteControlAttemptGeneration,
                remoteControlSourceRevision,
                attempt.generation,
            )) {
            return
        }
        remoteControlAttemptGeneration = attempt.generation
        remoteControlSourceRevision = attempt.epoch
        AndroidRemoteControlHost.onSourceChanged()
    }

    private fun retireRemoteControlSource() {
        remoteControlSourceRevision = 0L
        remoteControlAttemptGeneration = -1L
        AndroidRemoteControlHost.onSourceChanged()
    }

    private fun reconcileRemoteControlSource() {
        val attempt = currentProjectionAttempt
        val source = outgoingVideo
        val keep = attempt != null &&
            attempt.firstPacketPublished &&
            projectionOwnsFullDisplay(attempt) &&
            source.kind == LocalVideoKind.SCREEN &&
            source.callId.isNotEmpty() &&
            attempt.generation == remoteControlAttemptGeneration
        if (keep) return
        if (remoteControlSourceRevision != 0L ||
            remoteControlAttemptGeneration != -1L) {
            retireRemoteControlSource()
        }
    }

    fun resizeScreenShare(width: Int, height: Int, densityDpi: Int) {
        if (width <= 0 || height <= 0 || !sharingScreen) return
        // Android 14's projection callback reports the selected display/app bounds. The Activity's
        // own resources can describe a different window and must not overwrite that authority.
        if (Build.VERSION.SDK_INT >= 34) return
        (camHandler ?: startCamThread()).post {
            val attempt = currentProjectionAttempt ?: return@post
            resizeProjectionAttempt(attempt, width, height, densityDpi)
        }
    }

    /** Replace an encoder surface without publishing partial ownership. A concurrent candidate is
     *  preferred; devices with a one-encoder limit retry after retiring the old encoder and fail
     *  closed if the destructive retry cannot attach. camHandler-confined. */
    private fun resizeProjectionAttempt(
        attempt: ProjectionAttempt,
        width: Int,
        height: Int,
        densityDpi: Int,
    ) {
        if (width <= 0 || height <= 0 ||
            currentProjectionAttempt !== attempt ||
            liveAttemptGen != attempt.generation) {
            return
        }
        val geometry = remoteControlDisplayGeometry
        Log.i(
            TAG,
            "projection content=${width}x$height display=${geometry.width}x${geometry.height} " +
                "fullDisplay=${AndroidRemoteControlPolicy.ownsFullDisplay(
                    width,
                    height,
                    geometry.width,
                    geometry.height,
                )}",
        )
        val encW = (width and 1.inv()).coerceAtLeast(2)
        val encH = (height and 1.inv()).coerceAtLeast(2)
        val display = attempt.display ?: return
        val contentChanged =
            attempt.capturedContentWidth != width ||
                attempt.capturedContentHeight != height
        if (contentChanged) {
            attempt.capturedContentWidth = 0
            attempt.capturedContentHeight = 0
            retireRemoteControlSource()
        }
        if (attempt.rawConferenceFrames) {
            val oldReader = attempt.conferenceReader ?: return
            if (attempt.width == encW && attempt.height == encH &&
                attempt.densityDpi == densityDpi) {
                attempt.capturedContentWidth = width
                attempt.capturedContentHeight = height
                activateRemoteControlSource(attempt)
                emitOutgoingVideoSnapshot()
                return
            }
            val candidate = try {
                openConferenceReader(attempt, encW, encH)
            } catch (e: Throwable) {
                Log.e(TAG, "resizeScreenShare raw reader", e)
                failProjectionAttempt(attempt, restorePreviousCamera = true)
                return
            }
            attempt.conferenceReader = candidate
            try {
                display.resize(encW, encH, densityDpi)
                display.setSurface(candidate.surface)
            } catch (e: Throwable) {
                Log.e(TAG, "resizeScreenShare raw display swap", e)
                attempt.conferenceReader = oldReader
                candidate.close()
                failProjectionAttempt(attempt, restorePreviousCamera = true)
                return
            }
            attempt.width = encW
            attempt.height = encH
            attempt.densityDpi = densityDpi
            attempt.capturedContentWidth = width
            attempt.capturedContentHeight = height
            publishProjectionGeometry(attempt)
            emitOutgoingVideoSnapshot()
            oldReader.close()
            return
        }

        val old = attempt.encoder ?: return
        if (old.width == encW && old.height == encH && attempt.densityDpi == densityDpi) {
            attempt.capturedContentWidth = width
            attempt.capturedContentHeight = height
            activateRemoteControlSource(attempt)
            emitOutgoingVideoSnapshot()
            return
        }

        attempt.capturedContentWidth = 0
        attempt.capturedContentHeight = 0
        retireRemoteControlSource()
        var candidate = openScreenEncoder(attempt, encW, encH)
        var oldRetired = false
        if (candidate == null) {
            // Hardware codecs commonly allow only one live instance. Detach first, then retry all
            // sizes once without the old encoder consuming that resource.
            try {
                display.setSurface(null)
            } catch (e: Throwable) {
                Log.e(TAG, "detach screen encoder for resize", e)
                failProjectionAttempt(attempt, restorePreviousCamera = true)
                return
            }
            attempt.encoder = null
            old.close()
            oldRetired = true
            candidate = openScreenEncoder(attempt, encW, encH)
            if (candidate == null) {
                Log.e(TAG, "resizeScreenShare: no ${attempt.mime} encoder for ${encW}x$encH")
                failProjectionAttempt(attempt, restorePreviousCamera = true)
                return
            }
        }

        try {
            // Geometry replacement retires control before the display surface
            // changes. The new coordinate revision is published only after its
            // replacement encoder produces an actual packet.
            // VirtualDisplay applies the new logical size before the fixed-size encoder surface.
            display.resize(candidate.width, candidate.height, densityDpi)
            display.setSurface(candidate.input)
        } catch (e: Throwable) {
            Log.e(TAG, "resizeScreenShare display swap", e)
            candidate.close()
            if (!oldRetired) {
                val restored = try {
                    display.resize(old.width, old.height, attempt.densityDpi)
                    display.setSurface(old.input)
                    true
                } catch (restoreError: Throwable) {
                    Log.e(TAG, "resizeScreenShare rollback", restoreError)
                    false
                }
                if (restored) {
                    activateRemoteControlSource(attempt)
                    emitOutgoingVideoSnapshot()
                    return
                }
            }
            failProjectionAttempt(attempt, restorePreviousCamera = true)
            return
        }

        retireProjectionPreview(attempt)
        attempt.encoder = candidate
        attempt.width = candidate.width
        attempt.height = candidate.height
        attempt.densityDpi = densityDpi
        attempt.capturedContentWidth = width
        attempt.capturedContentHeight = height
        publishProjectionGeometry(attempt)
        emitOutgoingVideoSnapshot()
        if (!oldRetired) old.close()
        prepareProjectionPreview(attempt)
        requestScreenKeyFrame(attempt)
    }

    /** Close the resources of exactly [generation]; a newer attempt is never touched. camHandler-confined. */
    private fun closeAttempt(generation: Long) {
        currentAttempt?.takeIf { it.generation == generation }?.let {
            it.close()
            if (currentAttempt === it) currentAttempt = null
        }
        currentProjectionAttempt?.takeIf { it.generation == generation }?.let {
            retireProjectionPreview(it)
            it.close()
            if (currentProjectionAttempt === it) currentProjectionAttempt = null
        }
    }

    // ---- VideoCallback forwarders (daemon thread → JamiCore; sink-id routing lives here) ----

    internal fun onGetCameraInfo(device: String, sizes: UintVect, rates: UintVect) {
        if (device == SCREEN_DEVICE_ID) {
            val snapshot = outgoingVideo
            val width = snapshot.width.takeIf { it > 0 } ?: 1280
            val height = snapshot.height.takeIf { it > 0 } ?: 720
            capW = width
            capH = height
            sizes.add(width.toLong())
            sizes.add(height.toLong())
            rates.add(24L)
            return
        }
        try {
            val cc = camManager.getCameraCharacteristics(device)
            val map = cc.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val out = map?.getOutputSizes(ImageFormat.YUV_420_888) ?: arrayOf(Size(1280, 720))
            val chosen = out.filter { it.width <= 1280 && it.height <= 720 }
                .maxByOrNull { it.width * it.height } ?: out.minByOrNull { it.width * it.height }!!
            capW = chosen.width; capH = chosen.height
            sensorOrientation = cc.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            recomputeRotation()
            sizes.add(chosen.width.toLong()); sizes.add(chosen.height.toLong()); rates.add(30L)
            Log.i(TAG, "getCameraInfo($device) -> ${chosen.width}x${chosen.height} sensor=$sensorOrientation rot=$capRotation")
        } catch (e: Throwable) { Log.e(TAG, "getCameraInfo", e) }
    }

    internal fun onSetParameters(width: Int, height: Int) {
        if (width > 0 && height > 0) { capW = width; capH = height }
    }

    /** Daemon demand for frames ([cam] = the REGISTERED device id, stable across physical flips).
     *  The coordinator opens only when the camera-typed FGS is confirmed; a demand that outlives the
     *  lease (terminal/userStop/foreign device) is discarded. */
    internal fun onStartCapture(cam: String) {
        Log.i(TAG, "startCapture($cam)")
        recomputeRotation()
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.startCapture(it, cam, nextVideoSeq()) })
    }

    /** Daemon withdrew its demand. Staleness is keyed on the REGISTERED device id (a physical flip
     *  never changes it), so a genuine post-flip stop still closes and a foreign stop is ignored. */
    internal fun onStopCapture(camid: String) {
        executeVideoDecisions(transitionVideo { LocalVideoPolicy.stopCapture(it, camid) })
    }

    /** THE central M2 routing: local input sink id == the lease's predicted "camera://<device>" → self;
     *  id == callId → remote. (Verified against the daemon: VideoInput names its sink after the
     *  input MRL, so the prediction and the daemon-created sink agree.) */
    internal fun onDecodingStarted(id: String, w: Int, h: Int) {
        synchronized(videoSinkSignalLock) {
            val mediaOwner = activeMediaTarget().orEmpty()
            val groupLeg = activeGroupConferenceId?.let(groupCallLegs::get).orEmpty()
            val role = when (id) {
                localInputId -> VideoRole.SELF
                else -> if (GroupCallWire.ownsMediaSink(mediaOwner, groupLeg, id)) {
                    VideoRole.REMOTE
                } else {
                    Log.w(TAG, "decodingStarted unknown sink '$id' (local=$localInputId call=$mediaOwner)")
                    return
                }
            }
            val callId = mediaOwner
            activeVideoSinks[id] = ActiveVideoSink(role, w, h, callId)
            Log.i(TAG, "decodingStarted($id) -> $role ${w}x$h")
            main.post { videoBinder?.bindSink(role, id, w, h) }
            emit(mapOf("type" to "video", "accountId" to (accountId ?: ""), "callId" to callId,
                "role" to role.name.lowercase(), "active" to true, "width" to w, "height" to h))
        }
    }

    internal fun onDecodingStopped(id: String) {
        synchronized(videoSinkSignalLock) {
            // Route robustly from the retained registration: stopVideo may already have cleared localInputId.
            val sink = activeVideoSinks.remove(id) ?: run {
                Log.w(TAG, "decodingStopped unknown sink '$id'")
                return
            }
            val role = sink.role
            // A source switch can start the replacement decoder before the old decoder reports stopped. Keep the
            // role active when another sink for the same call already owns it; otherwise that stale stop briefly
            // hides a healthy stream in Dart. MainActivity's exact-id unbind guard independently protects the native
            // window from the same callback ordering.
            val replacement = activeVideoSinks.values.firstOrNull {
                it.callId == sink.callId && it.role == role
            }
            Log.i(TAG, "decodingStopped($id) -> $role replacement=${replacement != null}")
            main.post { videoBinder?.unbindSink(role, id) }
            val event = mutableMapOf<String, Any>(
                "type" to "video",
                "accountId" to (accountId ?: ""),
                "callId" to sink.callId,
                "role" to role.name.lowercase(),
                "active" to (replacement != null),
            )
            if (replacement != null) {
                event["width"] = replacement.width
                event["height"] = replacement.height
            }
            emit(event)
        }
    }

    // ---- call-state → audio + foreground-service driving ----

    private data class RetiredGlareSibling(val callId: String, val wasIncoming: Boolean)

    private data class CurrentClaim(
        val authoritative: Boolean,
        val peerVideo: Boolean,
        val retired: List<RetiredGlareSibling>,
        val terminalAlreadySeen: Boolean = false,
    )

    /** Release the pre-CURRENT/global call owner only after its final native leg and retained ring are gone. */
    private fun clearCallReservationIfIdleLocked(peerId: String) {
        if (!canReleaseCallReservation(
                reservedCallPeerId, peerId, placingOutgoing, currentWinnerCallId,
                callPeers.values.any { it == peerId },
                incomingCalls.snapshot().values.any { it.fromJamiId == peerId },
            )) return
        reservedCallPeerId = null
    }

    /** Atomically admit the first CURRENT and tombstone every sibling already known at that boundary. IncomingCall
     * uses the same lock, so a ring either lands in this snapshot or observes the established winner and refuses
     * itself; there is no gap in which it can survive behind the connected call. */
    private fun claimCurrent(
        winnerCallId: String,
        winnerPeerId: String,
    ): CurrentClaim = synchronized(callLifecycleLock) {
        val pendingWinner = incomingCalls[winnerCallId]
        if (recentTerminalCallIds.contains(winnerCallId)) {
            // The terminal callback overtook an older CURRENT callback. Preserve the daemon's chronological winner
            // for any still-pending placement even though this stale CURRENT must never be emitted/adopted now.
            if (placingOutgoing && winnerCallIdDuringPlacement == null) winnerCallIdDuringPlacement = winnerCallId
            incomingCalls.remove(winnerCallId)
            return@synchronized CurrentClaim(false, false, emptyList(), terminalAlreadySeen = true)
        }
        callPeers[winnerCallId] = winnerPeerId
        if (currentWinnerCallId != winnerCallId && !directCallAllowed(accountId ?: "", winnerPeerId)) {
            rejectedCallIds.add(winnerCallId)
            incomingCalls.remove(winnerCallId)
            return@synchronized CurrentClaim(false, false, emptyList())
        }
        val established = currentWinnerCallId ?: if (placingOutgoing) winnerCallIdDuringPlacement else null
        if (rejectedCallIds.contains(winnerCallId) || (established != null && established != winnerCallId)) {
            rejectedCallIds.add(winnerCallId)
            incomingCalls.remove(winnerCallId)
            return@synchronized CurrentClaim(false, false, emptyList())
        }

        currentWinnerCallId = winnerCallId
        reservedCallPeerId = winnerPeerId
        activeCallId = winnerCallId
        if (placingOutgoing && winnerCallIdDuringPlacement == null) winnerCallIdDuringPlacement = winnerCallId
        incomingCalls.remove(winnerCallId)
        val retired = allSiblingCallIds(callPeers.toMap(), winnerCallId).map { siblingId ->
            val wasIncoming = incomingCalls.remove(siblingId) != null
            rejectedCallIds.add(siblingId) // tombstone until terminal; suppress/re-end a late CURRENT
            RetiredGlareSibling(siblingId, wasIncoming)
        }
        CurrentClaim(true, pendingWinner?.let { listHasActiveVideo(it.offer) } ?: false, retired)
    }

    private fun retireGlareSiblings(accountId: String, winnerCallId: String, retired: List<RetiredGlareSibling>) {
        if (retired.isEmpty()) return
        Log.i(TAG, "CURRENT winner $winnerCallId; retiring glare siblings ${retired.joinToString { it.callId }}")
        for (sibling in retired) {
            cancelIncomingCallNotification(sibling.callId)
            worker.execute(DaemonOperation.RETIRE_SIBLING, diagnosticCallToken(sibling.callId)) {
                try {
                    if (sibling.wasIncoming) JamiService.refuse(accountId, sibling.callId)
                    else JamiService.hangUp(accountId, sibling.callId)
                } catch (e: Throwable) {
                    Log.e(TAG, "retire glare sibling ${sibling.callId}", e)
                }
            }
        }
    }

    internal fun handleCallState(accountId: String, callId: String, state: String, code: Int, fromJamiId: String) {
        Log.i(TAG, "callState($callId) = $state code=$code")
        val pending = incomingCalls[callId]
        var peerVideo = pending?.let { listHasActiveVideo(it.offer) } ?: false
        // Audio routing + the foreground service must run on the main thread (this callback is on a daemon
        // thread). Marshaling here also makes CallAudioController single-threaded (setSpeaker is main too).
        when (state) {
            "CURRENT" -> {
                // A ring can reach CURRENT without any accept from us: on simultaneous placement the daemon
                // resolves glare by answering the crossed incoming leg itself (manager.cpp processIncomingCall).
                // Drop this call's ring ownership here too, or its ringtone notification outlives the answer.
                val claim = claimCurrent(callId, fromJamiId)
                cancelIncomingCallNotification(callId)
                if (!claim.authoritative) {
                    worker.execute(DaemonOperation.RETIRE_STALE_CURRENT, diagnosticCallToken(callId)) {
                        try { JamiService.hangUp(accountId, callId) }
                        catch (e: Throwable) {
                            val reason = if (claim.terminalAlreadySeen) "stale" else "second"
                            Log.e(TAG, "hangUp($reason CURRENT $callId)", e)
                        }
                    }
                    return
                }
                peerVideo = claim.peerVideo
                localInputId?.let { sinkId ->
                    activeVideoSinks.computeIfPresent(sinkId) { _, sink -> sink.copy(callId = callId) }
                }
                // Adjudicate the camera lease BEFORE retiring its owning sibling: PendingReplacement
                // is entered under the lifecycle lock, the exact-source query resolves on the worker,
                // and only then is that sibling refused/hung up — its terminal cannot revoke a lease
                // the winner may still adopt. Every other sibling retires immediately.
                val leaseOwner = synchronized(callLifecycleLock) {
                    videoPhase.currentLease()?.takeIf { it.ownerCallId != callId }?.ownerCallId
                }
                val deferred = if (leaseOwner != null) claim.retired.filter { it.callId == leaseOwner } else emptyList()
                val needsAdjudication = synchronized(callLifecycleLock) {
                    videoPhase.currentLease()?.let { it.ownerCallId != callId } ?: false
                }
                if (needsAdjudication) {
                    beginLeaseReplacement(accountId, callId) {
                        retireGlareSiblings(accountId, callId, deferred)
                    }
                } else if (deferred.isNotEmpty()) {
                    retireGlareSiblings(accountId, callId, deferred)
                }
                retireGlareSiblings(accountId, callId, claim.retired - deferred.toSet())
                if (micMuted) {
                    worker.execute(DaemonOperation.REAPPLY_MUTE, diagnosticCallToken(callId)) {
                        val shouldMute = synchronized(callLifecycleLock) {
                            activeCallId == callId && currentWinnerCallId == callId && micMuted
                        }
                        if (!shouldMute) return@execute
                        try { JamiService.muteLocalMedia(accountId, callId, "MEDIA_TYPE_AUDIO", true) }
                        catch (e: Throwable) { Log.e(TAG, "reapply mute to CURRENT $callId", e) }
                    }
                }
                main.post { startCallAudio(video = outgoingVideo.kind != null) }
            }
            "HUNGUP", "OVER", "FAILURE", "BUSY", "PEER_BUSY" -> {
                AndroidRemoteControlHost.onCallEnded(callId)
                incomingCalls.remove(callId)
                cancelIncomingCallNotification(callId)
                // Only tear down audio/video if THIS was the active call (dropped the M1 `|| activeCallId == null`
                // clause, which fired teardown for unrelated calls). A never-connected outgoing call started
                // nothing to tear down; the callState emit above still clears the Dart UI.
                var ownsActiveMedia = false
                synchronized(callLifecycleLock) {
                    if (callId == activeCallId) {
                        activeCallId = null
                        micMuted = false
                        ownsActiveMedia = true
                    }
                    if (callId == currentWinnerCallId) currentWinnerCallId = null
                    if (placingOutgoing) terminalDuringPlacement.add(callId)
                    videoEffectAuthority.remove(callId)
                }
                if (ownsActiveMedia) {
                    speakerOn = false
                    teardownVideo(callId)
                    postMainAfterCameraQueue {
                        if (activeCallId == null) stopCallAudio()
                    }
                } else {
                    // A terminal for a non-active leg still ends its own lease (e.g. a placement leg
                    // that died before ever becoming active); an unrelated call's terminal is inert.
                    executeVideoDecisions(transitionVideo { LocalVideoPolicy.terminal(it, callId) })
                }
            }
            // INACTIVE is transient during renegotiation — NOT terminal; leave the call up.
        }
        val selfActive = activeVideoSinks.values.any { it.callId == callId && it.role == VideoRole.SELF }
        val remoteActive = activeVideoSinks.values.any { it.callId == callId && it.role == VideoRole.REMOTE }
        val outgoing = outgoingVideo
        emit(mapOf("type" to "callState", "accountId" to accountId,
            "callId" to callId, "state" to state, "code" to code, "fromJamiId" to fromJamiId,
            "cameraOn" to cameraOn, "micMuted" to micMuted,
            "outgoingVideoKind" to when (outgoing.kind) {
                LocalVideoKind.CAMERA -> "camera"
                LocalVideoKind.SCREEN -> "screen"
                null -> "off"
            },
            "outgoingVideoUri" to outgoing.uri,
            "outgoingVideoRevision" to outgoing.epoch,
            "remoteControlSourceRevision" to remoteControlSourceRevision,
            "outgoingVideoWidth" to outgoing.width,
            "outgoingVideoHeight" to outgoing.height,
            "speakerOn" to speakerOn, "peerVideo" to peerVideo,
            "selfActive" to selfActive, "remoteActive" to remoteActive))
        if (shouldSurfacePendingIncomingCall(isTerminalCallState(state), activeCallId)) {
            surfacePendingIncomingCallIfIdle()
        }
        if (isTerminalCallState(state)) {
            val retiredPeer = callPeers.remove(callId)
            rejectedCallIds.remove(callId)
            if (retiredPeer != null) synchronized(callLifecycleLock) {
                clearCallReservationIfIdleLocked(retiredPeer)
            }
        }
    }

    private fun callPeer(accountId: String, callId: String): String {
        callPeers[callId]?.let { return it }
        return try {
            authenticatedCallPeer(JamiService.getCallDetails(accountId, callId).toNative())
        } catch (_: Throwable) { "" }
    }

    private fun isTerminalCallState(state: String): Boolean =
        state == "HUNGUP" || state == "OVER" || state == "FAILURE" ||
            state == "BUSY" || state == "PEER_BUSY"

    private fun markRecentTerminalLocked(callId: String) {
        if (callId.isEmpty() || !recentTerminalCallIds.add(callId)) return
        while (recentTerminalCallIds.size > RECENT_TERMINAL_CALL_LIMIT) {
            val oldest = recentTerminalCallIds.iterator().next()
            recentTerminalCallIds.remove(oldest)
        }
    }

    private fun setOnlineLifetime(enabled: Boolean) {
        backgroundWakeRetryKey = Any()
        keepOnline = enabled
        if (!enabled) accountId?.let {
            backgroundWakeActivity.request(it, false, backgroundWakeController.scope(), backgroundWakeRetryKey)
        }
        main.post { applyBackgroundWakeLifetime() }
    }

    /** Worker-only native activation. Every caller updates the same acknowledgement. */
    private fun setWakeAccountActive(owner: String, active: Boolean) {
        check(owner == accountId) { "Wake account changed" }
        try {
            if (active) check(activatePreparedAccount(owner)) { "Wake activation awaits canonical privacy" }
            JamiService.setAccountActive(owner, active, !active)
            val observed = JamiService.getVolatileAccountDetails(owner).toNative()["Account.active"]
            check(observed == active.toString()) { "Wake account activation was not acknowledged" }
            backgroundWakeActivity.acknowledge(owner, active)
        } catch (error: Throwable) {
            backgroundWakeActivity.acknowledge(owner, null)
            Log.e(TAG, "wake account activation failed", error)
            throw error
        }
    }

    private fun hasCallLifetime(): Boolean =
        activeCallId != null ||
            activeGroupConferenceId != null ||
            pendingGroupConferenceId != null ||
            incomingCalls.snapshot().isNotEmpty() ||
            synchronized(callLifecycleLock) { placingOutgoing }

    private fun applyBackgroundWakeLifetime() {
        main.removeCallbacks(backgroundWakeCheck)
        val now = SystemClock.elapsedRealtime()
        val callActive = hasCallLifetime()
        val decision = BackgroundWakeLifetime.decide(
            nowMs = now,
            pushEnabled = backgroundWakeEnabled(),
            appVisible = activityResumed,
            accountEnabled = keepOnline,
            callActive = callActive,
            taskRemoved = taskRemovedWithPush,
            backgroundAtMs = backgroundAtMs,
            messagePushAtMs = messagePushAtMs,
            callPushAtMs = callPushAtMs,
        )
        val owner = accountId
        if (keepOnline && owner != null) {
            backgroundWakeActivity.request(owner, decision.keepAccountActive, backgroundWakeController.scope(), backgroundWakeRetryKey)
        }
        // A queued or failed sleep command is not an inactive-account
        // acknowledgement. Keep the service until that boundary is known.
        val sleepUnconfirmed = keepOnline && !decision.keepAccountActive &&
            backgroundWakeActivity.acknowledgedActive() != false
        when {
            callActive -> PushForegroundService.stop(appContext)
            (decision.keepOnlineForegroundService || sleepUnconfirmed) && !PushForegroundService.isRunningOrStarting() ->
                startOnlineLifetime()
            else -> CallForegroundService.stopIfRunning()
        }
        if ((!decision.keepAccountActive && !sleepUnconfirmed) || activityResumed) PushForegroundService.stop(appContext)
        decision.nextCheckMs?.let {
            main.postDelayed(backgroundWakeCheck, it.coerceAtLeast(1L))
        }
    }

    private fun startForegroundLifetime(intent: Intent): Boolean =
        try {
            appContext.startForegroundService(intent)
            true
        } catch (e: Throwable) {
            Log.e(TAG, "foreground service start failed", e)
            false
        }

    private fun startOnlineLifetime() {
        if (!CallForegroundService.showOnlineIfRunning()) {
            startForegroundLifetime(CallForegroundService.onlineIntent(appContext))
        }
    }

    internal fun onCallForegroundServiceStarted() {
        main.post { applyBackgroundWakeLifetime() }
    }

    private fun startCallAudio(video: Boolean = false) {
        backgroundWakeRetryKey = Any()
        audio?.onCallActive()
        val captureType = if (video) currentCaptureType() else CallForegroundService.CaptureType.NONE
        if (!CallForegroundService.showCallIfRunning(captureType)) {
            startForegroundLifetime(CallForegroundService.callIntent(appContext, captureType))
        }
    }

    private fun stopCallAudio() {
        backgroundWakeRetryKey = Any()
        audio?.onCallEnded()
        applyBackgroundWakeLifetime()
    }

    // ---- daemon callbacks (daemon thread → marshal everything via emit) ----

    private class ConfigCb : ConfigurationCallback() {
        override fun deviceAuthStateChanged(account: String, state: Int, details: StringMap) {
            guardDirectorCallback { JamiCore.onDevicePairingSignal(account, null, state, details, true) }
        }

        override fun addDeviceStateChanged(account: String, operation: Long, state: Int, details: StringMap) {
            guardDirectorCallback { JamiCore.onDevicePairingSignal(account, operation, state, details, false) }
        }

        override fun getAppDataPath(name: String, ret: StringVect) {
            guardDirectorFillCallback(clear = { ret.clear() }) {
                val d = File(JamiCore.appContext.filesDir, name).apply { mkdirs() }
                ret.add(d.absolutePath)
            }
        }

        override fun getDeviceName(ret: StringVect) {
            guardDirectorFillCallback(clear = { ret.clear() }) {
                ret.add("Doorlight")
            }
        }

        override fun audioMeter(id: String, level: Float) {
            guardDirectorCallback {
                if (id != "audiolayer_id" || !level.isFinite()) return
                JamiCore.emit(mapOf(
                    "type" to "audioMeter",
                    "id" to id,
                    "level" to level.coerceIn(0f, 1f),
                ))
            }
        }

        override fun deviceRevocationEnded(accountId: String, deviceId: String, status: Int) {
            guardDirectorCallback {
                JamiCore.deviceRevocations.ended(accountId, deviceId, status, SystemClock.elapsedRealtime())
                JamiCore.main.post(JamiCore.deviceRevocationCheck)
            }
        }

        override fun registrationStateChanged(accountId: String, state: String, code: Int, detail: String) {
            guardDirectorCallback {
                JamiCore.registrationByAccount[accountId] = state
                if (!JamiCore.isActiveAccount(accountId)) return
                JamiCore.lastRegistration = state
                Log.i(TAG, "registrationStateChanged($accountId) = $state")
                JamiCore.emit(mapOf("type" to "registrationState", "accountId" to accountId, "state" to state))
            }
        }

        override fun activeCallsChanged(accountId: String, conversationId: String, activeCalls: VectMap) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId) ||
                    JamiCore.routingSnapshot.group(conversationId) == null
                ) return
                val calls = JamiCore.snapshot(activeCalls).filter {
                    GroupCallWire.roomId(it["id"].orEmpty()) != null
                }
                JamiCore.emit(
                    mapOf(
                        "type" to "groupCallsChanged",
                        "accountId" to accountId,
                        "conversationId" to conversationId,
                        "calls" to calls,
                    ),
                )
            }
        }

        override fun needsHost(accountId: String, conversationId: String) {
            guardDirectorCallback {
                val conferenceId = JamiCore.activeGroupConferenceId ?: return
                if (!JamiCore.isActiveAccount(accountId) ||
                    JamiCore.groupConversationByConference[conferenceId] != conversationId
                ) return
                JamiCore.emit(
                    mapOf(
                        "type" to "groupNeedsHost",
                        "accountId" to accountId,
                        "conversationId" to conversationId,
                        "conferenceId" to conferenceId,
                    ),
                )
            }
        }

        override fun volatileAccountDetailsChanged(accountId: String, details: StringMap) {
            guardDirectorCallback {
                val announced = details.toNative()["Account.deviceAnnounced"] ?: ""
                if (announced.isNotEmpty()) {
                    JamiCore.announcedByAccount[accountId] = announced == "true"
                    if (!JamiCore.isActiveAccount(accountId)) return
                    JamiCore.emit(mapOf("type" to "deviceAnnounced", "accountId" to accountId, "announced" to (announced == "true")))
                }
            }
        }

        // Delivery status of an account (non-swarm) message — used by the reachability probe (presence). Forward
        // the message id + state so Dart can resolve FAILURE=4 (unreachable) / DISPLAYED=3. NOTE: SENT=2 is a
        // LOCAL socket-write success, not a peer ack (daemon message_engine.cpp) — Dart no longer treats it as
        // liveness; the pong is the real end-to-end proof.
        override fun accountMessageStatusChanged(accountId: String, conversationId: String, peer: String, messageId: String, state: Int) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId)) return
                val bare = bareJamiId(peer)
                if (if (conversationId.isEmpty()) !JamiCore.isTrustedPeer(accountId, bare)
                    else JamiCore.ownerForConversation(accountId, conversationId) == null) return
                JamiCore.emit(mapOf("type" to "messageStatus", "accountId" to accountId,
                    "conversationId" to conversationId, "peerJamiId" to bare,
                    "messageId" to messageId, "state" to state))
            }
        }

        // presence v2: an account (non-swarm) message arrived — the ping/pong path. Daemon emit order is
        // (accountId, FROM, MESSAGE-ID, payloads) (sipaccountbase.cpp:282); the id is "" on the channel path.
        override fun incomingAccountMessage(accountId: String, from: String, messageId: String, payloads: StringMap) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId)) return
                val nativePayloads = payloads.toNative()
                nativePayloads[GroupCallWire.PRESENCE_MIME]?.let { body ->
                    if (GroupCallWire.acceptPresence(JamiCore.routingSnapshot, from, body)) {
                        JamiCore.emit(
                            mapOf(
                                "type" to "groupCallPresence",
                                "accountId" to accountId,
                                "fromJamiId" to bareJamiId(from),
                                "payload" to body,
                            ),
                        )
                    }
                    return
                }
                routeAccountMessage(
                    snapshot = JamiCore.routingSnapshot,
                    from = from,
                    payloads = nativePayloads,
                    onFull = { f, p -> JamiCore.onAccountMessage(accountId, f, p) },
                    onWakeOnly = { f, p -> JamiCore.onWakeOnlyMessage(accountId, f, p) },
                    // Dropped BEFORE any Dart event: without this line a stale-snapshot friend's ping/pong
                    // vanishes without trace (the Log wrapper redacts the id in release builds).
                    onDrop = { f -> Log.w(TAG, "account message from untrusted ${bareJamiId(f)} dropped") },
                )
            }
        }

        override fun composingStatusChanged(
            accountId: String,
            conversationId: String,
            from: String,
            status: Int,
        ) {
            guardDirectorCallback {
                val peer = bareJamiId(from)
                val snapshot = JamiCore.routingSnapshot
                if (!JamiCore.isActiveAccount(accountId) ||
                    !snapshot.acceptsComposerActivity(accountId, conversationId, peer, status)) return
                JamiCore.emit(mapOf(
                    "type" to "composerActivity",
                    "accountId" to accountId,
                    "fromJamiId" to peer,
                    "conversationId" to conversationId,
                    "kind" to if (status == 1) "typing" else "idle",
                ))
            }
        }

        override fun contactAdded(accountId: String, uri: String, confirmed: Boolean) {
            guardDirectorCallback {
                JamiCore.requestRoutingRefresh(accountId)
            }
        }

        override fun contactRemoved(accountId: String, uri: String, banned: Boolean) {
            guardDirectorCallback {
                JamiCore.retireControlTrust(accountId, bareJamiId(uri))
                JamiCore.requestRoutingRefresh(accountId, forceEvent = true)
            }
        }

        override fun profileReceived(
            accountId: String,
            from: String,
            @Suppress("UNUSED_PARAMETER") path: String,
        ) {
            guardDirectorCallback {
                JamiCore.worker.execute(DaemonOperation.READ_PEER) {
                    JamiCore.onPeerProfile(accountId, from)
                }
            }
        }
    }

    private class CallCb : Callback() {
        override fun conferenceCreated(accountId: String, conversationId: String, confId: String) {
            guardDirectorCallback {
                val owner = JamiCore.captureAccountScope(accountId) ?: return
                val reservation = synchronized(JamiCore.callLifecycleLock) {
                    if (!JamiCore.groupPlacementStarted ||
                        (confId != JamiCore.pendingGroupConferenceId && confId != JamiCore.activeGroupConferenceId) ||
                        JamiCore.groupConversationByConference[confId] != conversationId) return
                    JamiCore.groupReservationId ?: return
                }
                JamiCore.worker.execute(DaemonOperation.READ_PEER) {
                    try {
                        if (!JamiCore.accountAuthority.owns(owner) ||
                            !JamiService.getConferenceList(accountId).contains(confId)) return@execute
                        synchronized(JamiCore.callLifecycleLock) {
                            if (!JamiCore.accountAuthority.owns(owner) || JamiCore.groupReservationId != reservation ||
                                !JamiCore.groupPlacementStarted ||
                                (confId != JamiCore.pendingGroupConferenceId && confId != JamiCore.activeGroupConferenceId) ||
                                JamiCore.groupConversationByConference[confId] != conversationId) return@execute
                            JamiCore.activeGroupConferenceId = confId
                            JamiCore.pendingGroupConferenceId = null
                        }
                        JamiCore.emit(mapOf("type" to "groupConferenceCreated", "reservationId" to reservation,
                            "accountId" to accountId, "conversationId" to conversationId, "conferenceId" to confId))
                    } catch (_: Throwable) {}
                }
            }
        }

        override fun conferenceChanged(accountId: String, confId: String, state: String) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId) || GroupCallWire.roomId(confId) == null) return
                JamiCore.emit(
                    mapOf(
                        "type" to "groupConferenceChanged",
                        "accountId" to accountId,
                        "conferenceId" to confId,
                        "state" to state,
                    ),
                )
            }
        }

        override fun conferenceRemoved(accountId: String, confId: String) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId) || GroupCallWire.roomId(confId) == null) return
                val owner = JamiCore.captureAccountScope(accountId) ?: return
                val captured = synchronized(JamiCore.callLifecycleLock) {
                    if (!JamiCore.groupPlacementStarted ||
                        (confId != JamiCore.activeGroupConferenceId && confId != JamiCore.pendingGroupConferenceId)) return
                    (JamiCore.groupReservationId ?: return) to JamiCore.groupCallLegs[confId]
                }
                JamiCore.worker.execute(DaemonOperation.READ_PEER) {
                    try {
                        if (!JamiCore.accountAuthority.owns(owner)) return@execute
                        if ((!captured.second.isNullOrEmpty() && JamiService.getCallList(accountId).contains(captured.second)) ||
                            JamiService.getConferenceList(accountId).contains(confId)) return@execute
                        if (!JamiCore.clearGroupCall(confId, captured.first, owner)) return@execute
                        JamiCore.emit(mapOf(
                            "type" to "groupConferenceRemoved", "reservationId" to captured.first,
                            "accountId" to accountId, "conferenceId" to confId,
                        ))
                    } catch (_: Throwable) {}
                }
            }
        }

        override fun onConferenceInfosUpdated(confId: String, infos: VectMap) {
            guardDirectorCallback {
                if (GroupCallWire.boundedConference(infos) == null) return
                val owner = JamiCore.captureAccountScope() ?: return
                val captured = synchronized(JamiCore.callLifecycleLock) {
                    val resolved = if (GroupCallWire.roomId(confId) != null) confId else
                        JamiCore.groupCallLegs.entries.firstOrNull { it.value == confId }?.key ?: return
                    if (!JamiCore.groupPlacementStarted ||
                        (resolved != JamiCore.activeGroupConferenceId && resolved != JamiCore.pendingGroupConferenceId) ||
                        !JamiCore.groupConversationByConference.containsKey(resolved)) return
                    resolved to (JamiCore.groupReservationId ?: return)
                }
                JamiCore.conferenceInfoIngress.offer(Runnable {
                    try {
                        if (!JamiCore.accountAuthority.owns(owner)) return@Runnable
                        val current = JamiService.getConferenceInfos(owner.accountId, confId)
                        val participants = GroupCallWire.boundedConference(current) ?: return@Runnable
                        synchronized(JamiCore.callLifecycleLock) {
                            if (!JamiCore.accountAuthority.owns(owner) || JamiCore.groupReservationId != captured.second ||
                                (captured.first != JamiCore.activeGroupConferenceId && captured.first != JamiCore.pendingGroupConferenceId)) return@Runnable
                        }
                        JamiCore.emit(mapOf("type" to "groupConferenceInfo", "reservationId" to captured.second,
                            "accountId" to owner.accountId, "conferenceId" to captured.first, "participants" to participants))
                    } catch (_: Throwable) {}
                })
            }
        }

        override fun incomingCall(accountId: String, callId: String, from: String, mediaList: VectMap) {
            guardDirectorCallback {
            val diagnostic = JamiCore.beginCallSignal("INCOMING_CALL", callId)
            var placementBarrier: CountDownLatch? = null
            var diagnosticFailure: Throwable? = null
            try {
            synchronized(JamiCore.callSignalDispatchLock) {
            JamiCore.acquiredCallSignal(diagnostic)
            if (JamiCore.groupConferenceForCall(accountId, callId) != null) return
            if (!JamiCore.isActiveAccount(accountId)) {
                JamiCore.worker.execute(DaemonOperation.CALLBACK_REFUSE, JamiCore.diagnosticCallToken(callId)) {
                    try { JamiService.refuse(accountId, callId) } catch (_: Throwable) {}
                }
                return
            }
            val offer = JamiCore.snapshot(mediaList)
            Log.i(TAG, "incomingCall($callId) from $from entries=${offer.size}")
            // SIP From is presentation data. Admission, retained rings and alerts
            // must use the identity authenticated by the call transport.
            val fromHex = try {
                authenticatedCallPeer(JamiService.getCallDetails(accountId, callId).toNative())
            } catch (_: Throwable) { "" }
            if (fromHex.isEmpty() || fromHex != bareJamiId(from)) {
                JamiCore.rejectedCallIds.add(callId)
                JamiCore.worker.execute(DaemonOperation.CALLBACK_REFUSE, JamiCore.diagnosticCallToken(callId)) {
                    try { JamiService.refuse(accountId, callId) } catch (_: Throwable) {}
                }
                return
            }
            var suppress = false
            var refuse = false
            synchronized(JamiCore.callLifecycleLock) {
                if (!JamiCore.isActiveAccount(accountId) ||
                    JamiCore.activeGroupConferenceId != null ||
                    JamiCore.pendingGroupConferenceId != null
                ) {
                    JamiCore.rejectedCallIds.add(callId)
                    suppress = true
                    refuse = true
                }
                val admission = incomingCallAdmission(
                    trusted = JamiCore.directCallAllowed(accountId, fromHex),
                    incomingPeerId = fromHex,
                    reservedPeerId = JamiCore.reservedCallPeerId,
                )
                if (!suppress && (
                    admission == IncomingCallAdmission.REJECT_UNTRUSTED ||
                        admission == IncomingCallAdmission.REJECT_CROSS_PEER_BUSY
                    )
                ) {
                    JamiCore.rejectedCallIds.add(callId)
                    suppress = true
                    refuse = true
                } else if (!suppress && admission == IncomingCallAdmission.ACCEPT_FIRST) {
                    JamiCore.reservedCallPeerId = fromHex
                }
                val winner = JamiCore.currentWinnerCallId ?:
                    if (JamiCore.placingOutgoing) JamiCore.winnerCallIdDuringPlacement else null
                when {
                    suppress -> Unit
                    JamiCore.recentTerminalCallIds.contains(callId) -> {
                        // The terminal callback overtook this signal. Do not recreate peer/offer/tombstone state.
                        suppress = true
                        refuse = true
                    }
                    JamiCore.rejectedCallIds.contains(callId) || (winner != null && winner != callId) -> {
                        // CURRENT already established a winner. Refusing here is safe, unlike pre-CURRENT glare.
                        JamiCore.callPeers[callId] = fromHex
                        JamiCore.rejectedCallIds.add(callId)
                        suppress = true
                        refuse = true
                    }
                    winner == callId -> suppress = true // reordered duplicate for the already-established call
                    else -> {
                        JamiCore.callPeers[callId] = fromHex
                        JamiCore.incomingCalls.put(callId, accountId, fromHex, offer)
                        // If this callback overtook an already-started placement, hold only the callback return
                        // until that placement completes. The patched daemon then refreshes currentCall and runs
                        // its own crossed-call rule. There is no wrapper accept, timer, or second daemon worker.
                        if (JamiCore.placingOutgoing && JamiCore.activeCallId == null) {
                            placementBarrier = JamiCore.outgoingPlacementBarrier
                        }
                    }
                }
                if (suppress && admission == IncomingCallAdmission.ACCEPT_FIRST) {
                    JamiCore.clearCallReservationIfIdleLocked(fromHex)
                }
            }
            if (suppress) {
                JamiCore.cancelIncomingCallNotification(callId)
                if (refuse) JamiCore.worker.execute(
                    DaemonOperation.CALLBACK_REFUSE, JamiCore.diagnosticCallToken(callId),
                ) {
                    try { JamiService.refuse(accountId, callId) } catch (_: Throwable) {}
                }
                return
            }
            // Suppress the immediate alert behind the native-active leg. If that leg dies while this ring is still
            // live, terminal handling re-emits it to Dart and posts the notification then.
            JamiCore.showIncomingCallNotification(callId)
            JamiCore.emit(mapOf("type" to "incomingCall", "accountId" to accountId,
                "callId" to callId, "fromJamiId" to fromHex,
                "fromName" to "", "withVideo" to JamiCore.listHasActiveVideo(offer)))
            }
            // Do not hold callSignalDispatchLock here: placeCallWithMedia can synchronously emit StateChange.
            // This event wait has no deadline; placement completion/failure always releases it in finally.
            placementBarrier?.await()
            } catch (t: Throwable) {
                diagnosticFailure = t
                throw t
            } finally {
                JamiCore.finishedCallSignal(diagnostic, diagnosticFailure)
            }
            }
        }

        override fun callStateChanged(accountId: String, callId: String, state: String, code: Int) {
            guardDirectorCallback {
            val groupConferenceId = JamiCore.groupConferenceForCall(accountId, callId)
            if (groupConferenceId != null) {
                val owner = JamiCore.captureAccountScope(accountId) ?: return
                val reservation = synchronized(JamiCore.callLifecycleLock) {
                    if (!JamiCore.accountAuthority.owns(owner) || JamiCore.activeGroupHosting ||
                        JamiCore.groupCallLegs[groupConferenceId] != callId) return
                    val current = JamiCore.groupReservationId ?: return
                    if (state == "CURRENT") {
                        JamiCore.activeGroupConferenceId = groupConferenceId
                        JamiCore.pendingGroupConferenceId = null
                    }
                    current
                }
                if (state == "CURRENT") JamiCore.main.post {
                    if (JamiCore.accountAuthority.owns(owner) && JamiCore.groupReservationId == reservation &&
                        JamiCore.activeGroupConferenceId == groupConferenceId) JamiCore.startCallAudio()
                }
                val event = mapOf(
                        "type" to "groupCallLegState",
                        "reservationId" to reservation,
                        "accountId" to accountId,
                        "conferenceId" to groupConferenceId,
                        "callId" to callId,
                        "state" to state,
                        "code" to code,
                )
                if (JamiCore.isTerminalCallState(state)) {
                    // Serialize complete cleanup with the next reservation.
                    JamiCore.worker.execute(DaemonOperation.READ_PEER) {
                        if (JamiCore.clearGroupCall(groupConferenceId, reservation, owner)) JamiCore.emit(event)
                    }
                } else JamiCore.emit(event)
                return
            }
            synchronized(JamiCore.callLifecycleLock) {
                // Before placement returns, only its exact returned leg can be
                // reconciled. Never let an unknown group leg become a direct call.
                if (JamiCore.groupPlacementStarted && JamiCore.pendingGroupConferenceId != null &&
                    !JamiCore.callPeers.containsKey(callId)) return
            }
            val diagnostic = JamiCore.beginCallSignal(JamiCore.callSignalOperation(state), callId)
            synchronized(JamiCore.callSignalDispatchLock) {
            JamiCore.acquiredCallSignal(diagnostic)
            var diagnosticFailure: Throwable? = null
            try {
            // Release native notification/replay ownership even if account adoption made this event stale for Dart.
            // Filtering first would strand the previous account's notification indefinitely.
            if (state == "HUNGUP" || state == "OVER" || state == "FAILURE" ||
                state == "BUSY" || state == "PEER_BUSY") {
                JamiCore.incomingCalls.remove(callId)
                JamiCore.cancelIncomingCallNotification(callId)
            }
            if (!JamiCore.isActiveAccount(accountId)) return
            if (JamiCore.isTerminalCallState(state)) synchronized(JamiCore.callLifecycleLock) {
                JamiCore.markRecentTerminalLocked(callId)
            }
            // Stranger calls and post-CURRENT glare losers are tombstoned until terminal. A loser can race the
            // queued refuse/hangUp and briefly report CURRENT; end it again and never let Dart adopt it.
            if (JamiCore.rejectedCallIds.contains(callId)) {
                val retiredPeer = JamiCore.callPeers[callId]
                if (state == "CURRENT") {
                    JamiCore.worker.execute(
                        DaemonOperation.RETIRE_STALE_CURRENT, JamiCore.diagnosticCallToken(callId),
                    ) {
                        try { JamiService.hangUp(accountId, callId) } catch (_: Throwable) {}
                    }
                }
                if (JamiCore.isTerminalCallState(state)) {
                    if (!retiredPeer.isNullOrEmpty()) {
                        // Let Dart release trusted retired-call state; stranger calls never entered callPeers.
                        if (JamiCore.activeCallId == callId || JamiCore.placingOutgoing) {
                            // A placed outgoing leg can own media before its first CURRENT is denied.
                            // Its real terminal must release that ownership, or record an early
                            // terminal before placement returns, not only release its tombstone.
                            JamiCore.handleCallState(accountId, callId, state, code, retiredPeer)
                        } else {
                            JamiCore.emit(mapOf("type" to "callState", "accountId" to accountId,
                                "callId" to callId, "state" to state, "code" to code,
                                "fromJamiId" to retiredPeer))
                        }
                    }
                    JamiCore.rejectedCallIds.remove(callId)
                    val removedPeer = JamiCore.callPeers.remove(callId)
                    if (removedPeer != null) synchronized(JamiCore.callLifecycleLock) {
                        JamiCore.clearCallReservationIfIdleLocked(removedPeer)
                    }
                }
                return
            }
            val fromHex = JamiCore.callPeer(accountId, callId)
            if (fromHex.isEmpty() ||
                (JamiCore.callPeers[callId] == null && !JamiCore.isTrustedPeer(accountId, fromHex))) {
                if (state == "CURRENT") {
                    JamiCore.worker.execute(
                        DaemonOperation.RETIRE_STALE_CURRENT, JamiCore.diagnosticCallToken(callId),
                    ) {
                        try { JamiService.hangUp(accountId, callId) } catch (_: Throwable) {}
                    }
                }
                return
            }
            val staleAfterTerminal = !JamiCore.isTerminalCallState(state) && synchronized(JamiCore.callLifecycleLock) {
                val stale = JamiCore.recentTerminalCallIds.contains(callId)
                if (stale && state == "CURRENT" && JamiCore.placingOutgoing &&
                    JamiCore.winnerCallIdDuringPlacement == null) {
                    JamiCore.winnerCallIdDuringPlacement = callId
                }
                stale
            }
            if (staleAfterTerminal) {
                if (state == "CURRENT") JamiCore.worker.execute(
                    DaemonOperation.RETIRE_STALE_CURRENT, JamiCore.diagnosticCallToken(callId),
                ) {
                    try { JamiService.hangUp(accountId, callId) } catch (_: Throwable) {}
                }
                return
            }
            JamiCore.callPeers[callId] = fromHex
            JamiCore.handleCallState(accountId, callId, state, code, fromHex)
            } catch (t: Throwable) {
                diagnosticFailure = t
                throw t
            } finally {
                JamiCore.finishedCallSignal(diagnostic, diagnosticFailure)
            }
            }
            }
        }

        override fun localVoiceActivity(callId: String, active: Boolean) {
            guardDirectorCallback {
            val account = synchronized(JamiCore.callLifecycleLock) {
                val currentAccount = JamiCore.accountId
                if (currentAccount.isNullOrEmpty() ||
                    !ownsAudioTransmissionCall(
                        callId,
                        JamiCore.activeCallId,
                        JamiCore.currentWinnerCallId,
                    ) ||
                    JamiCore.recentTerminalCallIds.contains(callId)
                ) {
                    return
                }
                currentAccount
            }
            // This event is a UI projection only. The daemon has already made
            // the sender decision from its stabilized post-DSP voice flag.
            JamiCore.emit(
                mapOf(
                    "type" to "localVoiceActivity",
                    "accountId" to account,
                    "callId" to callId,
                    "active" to active,
                ),
            )
            }
        }

        // Typed in-call channels. Remote control has a stronger identity contract than annotation: it is surfaced
        // only with account+device ids read from the secure transport's peer certificate.
        override fun incomingMessage(accountId: String, callId: String, from: String, messages: StringMap) {
            guardDirectorCallback {
            if (!JamiCore.isActiveAccount(accountId)) return
            val payloads = messages.toNative()
            val fromHex = from.removePrefix("jami:").substringBefore("@")
            if (!JamiCore.isTrustedPeer(accountId, fromHex)) return
            payloads[ANNOT_MIME]?.let { payload ->
                val active = synchronized(JamiCore.callLifecycleLock) {
                    JamiCore.activeCallId == callId && JamiCore.currentWinnerCallId == callId &&
                        JamiCore.callPeers[callId] == fromHex && !JamiCore.recentTerminalCallIds.contains(callId)
                }
                if (!active) return@let
                JamiCore.emit(mapOf(
                    "type" to "callMessage", "accountId" to accountId,
                    "callId" to callId, "channel" to "annotation", "mimeType" to ANNOT_MIME,
                    "fromJamiId" to fromHex, "payload" to payload,
                ))
            }
            payloads[CONTROL_MIME]?.let { payload ->
                if (!JamiCore.controlMessageAdmission.admit(
                        listOf(accountId, callId, fromHex), payload.length,
                        SystemClock.elapsedRealtime())) return@let
                val details = try {
                    JamiService.getCallDetails(accountId, callId).toNative()
                } catch (_: Throwable) {
                    emptyMap()
                }
                val authenticatedAccount = bareJamiId(
                    details["AUTHENTICATED_PEER_ACCOUNT_ID"].orEmpty(),
                )
                val authenticatedDevice = details["AUTHENTICATED_PEER_DEVICE_ID"].orEmpty()
                val ownsActiveCall = synchronized(JamiCore.callLifecycleLock) {
                    JamiCore.accountId == accountId &&
                        JamiCore.activeCallId == callId &&
                        JamiCore.callPeers[callId] == authenticatedAccount
                }
                if (authenticatedAccount.isEmpty() || authenticatedDevice.isEmpty() ||
                    fromHex != authenticatedAccount || !ownsActiveCall ||
                    !JamiCore.isTrustedPeer(accountId, authenticatedAccount)) return@let
                if (AndroidRemoteControlHost.onAuthenticatedPacket(
                        accountId,
                        JamiCore.myJamiId(),
                        callId,
                        authenticatedAccount,
                        authenticatedDevice,
                        payload,
                    )) {
                    return@let
                }
                JamiCore.emit(mapOf(
                    "type" to "callMessage", "accountId" to accountId,
                    "callId" to callId, "channel" to "control", "mimeType" to CONTROL_MIME,
                    "fromJamiId" to authenticatedAccount,
                    "authenticatedPeerAccountId" to authenticatedAccount,
                    "authenticatedPeerDeviceId" to authenticatedDevice,
                    "payload" to payload,
                ))
            }
            }
        }

        // The peer turned their camera on/off → re-invite. Mirror the offer and answer; tell Dart about peer video.
        override fun mediaChangeRequested(accountId: String, callId: String, mediaList: VectMap) {
            guardDirectorCallback {
            if (!JamiCore.isActiveAccount(accountId)) return
            val offer = JamiCore.snapshot(mediaList)
            Log.i(TAG, "mediaChangeRequested($callId) entries=${offer.size}")
            JamiCore.postAnswerMediaChange(callId, offer)
            val peerSource = offer.firstOrNull {
                it["MEDIA_TYPE"] == "MEDIA_TYPE_VIDEO" &&
                    it["ENABLED"] == "true" &&
                    it["MUTED"] == "false"
            }?.get("SOURCE").orEmpty()
            JamiCore.emit(mapOf("type" to "peerVideo", "accountId" to accountId,
                "callId" to callId, "on" to JamiCore.listHasActiveVideo(offer),
                "sourceKind" to if (
                    peerSource == SCREEN_MRL || peerSource.startsWith("display://")
                ) "screen" else "camera"))
            }
        }

        override fun mediaNegotiationStatus(callId: String, event: String, mediaList: VectMap) {
            guardDirectorCallback {
            Log.i(TAG, "mediaNegotiationStatus($callId) = $event")
            // This daemon emits no NEGOTIATION_FAIL or transaction token, and delivery may straddle
            // StartCapture. Capture only the current lease identity here; the worker re-reads live
            // media and may reconcile OFF, never infer or re-enable ON.
            if (event != "NEGOTIATION_SUCCESS") return
            val signal = JamiCore.videoNegotiationSignal(callId) ?: return
            // The callback map is deliberately not trusted as current topology. libjami has no
            // transaction id; the worker re-reads currentMediaList and revalidates this token.
            JamiCore.worker.execute(
                DaemonOperation.MEDIA_NEGOTIATED, JamiCore.diagnosticCallToken(signal.callId),
            ) { JamiCore.onMediaNegotiated(signal) }
            }
        }
    }

    private class PtVideoCallback : VideoCallback() {
        override fun getCameraInfo(device: String, formats: IntVect, sizes: UintVect, rates: UintVect) =
            guardDirectorFillCallback(clear = {
                formats.clear()
                sizes.clear()
                rates.clear()
            }) {
                JamiCore.onGetCameraInfo(device, sizes, rates)
                check(sizes.size % 2 == 0 && sizes.size / 2 == rates.size)
            }
        override fun setParameters(device: String, format: Int, width: Int, height: Int, rate: Int) =
            guardDirectorCallback { JamiCore.onSetParameters(width, height) }
        override fun startCapture(camid: String) = guardDirectorCallback { JamiCore.onStartCapture(camid) }
        override fun stopCapture(camid: String) = guardDirectorCallback { JamiCore.onStopCapture(camid) }
        override fun requestKeyFrame(camid: String) = guardDirectorCallback { JamiCore.onRequestKeyFrame(camid) }
        override fun setBitrate(device: String, bitrate: Int) =
            guardDirectorCallback { JamiCore.onSetBitrate(device, bitrate) }
        override fun decodingStarted(id: String, shm_path: String, w: Int, h: Int, is_mixer: Boolean) =
            guardDirectorCallback { JamiCore.onDecodingStarted(id, w, h) }
        override fun decodingStopped(id: String, shm_path: String, is_mixer: Boolean) =
            guardDirectorCallback { JamiCore.onDecodingStopped(id) }
    }

    private class PresenceCb : PresenceCallback() {
        // Forward the RAW tri-state (0=DISCONNECTED, 1=AVAILABLE, 2=CONNECTED — daemon jamiaccount.h PresenceState).
        // 2 = a live authenticated P2P channel to the peer RIGHT NOW (truth). 1 = a DHT DeviceAnnouncement record —
        // on the jami.net profile that record is proxy-held for ~24 h and replayed on every (re)subscribe, so it can
        // be a day stale; Dart treats it as a hint to verify, never as "online". Flattening 1/2 into one bool was
        // the original stale-green bug.
        override fun newBuddyNotification(accountId: String, buddyUri: String, status: Int, lineStatus: String) {
            guardDirectorCallback {
                if (!JamiCore.isActiveAccount(accountId)) return
                val bare = bareJamiId(buddyUri)
                if (!JamiCore.isTrustedPeer(accountId, bare)) {
                    JamiCore.connectedPeers.remove(bare)
                    return
                }
                if (status >= 2) JamiCore.connectedPeers += bare
                else JamiCore.connectedPeers.remove(bare)
                Log.i(TAG, "presence($buddyUri) status=$status")
                JamiCore.emit(mapOf("type" to "presence", "accountId" to accountId,
                    "peerJamiId" to bare, "status" to status))
            }
        }
    }

    private class DataCb : DataTransferCallback() {
        override fun dataTransferEventOwned(accountId: String, conversationId: String, interactionId: String,
                                           fileId: String, attemptId: String, eventCode: Int) =
            guardDirectorCallback {
                JamiCore.onDataTransferEvent(accountId, conversationId, interactionId, fileId, eventCode, attemptId)
            }
        override fun dataTransferEvent(accountId: String, conversationId: String, interactionId: String, fileId: String, eventCode: Int) =
            guardDirectorCallback {
                JamiCore.onDataTransferEvent(accountId, conversationId, interactionId, fileId, eventCode)
            }
    }

    private class ConvCb : ConversationCallback() {
        override fun messagesFound(id: Long, accountId: String, conversationId: String, messages: VectMap) =
            guardDirectorCallback { JamiCore.onHistorySearch(id, accountId, conversationId, messages) }
        override fun syblFileSeedReady(accountId: String, conversationId: String, operationId: String,
                                      commitId: String, fileId: String, ready: Boolean) =
            guardDirectorCallback { JamiCore.onOwnedFileSeed(accountId, conversationId, operationId, commitId, fileId, ready) }
        override fun syblMessageCompleted(accountId: String, conversationId: String, operationId: String, commitId: String) =
            guardDirectorCallback { JamiCore.onOwnedMessageCompleted(accountId, conversationId, operationId, commitId) }
        override fun swarmMessageReceived(accountId: String, conversationId: String, message: SwarmMessage) =
            guardDirectorCallback { JamiCore.onSwarmMessage(accountId, conversationId, message) }
        override fun reactionAdded(accountId: String, conversationId: String, messageId: String, reaction: StringMap) =
            guardDirectorCallback { JamiCore.onReaction(accountId, conversationId, messageId, reaction = reaction) }
        override fun reactionRemoved(accountId: String, conversationId: String, messageId: String, reactionId: String) =
            guardDirectorCallback { JamiCore.onReaction(accountId, conversationId, messageId, removedId = reactionId) }
        override fun swarmMessageUpdated(accountId: String, conversationId: String, message: SwarmMessage) =
            guardDirectorCallback { JamiCore.onSwarmMessageUpdated(accountId, conversationId, message) }
        override fun swarmLoaded(id: Long, accountId: String, conversationId: String, messages: SwarmMessageVect) =
            guardDirectorCallback(onFailure = { failure ->
                DirectorCallbackFailures.record(failure)
                Log.e(TAG, "history callback failed", failure)
            }) { JamiCore.onSwarmLoaded(id, accountId, conversationId, messages) }
        override fun conversationProfileUpdated(
            accountId: String,
            conversationId: String,
            profile: StringMap,
        ) = guardDirectorCallback {
            JamiCore.onConversationProfile(accountId, conversationId, profile.toNative())
        }
        override fun conversationReady(accountId: String, conversationId: String) =
            guardDirectorCallback { JamiCore.onConversationReady(accountId, conversationId) }
        override fun conversationRemoved(accountId: String, conversationId: String) =
            guardDirectorCallback { JamiCore.onConversationMembershipChanged(accountId) }
        override fun conversationSyncFinished(accountId: String) = guardDirectorCallback {
            if (JamiCore.isActiveAccount(accountId)) {
                JamiCore.emit(mapOf("type" to "conversationSyncFinished", "accountId" to accountId))
            }
        }
        override fun conversationMemberEvent(
            accountId: String,
            conversationId: String,
            memberUri: String,
            event: Int,
        ) = guardDirectorCallback { JamiCore.onConversationMembershipChanged(accountId) }
        override fun conversationRequestReceived(
            accountId: String,
            conversationId: String,
            metadata: StringMap,
        ) {
            guardDirectorCallback {
                JamiCore.onConversationRequest(
                    accountId,
                    conversationId,
                    metadata.get("from").orEmpty(),
                    metadata.get("mode").orEmpty(),
                    metadata.get("title").orEmpty(),
                )
            }
        }
    }
}
