package com.liddr.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.Serializable

/** The tokens for one signed-in device. Expiries are milliseconds since the epoch. */
@Serializable
data class Tokens(
    val accessToken: String,
    val accessExpiresAt: Long,
    val refreshToken: String,
    val roles: List<String>,
)

/** Where tokens live between launches. */
interface TokenStore {
    fun load(): Tokens?
    fun save(tokens: Tokens)
    fun clear()
}

/**
 * Keeps tokens encrypted under a key the Android Keystore holds and will not
 * release. Anything that cannot be decrypted, such as data restored to a new
 * phone, counts as signed out.
 */
class KeystoreTokenStore(context: Context) : TokenStore {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun load(): Tokens? {
        val stored = prefs.getString(ENTRY, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES))
            val plain = cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES)
            apiJson.decodeFromString<Tokens>(plain.decodeToString())
        }.getOrElse {
            clear()
            null
        }
    }

    override fun save(tokens: Tokens) {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(apiJson.encodeToString(Tokens.serializer(), tokens).encodeToByteArray())
        // commit, not apply: a rotated refresh token that is lost would look like reuse.
        prefs.edit().putString(ENTRY, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    }

    override fun clear() {
        prefs.edit().remove(ENTRY).commit()
    }

    private fun key(): SecretKey {
        val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keystore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val PREFS = "liddr_session"
        const val ENTRY = "tokens"
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "liddr_session_key"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        const val IV_BYTES = 12
    }
}
