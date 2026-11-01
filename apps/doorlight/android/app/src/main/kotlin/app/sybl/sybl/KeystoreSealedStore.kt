package app.sybl.sybl

import android.annotation.SuppressLint
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small Android-Keystore-backed sealed blob store.
 *
 * The ciphertext is ordinary app-private SharedPreferences data; the AES key is
 * non-exportable from Android Keystore. Callers own their plaintext format and
 * must treat a present-but-incomplete or undecryptable record as corruption.
 */
// commit() is deliberate: callers require the synchronous durability result
// before acknowledging a security-sensitive save or clear. Pulling in KTX for
// two SharedPreferences calls would not improve those semantics.
@SuppressLint("ApplySharedPref", "UseKtx")
internal class KeystoreSealedStore(
    private val preferencesName: String,
    private val keyAlias: String,
) {
    fun exists(context: Context): Boolean {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        return preferences.contains(KEY_IV) || preferences.contains(KEY_BLOB)
    }

    fun save(context: Context, clear: ByteArray): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(clear)
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).edit()
            .putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString(KEY_BLOB, Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .commit()
    } catch (_: Throwable) {
        false
    }

    /**
     * Returns null only when no record exists. A partial, corrupt, or
     * undecryptable record throws so the caller cannot silently replace it.
     */
    fun load(context: Context): ByteArray? {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val ivText = preferences.getString(KEY_IV, null)
        val blobText = preferences.getString(KEY_BLOB, null)
        if (ivText == null && blobText == null) return null
        require(ivText != null && blobText != null) { "incomplete sealed record" }
        val iv = Base64.decode(ivText, Base64.NO_WRAP)
        val encrypted = Base64.decode(blobText, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(encrypted)
    }

    fun clear(context: Context): Boolean = try {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).edit().clear().commit()
    } catch (_: Throwable) {
        false
    }

    private fun key(): SecretKey = synchronized(KEY_CREATION_LOCK) {
        val store = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return@synchronized it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        generator.generateKey()
    }

    private companion object {
        const val KEY_IV = "iv"
        const val KEY_BLOB = "blob"
        const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_BITS = 128
        val KEY_CREATION_LOCK = Any()
    }
}
