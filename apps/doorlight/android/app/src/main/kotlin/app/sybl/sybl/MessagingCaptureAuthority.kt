package app.sybl.sybl

internal enum class MessagingCaptureBlocker { DIRECT, GROUP, GROUP_PENDING, RESERVED, PLACING, ANSWER, RECORDING }

internal class MessagingCaptureLease internal constructor(
    val account: NativeAccountScope,
    internal val generation: Long,
)

/** A completed call cannot make an earlier camera request current again. */
internal class MessagingCaptureAuthority(private val accountCurrent: (NativeAccountScope) -> Boolean) {
    private val blockers = mutableSetOf<MessagingCaptureBlocker>()
    private var generation = 0L
    private var pending: MessagingCaptureLease? = null

    @Synchronized fun setBlocked(blocker: MessagingCaptureBlocker, blocked: Boolean) {
        val changed = if (blocked) blockers.add(blocker) else blockers.remove(blocker)
        if (changed) generation++
    }

    @Synchronized fun begin(account: NativeAccountScope?): MessagingCaptureLease? {
        if (account == null || account.accountId.isNullOrEmpty() ||
            !accountCurrent(account) || blockers.isNotEmpty() || pending != null) return null
        return MessagingCaptureLease(account, generation).also { pending = it }
    }

    @Synchronized fun owns(lease: MessagingCaptureLease): Boolean =
        pending === lease && lease.generation == generation && blockers.isEmpty() && accountCurrent(lease.account)

    @Synchronized fun retire(lease: MessagingCaptureLease) {
        if (pending === lease) pending = null
    }
}
