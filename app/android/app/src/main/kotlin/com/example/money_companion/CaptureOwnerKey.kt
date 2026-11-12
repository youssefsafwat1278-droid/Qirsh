package com.youssefsafwat.mali

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/**
 * The key behind the capture queue's owner hashes (HMAC-SHA256 of a uid).
 *
 * A non-exportable Android Keystore key, created on first use: the queue and
 * its overflow files hold only `HMAC(key, uid)`, never a uid, and the hash
 * cannot be recomputed from a copy of the app's files. The iOS queue keeps its
 * equivalent key in the Keychain (`SharedCaptureStore.uidHmacKey`).
 *
 * If the Keystore is unavailable the owner calls fail (Dart treats them as
 * "did not happen": capture stays unbound / the removal is retried), never a
 * fallback to an unkeyed hash.
 */
internal object CaptureOwnerKey {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "qirsh_capture_owner_hmac_v1"

    @Synchronized
    fun newMac(): Mac {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val key = store.getKey(ALIAS, null) as? SecretKey ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, KEYSTORE)
            .apply { init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN).build()) }
            .generateKey()
        return Mac.getInstance("HmacSHA256").apply { init(key) }
    }
}
