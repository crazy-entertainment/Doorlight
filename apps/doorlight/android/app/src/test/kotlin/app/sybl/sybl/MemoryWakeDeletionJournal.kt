package app.sybl.sybl

internal class MemoryWakeDeletionJournal : WakeDeletionJournal {
    var value: WakeDeletion? = null
    override fun load() = value
    override fun save(value: WakeDeletion) { this.value = value }
    override fun clear() { value = null }
}
