package app.sybl.sybl

/** Limits both sustained parsing work and retained UI work if Flutter stalls. */
internal class AnnotationIngress {
    private var observed: Long? = null
    private var messages = 128.0
    private var bytes = 1048576.0
    private var queuedMessages = 0
    private var queuedBytes = 0

    @Synchronized fun admit(size: Int, nowMs: Long): Boolean {
        if (size <= 0 || size > 65536) return false
        val elapsed = observed?.let { (nowMs - it).coerceAtLeast(0) } ?: 0
        observed = nowMs
        messages = (messages + elapsed * .064).coerceAtMost(128.0)
        bytes = (bytes + elapsed * 262.144).coerceAtMost(1048576.0)
        if (messages < 1 || bytes < size || queuedMessages >= 128 || queuedBytes + size > 1048576) return false
        messages--
        bytes -= size
        queuedMessages++
        queuedBytes += size
        return true
    }

    @Synchronized fun delivered(size: Int) {
        check(queuedMessages > 0 && queuedBytes >= size)
        queuedMessages--
        queuedBytes -= size
    }
}
