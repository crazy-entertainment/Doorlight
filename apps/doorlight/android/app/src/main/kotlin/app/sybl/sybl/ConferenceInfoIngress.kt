package app.sybl.sybl

/** Keeps daemon conference bursts to one delayed query and one worker task. */
internal class ConferenceInfoIngress(
    private val schedule: (Runnable) -> Boolean,
    private val dispatch: (Runnable) -> Unit,
) {
    private val lock = Any()
    private var latest: Runnable? = null
    private var busy = false

    fun offer(query: Runnable) {
        val start = synchronized(lock) {
            latest = query
            if (busy) false else {
                busy = true
                true
            }
        }
        if (start) scheduleNext()
    }

    private fun scheduleNext() {
        val accepted = try { schedule(Runnable { drain() }) } catch (_: Throwable) { false }
        if (!accepted) synchronized(lock) {
            latest = null
            busy = false
        }
    }

    private fun drain() {
        val query = synchronized(lock) {
            latest.also { latest = null }
        }
        if (query == null) {
            finish()
            return
        }
        try {
            dispatch(Runnable {
                try { query.run() } finally { finish() }
            })
        } catch (_: Throwable) {
            finish()
        }
    }

    private fun finish() {
        val again = synchronized(lock) {
            if (latest == null) {
                busy = false
                false
            } else true
        }
        if (again) scheduleNext()
    }
}
