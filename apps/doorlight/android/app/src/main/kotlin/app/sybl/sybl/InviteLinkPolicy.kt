package app.sybl.sybl

/** Bounded transport candidates only; Dart validates all fields before staging. */
internal object InviteLinkPolicy {
    fun candidate(value: String?, configuredOrigin: String): String? {
        if (value == null || value.length > 1024 || value.any { it <= ' ' || it == '\u007f' }) return null
        val custom = value.startsWith("sybl://add/") || value.startsWith("doorlight://add/")
        val configuredHttps = configuredOrigin.isNotEmpty() && value.startsWith("$configuredOrigin/invite/#")
        return if (custom || configuredHttps) value else null
    }
}
