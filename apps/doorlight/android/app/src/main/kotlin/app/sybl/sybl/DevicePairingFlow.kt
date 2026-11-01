package app.sybl.sybl

/** Process-local protocol projection. The host checks the selected-account lease
 * before every action and persists destination admission in IdentityRestoreJournal.
 * URI/code material is never a journal, a diagnostic, or an archive credential. */
internal class DevicePairingVisits {
    private var generation = 0L
    private val retired = LinkedHashSet<String>()
    @Synchronized fun capture() = generation
    @Synchronized fun allows(token: String, epoch: Long) = generation != Long.MAX_VALUE &&
        generation == epoch && DevicePairingFlow.validToken(token) && token !in retired
    @Synchronized fun retire(token: String) {
        if (!DevicePairingFlow.validToken(token)) return
        retired.add(token)
        if (retired.size > 64) retired.remove(retired.first())
    }
    @Synchronized fun retireAll() { if (generation != Long.MAX_VALUE) generation++ }
}

internal class DevicePairingFlow(
    val token: String,
    val account: String,
    val destination: Boolean,
) {
    companion object {
        private val hex40 = Regex("[0-9a-f]{40}")
        private val hex64 = Regex("[0-9a-f]{64}")
        private val offer = Regex("jami-auth://[0-9a-f]{64}/[1-9][0-9]{5}/doorlight-v1")
        fun validToken(value: String) = hex64.matches(value)
        fun validOffer(value: String) = value.length <= 100 && offer.matches(value)
        fun validCode(value: String) = value.length == 8 && value.all { it in '0'..'9' }
    }

    var operation = 0L; private set
    var status = "starting"; private set
    var terminal = false; private set
    var nativeSucceeded = false; private set
    var privacyCommitted = false; private set
    var retired = false; private set
    private var uri = ""
    private var code = ""
    private var peer = ""
    private var peerDevice = ""
    private var device = ""
    private var error = ""
    private var invalidCode = false

    @Synchronized fun bindOperation(value: Long): Boolean {
        if (value !in 1L..Int.MAX_VALUE.toLong() ||
            (destination && value !in 100000L..999999L) ||
            (operation != 0L && operation != value)) return false
        operation = value
        return true
    }

    /** Operation correlation precedes state projection, including terminal events. */
    @Synchronized fun accept(value: Long, state: Int, details: Map<String, String>): Boolean {
        if (terminal || operation == 0L || value != operation || state !in 1..5) return false
        if (state == 5) {
            val reason = details["error"] ?: return false
            if (reason.length > 64) return false
            if (reason.isEmpty() && !identities(details)) return false
            terminal = true
            nativeSucceeded = reason.isEmpty()
            error = reason.takeIf { it in setOf("canceled", "timeout", "auth_error", "network", "source_disabled") }
                ?: if (reason.isEmpty()) "" else "unavailable"
            status = if (nativeSucceeded) (if (destination) "confirming" else "complete") else "ended"
            uri = ""; code = ""
            return true
        }
        if (retired) return false
        if (destination) {
            when (state) {
                1 -> {
                    val offered = details["token"].orEmpty()
                    if (status != "starting" || !validOffer(offered) ||
                        details["operation"] != operation.toString() ||
                        details["auth_scheme"] != "doorlight-code-v1") return false
                    uri = offered; status = "waiting"
                }
                3 -> {
                    if (status !in setOf("waiting", "checking", "code", "unconfirmed") ||
                        details["auth_scheme"] != "doorlight-code-v1" || !identities(details, prepared = false)) return false
                    status = "code"; invalidCode = details["auth_error"] == "invalid_code"
                }
                4 -> {
                    if (status !in setOf("checking", "code", "unconfirmed") ||
                        details["prepared"] != "true" || !identities(details)) return false
                    status = "prepared"; uri = ""; code = ""; invalidCode = false
                }
                else -> return false
            }
        } else {
            when (state) {
                2 -> if (status == "starting") status = "connecting" else return false
                3 -> {
                    if (status !in setOf("starting", "connecting") ||
                        details["auth_scheme"] != "doorlight-code-v1") return false
                    status = "consent"
                }
                4 -> {
                    if (status !in setOf("codeIssued", "unconfirmed")) return false
                    status = "transferring"; code = ""
                }
                else -> return false
            }
        }
        return true
    }

    private fun identities(details: Map<String, String>, prepared: Boolean = true): Boolean {
        val nextPeer = details["peer_id"].orEmpty()
        val nextSource = details["peer_device"].orEmpty()
        val nextDevice = details["device_id"].orEmpty()
        if (!hex40.matches(nextPeer) || !hex64.matches(nextSource) ||
            (prepared && (!hex64.matches(nextDevice) || nextDevice == nextSource)) ||
            (peer.isNotEmpty() && peer != nextPeer) ||
            (peerDevice.isNotEmpty() && peerDevice != nextSource) ||
            (device.isNotEmpty() && prepared && device != nextDevice)) return false
        peer = nextPeer; peerDevice = nextSource
        if (prepared) device = nextDevice
        return true
    }

    @Synchronized fun issuedCode(value: String): Boolean {
        if (destination || retired || terminal || status != "consent" || !validCode(value)) return false
        code = value; status = "codeIssued"
        return true
    }
    @Synchronized fun submittingCode(): Boolean {
        if (!destination || retired || terminal || status != "code") return false
        status = "checking"; invalidCode = false
        return true
    }
    @Synchronized fun preparedPrivacy(): Boolean {
        if (!destination || retired || terminal || status != "prepared") return false
        privacyCommitted = true; status = "confirming"
        return true
    }
    @Synchronized fun acknowledgedDurably(): Boolean {
        if (!destination || !nativeSucceeded || !privacyCommitted) return false
        status = "ready"
        return true
    }
    @Synchronized fun unconfirmed() {
        if (!terminal || (destination && status != "ready")) status = "unconfirmed"
        code = ""
    }
    @Synchronized fun retire() {
        retired = true; uri = ""; code = ""
    }
    @Synchronized fun projection(): Map<String, Any> = mapOf(
        "flowToken" to token, "accountId" to account,
        "role" to if (destination) "destination" else "source",
        "operation" to operation, "status" to if (retired) "retired" else status,
        "terminal" to terminal, "error" to error,
        "uri" to if (retired) "" else uri, "code" to if (retired) "" else code,
        "peerId" to if (retired) "" else peer,
        "peerDeviceId" to if (retired) "" else peerDevice,
        "deviceId" to if (retired) "" else device,
        "invalidCode" to (!retired && invalidCode),
    )
    override fun toString() = "DevicePairingFlow(<private>)"
}
