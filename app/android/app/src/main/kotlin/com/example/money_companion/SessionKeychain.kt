package com.youssefsafwat.mali

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/*
 * ASR design v7.2 §6.1 — the Android side of `qirsh/session_keychain`
 * (`lib/core/auth/session_keychain.dart`; iOS: `ios/Runner/SessionKeychain.swift`).
 *
 * Before this file Android had no handler, so `protectedDataAvailable` failed,
 * every load deferred, and a build with a configured backend never left the
 * loading screen.
 *
 * Contract kept from iOS: every reply carries the status class (`found`,
 * `absent`, `ok`, `unavailable`, `error`); `absent` is only ever a confirmed
 * "does not exist"; every operation runs on ONE serial executor shared by every
 * engine in the process, so a reload queued after a write whose reply was lost
 * observes that write (§6.3). A write whose outcome is not known replies with a
 * channel error, which Dart reads as `unknown` and reconciles by a read.
 *
 * Android additions:
 *  - Items this file OWNS (the session record) are sealed with AES-256-GCM under
 *    a dedicated, non-exportable Android Keystore key (no user authentication:
 *    background refresh and capture run while the phone is locked). They live in
 *    one file under `noBackupFilesDir`, replaced atomically; backup and device
 *    transfer are disabled for the app as a whole (AndroidManifest.xml,
 *    data_extraction_rules.xml), and a Keystore key never leaves the device.
 *    No session value is ever stored in plaintext.
 *  - `permanent: true` on an `error` reply means the item can never be read
 *    again (its key is gone or invalidated, or the stored bytes are damaged).
 *    Dart treats that record as unrecoverable (sign in again) instead of
 *    deferring forever; a transient failure stays `permanent: false`.
 *  - `readPluginItem` reads `flutter_secure_storage`'s EncryptedSharedPreferences
 *    with the plugin's own file, master key and key prefix, never writes, and —
 *    unlike the plugin, which silently falls back to an empty store when its
 *    keyset cannot be opened — reports such a failure as `error`, never `absent`.
 */

/** One reply on the channel. [value] only for `found`. */
internal data class KeychainReply(
    val status: String,
    val value: String? = null,
    val code: String = status,
    val permanent: Boolean = false,
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("status", status)
        put("code", code)
        if (value != null) put("value", value)
        if (permanent) put("permanent", true)
    }

    companion object {
        fun found(v: String) = KeychainReply("found", v)
        val absent = KeychainReply("absent")
        val ok = KeychainReply("ok")
        fun transient(code: String) = KeychainReply("error", code = code)
        fun permanent(code: String) = KeychainReply("error", code = code, permanent = true)
    }
}

/** The write may or may not have landed: Dart must reconcile with a read. */
internal class IndeterminateWrite(cause: Throwable) : Exception("session store write indeterminate", cause)

/** Where the vault key lives. Production: [SessionKeychainKey] (Android Keystore). */
internal interface SessionKeySource {
    /** The key; null only when the store ANSWERED and holds none. Throws when it cannot answer. */
    fun load(): SecretKey?

    /** Creates (or replaces) the key. */
    fun create(): SecretKey

    /** True when [t] (or a cause) says the key can never be used again. */
    fun isPermanentFault(t: Throwable): Boolean
}

/**
 * The file that holds the sealed items: a header line, then one
 * `hex(name) envelope` line per item. Replaced atomically (temp + fsync +
 * rename), so a reader sees the old or the new content, never a mix.
 */
internal class SessionItemFile(private val file: File) {
    class Damaged : Exception("session store damaged")

    /** Empty when the file does not exist. Throws [IOException] (retryable) or [Damaged]. */
    fun load(): Map<String, String> {
        if (!file.exists()) return emptyMap()
        val lines = file.readLines(Charsets.UTF_8)
        if (lines.firstOrNull() != HEADER) throw Damaged()
        val out = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) continue
            val sp = line.indexOf(' ')
            if (sp <= 0) throw Damaged()
            val name = Hex.decode(line.substring(0, sp))?.toString(Charsets.UTF_8) ?: throw Damaged()
            out[name] = line.substring(sp + 1)
        }
        return out
    }

    /**
     * Replaces the content. Returns normally when the new content is durable;
     * throws [IOException] when it is confirmed NOT written (old content intact);
     * throws [IndeterminateWrite] when the outcome cannot be known.
     */
    fun save(items: Map<String, String>) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        val body = buildString {
            append(HEADER).append('\n')
            for ((k, v) in items) {
                append(Hex.encode(k.toByteArray(Charsets.UTF_8))).append(' ').append(v).append('\n')
            }
        }
        FileOutputStream(tmp).use { out ->
            out.write(body.toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        val renamed = try {
            tmp.renameTo(file)
        } catch (t: Throwable) {
            throw IndeterminateWrite(t)
        }
        if (!renamed) {
            tmp.delete()
            throw IOException("rename failed")
        }
    }

    companion object {
        const val HEADER = "qsk-store-v1"
    }
}

internal object Hex {
    private const val DIGITS = "0123456789abcdef"
    fun encode(b: ByteArray): String = buildString(b.size * 2) {
        for (x in b) {
            append(DIGITS[(x.toInt() shr 4) and 0xF]).append(DIGITS[x.toInt() and 0xF])
        }
    }

    fun decode(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        val out = ByteArray(s.length / 2)
        for (i in out.indices) {
            val hi = DIGITS.indexOf(s[2 * i])
            val lo = DIGITS.indexOf(s[2 * i + 1])
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }
}

/**
 * The owned items: read / write / delete with the iOS status classes.
 * Pure JVM (no Android API), so the JUnit tests run this exact code.
 */
internal class SessionVault(
    private val file: SessionItemFile,
    private val keys: SessionKeySource,
) {
    private class KeyFault(val permanent: Boolean) : Exception()

    @Synchronized
    fun read(name: String): KeychainReply {
        val items = try {
            file.load()
        } catch (_: SessionItemFile.Damaged) {
            return KeychainReply.permanent("store_damaged")
        } catch (_: Exception) {
            return KeychainReply.transient("store_io")
        }
        val envelope = items[itemName(name)] ?: return KeychainReply.absent
        val key = try {
            keys.load()
        } catch (t: Throwable) {
            return if (keys.isPermanentFault(t)) KeychainReply.permanent("key_invalidated")
            else KeychainReply.transient("keystore_unavailable")
        } ?: return KeychainReply.permanent("key_lost")
        return try {
            val plain = open(key, envelope, aad(name))
            if (plain != null) return KeychainReply.found(plain.toString(Charsets.UTF_8))
            // Authentication failed: the wrong key, or damaged bytes.
            val check = items[KEY_CHECK]
            val keyMatches = check != null && open(key, check, aad(KEY_CHECK))
                ?.contentEquals(KEY_CHECK_PLAIN) == true
            KeychainReply.permanent(if (keyMatches) "item_damaged" else "key_mismatch")
        } catch (f: KeyFault) {
            if (f.permanent) KeychainReply.permanent("key_invalidated")
            else KeychainReply.transient("keystore_unavailable")
        }
    }

    /**
     * Seals and stores [value]. When the key is gone or invalidated, the items
     * sealed with it can never be read again: a new key is created for this
     * write (the coordinator writes only on an explicit, authenticated action or
     * to retire a record), and the unreadable items stay as they are.
     */
    @Synchronized
    fun write(name: String, value: String): KeychainReply {
        val items = try {
            file.load().toMutableMap()
        } catch (_: SessionItemFile.Damaged) {
            // Nothing in a damaged file is readable; a full replacement is the
            // only write possible. Kept only if the new content is durable.
            mutableMapOf()
        } catch (_: Exception) {
            return KeychainReply.transient("store_io")
        }
        val loaded = try {
            keys.load()
        } catch (t: Throwable) {
            if (!keys.isPermanentFault(t)) return KeychainReply.transient("keystore_unavailable")
            null
        }
        try {
            val existing = loaded?.let { k -> trySeal(k, value, name)?.let { k to it } }
            val (key, sealed) = existing
                ?: keys.create().let { k -> k to seal(k, value.toByteArray(Charsets.UTF_8), aad(name)) }
            // The check always follows the live key (first item, or a key that
            // replaced a lost one).
            val check = items[KEY_CHECK]
            if (check == null || open(key, check, aad(KEY_CHECK))?.contentEquals(KEY_CHECK_PLAIN) != true) {
                items[KEY_CHECK] = seal(key, KEY_CHECK_PLAIN, aad(KEY_CHECK))
            }
            items[itemName(name)] = sealed
        } catch (_: Throwable) {
            // The key could not seal (and is not definitively gone), or a new
            // key could not be created: nothing was written.
            return KeychainReply.transient("keystore_unavailable")
        }
        return try {
            file.save(items)
            KeychainReply.ok
        } catch (e: IndeterminateWrite) {
            throw e
        } catch (_: Exception) {
            KeychainReply.transient("store_io")
        }
    }

    /** `ok` when the item is gone (or never existed). The key is kept. */
    @Synchronized
    fun delete(name: String): KeychainReply {
        val items = try {
            file.load().toMutableMap()
        } catch (_: SessionItemFile.Damaged) {
            return KeychainReply.permanent("store_damaged")
        } catch (_: Exception) {
            return KeychainReply.transient("store_io")
        }
        if (items.remove(itemName(name)) == null) return KeychainReply.ok
        return try {
            file.save(items)
            KeychainReply.ok
        } catch (e: IndeterminateWrite) {
            throw e
        } catch (_: Exception) {
            KeychainReply.transient("store_io")
        }
    }

    /** Null when the key can never seal again (a new key is needed). */
    private fun trySeal(key: SecretKey, value: String, name: String): String? = try {
        seal(key, value.toByteArray(Charsets.UTF_8), aad(name))
    } catch (f: KeyFault) {
        if (f.permanent) null else throw f
    }

    private fun seal(key: SecretKey, plain: ByteArray, aad: String): String {
        val cipher = Cipher.getInstance(TRANSFORM)
        try {
            cipher.init(Cipher.ENCRYPT_MODE, key)
        } catch (t: Throwable) {
            throw KeyFault(keys.isPermanentFault(t))
        }
        val nonce = cipher.iv ?: throw KeyFault(false)
        if (nonce.size != NONCE_BYTES) throw KeyFault(false)
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return PREFIX + Hex.encode(nonce + cipher.doFinal(plain))
    }

    /** Null when the envelope is malformed or fails authentication. */
    private fun open(key: SecretKey, envelope: String, aad: String): ByteArray? {
        if (!envelope.startsWith(PREFIX)) return null
        val bytes = Hex.decode(envelope.substring(PREFIX.length)) ?: return null
        if (bytes.size < NONCE_BYTES + TAG_BITS / 8) return null
        val cipher = Cipher.getInstance(TRANSFORM)
        try {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, bytes, 0, NONCE_BYTES))
        } catch (t: Throwable) {
            throw KeyFault(keys.isPermanentFault(t))
        }
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return try {
            cipher.doFinal(bytes, NONCE_BYTES, bytes.size - NONCE_BYTES)
        } catch (_: AEADBadTagException) {
            null
        } catch (t: Throwable) {
            throw KeyFault(keys.isPermanentFault(t))
        }
    }

    companion object {
        private const val TRANSFORM = "AES/GCM/NoPadding"
        const val PREFIX = "qsk1."
        private const val NONCE_BYTES = 12
        private const val TAG_BITS = 128
        const val KEY_CHECK = "\u0000key_check"
        private val KEY_CHECK_PLAIN = "qirsh.session.keychain.key_check.v1".toByteArray(Charsets.UTF_8)

        fun itemName(name: String) = "item:$name"
        fun aad(name: String) = "qirsh.session.keychain.v1/$name"
    }
}

/**
 * The vault key: a non-exportable Android Keystore AES-256 key, GCM only,
 * separate from the capture-queue and owner keys. No user-authentication and no
 * unlocked-device requirement (refresh and background capture run while the
 * phone is locked). Never part of a backup or a device transfer.
 */
internal object SessionKeychainKey : SessionKeySource {
    private const val KEYSTORE = "AndroidKeyStore"
    const val ALIAS = "qirsh_session_keychain_aes_v1"

    private fun store(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    @Synchronized
    override fun load(): SecretKey? {
        val store = store()
        if (!store.containsAlias(ALIAS)) return null
        return store.getKey(ALIAS, null) as? SecretKey
            ?: throw IllegalStateException("session key entry unusable")
    }

    @Synchronized
    override fun create(): SecretKey = KeyGenerator
        .getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        .apply {
            init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
        }
        .generateKey()

    override fun isPermanentFault(t: Throwable): Boolean {
        var c: Throwable? = t
        while (c != null) {
            if (c is KeyPermanentlyInvalidatedException) return true
            c = c.cause
        }
        return false
    }
}

/**
 * Status-preserving, read-only access to `flutter_secure_storage` 9.2.x items
 * written with `encryptedSharedPreferences: true` (SecureStorageOptions.android):
 * the plugin's file, master key spec and key prefix
 * (FlutterSecureStorage.java). It never creates a master key or a keyset — if
 * either is missing while the other exists, the store cannot answer (`error`).
 */
internal class PluginItemReader(private val context: Context) {
    private var prefs: android.content.SharedPreferences? = null

    fun read(key: String): KeychainReply {
        val name = "${PREFIX}_$key"
        val raw = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        // A plain-named entry is a legacy (non-EncryptedSharedPreferences) value
        // the plugin has not migrated yet: it exists, but not where we can read
        // it. Restrictive, never absent.
        if (raw.contains(name)) return KeychainReply.transient("plugin_unmigrated")
        val hasKeysets = raw.contains(KEY_KEYSET) && raw.contains(VALUE_KEYSET)
        val masterExists = try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                .containsAlias(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        } catch (_: Exception) {
            return KeychainReply.transient("keystore_unavailable")
        }
        if (!hasKeysets) {
            // Nothing has ever been written through EncryptedSharedPreferences.
            return if (!raw.contains(KEY_KEYSET) && !raw.contains(VALUE_KEYSET)) KeychainReply.absent
            else KeychainReply.permanent("plugin_keyset_partial")
        }
        if (!masterExists) return KeychainReply.permanent("plugin_master_key_lost")
        val esp = try {
            prefs ?: open().also { prefs = it }
        } catch (t: Throwable) {
            return KeychainReply.transient("plugin_store_unavailable")
        }
        return try {
            if (!esp.contains(name)) KeychainReply.absent
            else esp.getString(name, null)?.let { KeychainReply.found(it) }
                ?: KeychainReply.transient("plugin_value_unreadable")
        } catch (t: Throwable) {
            prefs = null
            KeychainReply.transient("plugin_value_unreadable")
        }
    }

    private fun open(): android.content.SharedPreferences {
        val master = MasterKey.Builder(context)
            .setKeyGenParameterSpec(
                KeyGenParameterSpec.Builder(
                    MasterKey.DEFAULT_MASTER_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setKeySize(256)
                    .build(),
            )
            .build()
        return EncryptedSharedPreferences.create(
            context,
            FILE,
            master,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    companion object {
        const val FILE = "FlutterSecureStorage"
        const val PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
        const val KEY_KEYSET = "__androidx_security_crypto_encrypted_prefs_key_keyset__"
        const val VALUE_KEYSET = "__androidx_security_crypto_encrypted_prefs_value_keyset__"
    }
}

/**
 * The channel, registered on every engine (activity and headless). One vault,
 * one plugin reader and ONE serial executor per process.
 */
internal object SessionKeychainChannel {
    const val NAME = "qirsh/session_keychain"
    const val FILE_NAME = "qirsh_session_keychain_v1.store"

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "qirsh.session_keychain").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private var vault: SessionVault? = null
    private var plugin: PluginItemReader? = null

    @Synchronized
    private fun vault(context: Context): SessionVault = vault ?: SessionVault(
        SessionItemFile(File(context.noBackupFilesDir, FILE_NAME)),
        SessionKeychainKey,
    ).also { vault = it }

    @Synchronized
    private fun plugin(context: Context): PluginItemReader =
        plugin ?: PluginItemReader(context.applicationContext).also { plugin = it }

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                // The app is not direct-boot aware, so it only runs once the
                // user's credential-encrypted storage is unlocked; asked anyway.
                "protectedDataAvailable" ->
                    result.success(app.getSystemService(UserManager::class.java)?.isUserUnlocked ?: false)
                "read", "write", "delete", "readPluginItem" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.error("bad_args", "key", null)
                        return@setMethodCallHandler
                    }
                    val value = call.argument<String>("value")
                    val method = call.method
                    executor.execute {
                        val reply: Result<KeychainReply> = runCatching {
                            when (method) {
                                "read" -> vault(app).read(key)
                                "write" -> if (value == null) KeychainReply.transient("bad_args")
                                else vault(app).write(key, value)
                                "delete" -> vault(app).delete(key)
                                else -> plugin(app).read(key)
                            }
                        }
                        main.post {
                            reply.fold(
                                onSuccess = { result.success(it.toMap()) },
                                // Outcome unknown: Dart reconciles with a read.
                                onFailure = { result.error("indeterminate", null, null) },
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
