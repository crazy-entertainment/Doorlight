package app.sybl.sybl

internal enum class LocalVideoKind { CAMERA, SCREEN }

/**
 * Pure decision model for Android's intent-first local video (send) lifecycle.
 *
 * Separated concerns, per the reviewed design:
 *  - INTENT: which call (or the in-flight placement, ownerCallId == null) wants to send video;
 *  - DEMAND: whether the daemon has asked for frames (StartCapture seen, not withdrawn);
 *  - HARDWARE: the Camera2 attempt, identified by [attemptGen]; each attempt owns its own
 *    reader/device/session and stale completions may close only their own resources.
 *
 * Identity rules:
 *  - [VideoLease.registeredDeviceId] is the daemon-registered device. StartCapture/StopCapture and
 *    setDeviceOrientation address THIS id. It never changes for the life of a lease.
 *  - [VideoLease.sinkId] = "camera://" + registeredDeviceId — the media SOURCE the daemon resolves,
 *    the self decoding sink id, and the raw-frame or encoded-packet capture target.
 *  - [VideoLease.physicalCameraId] is the Camera2 device actually opened; a flip changes only this.
 *  - [VideoLease.epoch] is the ownership token: every cross-thread continuation (FGS promotion,
 *    media action, camera callback via attemptGen) presents it and mismatches are discarded.
 *
 * Camera2 may open only after the camera-typed foreground promotion is confirmed
 * ([VideoLease.fgsConfirmed]); a demand that arrives earlier waits in Armed.
 *
 * Transitions run under JamiCore's callLifecycleLock; decisions execute outside the lock on their
 * proper thread. This object holds no Android or daemon types on purpose (JVM-testable).
 */
internal data class VideoLease(
    val epoch: Long,
    val registeredDeviceId: String,
    val sinkId: String,
    val physicalCameraId: String,
    val ownerCallId: String?,
    val fgsConfirmed: Boolean = false,
    val captureDemanded: Boolean = false,
    val kind: LocalVideoKind = LocalVideoKind.CAMERA,
    val width: Int = 0,
    val height: Int = 0,
)

/** A fact learned while exact-source replacement ownership is being adjudicated. */
internal enum class PendingVideoOutcome {
    /** The lease may be adopted and resumed. */
    VIABLE,

    /** Local capture/FGS failed; an owning winner must disable its video media. */
    CAPTURE_FAILED,

    /** The winner's negotiated media is already off; only truthful UI reconciliation remains. */
    NEGOTIATED_OFF,
}

internal sealed interface VideoPhase {
    object Idle : VideoPhase

    /** The user turned video off while the daemon still held the registered input demand. There
     *  is deliberately no camera intent or Camera2 resource in this phase. A same-call/device arm
     *  may inherit the demand because libjami can reuse its VideoInput without another
     *  StartCapture; StopCapture or terminal state clears it. */
    data class DormantDemand(
        val registeredDeviceId: String,
        val ownerCallId: String,
        val kind: LocalVideoKind = LocalVideoKind.CAMERA,
    ) : VideoPhase

    /** Intent declared (offer/re-invite in flight or negotiated); no Camera2 resources held. */
    data class Armed(val lease: VideoLease) : VideoPhase

    /** OpenCamera issued as [attemptGen]; resources belong to that attempt until its own close. */
    data class Opening(val lease: VideoLease, val attemptGen: Long) : VideoPhase

    /** setRepeatingRequest succeeded for [attemptGen]; frames are (about to be) flowing. */
    data class Capturing(val lease: VideoLease, val attemptGen: Long) : VideoPhase

    /** Capture failed while the placement had not yet returned a call id. Retained so binding the
     *  call applies an honest video-off instead of losing the failure. */
    data class FailedAwaitingBind(val lease: VideoLease) : VideoPhase

    /** A CURRENT winner differs from the lease owner; the exact-source adoption query is in
     *  flight. The old owner's terminal must NOT revoke while this is pending. [attemptGen] is
     *  non-null when Camera2 resources exist; [capturing] preserves Opening-vs-Capturing; and
     *  [outcome] retains any failure/off truth learned before the ownership answer arrives. */
    data class PendingReplacement(
        val lease: VideoLease,
        val attemptGen: Long?,
        val capturing: Boolean,
        val outcome: PendingVideoOutcome,
        val winnerCallId: String,
        val queryEpoch: Long,
    ) : VideoPhase
}

internal sealed interface VideoDecision {
    /** Open [physicalCameraId] as attempt [attemptGen]; completion must re-present the gen. */
    data class OpenCamera(
        val physicalCameraId: String,
        val attemptGen: Long,
        val epoch: Long,
        val kind: LocalVideoKind = LocalVideoKind.CAMERA,
    ) : VideoDecision

    /** Close the resources of exactly this attempt (a stale attempt closes only its own). */
    data class CloseCamera(val attemptGen: Long) : VideoDecision

    /** A screen input resumed after a transient daemon StopCapture. Its existing encoder remains
     *  owned by [attemptGen], but the RTP sender needs a fresh recovery point. */
    data class RequestKeyFrame(val attemptGen: Long) : VideoDecision

    /** Capture failed for a bound call: issue the MUTED=true re-invite naming the exact live
     *  source (an empty/different SOURCE would read as a source change and restart ICE), report
     *  camera-off truth, and re-sync the foreground camera type. requestMediaChange acceptance is
     *  LOCAL-only in this daemon; the report is truthful regardless. */
    data class DisableCallVideo(val callId: String, val sinkId: String, val epoch: Long) : VideoDecision

    /** Report camera truth only (already correct on the wire; no re-invite). */
    data class ReportCameraState(val callId: String, val on: Boolean, val epoch: Long) : VideoDecision

    /** Run the exact-source ownership query (currentMediaList) for a pending replacement. */
    data class QueryAdoption(val winnerCallId: String, val sinkId: String, val queryEpoch: Long) : VideoDecision
}

internal data class VideoTransition(val phase: VideoPhase, val decisions: List<VideoDecision> = emptyList())

/** The lease carried by any non-Idle phase (JamiCore reads this under its lifecycle lock). */
internal fun VideoPhase.currentLease(): VideoLease? = when (this) {
    is VideoPhase.Armed -> lease
    is VideoPhase.Opening -> lease
    is VideoPhase.Capturing -> lease
    is VideoPhase.FailedAwaitingBind -> lease
    is VideoPhase.PendingReplacement -> lease
    VideoPhase.Idle, is VideoPhase.DormantDemand -> null
}

internal object LocalVideoPolicy {
    private fun VideoPhase.lease(): VideoLease? = currentLease()

    private fun VideoPhase.attemptGen(): Long? = when (this) {
        is VideoPhase.Opening -> attemptGen
        is VideoPhase.Capturing -> attemptGen
        is VideoPhase.PendingReplacement -> attemptGen
        else -> null
    }

    private fun closeHeld(phase: VideoPhase): List<VideoDecision> =
        phase.attemptGen()?.let { listOf(VideoDecision.CloseCamera(it)) } ?: emptyList()

    /** A peer's independent source change cannot revoke our exact live lease.
     * The caller reasserts this lease as its own media transaction; every
     * token/call check remains explicit so a stale peer answer cannot revive
     * a stopped or replaced source. */
    fun shouldReassertAfterPeerAnswer(
        phase: VideoPhase,
        callId: String,
        leaseEpoch: Long,
        sinkId: String,
        followsPeerAnswer: Boolean,
        negotiatedOwnsSource: Boolean,
        authoritativeCall: Boolean,
    ): Boolean {
        val lease = phase.lease() ?: return false
        return followsPeerAnswer &&
            !negotiatedOwnsSource &&
            authoritativeCall &&
            lease.ownerCallId == callId &&
            lease.epoch == leaseEpoch &&
            lease.sinkId == sinkId
    }

    /** Capture became impossible: bound lease → honest per-call video disable; unbound placement →
     *  retain the failure so the eventual bind (or winner) applies it. */
    private fun failCapture(phase: VideoPhase, lease: VideoLease, closeGen: Long? = null): VideoTransition {
        val close = (closeGen ?: phase.attemptGen())?.let { listOf<VideoDecision>(VideoDecision.CloseCamera(it)) }
            ?: emptyList()
        val owner = lease.ownerCallId
        return if (owner != null) {
            VideoTransition(VideoPhase.Idle, close + VideoDecision.DisableCallVideo(owner, lease.sinkId, lease.epoch))
        } else {
            VideoTransition(VideoPhase.FailedAwaitingBind(lease), close)
        }
    }

    /** Declare a new send intent (placement or mid-call start). Supersedes any prior lease. */
    fun arm(
        phase: VideoPhase,
        epoch: Long,
        registeredDeviceId: String,
        physicalCameraId: String,
        ownerCallId: String?,
        kind: LocalVideoKind = LocalVideoKind.CAMERA,
        width: Int = 0,
        height: Int = 0,
    ): VideoTransition {
        val inheritsDemand = phase is VideoPhase.DormantDemand &&
            ownerCallId != null &&
            phase.ownerCallId == ownerCallId &&
            phase.registeredDeviceId == registeredDeviceId &&
            phase.kind == kind
        return VideoTransition(
            VideoPhase.Armed(
                VideoLease(
                    epoch = epoch,
                    registeredDeviceId = registeredDeviceId,
                    sinkId = CAMERA_MRL_PREFIX + registeredDeviceId,
                    physicalCameraId = physicalCameraId,
                    ownerCallId = ownerCallId,
                    captureDemanded = inheritsDemand,
                    kind = kind,
                    width = width,
                    height = height,
                )
            ),
            closeHeld(phase),
        )
    }

    /** The camera-typed foreground promotion for [epoch] is live; a waiting demand may now open. */
    fun fgsConfirmed(phase: VideoPhase, epoch: Long, nextAttemptGen: Long): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (lease.epoch != epoch) return VideoTransition(phase)
        val confirmed = lease.copy(fgsConfirmed = true)
        return when (phase) {
            is VideoPhase.Armed ->
                if (confirmed.captureDemanded) {
                    VideoTransition(
                        VideoPhase.Opening(confirmed, nextAttemptGen),
                        listOf(VideoDecision.OpenCamera(
                            confirmed.physicalCameraId,
                            nextAttemptGen,
                            confirmed.epoch,
                            confirmed.kind,
                        )),
                    )
                } else VideoTransition(VideoPhase.Armed(confirmed))
            is VideoPhase.Opening -> VideoTransition(phase.copy(lease = confirmed))
            is VideoPhase.Capturing -> VideoTransition(phase.copy(lease = confirmed))
            is VideoPhase.FailedAwaitingBind -> VideoTransition(phase.copy(lease = confirmed))
            is VideoPhase.PendingReplacement -> VideoTransition(phase.copy(lease = confirmed))
            VideoPhase.Idle, is VideoPhase.DormantDemand -> VideoTransition(phase)
        }
    }

    /** Foreground promotion failed: capture is impossible — treat as a capture failure. */
    fun fgsFailed(phase: VideoPhase, epoch: Long): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (lease.epoch != epoch) return VideoTransition(phase)
        return when (phase) {
            is VideoPhase.Armed, is VideoPhase.Opening, is VideoPhase.Capturing -> failCapture(phase, lease)
            is VideoPhase.PendingReplacement -> {
                val failedLease = lease.copy(fgsConfirmed = false)
                val outcome = if (phase.outcome == PendingVideoOutcome.NEGOTIATED_OFF) {
                    PendingVideoOutcome.NEGOTIATED_OFF
                } else {
                    PendingVideoOutcome.CAPTURE_FAILED
                }
                VideoTransition(
                    phase.copy(
                        lease = failedLease,
                        attemptGen = null,
                        capturing = false,
                        outcome = outcome,
                    ),
                    closeHeld(phase),
                )
            }
            else -> VideoTransition(phase)
        }
    }

    /** The placement that armed an unbound lease returned [callId]. Idempotent for a lease already
     *  bound to the same call; never rebinds a lease owned by a different call. */
    fun bindCall(phase: VideoPhase, epoch: Long, callId: String): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (lease.epoch != epoch || callId.isEmpty()) return VideoTransition(phase)
        if (lease.ownerCallId != null) return VideoTransition(phase)
        val bound = lease.copy(ownerCallId = callId)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(VideoPhase.Armed(bound))
            is VideoPhase.Opening -> VideoTransition(phase.copy(lease = bound))
            is VideoPhase.Capturing -> VideoTransition(phase.copy(lease = bound))
            // A pre-bind capture failure was retained precisely for this moment: the call now
            // exists, so apply the honest video-off to it.
            is VideoPhase.FailedAwaitingBind ->
                VideoTransition(VideoPhase.Idle, listOf(VideoDecision.DisableCallVideo(callId, lease.sinkId, lease.epoch)))
            is VideoPhase.PendingReplacement -> VideoTransition(phase.copy(lease = bound))
            VideoPhase.Idle, is VideoPhase.DormantDemand -> VideoTransition(phase)
        }
    }

    /** Daemon demand for frames. Opens only a confirmed-FGS lease; otherwise waits in Armed. */
    fun startCapture(phase: VideoPhase, deviceId: String, nextAttemptGen: Long): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (deviceId != lease.registeredDeviceId) return VideoTransition(phase) // foreign device
        return when (phase) {
            is VideoPhase.Armed -> {
                val demanded = lease.copy(captureDemanded = true)
                if (demanded.fgsConfirmed) {
                    VideoTransition(
                        VideoPhase.Opening(demanded, nextAttemptGen),
                        listOf(VideoDecision.OpenCamera(
                            demanded.physicalCameraId,
                            nextAttemptGen,
                            demanded.epoch,
                            demanded.kind,
                        )),
                    )
                } else VideoTransition(VideoPhase.Armed(demanded))
            }
            // Already opening/capturing for this device: record the demand, keep the attempt.
            is VideoPhase.Opening -> {
                val resumedScreen = lease.kind == LocalVideoKind.SCREEN && !lease.captureDemanded
                VideoTransition(
                    phase.copy(lease = lease.copy(captureDemanded = true)),
                    if (resumedScreen) {
                        listOf(VideoDecision.RequestKeyFrame(phase.attemptGen))
                    } else {
                        emptyList()
                    },
                )
            }
            is VideoPhase.Capturing -> {
                val resumedScreen = lease.kind == LocalVideoKind.SCREEN && !lease.captureDemanded
                VideoTransition(
                    phase.copy(lease = lease.copy(captureDemanded = true)),
                    if (resumedScreen) {
                        listOf(VideoDecision.RequestKeyFrame(phase.attemptGen))
                    } else {
                        emptyList()
                    },
                )
            }
            is VideoPhase.PendingReplacement -> {
                val resumedScreen = lease.kind == LocalVideoKind.SCREEN &&
                    !lease.captureDemanded &&
                    phase.attemptGen != null
                VideoTransition(
                    phase.copy(lease = lease.copy(captureDemanded = true)),
                    if (resumedScreen) {
                        listOf(VideoDecision.RequestKeyFrame(phase.attemptGen))
                    } else {
                        emptyList()
                    },
                )
            }
            else -> VideoTransition(phase)
        }
    }

    /** Camera2 attempt completion. Stale generations are discarded (their executor closes only
     *  their own resources). Success counts only after setRepeatingRequest succeeded. */
    fun openResult(phase: VideoPhase, attemptGen: Long, ok: Boolean): VideoTransition = when (phase) {
        is VideoPhase.Opening ->
            if (phase.attemptGen != attemptGen) VideoTransition(phase)
            else if (ok) VideoTransition(VideoPhase.Capturing(phase.lease, attemptGen))
            else failCapture(phase, phase.lease, closeGen = attemptGen)
        is VideoPhase.Capturing ->
            if (phase.attemptGen != attemptGen || ok) VideoTransition(phase)
            // Runtime loss (disconnect/error after configure) — same honest downgrade.
            else failCapture(phase, phase.lease, closeGen = attemptGen)
        is VideoPhase.PendingReplacement ->
            if (phase.attemptGen != attemptGen) VideoTransition(phase)
            else if (ok) VideoTransition(phase.copy(capturing = true))
            else VideoTransition(
                phase.copy(
                    attemptGen = null,
                    capturing = false,
                    outcome = if (phase.outcome == PendingVideoOutcome.NEGOTIATED_OFF) {
                        PendingVideoOutcome.NEGOTIATED_OFF
                    } else {
                        PendingVideoOutcome.CAPTURE_FAILED
                    },
                ),
                listOf(VideoDecision.CloseCamera(attemptGen)),
            )
        else -> VideoTransition(phase)
    }

    /** Daemon withdrew its demand (input released). The lease survives — a renegotiation may
     *  demand again; terminal/user paths revoke separately. */
    fun stopCapture(phase: VideoPhase, deviceId: String): VideoTransition {
        if (phase is VideoPhase.DormantDemand) {
            return if (deviceId == phase.registeredDeviceId) {
                VideoTransition(VideoPhase.Idle)
            } else {
                VideoTransition(phase)
            }
        }
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (deviceId != lease.registeredDeviceId) return VideoTransition(phase) // stale/foreign stop
        val undemanded = lease.copy(captureDemanded = false)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(VideoPhase.Armed(undemanded))
            is VideoPhase.Opening ->
                if (lease.kind == LocalVideoKind.SCREEN) {
                    VideoTransition(phase.copy(lease = undemanded))
                } else {
                    VideoTransition(
                        VideoPhase.Armed(undemanded),
                        listOf(VideoDecision.CloseCamera(phase.attemptGen)),
                    )
                }
            is VideoPhase.Capturing ->
                if (lease.kind == LocalVideoKind.SCREEN) {
                    // Media-source reinitialization emits StopCapture/StartCapture around the same
                    // one-shot projection. Keep the exact attempt parked; user Off, negotiated Off,
                    // terminal state, replacement, and projection/encoder failure still close it.
                    VideoTransition(phase.copy(lease = undemanded))
                } else {
                    VideoTransition(
                        VideoPhase.Armed(undemanded),
                        listOf(VideoDecision.CloseCamera(phase.attemptGen)),
                    )
                }
            is VideoPhase.PendingReplacement -> {
                if (lease.kind == LocalVideoKind.SCREEN) {
                    VideoTransition(phase.copy(lease = undemanded))
                } else {
                    val close = phase.attemptGen?.let {
                        listOf(VideoDecision.CloseCamera(it))
                    } ?: emptyList()
                    VideoTransition(
                        phase.copy(lease = undemanded, attemptGen = null, capturing = false),
                        close,
                    )
                }
            }
            else -> VideoTransition(phase)
        }
    }

    /** Publish the geometry actually produced by a live encoder. The ownership epoch stays fixed;
     *  stale resize completions cannot modify a replacement lease. */
    fun resize(phase: VideoPhase, epoch: Long, width: Int, height: Int): VideoTransition {
        if (width <= 0 || height <= 0) return VideoTransition(phase)
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (lease.epoch != epoch) return VideoTransition(phase)
        val resized = lease.copy(width = width, height = height)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(phase.copy(lease = resized))
            is VideoPhase.Opening -> VideoTransition(phase.copy(lease = resized))
            is VideoPhase.Capturing -> VideoTransition(phase.copy(lease = resized))
            is VideoPhase.FailedAwaitingBind -> VideoTransition(phase.copy(lease = resized))
            is VideoPhase.PendingReplacement -> VideoTransition(phase.copy(lease = resized))
            VideoPhase.Idle, is VideoPhase.DormantDemand -> VideoTransition(phase)
        }
    }

    /** User flipped front/back: only the physical Camera2 selection changes while no hardware is
     *  held; a held attempt is replaced (close old attempt, open the new physical device) under the
     *  SAME daemon input — never a daemon source change. */
    fun flip(phase: VideoPhase, newPhysicalId: String, nextAttemptGen: Long): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        val flipped = lease.copy(physicalCameraId = newPhysicalId)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(VideoPhase.Armed(flipped))
            is VideoPhase.FailedAwaitingBind -> VideoTransition(phase.copy(lease = flipped))
            is VideoPhase.Opening -> VideoTransition(
                VideoPhase.Opening(flipped, nextAttemptGen),
                listOf(
                    VideoDecision.CloseCamera(phase.attemptGen),
                    VideoDecision.OpenCamera(newPhysicalId, nextAttemptGen, flipped.epoch, flipped.kind),
                ),
            )
            is VideoPhase.Capturing -> VideoTransition(
                VideoPhase.Opening(flipped, nextAttemptGen),
                listOf(
                    VideoDecision.CloseCamera(phase.attemptGen),
                    VideoDecision.OpenCamera(newPhysicalId, nextAttemptGen, flipped.epoch, flipped.kind),
                ),
            )
            is VideoPhase.PendingReplacement -> VideoTransition(phase.copy(lease = flipped))
            VideoPhase.Idle, is VideoPhase.DormantDemand -> VideoTransition(phase)
        }
    }

    /** User turned the camera off. JamiCore issues the re-invite itself (existing stopVideo flow);
     *  the coordinator only releases ownership + hardware. */
    fun userStop(phase: VideoPhase, callId: String?): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (phase is VideoPhase.PendingReplacement) {
            return if (callId == null || callId == phase.winnerCallId) {
                val stopped = if (
                    callId != null && (lease.captureDemanded || phase.attemptGen != null)
                ) {
                    VideoPhase.DormantDemand(lease.registeredDeviceId, callId, lease.kind)
                } else {
                    VideoPhase.Idle
                }
                VideoTransition(stopped, closeHeld(phase))
            } else {
                // The old owner is no longer authoritative while the CURRENT winner's exact
                // source ownership is being adjudicated.
                VideoTransition(phase)
            }
        }
        if (callId != null && lease.ownerCallId != null && lease.ownerCallId != callId) {
            return VideoTransition(phase)
        }
        val owner = callId ?: lease.ownerCallId
        val stopped = if (owner != null && (lease.captureDemanded || phase.attemptGen() != null)) {
            VideoPhase.DormantDemand(lease.registeredDeviceId, owner, lease.kind)
        } else {
            VideoPhase.Idle
        }
        return VideoTransition(stopped, closeHeld(phase))
    }

    /** A call reached a terminal state. Only the owning call's terminal revokes; while a
     *  replacement is pending the LOSER's terminal must not close what the winner may adopt. */
    fun terminal(phase: VideoPhase, callId: String): VideoTransition {
        if (phase is VideoPhase.DormantDemand) {
            return if (phase.ownerCallId == callId) {
                VideoTransition(VideoPhase.Idle)
            } else {
                VideoTransition(phase)
            }
        }
        val lease = phase.lease() ?: return VideoTransition(phase)
        return when (phase) {
            is VideoPhase.PendingReplacement -> when (callId) {
                // The winner died while adjudicating: nothing left to adopt.
                phase.winnerCallId -> VideoTransition(VideoPhase.Idle, closeHeld(phase))
                else -> VideoTransition(phase) // loser terminal: hold for the resolution
            }
            else ->
                if (lease.ownerCallId == callId) VideoTransition(VideoPhase.Idle, closeHeld(phase))
                else VideoTransition(phase)
        }
    }

    /** NEGOTIATION_SUCCESS snapshot says whether the call's live media list still owns our exact
     *  source. Guarded, tokenless signal: acts only on the owning call, and only to turn video
     *  OFF-truthfully — never to (re)enable. */
    fun negotiated(phase: VideoPhase, callId: String, ownsSource: Boolean): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (phase is VideoPhase.PendingReplacement) {
            if (callId != phase.winnerCallId || ownsSource) return VideoTransition(phase)
            val offLease = lease.copy(captureDemanded = false)
            return VideoTransition(
                phase.copy(
                    lease = offLease,
                    attemptGen = null,
                    capturing = false,
                    outcome = PendingVideoOutcome.NEGOTIATED_OFF,
                ),
                closeHeld(phase),
            )
        }
        if (lease.ownerCallId != callId || ownsSource) return VideoTransition(phase)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(
                VideoPhase.Idle,
                listOf(VideoDecision.ReportCameraState(callId, false, lease.epoch)),
            )
            is VideoPhase.Opening, is VideoPhase.Capturing -> VideoTransition(
                VideoPhase.Idle,
                closeHeld(phase) + VideoDecision.ReportCameraState(callId, false, lease.epoch),
            )
            else -> VideoTransition(phase) // pending replacement resolution owns the outcome
        }
    }

    /** A CURRENT winner exists and differs from the lease owner (or the lease is unbound —
     *  including the CURRENT-before-placement-reply race). Enter PendingReplacement UNDER the
     *  lifecycle lock BEFORE any sibling retirement, then query exact-source ownership. */
    fun beginReplacement(phase: VideoPhase, winnerCallId: String, queryEpoch: Long): VideoTransition {
        val lease = phase.lease() ?: return VideoTransition(phase)
        if (lease.ownerCallId == winnerCallId) return VideoTransition(phase)
        return when (phase) {
            is VideoPhase.Armed -> VideoTransition(
                VideoPhase.PendingReplacement(
                    lease,
                    null,
                    capturing = false,
                    PendingVideoOutcome.VIABLE,
                    winnerCallId,
                    queryEpoch,
                ),
                listOf(VideoDecision.QueryAdoption(winnerCallId, lease.sinkId, queryEpoch)),
            )
            is VideoPhase.Opening -> VideoTransition(
                VideoPhase.PendingReplacement(
                    lease,
                    phase.attemptGen,
                    capturing = false,
                    PendingVideoOutcome.VIABLE,
                    winnerCallId,
                    queryEpoch,
                ),
                listOf(VideoDecision.QueryAdoption(winnerCallId, lease.sinkId, queryEpoch)),
            )
            is VideoPhase.Capturing -> VideoTransition(
                VideoPhase.PendingReplacement(
                    lease,
                    phase.attemptGen,
                    capturing = true,
                    PendingVideoOutcome.VIABLE,
                    winnerCallId,
                    queryEpoch,
                ),
                listOf(VideoDecision.QueryAdoption(winnerCallId, lease.sinkId, queryEpoch)),
            )
            // A retained pre-bind failure still needs exact-source proof before touching the
            // winner. A crossed audio-only winner must never receive our speculative disable.
            is VideoPhase.FailedAwaitingBind -> VideoTransition(
                VideoPhase.PendingReplacement(
                    lease,
                    null,
                    capturing = false,
                    PendingVideoOutcome.CAPTURE_FAILED,
                    winnerCallId,
                    queryEpoch,
                ),
                listOf(VideoDecision.QueryAdoption(winnerCallId, lease.sinkId, queryEpoch)),
            )
            is VideoPhase.PendingReplacement -> VideoTransition(phase) // one adjudication at a time
            VideoPhase.Idle, is VideoPhase.DormantDemand -> VideoTransition(phase)
        }
    }

    /** The exact-source ownership answer for [queryEpoch]. [nextAttemptGen] is allocated by the
     *  caller and is consumed only when demand+FGS arrived during adjudication without a held
     *  Camera2 attempt. */
    fun resolveReplacement(
        phase: VideoPhase,
        queryEpoch: Long,
        ownsSource: Boolean,
        nextAttemptGen: Long,
    ): VideoTransition {
        if (phase !is VideoPhase.PendingReplacement || phase.queryEpoch != queryEpoch) {
            return VideoTransition(phase)
        }
        val winner = phase.winnerCallId
        val adopted = phase.lease.copy(ownerCallId = winner)
        return when {
            ownsSource && phase.outcome == PendingVideoOutcome.CAPTURE_FAILED -> VideoTransition(
                VideoPhase.Idle,
                listOf(VideoDecision.DisableCallVideo(winner, phase.lease.sinkId, phase.lease.epoch)),
            )
            phase.outcome == PendingVideoOutcome.NEGOTIATED_OFF -> VideoTransition(
                VideoPhase.Idle,
                closeHeld(phase) + VideoDecision.ReportCameraState(winner, false, phase.lease.epoch),
            )
            ownsSource -> {
                when {
                    phase.attemptGen != null -> {
                        val restored = if (phase.capturing) {
                            VideoPhase.Capturing(adopted, phase.attemptGen)
                        } else {
                            VideoPhase.Opening(adopted, phase.attemptGen)
                        }
                        VideoTransition(
                            restored,
                            listOf(VideoDecision.ReportCameraState(winner, true, adopted.epoch)),
                        )
                    }
                    adopted.fgsConfirmed && adopted.captureDemanded -> VideoTransition(
                        VideoPhase.Opening(adopted, nextAttemptGen),
                        listOf(
                            VideoDecision.OpenCamera(
                                adopted.physicalCameraId,
                                nextAttemptGen,
                                adopted.epoch,
                                adopted.kind,
                            ),
                            VideoDecision.ReportCameraState(winner, true, adopted.epoch),
                        ),
                    )
                    else -> VideoTransition(
                        VideoPhase.Armed(adopted),
                        listOf(VideoDecision.ReportCameraState(winner, true, adopted.epoch)),
                    )
                }
            }
            else -> VideoTransition(
                VideoPhase.Idle,
                closeHeld(phase) + VideoDecision.ReportCameraState(winner, false, phase.lease.epoch),
            )
        }
    }

    /** Unconditional release: abandoned placement, dismissal, daemon-rejected re-invite, exceptions. */
    fun revoke(phase: VideoPhase): VideoTransition = VideoTransition(VideoPhase.Idle, closeHeld(phase))

    const val CAMERA_MRL_PREFIX = "camera://"
}
