package app.sybl.sybl

internal enum class ConversationLoadKind { FOLDER, CHAT, DM_TOPIC_STATE, SEARCH_MESSAGE }

internal sealed interface PendingConversationLoad {
    val kind: ConversationLoadKind
    val peerId: String
    val conversationId: String
}

internal data class FolderConversationLoad(
    override val peerId: String,
    override val conversationId: String,
    val keepLast: Int,
) : PendingConversationLoad {
    override val kind = ConversationLoadKind.FOLDER
}

internal data class ChatConversationLoad(
    override val peerId: String,
    override val conversationId: String,
    val fromMessage: String,
    val pageSize: Int,
) : PendingConversationLoad {
    override val kind = ConversationLoadKind.CHAT
}

internal data class DmTopicStateConversationLoad(
    override val peerId: String,
    override val conversationId: String,
    val fromMessage: String,
    val pageSize: Int,
) : PendingConversationLoad {
    override val kind = ConversationLoadKind.DM_TOPIC_STATE
}

/**
 * One private-search message load. Its captured owner, peer, conversation, message
 * and epoch are rechecked at completion; [answer] delivers at most once.
 */
internal class SearchMessageConversationLoad(
    val account: String,
    val owner: NativeAccountScope,
    override val peerId: String,
    override val conversationId: String,
    val messageId: String,
    val group: Boolean,
    val epoch: Long,
    private val reply: (Map<String, Any>?) -> Unit,
) : PendingConversationLoad {
    override val kind = ConversationLoadKind.SEARCH_MESSAGE
    private val answered = java.util.concurrent.atomic.AtomicBoolean(false)

    fun answer(value: Map<String, Any>?): Boolean {
        if (!answered.compareAndSet(false, true)) return false
        reply(value)
        return true
    }

    override fun toString() = "SearchMessageConversationLoad(<private>)"
}

/**
 * Bounded ownership for libjami loadConversation callbacks.
 *
 * libjami returns a random process-wide UInt32 and has no cancellation token
 * beyond that id. Every id is therefore remembered for this process after
 * completion, timeout, or cancellation; accepting it again could let an
 * arbitrarily late callback claim a newer request. If the bounded remembered
 * set is exhausted, new loads fail closed rather than recycle identity.
 */
internal class ConversationLoadRegistry(
    private val deadlineMs: Long = DEFAULT_DEADLINE_MS,
    private val maxActiveLoads: Int = DEFAULT_MAX_ACTIVE_LOADS,
    private val maxRememberedIds: Int = DEFAULT_MAX_REMEMBERED_IDS,
    private val monotonicMs: () -> Long = { System.nanoTime() / 1_000_000L },
    /** Called for every active load removed without [take] or a cancel: expiry, clear, peer removal,
     * duplicate ids and exhaustion. Loads that need an answer get it here, exactly once. Clear and peer
     * removal keep a [SearchMessageConversationLoad]: its daemon scan runs until completion or expiry. */
    private val onRetired: (PendingConversationLoad) -> Unit = {},
) {
    private data class Entry(
        val load: PendingConversationLoad,
        val registeredAtMs: Long,
    )

    private val active = HashMap<Long, Entry>()
    private val rememberedIds = HashSet<Long>()
    private var exhausted = false

    @Synchronized
    fun canStart(): Boolean {
        purgeExpired(monotonicMs())
        return !exhausted && active.size < maxActiveLoads &&
            rememberedIds.size < maxRememberedIds
    }

    @Synchronized
    fun register(id: Long, load: PendingConversationLoad): Boolean {
        val now = monotonicMs()
        purgeExpired(now)
        if (id <= 0L || exhausted) return false
        if (id in rememberedIds) {
            // Duplicate ids are indistinguishable. Retire the original active
            // request too so neither callback can mutate the wrong owner.
            active.remove(id)?.let { onRetired(it.load) }
            return false
        }
        if (rememberedIds.size >= maxRememberedIds) {
            exhausted = true
            retireAll()
            return false
        }
        rememberedIds.add(id)
        if (active.size >= maxActiveLoads) return false
        active[id] = Entry(load, now)
        return true
    }

    @Synchronized
    fun take(id: Long): PendingConversationLoad? {
        purgeExpired(monotonicMs())
        return active.remove(id)?.load
    }

    @Synchronized
    fun cancelChat(id: Long): Boolean = cancel(id, ConversationLoadKind.CHAT)

    @Synchronized
    fun cancelDmTopicState(id: Long): Boolean = cancel(id, ConversationLoadKind.DM_TOPIC_STATE)

    private fun cancel(id: Long, kind: ConversationLoadKind): Boolean {
        purgeExpired(monotonicMs())
        val entry = active[id] ?: return false
        if (entry.load.kind != kind) return false
        active.remove(id)
        return true
    }

    @Synchronized
    fun removePeer(peerId: String) {
        purgeExpired(monotonicMs())
        retireMatching { it.peerId == peerId && it.kind != ConversationLoadKind.SEARCH_MESSAGE }
    }

    @Synchronized
    fun clearActive() {
        retireMatching { it.kind != ConversationLoadKind.SEARCH_MESSAGE }
    }

    private fun retireMatching(predicate: (PendingConversationLoad) -> Boolean) {
        val retired = active.entries.filter { predicate(it.value.load) }
        retired.forEach { active.remove(it.key) }
        retired.forEach { onRetired(it.value.load) }
    }

    /** Retires expired entries; a timer calls this so an idle registry still answers. */
    @Synchronized
    fun sweepExpired() {
        purgeExpired(monotonicMs())
    }

    @Synchronized
    internal fun activeSize(): Int = active.size

    @Synchronized
    internal fun rememberedSize(): Int = rememberedIds.size

    private fun retireAll() = retireMatching { true }

    private fun purgeExpired(nowMs: Long) {
        val expired = active.entries.filter { nowMs - it.value.registeredAtMs >= deadlineMs }
        expired.forEach { active.remove(it.key) }
        expired.forEach { onRetired(it.value.load) }
    }

    companion object {
        const val DEFAULT_DEADLINE_MS = 35_000L
        const val DEFAULT_MAX_ACTIVE_LOADS = 64
        const val DEFAULT_MAX_REMEMBERED_IDS = 64 * 1024
    }
}
