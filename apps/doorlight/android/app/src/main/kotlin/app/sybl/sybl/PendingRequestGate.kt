package app.sybl.sybl

internal enum class PendingRequestAdmission { NEW, DUPLICATE, REJECTED }

/** Fixed in-memory abuse bound for unauthenticated conversation requests. */
internal class PendingRequestGate(
    private val maxPending: Int = 64,
    private val maxAdmissionsPerWindow: Int = 16,
    private val windowMs: Long = 60_000L,
) {
    private val ids = HashSet<String>()
    private val admittedAt = ArrayDeque<Long>()

    @Synchronized
    fun admit(id: String, nowMs: Long): PendingRequestAdmission {
        if (id in ids) return PendingRequestAdmission.DUPLICATE
        while (admittedAt.isNotEmpty() && nowMs - admittedAt.first() >= windowMs) {
            admittedAt.removeFirst()
        }
        if (ids.size >= maxPending || admittedAt.size >= maxAdmissionsPerWindow) {
            return PendingRequestAdmission.REJECTED
        }
        ids += id
        admittedAt += nowMs
        return PendingRequestAdmission.NEW
    }

    @Synchronized
    fun remove(id: String): Boolean = ids.remove(id)

    /** True while a surfaced request or its user decision still owns a bounded slot. */
    @Synchronized
    fun contains(id: String): Boolean = id in ids

    /** A failed decision restores its reserved slot without consuming another rate token. */
    @Synchronized
    fun restore(id: String): Boolean = id in ids || (ids.size < maxPending && ids.add(id))

    @Synchronized
    fun clear() {
        ids.clear()
        admittedAt.clear()
    }
}
