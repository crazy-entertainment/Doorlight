package app.sybl.sybl

internal object KnownDeviceWire {
    const val MAX_DEVICES = 64
    const val MAX_NAME_BYTES = 128

    private val deviceId = Regex("^[0-9a-f]{40,128}$")

    fun isDeviceId(value: String): Boolean = deviceId.matches(value)

    fun boundedName(value: String): String {
        val trimmed = value.trim()
        if (trimmed.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) return ""
        if (trimmed.any { it.isSurrogate() || it.code < 0x20 || it.code == 0x7f }) return ""
        return trimmed
    }

    fun project(
        known: Map<String, String>,
        currentId: String,
    ): List<Map<String, Any>> {
        val values = ArrayList<Map<String, Any>>(minOf(known.size, MAX_DEVICES))
        fun append(id: String, name: String) {
            if (values.size >= MAX_DEVICES || !isDeviceId(id)) return
            values += mapOf(
                "id" to id,
                "name" to boundedName(name),
                "current" to (id == currentId),
            )
        }

        known[currentId]?.let { append(currentId, it) }
        for ((id, name) in known) {
            if (id != currentId) append(id, name)
            if (values.size >= MAX_DEVICES) break
        }
        return values
    }

    fun canRevoke(
        requestedId: String,
        currentId: String,
        knownIds: Collection<String>,
    ): Boolean =
        isDeviceId(requestedId) &&
            isDeviceId(currentId) &&
            requestedId != currentId &&
            knownIds.any { it == requestedId }
}
