package app.sybl.sybl

/** Signed file metadata is a cache, not an authority independent of its exact commit. */
internal data class FileOfferKey(
    val accountId: String,
    val peerId: String,
    val conversationId: String,
    val interactionId: String,
    val fileId: String,
)

internal data class FileOffer(
    val size: Long,
    val name: String,
    val authorId: String,
    val outgoing: Boolean,
    val mediaMetadata: String?,
)

/** A bounded, thread-safe LRU for daemon callback and timeline projection threads. */
internal class BoundedFileCache<K, V>(private val capacity: Int) {
    init { require(capacity > 0) }

    private val entries = object : LinkedHashMap<K, V>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > capacity
    }

    @Synchronized fun get(key: K): V? = entries[key]

    @Synchronized fun putIfAbsent(key: K, value: V): V? {
        val prior = entries[key]
        if (prior == null) entries[key] = value
        return prior
    }

    @Synchronized fun remove(key: K, value: V): Boolean {
        if (entries[key] != value) return false
        entries.remove(key)
        return true
    }

    @Synchronized fun removeWhere(predicate: (K) -> Boolean) {
        entries.keys.removeIf(predicate)
    }

    @Synchronized fun clear() = entries.clear()

    @Synchronized fun size(): Int = entries.size
}
