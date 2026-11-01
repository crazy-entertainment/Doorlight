package app.sybl.sybl

/** Bounded, monotonic admission before certificate queries, parsing and queueing. */
internal class ControlMessageAdmission {
    private data class Bucket(var at: Long, var tokens: Double)
    private val peers = LinkedHashMap<List<String>, Bucket>()
    private var total = Bucket(0, 128.0)

    @Synchronized fun admit(key: List<String>, size: Int, now: Long): Boolean {
        if (size !in 1..6000 || key.size != 3 || key.any { it.isEmpty() || it.length > 256 }) return false
        fun refill(bucket: Bucket) {
            bucket.tokens = (bucket.tokens + (now - bucket.at).coerceAtLeast(0) * .320).coerceAtMost(128.0)
            bucket.at = now
        }
        refill(total)
        if (total.tokens < 1) return false
        peers.entries.removeAll { now - it.value.at > 60_000 }
        val peer = peers[key] ?: run {
            if (peers.size >= 32) return false
            Bucket(now, 64.0).also { peers[key] = it }
        }
        refill(peer)
        if (peer.tokens < 1) return false
        peer.tokens--
        total.tokens--
        return true
    }
}

/** At most one main-loop drain, yielding after eight ordered packets. */
internal class ControlMessageQueue(private val schedule: (Runnable) -> Boolean) {
    private data class Entry(val peer: List<String>, val duplicate: String?, val task: Runnable)
    private val queue = java.util.ArrayDeque<Entry>()
    private var scheduled = false
    val pending: Int get() = synchronized(this) { queue.size }

    @Synchronized fun offer(peer: List<String>, duplicate: String?, task: Runnable): Boolean {
        if (duplicate != null && queue.any { it.peer == peer && it.duplicate == duplicate }) return true
        if (queue.size >= 64 || queue.count { it.peer == peer } >= 32) return false
        queue.addLast(Entry(peer, duplicate, task))
        if (!scheduled) {
            scheduled = true
            if (!schedule(Runnable { drain() })) { queue.clear(); scheduled = false; return false }
        }
        return true
    }

    private fun drain() {
        repeat(8) {
            val next = synchronized(this) { queue.pollFirst() } ?: return@repeat
            next.task.run()
        }
        synchronized(this) {
            if (queue.isEmpty()) scheduled = false
            else if (!schedule(Runnable { drain() })) { queue.clear(); scheduled = false }
        }
    }
}

/** Peer responses cannot fill the daemon's general-purpose executor. */
internal class ControlResponseAdmission {
    private var pending = 0
    private var lastDenial: Long? = null
    @Synchronized fun acquire(now: Long, denial: Boolean): Boolean {
        if (pending >= 8 || (denial && lastDenial?.let { now - it < 1000 } == true)) return false
        if (denial) lastDenial = now
        pending++
        return true
    }
    @Synchronized fun delivered() { check(pending > 0); pending-- }
}
