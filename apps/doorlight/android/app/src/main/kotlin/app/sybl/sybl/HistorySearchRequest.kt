package app.sybl.sybl

/** A single admitted native worker. Its holder must keep the worker slot until
 * [terminal] is true, including after retirement or an error record. */
internal class HistorySearchRequest(
    val account: String,
    val conversation: String,
    private val group: Boolean,
    literal: String,
    private val limit: Int,
) {
    init {
        require(account.isNotEmpty() && Regex("[0-9a-f]{40}").matches(conversation))
        require(limit in 1..200 && literal.isNotEmpty() && literal.length <= 256)
    }

    private var query = literal
    private var retired = false
    private val hits = linkedMapOf<String, Map<String, Any>>()
    var terminal = false
        private set
    var failed = false
        private set
    var truncated = false
        private set

    /** The registry checks the native request ID before dispatching here.
     * At most limit + 1 native entries are requested, to detect truncation. */
    @Synchronized fun accept(
        accountId: String,
        conversationId: String,
        size: Int,
        read: (Int) -> Map<String, String>,
    ) {
        if (terminal || accountId != account ||
            (conversationId.isNotEmpty() && conversationId != conversation)) return
        if (conversationId.isEmpty()) {
            if (size == 0) {
                terminal = true
                query = ""
            } else {
                // Only the subsequent empty event proves that the worker ended.
                failed = true
                hits.clear()
            }
            return
        }
        if (retired || failed) return
        if (size !in 0..limit + 1) {
            failed = true
            hits.clear()
            return
        }
        truncated = truncated || size > limit
        for (index in 0 until size) {
            val projected = try {
                HistorySearchProjection.project(read(index), group, query)
            } catch (_: Exception) {
                // SWIG access/conversion errors must not carry content into
                // the general callback logger, or release this worker early.
                failed = true
                hits.clear()
                return
            } ?: continue
            val id = projected["messageId"] as String
            val prior = hits[id]
            if (prior != null && prior != projected) {
                failed = true
                hits.clear()
                return
            }
            if (prior == null) {
                if (hits.size == limit) truncated = true
                else hits[id] = projected
            }
        }
    }

    /** Lock/account retirement destroys private results without pretending to
     * cancel the native scan or releasing the registry's worker slot. */
    @Synchronized fun retire() {
        retired = true
        query = ""
        hits.clear()
    }

    @Synchronized fun result(): Map<String, Any>? =
        if (!terminal || failed || retired) null
        else mapOf("hits" to hits.values.toList(), "truncated" to truncated)

    override fun toString() = "HistorySearchRequest(<private>)"
}
