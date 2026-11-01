package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure trace vectors for the intent-first local-video coordinator. No Android, no daemon. */
class LocalVideoCoordinatorTest {
    private val dev = "1"
    private val sink = "camera://1"

    private fun armed(
        epoch: Long = 1,
        owner: String? = null,
        fgs: Boolean = false,
        demanded: Boolean = false,
        physical: String = dev,
    ) = VideoPhase.Armed(
        VideoLease(epoch, dev, sink, physical, owner, fgsConfirmed = fgs, captureDemanded = demanded)
    )

    @Test
    fun `intent then fgs then demand opens exactly once and captures`() {
        var t = LocalVideoPolicy.arm(VideoPhase.Idle, epoch = 1, registeredDeviceId = dev, physicalCameraId = dev, ownerCallId = null)
        assertTrue(t.phase is VideoPhase.Armed)
        assertTrue(t.decisions.isEmpty())

        t = LocalVideoPolicy.bindCall(t.phase, epoch = 1, callId = "call-a")
        t = LocalVideoPolicy.fgsConfirmed(t.phase, epoch = 1, nextAttemptGen = 10)
        assertTrue(t.decisions.isEmpty()) // no demand yet — FGS alone must not open hardware

        t = LocalVideoPolicy.startCapture(t.phase, dev, nextAttemptGen = 11)
        assertEquals(listOf<VideoDecision>(VideoDecision.OpenCamera(dev, 11, 1)), t.decisions)

        t = LocalVideoPolicy.openResult(t.phase, attemptGen = 11, ok = true)
        assertTrue(t.phase is VideoPhase.Capturing)
        assertTrue(t.decisions.isEmpty())
    }

    @Test
    fun `demand before fgs confirmation waits and opens on the confirmation`() {
        var t = LocalVideoPolicy.arm(VideoPhase.Idle, 1, dev, dev, ownerCallId = "call-a")
        t = LocalVideoPolicy.startCapture(t.phase, dev, nextAttemptGen = 10)
        assertTrue(t.phase is VideoPhase.Armed) // demanded, but FGS not confirmed → no hardware
        assertTrue(t.decisions.isEmpty())

        t = LocalVideoPolicy.fgsConfirmed(t.phase, epoch = 1, nextAttemptGen = 11)
        assertEquals(listOf<VideoDecision>(VideoDecision.OpenCamera(dev, 11, 1)), t.decisions)
        assertTrue(t.phase is VideoPhase.Opening)
    }

    @Test
    fun `stale fgs confirmation for an old epoch is discarded`() {
        val t = LocalVideoPolicy.fgsConfirmed(armed(epoch = 2, demanded = true), epoch = 1, nextAttemptGen = 10)
        assertTrue(t.phase is VideoPhase.Armed)
        assertTrue(t.decisions.isEmpty())
        assertEquals(false, (t.phase as VideoPhase.Armed).lease.fgsConfirmed)
    }

    @Test
    fun `foreign-device demand and stop are ignored`() {
        val open = LocalVideoPolicy.startCapture(armed(fgs = true), "999", nextAttemptGen = 10)
        assertTrue(open.decisions.isEmpty())

        val capturing = VideoPhase.Capturing(armed(fgs = true, demanded = true).lease, attemptGen = 10)
        val stop = LocalVideoPolicy.stopCapture(capturing, "999")
        assertEquals(capturing, stop.phase)
        assertTrue(stop.decisions.isEmpty())
    }

    @Test
    fun `pre-bind capture failure is retained and applied when the call binds`() {
        var t = LocalVideoPolicy.arm(VideoPhase.Idle, 1, dev, dev, ownerCallId = null)
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 1, nextAttemptGen = 10)
        t = LocalVideoPolicy.startCapture(t.phase, dev, nextAttemptGen = 11)
        t = LocalVideoPolicy.openResult(t.phase, attemptGen = 11, ok = false)
        assertTrue(t.phase is VideoPhase.FailedAwaitingBind)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(11)), t.decisions)

        t = LocalVideoPolicy.bindCall(t.phase, epoch = 1, callId = "call-a")
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.DisableCallVideo("call-a", sink, 1)), t.decisions)
    }

    @Test
    fun `bound capture failure disables that call's video`() {
        var t = LocalVideoPolicy.startCapture(armed(owner = "call-a", fgs = true), dev, nextAttemptGen = 10)
        t = LocalVideoPolicy.openResult(t.phase, attemptGen = 10, ok = false)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(
            listOf(VideoDecision.CloseCamera(10), VideoDecision.DisableCallVideo("call-a", sink, 1)),
            t.decisions,
        )
    }

    @Test
    fun `runtime camera loss while capturing downgrades honestly`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        val t = LocalVideoPolicy.openResult(capturing, attemptGen = 10, ok = false)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(
            listOf(VideoDecision.CloseCamera(10), VideoDecision.DisableCallVideo("call-a", sink, 1)),
            t.decisions,
        )
    }

    @Test
    fun `stale open results are discarded without touching the live attempt`() {
        val opening = VideoPhase.Opening(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 11)
        val t = LocalVideoPolicy.openResult(opening, attemptGen = 10, ok = false)
        assertEquals(opening, t.phase)
        assertTrue(t.decisions.isEmpty())
    }

    @Test
    fun `terminal before the open completes revokes and the late result is inert`() {
        var t = LocalVideoPolicy.startCapture(armed(owner = "call-a", fgs = true), dev, nextAttemptGen = 10)
        assertTrue(t.phase is VideoPhase.Opening)

        t = LocalVideoPolicy.terminal(t.phase, "call-a")
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        val late = LocalVideoPolicy.openResult(t.phase, attemptGen = 10, ok = true)
        assertEquals(VideoPhase.Idle, late.phase)
        assertTrue(late.decisions.isEmpty())
    }

    @Test
    fun `terminal for an unrelated call leaves the lease alone`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        val t = LocalVideoPolicy.terminal(capturing, "call-b")
        assertEquals(capturing, t.phase)
        assertTrue(t.decisions.isEmpty())
    }

    @Test
    fun `flip while armed changes only the physical selection`() {
        val t = LocalVideoPolicy.flip(armed(owner = "call-a"), newPhysicalId = "2", nextAttemptGen = 10)
        assertTrue(t.decisions.isEmpty())
        assertEquals("2", (t.phase as VideoPhase.Armed).lease.physicalCameraId)
        assertEquals(dev, t.phase.lease.registeredDeviceId) // daemon-visible identity never flips
    }

    @Test
    fun `flip while capturing replaces the attempt under the same daemon input`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        val t = LocalVideoPolicy.flip(capturing, newPhysicalId = "2", nextAttemptGen = 11)
        assertEquals(
            listOf(VideoDecision.CloseCamera(10), VideoDecision.OpenCamera("2", 11, 1)),
            t.decisions,
        )
        assertTrue(t.phase is VideoPhase.Opening)
        assertEquals(sink, (t.phase as VideoPhase.Opening).lease.sinkId)
    }

    @Test
    fun `daemon stop after a flip still closes because identity is the registered device`() {
        var t = LocalVideoPolicy.flip(
            VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10),
            newPhysicalId = "2",
            nextAttemptGen = 11,
        )
        t = LocalVideoPolicy.openResult(t.phase, attemptGen = 11, ok = true)
        val stop = LocalVideoPolicy.stopCapture(t.phase, dev) // daemon names its registered device
        assertTrue(stop.phase is VideoPhase.Armed)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(11)), stop.decisions)
    }

    @Test
    fun `user stop closes capture and retains only dormant daemon demand`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.userStop(capturing, "call-a")
        assertEquals(VideoPhase.DormantDemand(dev, "call-a"), t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        t = LocalVideoPolicy.startCapture(t.phase, dev, nextAttemptGen = 11)
        assertEquals(VideoPhase.DormantDemand(dev, "call-a"), t.phase)
        assertTrue(t.decisions.isEmpty())
    }

    @Test
    fun `rapid off then on inherits demand and reopens without another StartCapture`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.userStop(capturing, "call-a")
        t = LocalVideoPolicy.arm(t.phase, epoch = 2, registeredDeviceId = dev, physicalCameraId = dev, ownerCallId = "call-a")
        t = LocalVideoPolicy.fgsConfirmed(t.phase, epoch = 2, nextAttemptGen = 11)
        assertEquals(listOf<VideoDecision>(VideoDecision.OpenCamera(dev, 11, 2)), t.decisions)
        assertTrue(t.phase is VideoPhase.Opening)

        val stale = LocalVideoPolicy.openResult(t.phase, attemptGen = 10, ok = false)
        assertEquals(t.phase, stale.phase) // the dead attempt cannot fail the new one
        assertTrue(stale.decisions.isEmpty())
    }

    @Test
    fun `StopCapture while video is off clears dormant demand before a later arm`() {
        val capturing = VideoPhase.Capturing(
            armed(owner = "call-a", fgs = true, demanded = true).lease,
            attemptGen = 10,
        )
        var t = LocalVideoPolicy.userStop(capturing, "call-a")
        t = LocalVideoPolicy.stopCapture(t.phase, dev)
        assertEquals(VideoPhase.Idle, t.phase)

        t = LocalVideoPolicy.arm(t.phase, 2, dev, dev, ownerCallId = "call-a")
        assertEquals(false, (t.phase as VideoPhase.Armed).lease.captureDemanded)
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 2, nextAttemptGen = 11)
        assertTrue(t.decisions.isEmpty())
    }

    @Test
    fun `dormant demand is scoped to the same call and registered device`() {
        val dormant = VideoPhase.DormantDemand(dev, "call-a")

        val differentCall = LocalVideoPolicy.arm(
            dormant,
            epoch = 2,
            registeredDeviceId = dev,
            physicalCameraId = dev,
            ownerCallId = "call-b",
        )
        assertEquals(false, (differentCall.phase as VideoPhase.Armed).lease.captureDemanded)

        val differentDevice = LocalVideoPolicy.arm(
            dormant,
            epoch = 3,
            registeredDeviceId = "2",
            physicalCameraId = "2",
            ownerCallId = "call-a",
        )
        assertEquals(false, (differentDevice.phase as VideoPhase.Armed).lease.captureDemanded)

        val sameOwnerAndDevice = LocalVideoPolicy.arm(
            dormant,
            epoch = 4,
            registeredDeviceId = dev,
            physicalCameraId = "2",
            ownerCallId = "call-a",
        )
        assertEquals(true, (sameOwnerAndDevice.phase as VideoPhase.Armed).lease.captureDemanded)
    }

    @Test
    fun `terminal state clears dormant demand only for its owner`() {
        val dormant = VideoPhase.DormantDemand(dev, "call-a")
        val foreign = LocalVideoPolicy.terminal(dormant, "call-b")
        assertEquals(dormant, foreign.phase)

        val owner = LocalVideoPolicy.terminal(dormant, "call-a")
        assertEquals(VideoPhase.Idle, owner.phase)
        assertTrue(owner.decisions.isEmpty())
    }

    @Test
    fun `arming over a held attempt closes the prior attempt's resources`() {
        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        val t = LocalVideoPolicy.arm(capturing, epoch = 2, registeredDeviceId = dev, physicalCameraId = dev, ownerCallId = "call-b")
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)
        assertEquals(2, (t.phase as VideoPhase.Armed).lease.epoch)
    }

    @Test
    fun `replacement adjudicates before retirement and a loser terminal cannot revoke it`() {
        val capturing = VideoPhase.Capturing(armed(owner = "loser", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.beginReplacement(capturing, winnerCallId = "winner", queryEpoch = 7)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertEquals(listOf<VideoDecision>(VideoDecision.QueryAdoption("winner", sink, 7)), t.decisions)

        t = LocalVideoPolicy.terminal(t.phase, "loser")
        assertTrue(t.phase is VideoPhase.PendingReplacement) // held for the resolution
        assertTrue(t.decisions.isEmpty())

        t = LocalVideoPolicy.resolveReplacement(t.phase, queryEpoch = 7, ownsSource = true, nextAttemptGen = 20)
        assertTrue(t.phase is VideoPhase.Capturing)
        assertEquals("winner", (t.phase as VideoPhase.Capturing).lease.ownerCallId)
        assertEquals(listOf<VideoDecision>(VideoDecision.ReportCameraState("winner", true, 1)), t.decisions)
    }

    @Test
    fun `replacement without exact ownership closes the camera and reports off`() {
        val capturing = VideoPhase.Capturing(armed(owner = "loser", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.beginReplacement(capturing, "winner", queryEpoch = 7)
        t = LocalVideoPolicy.resolveReplacement(t.phase, queryEpoch = 7, ownsSource = false, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(
            listOf(VideoDecision.CloseCamera(10), VideoDecision.ReportCameraState("winner", false, 1)),
            t.decisions,
        )
    }

    @Test
    fun `demand received during replacement opens after exact-source adoption`() {
        var t = LocalVideoPolicy.beginReplacement(
            armed(owner = "loser", fgs = true),
            winnerCallId = "winner",
            queryEpoch = 7,
        )

        t = LocalVideoPolicy.startCapture(t.phase, dev, nextAttemptGen = 10)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertTrue((t.phase as VideoPhase.PendingReplacement).lease.captureDemanded)
        assertTrue(t.decisions.isEmpty()) // ownership must resolve before Camera2 opens

        t = LocalVideoPolicy.resolveReplacement(
            t.phase,
            queryEpoch = 7,
            ownsSource = true,
            nextAttemptGen = 20,
        )
        assertEquals(VideoPhase.Opening::class, t.phase::class)
        assertEquals(20, (t.phase as VideoPhase.Opening).attemptGen)
        assertEquals("winner", t.phase.lease.ownerCallId)
        assertEquals(
            listOf(
                VideoDecision.OpenCamera(dev, 20, 1),
                VideoDecision.ReportCameraState("winner", true, 1),
            ),
            t.decisions,
        )
    }

    @Test
    fun `fgs confirmation received during replacement opens preserved demand after adoption`() {
        var t = LocalVideoPolicy.beginReplacement(
            armed(owner = "loser", demanded = true),
            winnerCallId = "winner",
            queryEpoch = 7,
        )

        t = LocalVideoPolicy.fgsConfirmed(t.phase, epoch = 1, nextAttemptGen = 10)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertTrue((t.phase as VideoPhase.PendingReplacement).lease.fgsConfirmed)
        assertTrue(t.decisions.isEmpty())

        val stale = LocalVideoPolicy.resolveReplacement(
            t.phase,
            queryEpoch = 6,
            ownsSource = true,
            nextAttemptGen = 19,
        )
        assertEquals(t.phase, stale.phase)
        assertTrue(stale.decisions.isEmpty())

        t = LocalVideoPolicy.resolveReplacement(
            t.phase,
            queryEpoch = 7,
            ownsSource = true,
            nextAttemptGen = 20,
        )
        assertTrue(t.phase is VideoPhase.Opening)
        assertEquals(listOf(
            VideoDecision.OpenCamera(dev, 20, 1),
            VideoDecision.ReportCameraState("winner", true, 1),
        ), t.decisions)
    }

    @Test
    fun `winner terminal during adjudication ends it and the stale resolution is inert`() {
        val capturing = VideoPhase.Capturing(armed(owner = "loser", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.beginReplacement(capturing, "winner", queryEpoch = 7)
        t = LocalVideoPolicy.terminal(t.phase, "winner")
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        val stale = LocalVideoPolicy.resolveReplacement(t.phase, queryEpoch = 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, stale.phase)
        assertTrue(stale.decisions.isEmpty())
    }

    @Test
    fun `capture failure while pending resolves an owning winner to an honest disable`() {
        val opening = VideoPhase.Opening(armed(owner = "loser", fgs = true, demanded = true).lease, attemptGen = 10)
        var t = LocalVideoPolicy.beginReplacement(opening, "winner", queryEpoch = 7)
        t = LocalVideoPolicy.openResult(t.phase, attemptGen = 10, ok = false)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        t = LocalVideoPolicy.resolveReplacement(t.phase, queryEpoch = 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.DisableCallVideo("winner", sink, 1)), t.decisions)
    }

    @Test
    fun `fgs failure while replacement is pending is retained through a positive answer`() {
        val opening = VideoPhase.Opening(
            armed(owner = "loser", fgs = true, demanded = true).lease,
            attemptGen = 10,
        )
        var t = LocalVideoPolicy.beginReplacement(opening, "winner", queryEpoch = 7)
        t = LocalVideoPolicy.fgsFailed(t.phase, epoch = 1)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertEquals(PendingVideoOutcome.CAPTURE_FAILED, (t.phase as VideoPhase.PendingReplacement).outcome)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        t = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.DisableCallVideo("winner", sink, 1)), t.decisions)
    }

    @Test
    fun `winner negotiated off while replacement is pending cannot be restored by query`() {
        val capturing = VideoPhase.Capturing(
            armed(owner = "loser", fgs = true, demanded = true).lease,
            attemptGen = 10,
        )
        var t = LocalVideoPolicy.beginReplacement(capturing, "winner", queryEpoch = 7)

        val loserOff = LocalVideoPolicy.negotiated(t.phase, "loser", ownsSource = false)
        assertEquals(t.phase, loserOff.phase) // only the prospective winner is authoritative

        t = LocalVideoPolicy.negotiated(t.phase, "winner", ownsSource = false)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertEquals(PendingVideoOutcome.NEGOTIATED_OFF, (t.phase as VideoPhase.PendingReplacement).outcome)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        t = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.ReportCameraState("winner", false, 1)), t.decisions)
    }

    @Test
    fun `winner user stop during replacement revokes hardware and makes the query stale`() {
        val capturing = VideoPhase.Capturing(
            armed(owner = "loser", fgs = true, demanded = true).lease,
            attemptGen = 10,
        )
        var t = LocalVideoPolicy.beginReplacement(capturing, "winner", queryEpoch = 7)
        val loserStop = LocalVideoPolicy.userStop(t.phase, "loser")
        assertEquals(t.phase, loserStop.phase)

        t = LocalVideoPolicy.userStop(t.phase, "winner")
        assertEquals(VideoPhase.DormantDemand(dev, "winner"), t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.CloseCamera(10)), t.decisions)

        val stale = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.DormantDemand(dev, "winner"), stale.phase)
        assertTrue(stale.decisions.isEmpty())
    }

    @Test
    fun `unbound lease meets a CURRENT winner through the same adjudication`() {
        // CURRENT can beat the placeCall reply: the lease is unbound, the winner is our own leg.
        var t = LocalVideoPolicy.beginReplacement(armed(owner = null, fgs = true), "winner", queryEpoch = 7)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        t = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals("winner", (t.phase as VideoPhase.Armed).lease.ownerCallId)
    }

    @Test
    fun `retained pre-bind failure queries ownership before touching the winner`() {
        val failed = VideoPhase.FailedAwaitingBind(armed(owner = null).lease)
        var t = LocalVideoPolicy.beginReplacement(failed, "winner", queryEpoch = 7)
        assertTrue(t.phase is VideoPhase.PendingReplacement)
        assertEquals(listOf<VideoDecision>(VideoDecision.QueryAdoption("winner", sink, 7)), t.decisions)

        t = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = true, nextAttemptGen = 20)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.DisableCallVideo("winner", sink, 1)), t.decisions)
    }

    @Test
    fun `retained pre-bind failure never disables a winner without exact ownership`() {
        val failed = VideoPhase.FailedAwaitingBind(armed(owner = null).lease)
        var t = LocalVideoPolicy.beginReplacement(failed, "winner", queryEpoch = 7)
        t = LocalVideoPolicy.resolveReplacement(t.phase, 7, ownsSource = false, nextAttemptGen = 20)

        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.ReportCameraState("winner", false, 1)), t.decisions)
    }

    @Test
    fun `negotiated-off reconciles armed opening and capturing but never a foreign call`() {
        val armedT = LocalVideoPolicy.negotiated(armed(owner = "call-a"), "call-a", ownsSource = false)
        assertEquals(VideoPhase.Idle, armedT.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.ReportCameraState("call-a", false, 1)), armedT.decisions)

        val opening = VideoPhase.Opening(
            armed(owner = "call-a", fgs = true, demanded = true).lease,
            attemptGen = 9,
        )
        val openingT = LocalVideoPolicy.negotiated(opening, "call-a", ownsSource = false)
        assertEquals(VideoPhase.Idle, openingT.phase)
        assertEquals(
            listOf(VideoDecision.CloseCamera(9), VideoDecision.ReportCameraState("call-a", false, 1)),
            openingT.decisions,
        )

        val capturing = VideoPhase.Capturing(armed(owner = "call-a", fgs = true, demanded = true).lease, attemptGen = 10)
        val capT = LocalVideoPolicy.negotiated(capturing, "call-a", ownsSource = false)
        assertEquals(VideoPhase.Idle, capT.phase)
        assertEquals(
            listOf(VideoDecision.CloseCamera(10), VideoDecision.ReportCameraState("call-a", false, 1)),
            capT.decisions,
        )

        val foreign = LocalVideoPolicy.negotiated(capturing, "call-b", ownsSource = false)
        assertEquals(capturing, foreign.phase)
        val owning = LocalVideoPolicy.negotiated(capturing, "call-a", ownsSource = true)
        assertEquals(capturing, owning.phase)
    }

    @Test
    fun `peer media answer preserves only the exact authoritative local lease`() {
        val phase = VideoPhase.Capturing(
            armed(owner = "call-a", fgs = true, demanded = true).lease,
            attemptGen = 10,
        )
        fun preserve(
            follows: Boolean = true,
            owns: Boolean = false,
            authoritative: Boolean = true,
            callId: String = "call-a",
            epoch: Long = 1,
            source: String = sink,
        ) = LocalVideoPolicy.shouldReassertAfterPeerAnswer(
            phase,
            callId,
            epoch,
            source,
            follows,
            owns,
            authoritative,
        )

        assertTrue(preserve())
        assertFalse(preserve(follows = false))
        assertFalse(preserve(owns = true))
        assertFalse(preserve(authoritative = false))
        assertFalse(preserve(callId = "call-b"))
        assertFalse(preserve(epoch = 2))
        assertFalse(preserve(source = "camera://other"))
        assertFalse(
            LocalVideoPolicy.shouldReassertAfterPeerAnswer(
                VideoPhase.Idle,
                "call-a",
                1,
                sink,
                true,
                false,
                true,
            ),
        )
    }

    @Test
    fun `fgs promotion failure is a capture failure`() {
        val bound = LocalVideoPolicy.fgsFailed(armed(owner = "call-a", demanded = true), epoch = 1)
        assertEquals(VideoPhase.Idle, bound.phase)
        assertEquals(listOf<VideoDecision>(VideoDecision.DisableCallVideo("call-a", sink, 1)), bound.decisions)

        val unbound = LocalVideoPolicy.fgsFailed(armed(owner = null), epoch = 1)
        assertTrue(unbound.phase is VideoPhase.FailedAwaitingBind)
    }

    @Test
    fun `sequential calls reuse the same source under fresh epochs`() {
        // Call 1 full cycle.
        var t = LocalVideoPolicy.arm(VideoPhase.Idle, 1, dev, dev, "call-1")
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 1, 10)
        t = LocalVideoPolicy.startCapture(t.phase, dev, 11)
        t = LocalVideoPolicy.openResult(t.phase, 11, ok = true)
        t = LocalVideoPolicy.terminal(t.phase, "call-1")
        assertEquals(VideoPhase.Idle, t.phase)

        // Call 2 arms the same registered device; call-1's stale continuations stay dead.
        t = LocalVideoPolicy.arm(t.phase, 2, dev, dev, "call-2")
        val staleFgs = LocalVideoPolicy.fgsConfirmed(t.phase, epoch = 1, nextAttemptGen = 12)
        assertEquals(false, (staleFgs.phase as VideoPhase.Armed).lease.fgsConfirmed)
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 2, 13)
        t = LocalVideoPolicy.startCapture(t.phase, dev, 14)
        assertEquals(listOf<VideoDecision>(VideoDecision.OpenCamera(dev, 14, 2)), t.decisions)
        val staleOpen = LocalVideoPolicy.openResult(t.phase, attemptGen = 11, ok = false)
        assertTrue(staleOpen.decisions.isEmpty())
    }

    @Test
    fun `bind is idempotent for the same call and never rebinds a different owner`() {
        val bound = LocalVideoPolicy.bindCall(armed(owner = "call-a"), epoch = 1, callId = "call-a")
        assertEquals("call-a", (bound.phase as VideoPhase.Armed).lease.ownerCallId)
        val other = LocalVideoPolicy.bindCall(armed(owner = "call-a"), epoch = 1, callId = "call-b")
        assertEquals("call-a", (other.phase as VideoPhase.Armed).lease.ownerCallId)
        val idle = LocalVideoPolicy.bindCall(VideoPhase.Idle, epoch = 1, callId = "call-a")
        assertEquals(VideoPhase.Idle, idle.phase)
    }

    @Test
    fun `screen demand then projection FGS opens the desktop producer`() {
        var t = LocalVideoPolicy.arm(
            VideoPhase.Idle, 40, "desktop", "desktop", "call-a",
            kind = LocalVideoKind.SCREEN, width = 1080, height = 2400,
        )
        t = LocalVideoPolicy.startCapture(t.phase, "desktop", 41)
        assertTrue(t.decisions.isEmpty())
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 40, 42)
        assertEquals(
            listOf(VideoDecision.OpenCamera("desktop", 42, 40, LocalVideoKind.SCREEN)),
            t.decisions,
        )
    }

    @Test
    fun `screen FGS then demand opens once and stale epoch is inert`() {
        var t = LocalVideoPolicy.arm(
            VideoPhase.Idle, 50, "desktop", "desktop", "call-a",
            kind = LocalVideoKind.SCREEN,
        )
        val stale = LocalVideoPolicy.fgsConfirmed(t.phase, 49, 51)
        assertEquals(t.phase, stale.phase)
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 50, 52)
        assertTrue(t.decisions.isEmpty())
        t = LocalVideoPolicy.startCapture(t.phase, "desktop", 53)
        assertEquals(
            VideoDecision.OpenCamera("desktop", 53, 50, LocalVideoKind.SCREEN),
            t.decisions.single(),
        )
    }

    @Test
    fun `screen open failure disables only its exact call and generation`() {
        var t = LocalVideoPolicy.arm(
            VideoPhase.Idle, 60, "desktop", "desktop", "call-a",
            kind = LocalVideoKind.SCREEN,
        )
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 60, 61)
        t = LocalVideoPolicy.startCapture(t.phase, "desktop", 62)
        val stale = LocalVideoPolicy.openResult(t.phase, 61, ok = false)
        assertEquals(t.phase, stale.phase)
        t = LocalVideoPolicy.openResult(t.phase, 62, ok = false)
        assertEquals(VideoPhase.Idle, t.phase)
        assertEquals(
            listOf(
                VideoDecision.CloseCamera(62),
                VideoDecision.DisableCallVideo("call-a", "camera://desktop", 60),
            ),
            t.decisions,
        )
    }

    @Test
    fun `projection system stop and user stop share generation teardown`() {
        val lease = VideoLease(
            70, "desktop", "camera://desktop", "desktop", "call-a",
            fgsConfirmed = true, captureDemanded = true, kind = LocalVideoKind.SCREEN,
        )
        val capturing = VideoPhase.Capturing(lease, 71)
        val system = LocalVideoPolicy.openResult(capturing, 71, ok = false)
        assertEquals(VideoPhase.Idle, system.phase)
        assertTrue(system.decisions.contains(VideoDecision.CloseCamera(71)))
        val user = LocalVideoPolicy.userStop(capturing, "call-a")
        assertTrue(user.phase is VideoPhase.DormantDemand)
        assertEquals(listOf(VideoDecision.CloseCamera(71)), user.decisions)
    }

    @Test
    fun `daemon screen reinitialization parks and resumes the one-shot projection`() {
        val lease = VideoLease(
            72, "desktop", "camera://desktop", "desktop", "call-a",
            fgsConfirmed = true, captureDemanded = true, kind = LocalVideoKind.SCREEN,
        )
        val capturing = VideoPhase.Capturing(lease, 73)
        val stopped = LocalVideoPolicy.stopCapture(capturing, "desktop")
        val parked = stopped.phase as VideoPhase.Capturing
        assertEquals(73L, parked.attemptGen)
        assertFalse(parked.lease.captureDemanded)
        assertTrue(stopped.decisions.isEmpty())

        val resumed = LocalVideoPolicy.startCapture(stopped.phase, "desktop", 74)
        val live = resumed.phase as VideoPhase.Capturing
        assertEquals(73L, live.attemptGen)
        assertTrue(live.lease.captureDemanded)
        assertEquals(listOf(VideoDecision.RequestKeyFrame(73)), resumed.decisions)
    }

    @Test
    fun `parked projection still closes when negotiation proves the source off`() {
        val lease = VideoLease(
            75, "desktop", "camera://desktop", "desktop", "call-a",
            fgsConfirmed = true, captureDemanded = false, kind = LocalVideoKind.SCREEN,
        )
        val parked = VideoPhase.Capturing(lease, 76)
        val off = LocalVideoPolicy.negotiated(parked, "call-a", ownsSource = false)
        assertEquals(VideoPhase.Idle, off.phase)
        assertEquals(
            listOf(
                VideoDecision.CloseCamera(76),
                VideoDecision.ReportCameraState("call-a", false, 75),
            ),
            off.decisions,
        )
    }

    @Test
    fun `encoder geometry updates only the matching projection epoch`() {
        val lease = VideoLease(
            77, "desktop", "camera://desktop", "desktop", "call-a",
            fgsConfirmed = true, captureDemanded = true, kind = LocalVideoKind.SCREEN,
            width = 1080, height = 2400,
        )
        val capturing = VideoPhase.Capturing(lease, 78)
        val stale = LocalVideoPolicy.resize(capturing, 76, 540, 1200)
        assertEquals(capturing, stale.phase)
        val resized = LocalVideoPolicy.resize(capturing, 77, 540, 1200)
        assertEquals(540, resized.phase.currentLease()?.width)
        assertEquals(1200, resized.phase.currentLease()?.height)
        assertTrue(resized.decisions.isEmpty())
    }

    @Test
    fun `rapid camera screen camera replaces only owned generations`() {
        var t = LocalVideoPolicy.arm(VideoPhase.Idle, 80, dev, dev, "call-a")
        t = LocalVideoPolicy.fgsConfirmed(t.phase, 80, 81)
        t = LocalVideoPolicy.startCapture(t.phase, dev, 82)
        t = LocalVideoPolicy.openResult(t.phase, 82, ok = true)
        t = LocalVideoPolicy.arm(
            t.phase, 83, "desktop", "desktop", "call-a",
            kind = LocalVideoKind.SCREEN,
        )
        assertEquals(listOf(VideoDecision.CloseCamera(82)), t.decisions)
        t = LocalVideoPolicy.arm(t.phase, 84, dev, dev, "call-a")
        assertEquals(LocalVideoKind.CAMERA, t.phase.currentLease()?.kind)
        assertEquals(84L, t.phase.currentLease()?.epoch)
    }
}
