package app.sybl.sybl

/** Sequential window scan used only to find a direct Android system-control click target. */
internal object RemoteControlSystemNodeScan {
    const val MAX_NODES = 512

    fun <W, N : Any> visit(
        windows: Iterable<W>,
        root: (W) -> N?,
        childCount: (N) -> Int,
        child: (N, Int) -> N?,
        visitNode: (N) -> Unit,
    ): Boolean {
        // Count discovery attempts, including missing roots/children. Every
        // visited node must first use one of these shared slots, so the queue
        // and visits are bounded too. A window cannot reset the budget.
        var remaining = MAX_NODES
        return try {
            for (window in windows) {
                if (remaining == 0) return false
                --remaining
                val first = root(window) ?: continue
                val queue = ArrayDeque<N>().apply { add(first) }
                while (queue.isNotEmpty()) {
                    val node = queue.removeFirst()
                    visitNode(node)
                    val count = childCount(node)
                    if (count < 0) return false
                    for (index in 0 until count) {
                        if (remaining == 0) return false
                        --remaining
                        child(node, index)?.let(queue::add)
                    }
                }
            }
            true
        } catch (_: Exception) {
            // A failed/stale accessibility query cannot authorize a partial
            // direct-click candidate. The caller can use the OS gesture path.
            false
        }
    }
}
