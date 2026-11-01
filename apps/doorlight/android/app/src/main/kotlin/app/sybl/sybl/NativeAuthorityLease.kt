package app.sybl.sybl

/** Reads never extend authority. Time is measured from before native verification. */
internal class NativeAuthorityLease<T>(private val nowMs: () -> Long) {
    private var value: T? = null
    private var observedAt = 0L

    @Synchronized fun publish(next: T, startedAt: Long): Boolean {
        if (nowMs() - startedAt !in 0 until 250L) {
            value = null
            return false
        }
        observedAt = startedAt
        value = next
        return true
    }

    @Synchronized fun current(): T? = value?.takeIf { nowMs() - observedAt in 0 until 250L }
    @Synchronized fun refreshDue(): Boolean = value == null || nowMs() - observedAt !in 0 until 100L
    @Synchronized fun clear() { value = null }
}
