package app.sybl.sybl

internal data class SavedBackgroundWake(
    val requested: Boolean = false,
    val profile: String = "jami",
    val relayUrl: String = "",
    val registered: Boolean = false,
    val ownerAccount: String = "",
    val retiringRelay: String? = null,
    val renewedAtMs: Long = 0,
)

internal interface BackgroundWakeTokens {
    fun setEnabled(enabled: Boolean)
    fun get(callback: (String?) -> Unit)
    fun delete(callback: (Boolean) -> Unit)
}

/** Native wake ownership. Relay I/O uses the existing serial daemon worker. */
internal class BackgroundWakeController(
    private val registration: WakeRegistration,
    private val tokens: BackgroundWakeTokens,
    private val load: () -> SavedBackgroundWake,
    private val save: (SavedBackgroundWake) -> Boolean,
    private val available: () -> Boolean,
    private val account: () -> String?,
    private val worker: (() -> Unit) -> Unit,
    private val main: (() -> Unit) -> Unit,
    private val clearDaemonToken: () -> Unit,
    private val publish: (String, String) -> Unit,
    private val ready: (String, String) -> Unit,
    private val reconcileLifetime: () -> Unit,
    private val wallClockMs: () -> Long = System::currentTimeMillis,
    private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val lock = Any()
    private var state: SavedBackgroundWake? = runCatching(load).getOrNull()
    private var healthy = state != null
    private var generation = Any()
    private var pendingOperation: Operation? = null
    private var selectedAccount = account()
    private var deletingToken = false
    private var afterTokenDeletion: (() -> Unit)? = null
    private var lastLifecycleAttempt: Long? = null
    private var lifecycleQueued = false

    /** Foreground lifecycle only: renew daily, with a bounded retry admission. */
    fun resumed() {
        synchronized(lock) {
            val value = state ?: return
            if (!healthy || !effective(value) || account().isNullOrEmpty() || lifecycleQueued ||
                pendingOperation?.let { current(it) && !it.completed } == true) return
            val age = wallClockMs() - value.renewedAtMs
            if (value.registered && value.retiringRelay == null &&
                runCatching { registration.pendingDeletion() == null }.getOrDefault(false) &&
                value.renewedAtMs > 0 && age in 0 until 86_400_000L) return
            val now = monotonicMs()
            if (lastLifecycleAttempt?.let { now - it in 0 until 1_800_000L } == true) return
            lastLifecycleAttempt = now
            lifecycleQueued = true
        }
        try {
            worker {
                synchronized(lock) { lifecycleQueued = false }
                resumePending(renew = true)
            }
        } catch (_: Throwable) {
            synchronized(lock) { lifecycleQueued = false }
        }
    }

    private class Operation(val generation: Any, val account: String?, val callback: (Boolean) -> Unit,
                            val ownerCurrent: () -> Boolean = { true }) {
        var completed = false
        var cleanupPending = false
        var cleanupSucceeded = true
        var afterCleanup: (() -> Unit)? = null
    }

    private fun effective(value: SavedBackgroundWake) =
        BackgroundWakePolicy.effective(value.requested, value.profile, available())

    fun desired(): Boolean = synchronized(lock) { healthy && state?.let(::effective) == true }

    fun enabled(): Boolean = synchronized(lock) {
        healthy && state?.let {
            it.registered && it.retiringRelay == null && effective(it) &&
                it.renewedAtMs > 0 && wallClockMs() - it.renewedAtMs in 0 until 2_592_000_000L &&
                it.ownerAccount.isNotEmpty() && (account() == null || it.ownerAccount == account()) &&
                runCatching { registration.pendingDeletion() == null && registration.handle.isNotEmpty() }.getOrDefault(false)
        } == true
    }

    fun wakeOwner(): String? = synchronized(lock) { state?.ownerAccount?.takeIf { enabled() } }

    private fun operationAccount(): String? = account() ?: state?.ownerAccount?.takeIf(String::isNotEmpty)

    /** Only current, acknowledged capability state is eligible for presence publication. */
    fun handle(): String = synchronized(lock) {
        if (!enabled()) "" else runCatching { registration.handle }.getOrDefault("")
    }

    private fun persist(next: SavedBackgroundWake): Boolean {
        state = next
        healthy = runCatching { save(next) }.getOrDefault(false)
        if (!healthy) state = next.copy(registered = false)
        return healthy
    }

    private fun begin(callback: (Boolean) -> Unit, ownerCurrent: () -> Boolean = { true }): Operation {
        pendingOperation?.let { finish(it, false) }
        generation = Any()
        return Operation(generation, operationAccount(), callback, ownerCurrent).also { pendingOperation = it }
    }

    fun scope(): Any = synchronized(lock) { generation }

    fun owns(scope: Any, owner: String?): Boolean = synchronized(lock) {
        scope === generation && owner == account()
    }

    fun changeProfile(profile: String) {
        val value = synchronized(lock) { state } ?: return
        if (profile != value.profile) configure(value.requested, profile, value.relayUrl) {}
    }

    fun goOffline() {
        val value = synchronized(lock) { state } ?: return
        configure(false, value.profile, value.relayUrl) {}
    }

    private fun current(operation: Operation): Boolean =
        operation.generation === generation && operation.account == operationAccount() && operation.ownerCurrent()

    private fun finish(operation: Operation, success: Boolean, handle: String? = null) {
        main {
            synchronized(lock) {
                if (operation.completed) return@synchronized
                if (success && operation.cleanupPending && current(operation)) {
                    operation.afterCleanup = { finish(operation, success, handle) }
                    return@synchronized
                }
                operation.completed = true
                val owns = current(operation)
                if (owns) {
                    reconcileLifetime()
                    if (success && handle != null && enabled()) {
                        operation.account?.let { ready(it, handle) }
                    }
                }
                operation.callback(owns && success && operation.cleanupSucceeded)
            }
        }
    }

    fun configure(enabled: Boolean, profile: String, relayUrl: String,
                  ownerCurrent: () -> Boolean = { true }, callback: (Boolean) -> Unit) {
        val operation: Operation
        synchronized(lock) {
            if (!ownerCurrent()) { main { callback(false) }; return }
            operation = begin(callback, ownerCurrent)
            val previous = state ?: runCatching(load).getOrNull()
            if (previous == null) { finish(operation, false); return }
            val next = previous.copy(requested = enabled, profile = profile, relayUrl = relayUrl, registered = false)
            val retire = previous.retiringRelay ?: previous.relayUrl.takeIf {
                !effective(next) || previous.relayUrl != relayUrl ||
                    (previous.ownerAccount.isNotEmpty() && previous.ownerAccount != operation.account)
            }
            if (!persist(next.copy(retiringRelay = retire))) {
                retireAfterPersistenceFailure(operation, retire)
                return
            }
        }
        main { synchronized(lock) { if (current(operation)) reconcileLifetime() } }
        if (!desired()) {
            disableFirebase(operation)
            cleanThen(operation, token = null)
        } else requestToken(operation)
    }

    /** Called before a new native account is adopted, including A -> B -> A. */
    fun accountChanged(nextAccount: String) {
        synchronized(lock) {
            if (selectedAccount == nextAccount) return
            val firstAdoption = selectedAccount == null && state?.ownerAccount == nextAccount
            selectedAccount = nextAccount
            if (!firstAdoption) {
                pendingOperation?.let { finish(it, false) }
                generation = Any()
            }
            val previous = state ?: return
            val retire = previous.retiringRelay ?: previous.relayUrl.takeIf {
                previous.ownerAccount != nextAccount && runCatching { registration.handle.isNotEmpty() }.getOrDefault(true)
            }
            persist(previous.copy(registered = previous.registered && retire == null, retiringRelay = retire))
        }
        // Selection is performed by the current worker operation. Queue behind
        // it so the next operation captures the adopted account, not its predecessor.
        worker { resumePending() }
    }

    private fun resumePending(renew: Boolean = false) {
        val operation: Operation
        val retirement: String?
        val durable: Boolean
        synchronized(lock) {
            val value = state ?: return
            if (healthy && value.retiringRelay == null &&
                    runCatching { registration.pendingDeletion() == null }.getOrDefault(false) &&
                    ((!renew && value.registered) || pendingOperation?.let { current(it) && !it.completed } == true)) return
            operation = begin(callback = {})
            if (renew) persist(value.copy(registered = false))
            retirement = value.retiringRelay ?: runCatching { registration.pendingDeletion()?.relay }.getOrNull()
            durable = healthy
        }
        if (!durable) retireAfterPersistenceFailure(operation, retirement)
        else if (retirement != null || !desired()) cleanThen(operation, null, acquireTokenAfter = true)
        else requestToken(operation)
    }

    /** A trust reduction is native work; Flutter event delivery is not an acknowledgement. */
    fun rotate(expectedRelay: String? = null, ownerCurrent: () -> Boolean = { true }, callback: (Boolean) -> Unit = {}) {
        val operation: Operation
        synchronized(lock) {
            if (expectedRelay != null && expectedRelay != state?.relayUrl) { main { callback(false) }; return }
            if (!ownerCurrent()) { main { callback(false) }; return }
            operation = begin(callback, ownerCurrent)
            val previous = state ?: run { finish(operation, false); return }
            if (!persist(previous.copy(registered = false,
                    retiringRelay = previous.retiringRelay ?: previous.relayUrl))) {
                retireAfterPersistenceFailure(operation, previous.retiringRelay ?: previous.relayUrl)
                return
            }
        }
        main { synchronized(lock) { if (current(operation)) reconcileLifetime() } }
        // Delete first. A failed Firebase token request cannot retain the old
        // authorization after a successful native reduction.
        cleanThen(operation, null, acquireTokenAfter = true)
    }

    fun refresh(token: String) {
        if (token.isEmpty()) return
        val operation: Operation
        synchronized(lock) {
            if (!desired()) return
            operation = begin(callback = {})
            val previous = state ?: return
            if (!persist(previous.copy(registered = false))) { finish(operation, false); return }
            if (deletingToken) {
                afterTokenDeletion = { requestToken(operation) }
                return
            }
        }
        cleanThen(operation, token)
    }

    private fun retireAfterPersistenceFailure(operation: Operation, relay: String?) {
        // The durable marker failed: never report success. A known credential
        // can still retire the remote registration now. Failed deletion remains
        // pending and is not evidence of remote absence, including after restart.
        main { synchronized(lock) { if (current(operation)) reconcileLifetime() } }
        disableFirebase(operation)
        try {
            worker {
                synchronized(lock) {
                    if (!current(operation)) { finish(operation, false); return@worker }
                }
                if (relay != null) runCatching {
                    val authority = registration.deletionAuthority()
                    registration.disable(authority?.relay ?: relay, authority?.account ?: state?.ownerAccount.orEmpty())
                }
                finish(operation, false)
            }
        } catch (_: Throwable) { finish(operation, false) }
    }

    private fun disableFirebase(operation: Operation) {
        if (!available()) return
        synchronized(lock) {
            if (!current(operation) || desired()) return
            operation.cleanupSucceeded = runCatching { tokens.setEnabled(false) }.isSuccess
            if (deletingToken) {
                // Another withdrawal owns SDK deletion; do not report this one
                // fully cleaned before it is known to have finished.
                operation.cleanupSucceeded = false
                return
            }
            deletingToken = true
            operation.cleanupPending = true
        }
        try {
            tokens.delete { success ->
                val (next, completion) = synchronized(lock) {
                    deletingToken = false
                    operation.cleanupPending = false
                    operation.cleanupSucceeded = operation.cleanupSucceeded && success
                    val completion = operation.afterCleanup.also { operation.afterCleanup = null }
                    afterTokenDeletion.also { afterTokenDeletion = null } to completion
                }
                completion?.invoke()
                next?.invoke()
            }
        } catch (_: Throwable) {
            val completion = synchronized(lock) {
                deletingToken = false
                operation.cleanupPending = false
                operation.cleanupSucceeded = false
                operation.afterCleanup.also { operation.afterCleanup = null }
            }
            completion?.invoke()
        }
    }

    private fun requestToken(operation: Operation) {
        synchronized(lock) {
            if (!current(operation) || !desired() || operation.account.isNullOrEmpty()) {
                finish(operation, false)
                return
            }
            if (deletingToken) {
                afterTokenDeletion = { requestToken(operation) }
                return
            }
            try {
                // Submission is ordered with opt-out. The lock is not held
                // while Firebase resolves this asynchronous request.
                tokens.setEnabled(true)
                if (!current(operation) || !desired()) { finish(operation, false); return }
                tokens.get { token ->
                    synchronized(lock) {
                        if (!current(operation) || !desired()) { finish(operation, false); return@get }
                        if (token.isNullOrEmpty()) { finish(operation, false); return@get }
                    }
                    cleanThen(operation, token)
                }
            } catch (_: Throwable) { finish(operation, false) }
        }
    }

    private fun cleanThen(operation: Operation, token: String?, acquireTokenAfter: Boolean = false) {
        worker {
            try {
            val retirement: String?
            val relay: String
            synchronized(lock) {
                if (!current(operation) || !healthy) { finish(operation, false); return@worker }
                retirement = state?.retiringRelay ?: registration.pendingDeletion()?.relay
                relay = state?.relayUrl.orEmpty()
            }
                clearDaemonToken()
                if (retirement != null) {
                    val authority = registration.deletionAuthority()
                    val removed = registration.disable(authority?.relay ?: retirement,
                        authority?.account ?: state?.ownerAccount.orEmpty())
                    synchronized(lock) {
                        if (!current(operation)) { finish(operation, false); return@worker }
                        if (!removed || !persist(state!!.copy(retiringRelay = null, registered = false))) {
                            finish(operation, false)
                            return@worker
                        }
                    }
                }
                synchronized(lock) {
                    if (!current(operation)) { finish(operation, false); return@worker }
                    if (!desired()) { finish(operation, true); return@worker }
                }
                if (acquireTokenAfter) { main { requestToken(operation) }; return@worker }
                if (token == null || operation.account.isNullOrEmpty()) { finish(operation, false); return@worker }
                val handle = registration.enable(relay, token, operation.account)
                synchronized(lock) {
                    if (!current(operation)) { finish(operation, false); return@worker }
                    if (handle.isNullOrEmpty() || !persist(state!!.copy(registered = true,
                            ownerAccount = operation.account, renewedAtMs = wallClockMs()))) {
                        finish(operation, false)
                        return@worker
                    }
                    publish(operation.account, handle)
                }
                finish(operation, true, handle)
            } catch (_: Throwable) { finish(operation, false) }
        }
    }
}
