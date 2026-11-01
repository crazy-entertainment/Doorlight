package app.sybl.sybl

import org.json.JSONObject

internal data class WakeDeletion(
    val relay: String,
    val account: String,
    val capability: WakeCapability,
    val requested: Boolean = true,
)

internal interface WakeDeletionJournal {
    fun load(): WakeDeletion?
    fun save(value: WakeDeletion)
    fun clear()
}

internal class SealedWakeDeletionJournal(
    private val read: () -> ByteArray?,
    private val write: (ByteArray) -> Boolean,
    private val remove: () -> Boolean,
) : WakeDeletionJournal {
    private var retained: WakeDeletion? = null

    @Synchronized override fun load(): WakeDeletion? = retained ?: decode()

    @Synchronized override fun save(value: WakeDeletion) {
        check(load().let {
            it == null || (it.relay == value.relay && it.account == value.account &&
                it.capability == value.capability && (!it.requested || value.requested))
        }) { "Wake deletion is unresolved" }
        check(value.relay.length in 1..2048 && value.account.length <= 128 && value.capability.valid())
        retained = value
        val bytes = JSONObject().put("version", 1).put("relay", value.relay)
            .put("account", value.account).put("handle", value.capability.handle)
            .put("requested", value.requested)
            .put("secret", value.capability.secret).toString().toByteArray(Charsets.UTF_8)
        try {
            check(write(bytes)) { "Wake deletion was not saved" }
            check(decode() == value) { "Wake deletion was not verified" }
            retained = null
        } finally { bytes.fill(0) }
    }

    @Synchronized override fun clear() {
        retained = load()
        check(remove()) { "Wake deletion completion was not saved" }
        check(decode() == null) { "Wake deletion completion was not verified" }
        retained = null
    }

    private fun decode(): WakeDeletion? {
        val bytes = read() ?: return null
        return try {
            check(bytes.size in 1..4096) { "Invalid wake deletion record" }
            val value = JSONObject(bytes.toString(Charsets.UTF_8))
            check(value.length() == 6 && value.opt("version") == 1)
            val relay = value.opt("relay") as? String ?: error("Invalid wake deletion relay")
            val account = value.opt("account") as? String ?: error("Invalid wake deletion owner")
            val handle = value.opt("handle") as? String ?: error("Invalid wake deletion credential")
            val secret = value.opt("secret") as? String ?: error("Invalid wake deletion credential")
            val requested = value.opt("requested") as? Boolean ?: error("Invalid wake deletion state")
            check(relay.length in 1..2048 && account.length <= 128)
            WakeDeletion(relay, account, WakeCapability(handle, secret), requested).also { check(it.capability.valid()) }
        } finally { bytes.fill(0) }
    }
}
