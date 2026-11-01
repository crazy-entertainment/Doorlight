package app.sybl.sybl

/** Native account activation intent is separate from queued work and acknowledgement. */
internal class BackgroundWakeAccountActivity(
    private val worker: (() -> Unit) -> Unit,
    private val main: (() -> Unit) -> Unit,
    private val setActive: (String, Boolean) -> Unit,
    private val changed: () -> Unit,
) {
    private data class Intent(val policy: Any, val retryKey: Any)
    private data class Command(val owner: String, val ownerEpoch: Any, val target: Boolean, val intent: Intent)
    private var account: String? = null
    private var ownerEpoch = Any()
    private var active: Boolean? = null
    private var desired: Boolean? = null
    private var intent: Intent? = null
    private var inFlight: Command? = null
    private var failedIntent: Intent? = null
    private var failedTarget: Boolean? = null

    @Synchronized fun select(owner: String, knownActive: Boolean?) {
        account = owner
        ownerEpoch = Any()
        active = knownActive
        desired = knownActive
        intent = null
        inFlight = null
        failedIntent = null
        failedTarget = null
    }

    @Synchronized fun acknowledgedActive(): Boolean? = active

    @Synchronized fun acknowledge(owner: String, knownActive: Boolean?) {
        if (account != owner) return
        active = knownActive
        // External activation can precede a newer push/visibility/offline policy.
        // Recompute that policy on main instead of driving the previous target.
        main(changed)
    }

    @Synchronized fun request(owner: String, target: Boolean, intent: Any, retryKey: Any = Unit) {
        if (account != owner) return
        if (desired != target) {
            failedIntent = null
            failedTarget = null
        }
        desired = target
        this.intent = Intent(intent, retryKey)
        drive()
    }

    private fun drive() {
        val owner = account ?: return
        val target = desired ?: return
        val latest = intent ?: return
        if (inFlight != null || active == target || (failedIntent == latest && failedTarget == target)) return
        val command = Command(owner, ownerEpoch, target, latest)
        inFlight = command
        try { worker { execute(command) } }
        catch (_: Throwable) {
            inFlight = null
            active = null
            failedIntent = latest
            failedTarget = target
            main(changed)
        }
    }

    private fun execute(command: Command) {
        synchronized(this) {
            if (inFlight !== command || ownerEpoch !== command.ownerEpoch) return
            // A new policy with the same target can use this command. A changed
            // target supersedes it before native submission.
            if (desired != command.target || active == command.target) {
                inFlight = null
                drive()
                return
            }
        }
        val acknowledged = runCatching { setActive(command.owner, command.target) }.isSuccess
        synchronized(this) {
            if (inFlight !== command || ownerEpoch !== command.ownerEpoch) return
            inFlight = null
            active = command.target.takeIf { acknowledged }
            if (!acknowledged) {
                failedIntent = command.intent
                failedTarget = command.target
            } else {
                failedIntent = null
                failedTarget = null
            }
            // Native work already submitted cannot be recalled. Complete a
            // newer opposing intent after its acknowledgement.
            drive()
        }
        // A failure is unknown. drive() will not spin on the same failed intent;
        // a new policy or visibility/call transition can request recovery.
        main(changed)
    }
}
