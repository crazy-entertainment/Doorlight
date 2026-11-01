package app.sybl.sybl

/** Migrates deletion authority only after the sealed copy has been read back. */
internal class SealedWakeRegistrationStore(
    private val legacy: WakeRegistrationStore,
    private val read: () -> ByteArray?,
    private val write: (ByteArray) -> Boolean,
    private val remove: () -> Boolean,
) : WakeRegistrationStore {
    private var retained: WakeCapability? = null

    @Synchronized override fun load(): WakeCapability? {
        retained?.let { return it }
        val sealed = readCapability()
        val old = legacy.load()
        if (sealed != null) {
            check(old == null || old == sealed) { "Wake credential migration conflict" }
            if (old != null) {
                // A failed commit can still populate SharedPreferences' memory map.
                persist(sealed)
                legacy.clear()
            }
            return sealed
        }
        if (old == null) return null
        persist(old)
        // A failed clear leaves both copies available; it never rotates one.
        legacy.clear()
        return old
    }

    @Synchronized override fun save(capability: WakeCapability) {
        check(capability.valid()) { "Invalid wake credential" }
        val previous = load()
        check(previous == null || previous == capability) { "Wake deletion is unresolved" }
        retained = capability
        persist(capability)
        retained = null
    }

    @Synchronized override fun clear() {
        val previous = load() ?: return
        retained = previous
        legacy.clear()
        check(remove()) { "Wake credential removal was not saved" }
        check(readCapability() == null) { "Wake credential removal was not verified" }
        retained = null
    }

    private fun persist(capability: WakeCapability) {
        val bytes = "SYBLWC1\n${capability.handle}\n${capability.secret}".toByteArray(Charsets.US_ASCII)
        try {
            check(write(bytes)) { "Sealed wake credential was not saved" }
            check(readCapability() == capability) { "Sealed wake credential was not verified" }
        } finally { bytes.fill(0) }
    }

    private fun readCapability(): WakeCapability? {
        val bytes = read() ?: return null
        return try {
            check(bytes.size == 95) { "Invalid sealed wake credential" }
            val parts = bytes.toString(Charsets.US_ASCII).split('\n')
            check(parts.size == 3 && parts[0] == "SYBLWC1") { "Invalid sealed wake credential" }
            WakeCapability(parts[1], parts[2]).also {
                check(it.valid()) { "Invalid sealed wake credential" }
            }
        } finally { bytes.fill(0) }
    }
}
