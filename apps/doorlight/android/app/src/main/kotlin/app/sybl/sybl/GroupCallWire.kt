package app.sybl.sybl

internal object GroupCallWire {
    const val MAX_CONFERENCE_STREAMS = 128
    const val MAX_CONFERENCE_FIELDS = 32
    const val MAX_CONFERENCE_FIELD_BYTES = 1024
    const val MAX_CONFERENCE_BYTES = 64 * 1024

    /** Validate before copying SWIG maps or sending them across the UI channel. */
    fun boundedConference(infos: List<Map<String, String>>): List<Map<String, String>>? {
        if (infos.size > MAX_CONFERENCE_STREAMS) return null
        var bytes = 0
        val result = ArrayList<Map<String, String>>(infos.size)
        for (info in infos) {
            if (info.size > MAX_CONFERENCE_FIELDS) return null
            val row = HashMap<String, String>()
            for ((key, value) in info) {
                if (key.length > MAX_CONFERENCE_FIELD_BYTES || value.length > MAX_CONFERENCE_FIELD_BYTES) return null
                val keyBytes = key.toByteArray(Charsets.UTF_8).size
                val valueBytes = value.toByteArray(Charsets.UTF_8).size
                bytes += keyBytes + valueBytes
                if (keyBytes > MAX_CONFERENCE_FIELD_BYTES || valueBytes > MAX_CONFERENCE_FIELD_BYTES ||
                    bytes > MAX_CONFERENCE_BYTES) return null
                row[key] = value
            }
            result.add(row)
        }
        return result
    }
    const val PRESENCE_MIME = "application/x-sybl-group-call-presence+json"
    const val MAX_PRESENCE_BYTES = 2048
    private val conferenceId = Regex("^syblv1-([a-z0-9][a-z0-9-]{0,31})-([1-9][0-9]{0,19})$")

    fun roomId(value: String): String? = conferenceId.matchEntire(value)?.groupValues?.get(1)

    fun mediaTarget(conferenceId: String, callLeg: String, hosting: Boolean): String =
        if (hosting) conferenceId else callLeg.ifEmpty { conferenceId }

    fun ownsMediaSink(owner: String, callLeg: String, sinkId: String): Boolean =
        owner.isNotEmpty() && (sinkId == owner || (callLeg.isNotEmpty() && sinkId == callLeg))

    fun screenShareNeedsRawFrames(conferenceId: String, hosting: Boolean): Boolean =
        hosting && conferenceId.isNotEmpty()

    fun hostConferenceForCurrent(
        conferenceId: String,
        hosting: Boolean,
        rejected: Boolean,
        state: String,
    ): String? = conferenceId.takeIf { hosting && !rejected && state == "CURRENT" && it.isNotEmpty() }

    fun acceptPresence(snapshot: RoutingSnapshot, rawSender: String, body: String): Boolean {
        if (body.toByteArray(Charsets.UTF_8).size > MAX_PRESENCE_BYTES) return false
        val sender = bareJamiId(rawSender)
        return sender.isNotEmpty() && snapshot.groups.values.any { sender in it.activeMemberIds }
    }
}
