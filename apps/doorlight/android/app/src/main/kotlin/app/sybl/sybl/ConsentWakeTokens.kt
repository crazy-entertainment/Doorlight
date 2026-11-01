package app.sybl.sybl

/**
 * Keeps a never-enabled installation out of Firebase, including its deletion APIs.
 * The durable cleanup marker precedes SDK access and survives failed withdrawals.
 */
internal class ConsentWakeTokens(
    private val loadCleanupPending: () -> Boolean,
    private val saveCleanupPending: (Boolean) -> Boolean,
    private val backend: BackgroundWakeTokens,
) : BackgroundWakeTokens {
    private val lock = Any()
    private var enabled = false
    private var requests = 0
    private var deleting = false
    private val deletions = mutableListOf<(Boolean) -> Unit>()

    override fun setEnabled(enabled: Boolean) {
        synchronized(lock) {
            if (enabled) {
                check(!deleting && deletions.isEmpty()) { "Wake cleanup is still pending" }
                check(saveCleanupPending(true)) { "Wake consent could not be saved" }
                backend.setEnabled(true)
                this.enabled = true
            } else {
                this.enabled = false
                if (loadCleanupPending()) backend.setEnabled(false)
            }
        }
    }

    override fun get(callback: (String?) -> Unit) {
        var settled = false
        synchronized(lock) {
            check(enabled && !deleting && deletions.isEmpty()) { "Wake consent is inactive" }
            requests += 1
        }
        try {
            backend.get { token ->
                val result = synchronized(lock) {
                    if (settled) return@get
                    settled = true
                    requests -= 1
                    token.takeIf { enabled }
                }
                try {
                    callback(result)
                } finally {
                    deleteWhenIdle()
                }
            }
        } catch (error: Throwable) {
            synchronized(lock) {
                if (!settled) {
                    settled = true
                    requests -= 1
                }
            }
            deleteWhenIdle()
            throw error
        }
    }

    override fun delete(callback: (Boolean) -> Unit) {
        synchronized(lock) { deletions += callback }
        deleteWhenIdle()
    }

    private fun deleteWhenIdle() {
        synchronized(lock) {
            if (requests != 0 || deleting || deletions.isEmpty()) return
            deleting = true
        }
        try {
            if (!loadCleanupPending()) completeDeletion(true)
            else backend.delete { success ->
                completeDeletion(success && runCatching { saveCleanupPending(false) }.getOrDefault(false))
            }
        } catch (_: Throwable) {
            completeDeletion(false)
        }
    }

    private fun completeDeletion(success: Boolean) {
        val callbacks = synchronized(lock) {
            deleting = false
            deletions.toList().also { deletions.clear() }
        }
        callbacks.forEach { it(success) }
    }
}
