package app.sybl.sybl

import android.content.SharedPreferences
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.SecureRandom
import java.util.Base64

internal data class WakeCapability(val handle: String, val secret: String) {
    fun valid(): Boolean = HANDLE.matches(handle) && HANDLE.matches(secret) && handle != secret

    private companion object {
        val HANDLE = Regex("^[A-Za-z0-9_-]{43}$")
    }
}

internal interface WakeRegistrationStore {
    fun load(): WakeCapability?
    fun save(capability: WakeCapability)
    fun clear()
}

internal data class WakeRelayRequest(
    val method: String,
    val url: String,
    val bearer: String,
    val body: String = "",
)

internal fun interface WakeRegistrationTransport {
    fun execute(request: WakeRelayRequest): Boolean

    fun status(request: WakeRelayRequest): Int =
        if (execute(request)) HttpURLConnection.HTTP_NO_CONTENT else HttpURLConnection.HTTP_UNAVAILABLE
}

internal class WakeRegistration(
    private val store: WakeRegistrationStore,
    private val transport: WakeRegistrationTransport,
    private val deletionJournal: WakeDeletionJournal,
    private val randomBytes: (Int) -> ByteArray = { size -> ByteArray(size).also(SecureRandom()::nextBytes) },
) {
    @Volatile var registered: Boolean = false
        private set

    val handle: String get() = store.load()?.takeIf(WakeCapability::valid)?.handle.orEmpty()

    fun deletionAuthority(): WakeDeletion? = deletionJournal.load()
    fun pendingDeletion(): WakeDeletion? = deletionJournal.load()?.takeIf { it.requested }

    fun enable(relayUrl: String, fcmToken: String, ownerAccount: String = ""): String? {
        val authority = deletionJournal.load()
        if (authority?.requested == true) return null
        val base = validRelayUrl(relayUrl) ?: return null
        if (authority != null && (authority.relay != base || authority.account != ownerAccount)) return null
        if (!validToken(fcmToken)) return null
        val capability = store.load()?.takeIf(WakeCapability::valid) ?: newCapability()
        // A failed SharedPreferences commit can still update its process map.
        // Require durable acknowledgement on retry as well as on first creation.
        store.save(capability)
        check(authority == null || authority.capability == capability) { "Wake credential ownership conflict" }
        deletionJournal.save(WakeDeletion(base, ownerAccount, capability, requested = false))
        val status = transport.status(registerRequest(base, capability, fcmToken))
        if (status == HttpURLConnection.HTTP_GONE) {
            // The relay keeps a deleted handle as a tombstone. Its 410 proves
            // the old credential can no longer wake or register this handle.
            // Clear the journal first: a crash before clearing the store can
            // safely retry the same 410 and finish rotating.
            deletionJournal.clear()
            store.clear()
            val replacement = newCapability()
            store.save(replacement)
            deletionJournal.save(WakeDeletion(base, ownerAccount, replacement, requested = false))
            registered = transport.status(registerRequest(base, replacement, fcmToken)) ==
                HttpURLConnection.HTTP_NO_CONTENT
            return replacement.handle.takeIf { registered }
        }
        registered = status == HttpURLConnection.HTTP_NO_CONTENT
        return capability.handle.takeIf { registered }
    }

    fun disable(relayUrl: String, ownerAccount: String = ""): Boolean {
        registered = false
        val pending = deletionJournal.load()
        val stored = store.load()?.takeIf(WakeCapability::valid)
        if (pending == null && stored == null) return true
        val base = validRelayUrl(relayUrl) ?: return false
        if (pending != null && (pending.relay != base || pending.account != ownerAccount)) return false
        val capability = pending?.capability ?: checkNotNull(stored)
        check(stored == null || stored == capability) { "Wake deletion credential conflict" }
        deletionJournal.save(WakeDeletion(base, ownerAccount, capability))
        if (!transport.execute(WakeRelayRequest(
                method = "DELETE",
                url = "$base/v1/registrations/${capability.handle}",
                bearer = capability.secret,
            ))) return false
        store.clear()
        deletionJournal.clear()
        return true
    }

    private fun newCapability() = WakeCapability(randomValue(), randomValue())

    private fun randomValue(): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(randomBytes(32))

    private fun registerRequest(base: String, capability: WakeCapability, token: String) =
        WakeRelayRequest(
            method = "PUT",
            url = "$base/v1/registrations/${capability.handle}",
            bearer = capability.secret,
            body = JSONObject().put("token", token).toString(),
        )

    private fun validRelayUrl(value: String): String? = try {
        val uri = URI(value)
        value.trimEnd('/').takeIf {
            uri.scheme == "https" && uri.host != null && uri.userInfo == null &&
                uri.query == null && uri.fragment == null &&
                (uri.path.isNullOrEmpty() || uri.path == "/")
        }
    } catch (_: Exception) {
        null
    }

    private fun validToken(value: String): Boolean = value.length in 20..4096
}

internal class SharedPreferencesWakeRegistrationStore(
    private val preferences: SharedPreferences,
) : WakeRegistrationStore {
    @Volatile private var retainedAfterFailure: WakeCapability? = null

    override fun load(): WakeCapability? {
        retainedAfterFailure?.let { return it }
        val handle = preferences.getString(HANDLE_KEY, null)
        val secret = preferences.getString(SECRET_KEY, null)
        if (handle == null && secret == null) return null
        check(handle != null && secret != null) { "Wake credential is incomplete" }
        return WakeCapability(handle, secret).also {
            check(it.valid()) { "Wake credential is invalid" }
        }
    }

    override fun save(capability: WakeCapability) {
        retainedAfterFailure = capability
        check(preferences.edit().putString(HANDLE_KEY, capability.handle)
            .putString(SECRET_KEY, capability.secret).commit()) { "Wake credential was not saved" }
        retainedAfterFailure = null
    }

    override fun clear() {
        // Failed commit can already remove the keys from the process map.
        // Keep the exact credential so a later deletion attempt cannot infer absence.
        retainedAfterFailure = load()
        check(preferences.edit().remove(HANDLE_KEY).remove(SECRET_KEY).commit()) {
            "Wake credential removal was not saved"
        }
        retainedAfterFailure = null
    }

    private companion object {
        const val HANDLE_KEY = "wakeHandle"
        const val SECRET_KEY = "wakeSecret"
    }
}

internal class HttpWakeRegistrationTransport : WakeRegistrationTransport {
    override fun execute(request: WakeRelayRequest): Boolean =
        status(request) == HttpURLConnection.HTTP_NO_CONTENT

    override fun status(request: WakeRelayRequest): Int {
        val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
            requestMethod = request.method
            connectTimeout = 3_000
            readTimeout = 3_000
            instanceFollowRedirects = false
            setRequestProperty("Authorization", "Bearer ${request.bearer}")
            setRequestProperty("Cache-Control", "no-store")
        }
        return try {
            if (request.body.isNotEmpty()) {
                val bytes = request.body.toByteArray(Charsets.UTF_8)
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }
}
