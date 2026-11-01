package app.sybl.sybl

import android.content.Context
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Base64

/**
 * Device-bound working password for libjami's account archive.
 *
 * This protects archive.gz (and therefore the master identity used to mint new
 * devices). It does not encrypt libjami's live device key, swarm repositories,
 * or received files; the app-lock/capture shield remains a separate control.
 */
internal object ArchiveSecretStore {
    private val store = KeystoreSealedStore(
        preferencesName = "archive_secret",
        keyAlias = "sybl.archive.secret",
    )

    /**
     * Loads the existing secret or creates it exactly once. A present corrupt
     * record throws and is never replaced with a fresh secret.
     */
    @Synchronized
    fun loadOrCreate(context: Context): ArchiveSecretResult {
        val existing = store.load(context)
        if (existing != null) {
            return try {
                ArchiveSecretResult(
                    secret = ArchiveSecretFormat.decode(existing),
                    created = false,
                )
            } finally {
                existing.fill(0)
            }
        }

        val generated = ArchiveSecretFormat.generate()
        val clear = generated.toByteArray(StandardCharsets.US_ASCII)
        try {
            check(store.save(context, clear)) { "device archive secret could not be persisted" }
        } finally {
            clear.fill(0)
        }

        // Read-after-write makes durability and Keystore decryptability part of
        // the transaction before libjami is asked to use the secret.
        val persisted = checkNotNull(store.load(context)) {
            "device archive secret disappeared after persistence"
        }
        return try {
            val decoded = ArchiveSecretFormat.decode(persisted)
            check(decoded == generated) { "device archive secret changed during persistence" }
            ArchiveSecretResult(secret = decoded, created = true)
        } finally {
            persisted.fill(0)
        }
    }
}

internal data class ArchiveSecretResult(
    val secret: String,
    val created: Boolean,
)

internal object ArchiveSecretFormat {
    private const val RANDOM_BYTES = 32
    private val valid = Regex("^[A-Za-z0-9_-]{43}$")

    fun generate(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(RANDOM_BYTES)
        random.nextBytes(bytes)
        return try {
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        } finally {
            bytes.fill(0)
        }
    }

    fun decode(bytes: ByteArray): String {
        val value = String(bytes, StandardCharsets.US_ASCII)
        require(isValid(value)) { "invalid device archive secret" }
        return value
    }

    fun isValid(value: String): Boolean = valid.matches(value)
}
