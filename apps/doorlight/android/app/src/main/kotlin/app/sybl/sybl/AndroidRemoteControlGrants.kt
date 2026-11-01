package app.sybl.sybl

import android.content.Context
import java.nio.charset.StandardCharsets

internal data class AndroidRemoteControlGrant(
    val localAccount: String,
    val controllerAccount: String,
    val controllerDevice: String,
    val createdAtMs: Long,
    val lastUsedAtMs: Long,
)

internal object AndroidRemoteControlGrantPolicy {
    const val MAX_GRANTS = 64
    private val account = Regex("^[0-9a-f]{40}$")
    private val device = Regex("^[0-9a-f]{40,128}$")

    fun validIdentity(local: String, controller: String, deviceId: String): Boolean =
        account.matches(local) && account.matches(controller) && device.matches(deviceId)

    fun decode(clear: ByteArray): List<AndroidRemoteControlGrant> {
        if (clear.isEmpty()) return emptyList()
        val text = String(clear, StandardCharsets.US_ASCII)
        require(text.toByteArray(StandardCharsets.US_ASCII).contentEquals(clear)) {
            "grant store is not ASCII"
        }
        val records = text.lineSequence().filter(String::isNotEmpty).map { line ->
            val fields = line.split('|')
            require(fields.size == 5) { "invalid grant record" }
            AndroidRemoteControlGrant(
                fields[0],
                fields[1],
                fields[2],
                fields[3].toLong(),
                fields[4].toLong(),
            )
        }.toList()
        require(records.size <= MAX_GRANTS) { "too many grants" }
        return records
    }

    fun encode(grants: List<AndroidRemoteControlGrant>): ByteArray {
        require(grants.size <= MAX_GRANTS) { "too many grants" }
        return grants.joinToString("\n") { grant ->
            require(
                validIdentity(
                    grant.localAccount,
                    grant.controllerAccount,
                    grant.controllerDevice,
                ),
            ) { "invalid grant identity" }
            "${grant.localAccount}|${grant.controllerAccount}|${grant.controllerDevice}|" +
                "${grant.createdAtMs}|${grant.lastUsedAtMs}"
        }.toByteArray(StandardCharsets.US_ASCII)
    }
}

/** Deletes legacy saved grants; saved consent never supplies admission authority. */
internal class AndroidRemoteControlGrantRepository(
    private val readClear: () -> ByteArray?,
    private val writeClear: (ByteArray) -> Boolean,
) {
    // Keep failed durable cleanup visible even after a later retry succeeds.
    @Volatile var revocationFailed = false
        private set

    @Synchronized
    fun removePeer(localAccount: String, controllerAccount: String): Boolean {
        if (!AndroidRemoteControlGrantPolicy.validIdentity(
                localAccount, controllerAccount, "0".repeat(40))) return false
        return try {
            val original = load()
            val retained = original.filterNot {
                it.localAccount == localAccount && it.controllerAccount == controllerAccount
            }
            val removed = (retained.size == original.size || save(retained)) &&
                load().none {
                    it.localAccount == localAccount && it.controllerAccount == controllerAccount
                }
            if (!removed) revocationFailed = true
            removed
        } catch (_: Throwable) {
            revocationFailed = true
            false
        }
    }

    private fun load(): List<AndroidRemoteControlGrant> {
        val clear = readClear() ?: return emptyList()
        return try {
            AndroidRemoteControlGrantPolicy.decode(clear)
        } finally {
            clear.fill(0)
        }
    }

    private fun save(grants: List<AndroidRemoteControlGrant>): Boolean {
        val clear = AndroidRemoteControlGrantPolicy.encode(grants)
        return try {
            writeClear(clear)
        } finally {
            clear.fill(0)
        }
    }
}

internal object AndroidRemoteControlGrantStore {
    private val store = KeystoreSealedStore(
        preferencesName = "remote_control_grants",
        keyAlias = "sybl.remote.control.grants",
    )
    private var current: AndroidRemoteControlGrantRepository? = null

    @Synchronized
    private fun repository(context: Context): AndroidRemoteControlGrantRepository {
        current?.let { return it }
        val app = context.applicationContext
        return AndroidRemoteControlGrantRepository(
            { store.load(app) },
            { store.save(app, it) },
        ).also { current = it }
    }

    fun removePeer(context: Context, local: String, controller: String) =
        repository(context).removePeer(local, controller)
}
