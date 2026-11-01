package app.sybl.sybl

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.TouchInteractionController
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.Display
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Android's controllee authority.
 *
 * The daemon callback supplies the peer account/device from the authenticated
 * call certificate. Wire JSON can request consent but can never create a
 * grant. Only a local click in [AndroidRemoteControlAccessibilityService]'s
 * accessibility overlay mints the token/epoch below.
 */
internal object AndroidRemoteControlHost {
    const val CAP_MOUSE = AndroidRemoteControlProtocol.CAP_MOUSE
    const val CAP_KEYBOARD = AndroidRemoteControlProtocol.CAP_KEYBOARD
    const val CAP_TEXT = AndroidRemoteControlProtocol.CAP_TEXT
    const val CAP_CLIPBOARD = AndroidRemoteControlProtocol.CAP_CLIPBOARD
    const val CAP_BACK = AndroidRemoteControlProtocol.CAP_BACK
    const val CAP_HOME = AndroidRemoteControlProtocol.CAP_HOME
    const val CAP_RECENTS = AndroidRemoteControlProtocol.CAP_RECENTS
    const val ANDROID_CAPABILITIES = AndroidRemoteControlProtocol.ANDROID_CAPABILITIES

    private const val REQUEST_TIMEOUT_MS = 20_000L
    private const val MAX_EVENTS_PER_SECOND = 320
    private const val MAX_ANNOTATION_STROKES = 160
    private const val MAX_ANNOTATION_POINTS = 24_000

    data class Source(
        val callId: String,
        val revision: Long,
        val frameWidth: Int,
        val frameHeight: Int,
        val displayWidth: Int,
        val displayHeight: Int,
        val safeBounds: Rect,
        val rotation: Int,
    )

    data class AnnotationPoint(val x: Float, val y: Float)

    data class AnnotationStroke(
        val color: Int,
        val width: Float,
        val points: List<AnnotationPoint>,
    )

    data class AnnotationOverlay(
        val source: AndroidRemoteControlSourceIdentity,
        val displayWidth: Int,
        val displayHeight: Int,
        val strokes: List<AnnotationStroke>,
    )

    internal fun sourceIdentity(source: Source) = AndroidRemoteControlSourceIdentity(
        callId = source.callId,
        revision = source.revision,
        frameWidth = source.frameWidth,
        frameHeight = source.frameHeight,
        displayWidth = source.displayWidth,
        displayHeight = source.displayHeight,
        safeLeft = source.safeBounds.left,
        safeTop = source.safeBounds.top,
        safeRight = source.safeBounds.right,
        safeBottom = source.safeBounds.bottom,
        rotation = source.rotation,
    )

    private data class Active(
        val binding: AndroidRemoteControlBinding,
        val capabilities: Int,
        val generation: Long,
        val token: ByteArray,
        val tokenHex: String,
        val epoch: Long,
        val identityColor: String,
        var lastSequence: Long = 0,
        var rateWindowStartedMs: Long = SystemClock.elapsedRealtime(),
        var rateWindowEvents: Int = 0,
    )

    private val lock = Any()
    private val random = SecureRandom()
    private val epochs = AtomicLong(1)
    private val generations = AtomicLong(1)
    private val main = Handler(Looper.getMainLooper())
    private val ingress = ControlMessageQueue { main.post(it) }
    private val responseAdmission = ControlResponseAdmission()
    @Volatile
    private var service: AndroidRemoteControlAccessibilityService? = null
    private var active: Active? = null
    private var annotationOverlay: AnnotationOverlay? = null
    private val consent = RemoteControlConsentFlow(
        lock = lock,
        authorityCurrent = { JamiCore.remoteControlAuthorityCurrent(it) },
        leaseCurrent = { JamiCore.remoteControlLeaseCurrent(it) },
        currentSource = { JamiCore.remoteControlSource()?.let(::sourceIdentity) },
        serviceAttached = { service != null },
        sessionActive = { active != null },
        revalidate = { binding, verified ->
            JamiCore.submit(
                DaemonOperation.READ_PEER,
                binding.callId,
                { JamiCore.revalidateRemoteControlBinding(binding) },
            ) { verified(it == true) }
        },
        showConsent = { request ->
            service?.showConsent(
                request.binding,
                request.generation,
                onAllow = ::allowPending,
                onDeny = ::denyPending,
            ) ?: false
        },
        hideConsent = { generation -> service?.hideConsent(generation) },
        sendDeny = ::sendDeny,
        scheduleTimeout = { _, expire -> main.postDelayed(expire, REQUEST_TIMEOUT_MS) },
        activate = ::activateSession,
        activated = ::finishActivation,
        emitState = { request, state, reason -> emitHostState(request, state, reason) },
    )

    fun isServiceEnabled(): Boolean = service != null

    fun attach(value: AndroidRemoteControlAccessibilityService) {
        service = value
        value.updateAnnotationOverlay(annotationOverlay)
        JamiCore.emit(
            mapOf("type" to "remoteControlAccessibilityState", "enabled" to true),
        )
    }

    fun detach(value: AndroidRemoteControlAccessibilityService) {
        if (service !== value) return
        service = null
        stopLocal("accessibility-disabled")
        JamiCore.emit(
            mapOf("type" to "remoteControlAccessibilityState", "enabled" to false),
        )
    }

    /**
     * Returns true only for controller->controllee packets this Android host
     * owns. Grant/deny/revoke packets remain available to Dart's controller.
     */
    fun onAuthenticatedPacket(
        localAccount: String,
        localJamiId: String,
        callId: String,
        controllerAccount: String,
        controllerDevice: String,
        payload: String,
    ): Boolean {
        if (localAccount.isBlank() ||
            callId.isBlank() ||
            controllerAccount.isBlank() ||
            controllerDevice.isBlank()
        ) {
            return false
        }
        val packet = AndroidRemoteControlPacketParser.parse(payload) ?: return false
        // libjami callbacks are not Android UI callbacks. One main-queue ingress
        // serializes consent, safety inspection, packet order, and input enqueue.
        ingress.offer(listOf(localAccount, callId, controllerAccount, controllerDevice),
            if (packet is AndroidRemoteControlRequest) payload else null, Runnable {
            when (packet) {
                is AndroidRemoteControlRequest -> handleRequest(
                    localAccount,
                    localJamiId,
                    callId,
                    controllerAccount,
                    controllerDevice,
                    packet,
                )
                is AndroidRemoteControlInput -> handleInput(
                    localAccount,
                    callId,
                    controllerAccount,
                    controllerDevice,
                    packet,
                )
                AndroidRemoteControlEnd -> handleEnd(
                    localAccount,
                    callId,
                    controllerAccount,
                    controllerDevice,
                )
            }
        })
        return true
    }

    private fun handleRequest(
        localAccount: String,
        localJamiId: String,
        callId: String,
        account: String,
        device: String,
        request: AndroidRemoteControlRequest,
    ) {
        val source = JamiCore.remoteControlSource() ?: run {
            sendDeny(callId, "unsupported")
            return
        }
        if (JamiCore.accountId != localAccount ||
            source.callId != callId ||
            source.revision != request.sourceRevision) {
            sendDeny(callId, "unsupported")
            return
        }
        val granted = AndroidRemoteControlPolicy.negotiatedCapabilities(request.capabilities)
        val accessibility = service
        if (granted == 0 || accessibility == null) {
            sendDeny(callId, "unsupported")
            return
        }
        // Stored legacy grants never authorize a session in v1.
        val persistentAvailable = false
        val binding = AndroidRemoteControlBinding(
            callId = callId,
            localAccount = localAccount,
            controllerAccount = account,
            controllerDevice = device,
            source = sourceIdentity(source),
        )
        if (!JamiCore.remoteControlAuthorityCurrent(binding)) return
        consent.request(
            RemoteControlConsentRequest(
                binding,
                localJamiId,
                request.capabilities,
                granted,
                positive(generations.getAndIncrement()),
                persistentAvailable,
                request.identityColor,
            ),
        )
    }

    fun allowPending(generation: Long, persistDevice: Boolean = false): Unit =
        consent.allow(generation, persistDevice)

    private fun bindingIsCurrent(binding: AndroidRemoteControlBinding): Boolean =
        JamiCore.remoteControlLeaseCurrent(binding) &&
            JamiCore.remoteControlSource()?.let(::sourceIdentity) == binding.source

    // Runs under the shared lock, after the flow has retired the pending request
    // and confirmed a current native lease for this exact binding.
    private fun activateSession(request: RemoteControlConsentRequest) {
        val token = ByteArray(32).also(random::nextBytes)
        val session = Active(
            request.binding,
            request.grantedCapabilities,
            request.generation,
            token,
            token.toHex(),
            positive(epochs.getAndIncrement()),
            request.identityColor,
        )
        active = session
        scheduleAuthorityCheck(session)
    }

    private fun finishActivation(request: RemoteControlConsentRequest) {
        val generation = request.generation
        val session = synchronized(lock) {
            active?.takeIf { it.generation == generation }
        } ?: return
        val accessibility = service ?: run {
            revoke(session, "indicator-unavailable", notifyPeer = false)
            sendDeny(session.binding.callId, "unsupported")
            return
        }
        if (!accessibility.showCancellationTarget(generation) ||
            !accessibility.showHelpControls(
                generation, JamiCore.remoteHelpPeerName(session.binding),
            ) { stopGeneration(generation) }) {
            revoke(session, "indicator-unavailable", notifyPeer = false)
            sendDeny(session.binding.callId, "unsupported")
            return
        }
        accessibility.startLocalTouchFeedback(
            generation,
            JamiCore.localIdentityColor(),
        )
        val grant = JSONObject()
            .put("v", 1)
            .put("t", "grant")
            .put("token", session.tokenHex)
            .put("epoch", session.epoch)
            .put("sourceRevision", session.binding.source.revision)
            .put("caps", capabilityNames(session.capabilities))
            .toString()
        send(session.binding.callId, grant,
             stillAuthorized = { ownsGeneration(session.generation, session.binding.source) }) { ok ->
            if (!ok) revoke(session, "transport-failure", notifyPeer = false)
        }
        synchronized(lock) {
            if (active === session && bindingIsCurrent(session.binding))
                emitHostState(session, "active", "")
        }
    }

    fun denyPending(generation: Long, reason: String = "user"): Unit =
        consent.deny(generation, reason)

    private fun scheduleAuthorityCheck(session: Active) {
        main.postDelayed({
            if (synchronized(lock) { active !== session }) return@postDelayed
            if (!bindingIsCurrent(session.binding)) {
                revoke(session, "authority-expired", notifyPeer = true)
            } else scheduleAuthorityCheck(session)
        }, 50)
    }

    private fun handleInput(
        localAccount: String,
        callId: String,
        account: String,
        device: String,
        input: AndroidRemoteControlInput,
    ) {
        val now = SystemClock.elapsedRealtime()
        val pair = synchronized(lock) {
            val session = active ?: return
            val source = JamiCore.remoteControlSource()
            if (source == null ||
                source.callId != callId ||
                source.revision != input.sourceRevision
            ) {
                main.post { revoke(session, "source-changed", notifyPeer = true) }
                return
            }
            val presentedBinding = AndroidRemoteControlBinding(
                callId = callId,
                localAccount = localAccount,
                controllerAccount = account,
                controllerDevice = device,
                source = sourceIdentity(source),
            )
            if (JamiCore.accountId == localAccount &&
                AndroidRemoteControlPolicy.authenticatedSequenceGap(
                    session.binding, presentedBinding, session.token, input.token,
                    session.epoch, input.epoch, session.lastSequence, input.sequence,
                )) {
                active = null // Fence queued and new OS work before posting cleanup.
                main.post { finishRevocation(session, "sequence-gap", true) }
                return
            }
            if (JamiCore.accountId != localAccount ||
                !AndroidRemoteControlPolicy.authorizesInput(
                    expectedBinding = session.binding,
                    presentedBinding = presentedBinding,
                    expectedToken = session.token,
                    presentedToken = input.token,
                    expectedEpoch = session.epoch,
                    presentedEpoch = input.epoch,
                    lastSequence = session.lastSequence,
                    presentedSequence = input.sequence,
                    capabilities = session.capabilities,
                    events = input.events,
                )
            ) {
                return
            }
            if (now - session.rateWindowStartedMs >= 1_000L) {
                session.rateWindowStartedMs = now
                session.rateWindowEvents = 0
            }
            session.rateWindowEvents += input.events.size
            if (session.rateWindowEvents > MAX_EVENTS_PER_SECOND) {
                main.post { revoke(session, "rate-limit", notifyPeer = true) }
                return
            }
            session.lastSequence = input.sequence
            session to source
        }
        val accessibility = service
        if (accessibility == null) {
            revoke(pair.first, "protected-surface", notifyPeer = true)
            return
        }
        accessibility.applyEvents(
            pair.first.generation,
            pair.second,
            input.events,
            pair.first.identityColor,
        )
    }

    private fun handleEnd(
        localAccount: String,
        callId: String,
        account: String,
        device: String,
    ) {
        val request = consent.retireIf {
            it.binding.callId == callId &&
                it.binding.localAccount == localAccount &&
                it.binding.controllerAccount == account &&
                it.binding.controllerDevice == device
        }
        if (request != null) {
            service?.hideConsent(request.generation)
            emitHostState(request, "ended", "controller-ended")
        }
        val session = synchronized(lock) {
            active?.takeIf {
                it.binding.callId == callId &&
                    it.binding.localAccount == localAccount &&
                    it.binding.controllerAccount == account &&
                    it.binding.controllerDevice == device
            }
        }
        if (session != null) revoke(session, "controller-ended", notifyPeer = false)
    }

    fun stopLocal(reason: String): Boolean {
        val retired = consent.stop(reason)
        val session = synchronized(lock) { active }
        if (session != null) revoke(session, reason, notifyPeer = true)
        return retired || session != null
    }

    fun onCallEnded(callId: String) {
        val owns = synchronized(lock) {
            consent.current()?.binding?.callId == callId || active?.binding?.callId == callId
        }
        if (owns) stopLocal("call-ended")
        if (annotationOverlay?.source?.callId == callId) {
            annotationOverlay = null
            service?.updateAnnotationOverlay(null)
        }
    }

    fun onTrustReduced(
        accountId: String,
        localJamiId: String,
        controllerAccount: String,
        callId: String,
    ): Boolean {
        fun matches(binding: AndroidRemoteControlBinding) =
            binding.localAccount == accountId && binding.controllerAccount == controllerAccount
        val retired = synchronized(lock) {
            val request = consent.retireIf { matches(it.binding) }
            val session = active?.takeIf { matches(it.binding) }
            if (session != null) active = null
            request to session
        }
        retired.first?.let {
            service?.hideConsent(it.generation)
            emitHostState(it, "denied", "trust-removed")
        }
        retired.second?.let {
            service?.cancelRemoteInput(it.generation)
            emitHostState(it, "ended", "trust-removed")
        }
        if (callId.isNotEmpty() && annotationOverlay?.source?.callId == callId) {
            annotationOverlay = null
            service?.updateAnnotationOverlay(null)
        }
        // Keep legacy-store I/O outside the live authority lock.
        val removed = AndroidRemoteControlGrantStore.removePeer(
            JamiCore.appContext, localJamiId, controllerAccount,
        )
        JamiCore.emit(mapOf(
            "type" to "remoteControlTrustRetired", "accountId" to accountId,
            "peerJamiId" to controllerAccount, "grantsRemoved" to removed,
            // All future submission boundaries observe retired authority. This
            // does not undo a gesture Android already accepted.
            "releaseComplete" to true,
        ))
        return removed
    }

    fun onSourceChanged() {
        val request = consent.current()
        val session = synchronized(lock) { active }
        val source = JamiCore.remoteControlSource()
        if (request != null &&
            (source == null ||
                sourceIdentity(source) != request.binding.source)
        ) {
            denyPending(request.generation, "unsupported")
        }
        if (session != null &&
            (source == null ||
                sourceIdentity(source) != session.binding.source)
        ) {
            revoke(session, "source-changed", notifyPeer = true)
        }
        val overlay = annotationOverlay
        if (overlay != null &&
            (source == null || sourceIdentity(source) != overlay.source)
        ) {
            annotationOverlay = null
            service?.updateAnnotationOverlay(null)
        }
    }

    /**
     * Accept only a snapshot bound to the daemon's exact active local screen
     * source. Flutter cannot use this method to paint over an unrelated call or
     * a stale capture revision.
     */
    fun updateAnnotationOverlay(arguments: Map<*, *>): Boolean {
        if (arguments["active"] != true) {
            annotationOverlay = null
            service?.updateAnnotationOverlay(null)
            return true
        }
        val callId = arguments["callId"] as? String ?: return false
        val revision = (arguments["sourceRevision"] as? Number)?.toLong() ?: return false
        val source = JamiCore.remoteControlSource() ?: return false
        if (callId.isBlank() ||
            source.callId != callId ||
            source.revision != revision ||
            source.displayWidth <= 0 ||
            source.displayHeight <= 0
        ) {
            return false
        }
        val rawStrokes = arguments["strokes"] as? List<*> ?: return false
        if (rawStrokes.size > MAX_ANNOTATION_STROKES) return false
        var pointCount = 0
        val strokes = ArrayList<AnnotationStroke>(rawStrokes.size)
        for (rawStroke in rawStrokes) {
            val stroke = rawStroke as? Map<*, *> ?: return false
            val color = (stroke["color"] as? Number)?.toLong()?.toInt() ?: return false
            val width = (stroke["width"] as? Number)?.toFloat() ?: return false
            if (!width.isFinite() || width !in 0.5f..24f) return false
            val rawPoints = stroke["points"] as? List<*> ?: return false
            pointCount += rawPoints.size
            if (pointCount > MAX_ANNOTATION_POINTS) return false
            val points = ArrayList<AnnotationPoint>(rawPoints.size)
            for (rawPoint in rawPoints) {
                val pair = rawPoint as? List<*> ?: return false
                if (pair.size != 2) return false
                val x = (pair[0] as? Number)?.toFloat() ?: return false
                val y = (pair[1] as? Number)?.toFloat() ?: return false
                if (!x.isFinite() || !y.isFinite() || x !in 0f..1f || y !in 0f..1f) {
                    return false
                }
                points += AnnotationPoint(x, y)
            }
            if (points.isNotEmpty()) {
                strokes += AnnotationStroke(color, width, points)
            }
        }
        val snapshot = AnnotationOverlay(
            sourceIdentity(source),
            source.displayWidth,
            source.displayHeight,
            strokes,
        )
        annotationOverlay = snapshot
        service?.updateAnnotationOverlay(snapshot)
        return true
    }

    fun ownsGeneration(
        generation: Long,
        source: AndroidRemoteControlSourceIdentity,
    ): Boolean = synchronized(lock) {
        active?.generation == generation &&
            active?.binding?.source == source &&
            active?.let { bindingIsCurrent(it.binding) } == true
    }

    // Linearization point shared with revoke: an OS action either begins while
    // this exact authority owns the lock, or observes that authority retired.
    fun applyIfOwned(
        generation: Long,
        source: AndroidRemoteControlSourceIdentity,
        action: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (active?.generation != generation ||
            active?.binding?.source != source ||
            active?.let { bindingIsCurrent(it.binding) } != true
        ) {
            false
        } else {
            action()
            true
        }
    }

    fun inputRefused(generation: Long, source: AndroidRemoteControlSourceIdentity, reason: String) {
        val session = synchronized(lock) {
            active?.takeIf { it.generation == generation && it.binding.source == source }
        } ?: return
        revoke(session, reason, notifyPeer = true)
    }

    private fun stopGeneration(generation: Long) {
        val session = synchronized(lock) {
            active?.takeIf { it.generation == generation }
        } ?: return
        revoke(session, "local-stop", notifyPeer = true)
    }

    private fun revoke(session: Active, reason: String, notifyPeer: Boolean) {
        val removed = synchronized(lock) {
            if (active !== session) false else {
                active = null
                true
            }
        }
        if (!removed) return
        finishRevocation(session, reason, notifyPeer)
    }

    private fun finishRevocation(session: Active, reason: String, notifyPeer: Boolean) {
        // Retire authority before asking the service to cancel any gesture.
        service?.cancelRemoteInput(session.generation)
        if (notifyPeer) {
            send(
                session.binding.callId,
                JSONObject().put("v", 1).put("t", "revoke").toString(),
            )
        }
        emitHostState(session, "ended", reason)
    }

    private fun sendDeny(callId: String, reason: String) {
        send(
            callId,
            JSONObject().put("v", 1).put("t", "deny").put("reason", reason).toString(),
            denial = true,
        )
    }

    private fun send(
        callId: String,
        packet: String,
        stillAuthorized: (() -> Boolean)? = null,
        denial: Boolean = false,
        completed: ((Boolean) -> Unit)? = null,
    ) {
        if (!responseAdmission.acquire(SystemClock.elapsedRealtime(), denial)) {
            completed?.invoke(false)
            return
        }
        val scope = JamiCore.captureCallMessage(callId)
        JamiCore.submit(
            DaemonOperation.SEND_CALL_MESSAGE,
            callId,
            { scope != null && (stillAuthorized?.invoke() != false) &&
                JamiCore.sendCallMessage(scope, packet, "control") },
        ) {
            responseAdmission.delivered()
            completed?.invoke(it == true)
        }
    }

    private fun emitHostState(value: Active, state: String, reason: String) =
        emitHostState(
            value.binding,
            value.generation,
            value.capabilities,
            state,
            reason,
        )

    private fun emitHostState(value: RemoteControlConsentRequest, state: String, reason: String) =
        emitHostState(
            value.binding,
            value.generation,
            value.grantedCapabilities,
            state,
            reason,
        )

    private fun emitHostState(
        binding: AndroidRemoteControlBinding,
        generation: Long,
        capabilities: Int,
        state: String,
        reason: String,
    ) {
        JamiCore.emit(
            mapOf(
                "type" to "remoteControlState",
                "state" to state,
                "accountId" to binding.localAccount,
                "callId" to binding.callId,
                "controllerAccountId" to binding.controllerAccount,
                "controllerDeviceId" to binding.controllerDevice,
                "sourceRevision" to binding.source.revision,
                "hostGeneration" to generation,
                "controlCapabilities" to capabilities,
                "persistentAvailable" to false,
                "coControl" to false,
                "reason" to reason,
            ),
        )
    }

    private fun capabilityNames(bits: Int): JSONArray = JSONArray().apply {
        if (bits and CAP_MOUSE != 0) put("mouse")
        if (bits and CAP_TEXT != 0) put("text")
        if (bits and CAP_BACK != 0) put("back")
        if (bits and CAP_HOME != 0) put("home")
        if (bits and CAP_RECENTS != 0) put("recents")
    }

    private fun positive(value: Long): Long = if (value > 0) value else 1

    private fun ByteArray.toHex(): String =
        joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
}

/**
 * Public Android accessibility APIs are the only input mechanism used here.
 * Android itself creates/binds this service after the user explicitly enables
 * it in Settings; the application cannot enable it programmatically.
 */
class AndroidRemoteControlAccessibilityService : AccessibilityService() {
    private data class QueuedRemoteEvent(
        val generation: Long,
        val source: AndroidRemoteControlHost.Source,
        val sourceIdentity: AndroidRemoteControlSourceIdentity,
        val event: AndroidRemoteControlEvent,
        val identityColor: String,
    )

    companion object {
        private const val MAX_QUEUED_REMOTE_EVENTS = 384
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var windowManager: WindowManager
    private var consentView: View? = null
    private var consentGeneration = 0L
    private var cancellationTargetView: View? = null
    private var helpControlsView: View? = null
    private var helpControlsGeneration = 0L
    private var cancellationTargetGeneration = 0L
    private var annotationView: AnnotationOverlayView? = null
    private var pointerView: RemotePointerView? = null
    private var localTouchPulseView: LocalTouchPulseView? = null
    private var localTouchFeedback: LocalTouchFeedbackSession? = null
    private var localTouchGeneration = 0L
    private var localTouchColor = Color.TRANSPARENT
    private var localTouchDown = false
    private val promoteLocalTouch = Runnable {
        if (localTouchDown && localTouchGeneration > 0) {
            localTouchPulseView?.apply {
                sustained = true
                invalidate()
            }
        }
    }
    private var pointerX = 0f
    private var pointerY = 0f
    private var pointerGeneration = 0L
    private var pointerSource: AndroidRemoteControlSourceIdentity? = null
    private var heldButton: String? = null
    private var heldStartedMs = 0L
    private val heldPoints = ArrayList<Pair<Float, Float>>()
    private var dispatchGeneration = 0L
    private val remoteEventQueue = ArrayDeque<QueuedRemoteEvent>()
    private var remoteDrainPosted = false
    private val annotationVisibilityCheck = Runnable {
        refreshAnnotationVisibility()
        refreshPointerVisibility()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        AndroidRemoteControlHost.attach(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        main.removeCallbacks(annotationVisibilityCheck)
        refreshAnnotationVisibility()
        refreshPointerVisibility()
        main.postDelayed(annotationVisibilityCheck, 200)
    }

    override fun onInterrupt() {
        AndroidRemoteControlHost.stopLocal("accessibility-interrupted")
    }

    override fun onDestroy() {
        main.removeCallbacks(annotationVisibilityCheck)
        AndroidRemoteControlHost.detach(this)
        removeView(consentView)
        removeView(cancellationTargetView)
        removeView(helpControlsView)
        removeView(annotationView)
        removeView(pointerView)
        stopLocalTouchFeedback()
        consentView = null
        cancellationTargetView = null
        helpControlsView = null
        annotationView = null
        pointerView = null
        remoteEventQueue.clear()
        remoteDrainPosted = false
        super.onDestroy()
    }

    internal fun showConsent(
        binding: AndroidRemoteControlBinding,
        generation: Long,
        onAllow: (Long, Boolean) -> Unit,
        onDeny: (Long) -> Unit,
    ): Boolean {
        if (consentView != null || cancellationTargetView != null) return false
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(14))
            setBackgroundColor(Color.rgb(32, 34, 38))
            addView(TextView(context).apply {
                text = getString(R.string.remote_control_consent_title)
                setTextColor(Color.WHITE)
                textSize = 18f
            })
            addView(TextView(context).apply {
                text = getString(
                    R.string.remote_control_consent_identity,
                    binding.controllerAccount,
                    binding.controllerDevice,
                )
                textDirection = View.TEXT_DIRECTION_LTR
                setTextColor(Color.WHITE)
                textSize = 13f
                setPadding(0, dp(8), 0, dp(8))
            })
            addView(TextView(context).apply {
                text = getString(R.string.remote_control_consent_body)
                setTextColor(Color.LTGRAY)
                textSize = 13f
                setPadding(0, dp(8), 0, dp(8))
            })
            addView(TextView(context).apply {
                text = getString(R.string.remote_control_consent_secondary)
                setTextColor(Color.LTGRAY)
                textSize = 13f
                setPadding(0, 0, 0, dp(8))
            })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
                addView(Button(context).apply {
                    text = getString(R.string.remote_control_deny)
                    setOnClickListener { onDeny(generation) }
                })
                addView(Button(context).apply {
                    text = getString(R.string.remote_control_allow_once)
                    setOnClickListener { onAllow(generation, false) }
                })
            })
        }
        val scroll = ScrollView(this).apply { addView(panel) }
        return addOverlay(scroll, Gravity.TOP).also { shown ->
            if (shown) {
                consentView = scroll
                consentGeneration = generation
            }
        }
    }

    fun hideConsent(generation: Long) {
        if (Looper.myLooper() != main.looper) {
            main.post { hideConsent(generation) }
            return
        }
        if (generation != consentGeneration) return
        removeView(consentView)
        consentView = null
        consentGeneration = 0
    }

    fun showCancellationTarget(generation: Long): Boolean {
        if (cancellationTargetView != null) return false
        val target = View(this).apply {
            minimumWidth = 1
            minimumHeight = 1
            alpha = .01f
        }
        return addOverlay(target, Gravity.TOP or Gravity.END, 1, 1).also { shown ->
            if (shown) {
                cancellationTargetView = target
                cancellationTargetGeneration = generation
            }
        }
    }

    fun hideCancellationTarget(generation: Long) {
        if (Looper.myLooper() != main.looper) {
            main.post { hideCancellationTarget(generation) }
            return
        }
        if (generation != cancellationTargetGeneration) return
        if (helpControlsGeneration == generation) {
            removeView(helpControlsView)
            helpControlsView = null
            helpControlsGeneration = 0
        }
        removeView(cancellationTargetView)
        cancellationTargetView = null
        cancellationTargetGeneration = 0
    }

    fun showHelpControls(generation: Long, person: String, onStop: () -> Unit): Boolean {
        if (helpControlsView != null) return false
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            setBackgroundColor(Color.rgb(32, 34, 38))
            addView(TextView(context).apply {
                text = getString(R.string.remote_control_active, person)
                setTextColor(Color.WHITE)
                textSize = 14f
                maxWidth = resources.displayMetrics.widthPixels - dp(24)
            })
            addView(Button(context).apply {
                text = getString(R.string.remote_control_stop)
                setOnClickListener { onStop() }
            })
        }
        return addOverlay(panel, Gravity.TOP or Gravity.END).also { shown ->
            if (shown) {
                helpControlsView = panel
                helpControlsGeneration = generation
            }
        }
    }

    fun startLocalTouchFeedback(generation: Long, identityColor: String): Boolean {
        stopLocalTouchFeedback()
        if (!AndroidRemoteControlPolicy.localTouchFeedbackAvailable(
                Build.VERSION.SDK_INT,
                generation > 0,
                identityColor,
            )
        ) {
            return false
        }
        val color = IdentityColorWire.argb(identityColor) ?: return false
        return try {
            localTouchGeneration = generation
            localTouchColor = color
            localTouchFeedback = Api33LocalTouchFeedback()
            true
        } catch (_: Throwable) {
            stopLocalTouchFeedback()
            false
        }
    }

    fun stopLocalTouchFeedback(generation: Long? = null) {
        if (generation != null && generation != localTouchGeneration) return
        try {
            localTouchFeedback?.stop()
        } catch (_: Throwable) {
        }
        localTouchFeedback = null
        localTouchGeneration = 0
        localTouchColor = Color.TRANSPARENT
        localTouchDown = false
        main.removeCallbacks(promoteLocalTouch)
        removeView(localTouchPulseView)
        localTouchPulseView = null
    }

    private interface LocalTouchFeedbackSession {
        fun stop()
    }

    @android.annotation.TargetApi(33)
    private inner class Api33LocalTouchFeedback :
        LocalTouchFeedbackSession,
        TouchInteractionController.Callback {
        private val controller = getTouchInteractionController(Display.DEFAULT_DISPLAY)

        init {
            try {
                controller.registerCallback(mainExecutor, this)
                setServiceInfo(serviceInfo.apply {
                    flags = flags or AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE
                })
            } catch (error: Throwable) {
                try {
                    controller.unregisterCallback(this)
                } catch (_: Throwable) {
                }
                throw error
            }
        }

        override fun onMotionEvent(event: MotionEvent) {
            val showPulse = event.actionMasked == MotionEvent.ACTION_DOWN &&
                localTouchGeneration > 0
            val x = event.x
            val y = event.y
            try {
                controller.requestDelegating()
            } catch (_: Throwable) {
                main.post { stopLocalTouchFeedback() }
                return
            }
            if (showPulse) {
                localTouchDown = true
                showLocalTouchPulse(x, y)
                main.removeCallbacks(promoteLocalTouch)
                main.postDelayed(promoteLocalTouch, 160)
            }
        }

        override fun onStateChanged(state: Int) {
            if (state != TouchInteractionController.STATE_CLEAR) return
            localTouchDown = false
            main.removeCallbacks(promoteLocalTouch)
            hideLocalTouch()
        }

        override fun stop() {
            controller.unregisterCallback(this)
            setServiceInfo(serviceInfo.apply {
                flags = flags and
                    AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE.inv()
            })
        }
    }

    internal fun updateAnnotationOverlay(
        snapshot: AndroidRemoteControlHost.AnnotationOverlay?,
    ) {
        main.post {
            if (snapshot == null) {
                removeView(annotationView)
                annotationView = null
                return@post
            }
            val view = annotationView ?: AnnotationOverlayView(this).also { created ->
                if (!addAnnotationOverlay(created)) return@post
                annotationView = created
            }
            view.snapshot = snapshot
            view.invalidate()
            refreshAnnotationVisibility()
        }
    }

    private fun refreshAnnotationVisibility() {
        annotationView?.visibility = View.VISIBLE
    }

    private fun refreshPointerVisibility() {
        pointerView?.visibility =
            if (pointerGeneration > 0) View.VISIBLE else View.GONE
    }

    internal fun applyEvents(
        generation: Long,
        source: AndroidRemoteControlHost.Source,
        events: List<AndroidRemoteControlEvent>,
        identityColor: String,
    ) {
        val sourceIdentity = AndroidRemoteControlHost.sourceIdentity(source)
        main.post {
            if (!AndroidRemoteControlHost.ownsGeneration(generation, sourceIdentity)) return@post
            if (source.displayWidth <= 0 ||
                source.displayHeight <= 0) {
                AndroidRemoteControlHost.stopLocal("protected-surface")
                return@post
            }
            val acceptedEvents = events
            if (acceptedEvents.isEmpty()) return@post
            if (remoteEventQueue.size + acceptedEvents.size > MAX_QUEUED_REMOTE_EVENTS) {
                AndroidRemoteControlHost.stopLocal("queue-limit")
                return@post
            }
            acceptedEvents.forEach { event ->
                remoteEventQueue += QueuedRemoteEvent(
                    generation,
                    source,
                    sourceIdentity,
                    event,
                    identityColor,
                )
            }
            if (!remoteDrainPosted) {
                remoteDrainPosted = true
                main.post(::drainRemoteEvent)
            }
        }
    }

    private fun drainRemoteEvent() {
        val queued = remoteEventQueue.removeFirstOrNull()
        if (queued == null) {
            remoteDrainPosted = false
            return
        }
        if (!AndroidRemoteControlHost.ownsGeneration(
                queued.generation,
                queued.sourceIdentity,
            )
        ) {
            main.post(::drainRemoteEvent)
            return
        }
        dispatchGeneration = queued.generation
        when (val event = queued.event) {
            is AndroidRemoteControlMove -> {
                val point = mapPoint(event.x, event.y, queued.source)
                if (point != null) {
                    pointerX = point.first
                    pointerY = point.second
                    pointerGeneration = queued.generation
                    pointerSource = queued.sourceIdentity
                    showRemotePointer(pointerX, pointerY, queued.identityColor)
                    if (heldButton != null) appendHeldPoint(pointerX, pointerY)
                } else {
                    pointerGeneration = 0
                    pointerSource = null
                    hideRemotePointer()
                    heldButton = null
                    heldPoints.clear()
                }
            }
            is AndroidRemoteControlButton ->
                applyButton(event, queued.generation, queued.sourceIdentity)
            is AndroidRemoteControlWheel ->
                dispatchWheel(
                    event.delta,
                    queued.generation,
                    queued.sourceIdentity,
                    queued.source,
                )
            is AndroidRemoteControlText ->
                applyText(
                    event.value,
                    queued.generation,
                    queued.sourceIdentity,
                )
            is AndroidRemoteControlAction ->
                applyGlobal(
                    event.name,
                    queued.generation,
                    queued.sourceIdentity,
                )
        }
        main.post(::drainRemoteEvent)
    }

    private fun applyButton(
        event: AndroidRemoteControlButton,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
    ) {
        if (event.name !in setOf("left", "right")) return
        if (!AndroidRemoteControlPolicy.ownsPointer(
                pointerGeneration,
                pointerSource,
                generation,
                sourceIdentity,
            )
        ) {
            return
        }
        if (event.down) {
            if (heldButton != null) return
            heldButton = event.name
            heldStartedMs = SystemClock.elapsedRealtime()
            heldPoints.clear()
            appendHeldPoint(pointerX, pointerY)
            return
        }
        if (heldButton != event.name) return
        appendHeldPoint(pointerX, pointerY)
        val elapsed = SystemClock.elapsedRealtime() - heldStartedMs
        val duration = if (event.name == "right") 650L else elapsed.coerceIn(40L, 2_000L)
        val first = heldPoints.firstOrNull()
        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop.toFloat()
        val directSystemClick = event.name == "left" &&
            elapsed <= 500L &&
            first != null &&
            abs(first.first - pointerX) <= touchSlop &&
            abs(first.second - pointerY) <= touchSlop
        val path = Path()
        heldPoints.firstOrNull()?.let { path.moveTo(it.first, it.second) }
        for (point in heldPoints.drop(1)) path.lineTo(point.first, point.second)
        heldButton = null
        heldPoints.clear()
        if (directSystemClick) {
            navigationActionAt(pointerX, pointerY)?.let { action ->
                applyGlobal(action, generation, sourceIdentity)
                return
            }
            if (clickSystemControlAt(pointerX, pointerY, generation, sourceIdentity)) return
        }
        dispatchPath(path, duration, generation, sourceIdentity)
    }

    private fun navigationActionAt(x: Float, y: Float): String? {
        if (Build.VERSION.SDK_INT < 30) return null
        val source = JamiCore.remoteControlSource() ?: return null
        val metrics = windowManager.maximumWindowMetrics
        val systemInset = metrics.windowInsets.getInsetsIgnoringVisibility(
            WindowInsets.Type.navigationBars(),
        ).bottom
        val applicationBounds = Rect()
        rootInActiveWindow?.getBoundsInScreen(applicationBounds)
        val inset = AndroidRemoteControlPolicy.navigationBottomInset(
            systemInset = systemInset,
            displayHeight = source.displayHeight,
            applicationBottom = applicationBounds.bottom.takeIf { it > 0 }
                ?: source.displayHeight,
        )
        val navigationMode = Settings.Secure.getInt(
            contentResolver,
            "navigation_mode",
            0,
        )
        val action = AndroidRemoteControlPolicy.threeButtonNavigationAction(
            x = x.toInt(),
            y = y.toInt(),
            width = source.displayWidth,
            height = source.displayHeight,
            bottomInset = inset,
            threeButtonMode = navigationMode == 0,
        )
        return action
    }

    private fun clickSystemControlAt(
        x: Float,
        y: Float,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
    ): Boolean {
        var target: AccessibilityNodeInfo? = null
        var targetArea = Int.MAX_VALUE
        val bounds = Rect()
        var systemWindow = false
        var rootPackage: String? = null
        val complete = RemoteControlSystemNodeScan.visit(
            windows = windows,
            root = { window ->
                systemWindow = window.type == AccessibilityWindowInfo.TYPE_SYSTEM
                window.root?.also { rootPackage = it.packageName?.toString() }
            },
            childCount = { it.childCount },
            child = { node, index -> node.getChild(index) },
            visitNode = { node ->
                node.getBoundsInScreen(bounds)
                val clickable = node.isClickable || node.actionList.any {
                    it.id == AccessibilityNodeInfo.ACTION_CLICK
                }
                if (bounds.contains(x.toInt(), y.toInt()) &&
                    AndroidRemoteControlPolicy.directSystemControlAllowed(
                        systemWindow = systemWindow,
                        packageName = node.packageName?.toString() ?: rootPackage,
                        ownPackage = packageName,
                        visible = node.isVisibleToUser,
                        clickable = clickable,
                    )
                ) {
                    val area = bounds.width() * bounds.height()
                    if (area in 1 until targetArea) {
                        target = node
                        targetArea = area
                    }
                }
            },
        )
        // An incomplete scan cannot choose a target from only part of the
        // window tree. The normal OS gesture remains the fallback.
        if (!complete) return false
        val selected = target ?: return false
        var accepted = false
        val owned = AndroidRemoteControlHost.applyIfOwned(generation, sourceIdentity) {
            accepted = selected.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        return owned && accepted
    }

    private fun appendHeldPoint(x: Float, y: Float) {
        val last = heldPoints.lastOrNull()
        if (last == null || abs(last.first - x) >= 1f || abs(last.second - y) >= 1f) {
            if (heldPoints.size < 256) heldPoints += x to y
        }
    }

    private fun dispatchWheel(
        delta: Int,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
        source: AndroidRemoteControlHost.Source,
    ) {
        if (!AndroidRemoteControlPolicy.ownsPointer(
                pointerGeneration,
                pointerSource,
                generation,
                sourceIdentity,
            )
        ) {
            return
        }
        val amount = min(source.safeBounds.height() * 0.35f, max(80f, abs(delta) * 1.5f))
        val direction = if (delta > 0) 1f else -1f
        val startY = (
            pointerY - direction * amount / 2
            ).coerceIn(source.safeBounds.top.toFloat(), source.safeBounds.bottom - 1f)
        val endY = (
            pointerY + direction * amount / 2
            ).coerceIn(source.safeBounds.top.toFloat(), source.safeBounds.bottom - 1f)
        val x = pointerX.coerceIn(
            source.safeBounds.left.toFloat(),
            source.safeBounds.right - 1f,
        )
        val path = Path().apply {
            moveTo(x, startY)
            lineTo(x, endY)
        }
        dispatchPath(path, 260L, generation, sourceIdentity)
    }

    private fun dispatchPath(
        path: Path,
        duration: Long,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
    ) {
        var accepted = false
        val owned = AndroidRemoteControlHost.applyIfOwned(generation, sourceIdentity) {
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build()
            accepted = dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    if (AndroidRemoteControlHost.ownsGeneration(generation, sourceIdentity)) {
                        AndroidRemoteControlHost.stopLocal("gesture-cancelled")
                    }
                }
            }, null)
        }
        if (owned && !accepted) {
            AndroidRemoteControlHost.stopLocal("gesture-rejected")
        }
    }

    private fun applyText(
        value: String,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
    ) {
        val result = executeRemoteControlAction(
            withAuthority = { action -> AndroidRemoteControlHost.applyIfOwned(generation, sourceIdentity, action) },
        ) action@{
            val root = rootInActiveWindow ?: return@action false
            val window = windows.firstOrNull { it.isActive && it.isFocused }
                ?: root.window
                ?: return@action false
            if (root.windowId != window.id) {
                return@action false
            }
            val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: return@action false
            if (node.windowId != window.id || !safeEditableNode(node)) {
                return@action false
            }
            val existing = node.text?.toString().orEmpty()
            if (existing.length > 4_096) return@action false
            val replacement = existing + value
            if (replacement.toByteArray(Charsets.UTF_8).size > 4_096) {
                return@action false
            }
            val arguments = android.os.Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    replacement,
                )
            }
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        }
        if (result == RemoteControlActionResult.REFUSED) {
            AndroidRemoteControlHost.inputRefused(generation, sourceIdentity, "text-rejected")
        }
    }

    private fun applyGlobal(
        name: String,
        generation: Long,
        sourceIdentity: AndroidRemoteControlSourceIdentity,
    ) {
        val action = when (name) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            else -> return
        }
        val result = executeRemoteControlAction(
            withAuthority = { operation -> AndroidRemoteControlHost.applyIfOwned(generation, sourceIdentity, operation) },
        ) {
            performGlobalAction(action)
        }
        if (result == RemoteControlActionResult.REFUSED) {
            AndroidRemoteControlHost.inputRefused(generation, sourceIdentity, "global-action-rejected")
        }
    }

    private fun safeEditableNode(node: AccessibilityNodeInfo): Boolean {
        if (!node.isEditable ||
            !node.isFocused) {
            return false
        }
        return node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
    }

    private fun mapPoint(
        x: Double,
        y: Double,
        source: AndroidRemoteControlHost.Source,
    ): Pair<Float, Float>? {
        val mapped = AndroidRemoteControlPolicy.mapSharedFramePoint(
            x,
            y,
            source.frameWidth,
            source.frameHeight,
            source.displayWidth,
            source.displayHeight,
        ) ?: return null
        val screenX = mapped.first.toFloat()
        val screenY = mapped.second.toFloat()
        if (!source.safeBounds.contains(screenX.toInt(), screenY.toInt())) return null
        return screenX to screenY
    }

    fun cancelRemoteInput(generation: Long) {
        if (Looper.myLooper() != main.looper) {
            main.post { cancelRemoteInput(generation) }
            return
        }
        stopLocalTouchFeedback(generation)
        remoteEventQueue.removeAll { it.generation == generation }
        if (pointerGeneration == generation) {
            pointerGeneration = 0
            pointerSource = null
            hideRemotePointer()
        }
        if (dispatchGeneration != generation) {
            hideCancellationTarget(generation)
            return
        }
        heldButton = null
        heldPoints.clear()
        // dispatchGesture cancels any gesture already dispatched by this
        // service. Keep the overlay until this cancellation stroke completes
        // so it cannot land on the application below.
        val target = cancellationTargetView
        if (target != null) {
            val location = IntArray(2)
            target.getLocationOnScreen(location)
            val path = Path().apply {
                moveTo(
                    location[0] + target.width / 2f,
                    location[1] + target.height / 2f,
                )
            }
            try {
                val accepted = dispatchGesture(
                    GestureDescription.Builder()
                        .addStroke(GestureDescription.StrokeDescription(path, 0, 1))
                        .build(),
                    object : GestureResultCallback() {
                        override fun onCompleted(gestureDescription: GestureDescription?) {
                            hideCancellationTarget(generation)
                        }

                        override fun onCancelled(gestureDescription: GestureDescription?) {
                            hideCancellationTarget(generation)
                        }
                    },
                    null,
                )
                if (accepted) {
                    main.postDelayed({ hideCancellationTarget(generation) }, 1_000)
                } else {
                    hideCancellationTarget(generation)
                }
            } catch (_: Throwable) {
                hideCancellationTarget(generation)
            }
        } else {
            hideCancellationTarget(generation)
        }
        dispatchGeneration = 0
    }

    private fun addOverlay(
        view: View,
        gravity: Int,
        width: Int = WindowManager.LayoutParams.WRAP_CONTENT,
        height: Int = WindowManager.LayoutParams.WRAP_CONTENT,
    ): Boolean = try {
        windowManager.addView(
            view,
            WindowManager.LayoutParams(
                width,
                height,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_SECURE,
                android.graphics.PixelFormat.TRANSLUCENT,
            ).apply {
                this.gravity = gravity
                title = "Doorlight remote control"
            },
        )
        true
    } catch (_: Throwable) {
        false
    }

    private fun overlayLayoutParams(width: Int, height: Int, title: String) =
        WindowManager.LayoutParams(
            width,
            height,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.title = title
        }

    private fun addAnnotationOverlay(view: View): Boolean = try {
        windowManager.addView(
            view,
            overlayLayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                "Doorlight annotations",
            ),
        )
        true
    } catch (_: Throwable) {
        false
    }

    private fun showRemotePointer(x: Float, y: Float, identityColor: String) {
        val color = IdentityColorWire.argb(identityColor) ?: return
        val view = pointerView ?: RemotePointerView(this).also { created ->
            if (!addPointerOverlay(created)) return
            pointerView = created
        }
        view.outlineColor = color
        view.invalidate()
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return
        params.x = x.toInt()
        params.y = y.toInt()
        try {
            windowManager.updateViewLayout(view, params)
        } catch (_: Throwable) {
            removeView(view)
            pointerView = null
            return
        }
        refreshPointerVisibility()
    }

    private fun hideRemotePointer() {
        pointerView?.visibility = View.GONE
    }

    private fun showLocalTouchPulse(x: Float, y: Float) {
        if (localTouchGeneration <= 0 || localTouchColor == Color.TRANSPARENT) return
        val view = localTouchPulseView ?: LocalTouchPulseView(this).also { created ->
            if (!addLocalTouchPulseOverlay(created)) return
            localTouchPulseView = created
        }
        view.pulseColor = localTouchColor
        view.sustained = false
        view.invalidate()
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return
        params.x = (x - params.width / 2f).toInt()
        params.y = (y - params.width / 2f).toInt()
        try {
            windowManager.updateViewLayout(view, params)
        } catch (_: Throwable) {
            removeView(view)
            localTouchPulseView = null
            return
        }
        view.animate().cancel()
        view.alpha = 1f
        view.scaleX = .72f
        view.scaleY = .72f
        view.animate()
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(120)
            .start()
    }

    private fun hideLocalTouch() {
        localTouchPulseView?.animate()
            ?.alpha(0f)
            ?.scaleX(1.2f)
            ?.scaleY(1.2f)
            ?.setDuration(160)
            ?.start()
    }

    private fun addPointerOverlay(view: View): Boolean = try {
        windowManager.addView(
            view,
            overlayLayoutParams(dp(32), dp(48), "Doorlight remote pointer"),
        )
        true
    } catch (_: Throwable) {
        false
    }

    private fun addLocalTouchPulseOverlay(view: View): Boolean = try {
        windowManager.addView(
            view,
            overlayLayoutParams(dp(44), dp(64), "Doorlight local touch"),
        )
        true
    } catch (_: Throwable) {
        false
    }

    private fun removeView(view: View?) {
        if (view == null || !::windowManager.isInitialized) return
        try {
            windowManager.removeViewImmediate(view)
        } catch (_: Throwable) {
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private class AnnotationOverlayView(context: Context) : View(context) {
        var snapshot: AndroidRemoteControlHost.AnnotationOverlay? = null
        private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        private val density = resources.displayMetrics.density

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            setWillNotDraw(false)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val current = snapshot ?: return
            if (width <= 0 || height <= 0 ||
                current.displayWidth <= 0 || current.displayHeight <= 0) {
                return
            }
            for (stroke in current.strokes) {
                val first = stroke.points.firstOrNull() ?: continue
                strokePaint.color = stroke.color
                strokePaint.strokeWidth = stroke.width * density
                if (stroke.points.size == 1) {
                    strokePaint.style = Paint.Style.FILL
                    canvas.drawCircle(
                        first.x * width,
                        first.y * height,
                        strokePaint.strokeWidth,
                        strokePaint,
                    )
                    strokePaint.style = Paint.Style.STROKE
                    continue
                }
                val path = Path().apply {
                    moveTo(first.x * width, first.y * height)
                    for (point in stroke.points.drop(1)) {
                        lineTo(point.x * width, point.y * height)
                    }
                }
                canvas.drawPath(path, strokePaint)
            }
        }
    }

    private class LocalTouchPulseView(context: Context) : View(context) {
        var pulseColor = Color.TRANSPARENT
        var sustained = false
        private val density = resources.displayMetrics.density
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = resources.displayMetrics.density * 3f
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            setWillNotDraw(false)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (pulseColor == Color.TRANSPARENT) return
            val x = width / 2f
            val y = width / 2f
            val radius = width * .28f
            fill.color = Color.argb(
                72,
                Color.red(pulseColor),
                Color.green(pulseColor),
                Color.blue(pulseColor),
            )
            ring.color = pulseColor
            if (sustained) {
                canvas.drawRoundRect(
                    x - 4f * density,
                    y + radius * .35f,
                    x + 4f * density,
                    height - 4f * density,
                    4f * density,
                    4f * density,
                    fill,
                )
                canvas.drawRoundRect(
                    x - 4f * density,
                    y + radius * .35f,
                    x + 4f * density,
                    height - 4f * density,
                    4f * density,
                    4f * density,
                    ring,
                )
            }
            canvas.drawCircle(x, y, radius, fill)
            canvas.drawCircle(x, y, radius, ring)
        }
    }

    /** White source pointer with dark separation and the controller's color outside it. */
    private class RemotePointerView(context: Context) : View(context) {
        var outlineColor: Int = Color.WHITE
        private val density = resources.displayMetrics.density
        private val path = Path()
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            setWillNotDraw(false)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val s = density
            path.reset()
            path.moveTo(4f * s, 4f * s)
            path.lineTo(4f * s, 33f * s)
            path.lineTo(11f * s, 26f * s)
            path.lineTo(16f * s, 39f * s)
            path.lineTo(22f * s, 36f * s)
            path.lineTo(16f * s, 24f * s)
            path.lineTo(27f * s, 24f * s)
            path.close()
            paint.style = Paint.Style.STROKE
            paint.color = outlineColor
            paint.strokeWidth = 7f * s
            canvas.drawPath(path, paint)
            paint.color = Color.rgb(24, 24, 24)
            paint.strokeWidth = 3f * s
            canvas.drawPath(path, paint)
            paint.style = Paint.Style.FILL
            paint.color = Color.WHITE
            canvas.drawPath(path, paint)
        }
    }
}
