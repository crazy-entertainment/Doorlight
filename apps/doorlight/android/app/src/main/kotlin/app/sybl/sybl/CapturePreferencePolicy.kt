package app.sybl.sybl

/** Only a successfully read, explicitly stored Boolean false opts out. */
internal fun captureProtectionPreference(read: () -> Any?): Boolean =
    try { read() as? Boolean ?: true } catch (_: Exception) { true }
