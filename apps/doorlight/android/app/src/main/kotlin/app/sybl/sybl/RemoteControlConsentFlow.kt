package app.sybl.sybl

/** One consent request for a controller's remote-input session. */
internal data class RemoteControlConsentRequest(
    val binding: AndroidRemoteControlBinding,
    val localJamiId: String,
    val requestedCapabilities: Int,
    val grantedCapabilities: Int,
    val generation: Long,
    val persistentAvailable: Boolean,
    val identityColor: String,
)

/**
 * Owns the pending consent request and its transitions: requested, displayed,
 * allow-requested, verified, activated, plus deny, timeout and stop.
 *
 * A pending request is valid while it is the same object, native call/peer
 * authority is current and the source identity matches. It needs no lease: the
 * lease is published only by native revalidation, which runs after the user
 * presses Allow. Activation additionally requires a current lease for the exact
 * binding. Every exit retires [pending]. State changes happen under [lock]
 * (shared with the host); collaborator side effects run outside it, except
 * [activate], which must be atomic with retiring the request.
 */
internal class RemoteControlConsentFlow(
    private val lock: Any,
    private val authorityCurrent: (AndroidRemoteControlBinding) -> Boolean,
    private val leaseCurrent: (AndroidRemoteControlBinding) -> Boolean,
    private val currentSource: () -> AndroidRemoteControlSourceIdentity?,
    private val serviceAttached: () -> Boolean,
    private val sessionActive: () -> Boolean,
    private val revalidate: (AndroidRemoteControlBinding, (Boolean) -> Unit) -> Unit,
    private val showConsent: (RemoteControlConsentRequest) -> Boolean,
    private val hideConsent: (Long) -> Unit,
    private val sendDeny: (String, String) -> Unit,
    private val scheduleTimeout: (Long, () -> Unit) -> Unit,
    private val activate: (RemoteControlConsentRequest) -> Unit,
    private val activated: (RemoteControlConsentRequest) -> Unit,
    private val emitState: (RemoteControlConsentRequest, String, String) -> Unit,
) {
    private var pending: RemoteControlConsentRequest? = null

    fun current(): RemoteControlConsentRequest? = synchronized(lock) { pending }

    /** Retires and returns the pending request when [matches] accepts it. */
    fun retireIf(
        matches: (RemoteControlConsentRequest) -> Boolean,
    ): RemoteControlConsentRequest? = synchronized(lock) {
        pending?.takeIf(matches)?.also { pending = null }
    }

    fun request(candidate: RemoteControlConsentRequest) {
        val callId = candidate.binding.callId
        synchronized(lock) {
            if (sessionActive()) {
                sendDeny(callId, "busy")
                return
            }
            val existing = pending
            if (existing != null) {
                if (existing.binding != candidate.binding ||
                    existing.requestedCapabilities != candidate.requestedCapabilities) {
                    sendDeny(callId, "busy")
                }
                return
            }
            pending = candidate
        }
        if (!serviceAttached() || !pendingIsCurrent(candidate)) {
            if (retire(candidate)) sendDeny(callId, "unsupported")
            return
        }
        if (!showConsent(candidate)) {
            if (retire(candidate)) sendDeny(callId, "unsupported")
            return
        }
        scheduleTimeout(candidate.generation) { timeout(candidate.generation) }
    }

    fun allow(generation: Long, persistDevice: Boolean = false) {
        if (persistDevice) return
        val request = synchronized(lock) {
            pending?.takeIf { it.generation == generation }
        } ?: return
        revalidate(request.binding) { verified -> finishAllow(request, verified) }
    }

    private fun finishAllow(request: RemoteControlConsentRequest, verified: Boolean) {
        var reason: String? = null
        val stale = synchronized(lock) {
            if (pending !== request) return@synchronized true
            pending = null
            when {
                !verified -> reason = "unsupported"
                !serviceAttached() -> reason = "user"
                !pendingIsCurrent(request, retired = true) ||
                    !leaseCurrent(request.binding) || sessionActive() -> reason = "unsupported"
                else -> activate(request)
            }
            false
        }
        if (stale) return
        hideConsent(request.generation)
        val denied = reason
        if (denied == null) {
            activated(request)
        } else {
            sendDeny(request.binding.callId, denied)
            emitState(request, "denied", denied)
        }
    }

    fun deny(generation: Long, reason: String = "user") {
        val request = retireIf { it.generation == generation } ?: return
        hideConsent(generation)
        sendDeny(request.binding.callId, reason)
        emitState(request, "denied", reason)
    }

    private fun timeout(generation: Long) {
        val expired = retireIf { it.generation == generation } ?: return
        hideConsent(expired.generation)
        sendDeny(expired.binding.callId, "timeout")
    }

    /** Returns true when a pending request was retired. */
    fun stop(reason: String): Boolean {
        val request = retireIf { true } ?: return false
        hideConsent(request.generation)
        sendDeny(request.binding.callId, "user")
        emitState(request, "ended", reason)
        return true
    }

    private fun retire(request: RemoteControlConsentRequest): Boolean = synchronized(lock) {
        if (pending === request) {
            pending = null
            true
        } else {
            false
        }
    }

    private fun pendingIsCurrent(
        request: RemoteControlConsentRequest,
        retired: Boolean = false,
    ): Boolean =
        synchronized(lock) {
            (retired || pending === request) &&
                authorityCurrent(request.binding) &&
                currentSource() == request.binding.source
        }
}
