package app.sybl.sybl

/** Exact persisted consent owns an initial reset and an interrupted retry. */
internal fun resetLocalAccount(expected: String, marker: String?, selected: String?, accounts: List<String>,
    retire: () -> Boolean, remove: (String) -> Unit, removed: (String) -> Boolean): Boolean {
    if (!expected.matches(Regex("[A-Za-z0-9_-]{1,128}")) || marker != expected ||
        (!selected.isNullOrEmpty() && selected != expected) || accounts.any { it != expected }) return false
    if (!retire()) return false
    if (expected in accounts) remove(expected)
    return removed(expected)
}
