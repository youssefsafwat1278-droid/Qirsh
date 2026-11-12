package com.youssefsafwat.mali

import java.io.File
import java.nio.file.Files
import java.security.KeyStoreException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The REAL [SessionVault] / [SessionItemFile] against the JVM's AES/GCM and a
 * temp directory. The Android Keystore is replaced by [TestKeys], which can
 * lose, invalidate or swap its key, or stop answering. Synthetic values only.
 */
class SessionVaultTest {
    private class PermanentFault : Exception("permanently invalidated")

    /** A key whose every use fails like a permanently invalidated Keystore key. */
    private class InvalidatedKey : SecretKey {
        override fun getAlgorithm() = "AES"
        override fun getFormat() = "RAW"
        override fun getEncoded(): ByteArray = throw PermanentFault()
    }

    private class TestKeys : SessionKeySource {
        var key: SecretKey? = null
        var answering = true
        var invalidated = false
        var creates = 0

        override fun load(): SecretKey? {
            if (!answering) throw KeyStoreException("not answering")
            val k = key ?: return null
            return if (invalidated) InvalidatedKey() else k
        }

        override fun create(): SecretKey {
            if (!answering) throw KeyStoreException("not answering")
            creates++
            invalidated = false
            return newKey().also { key = it }
        }

        override fun isPermanentFault(t: Throwable): Boolean {
            var c: Throwable? = t
            while (c != null) {
                if (c is PermanentFault) return true
                c = c.cause
            }
            return false
        }
    }

    companion object {
        fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        const val ITEM = "qirsh.session.v2.ns-synthetic"
        const val OTHER = "qirsh.session.v2.ns-other"
        const val SESSION_A = """{"owner":"11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa","refresh_token":"synthetic-refresh-A"}"""
        const val SESSION_B = """{"owner":"22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb","refresh_token":"synthetic-refresh-B"}"""
        const val TOMBSTONE = """{"kind":"tombstone","seq":7}"""
    }

    private lateinit var dir: File
    private lateinit var file: File
    private lateinit var keys: TestKeys

    private fun vault() = SessionVault(SessionItemFile(file), keys)

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("qsk").toFile()
        file = File(dir, "qirsh_session_keychain_v1.store")
        keys = TestKeys()
    }

    private fun assertPermanent(r: KeychainReply, code: String) {
        assertEquals("error", r.status)
        assertTrue("permanent expected for $code", r.permanent)
        assertEquals(code, r.code)
        assertNull(r.value)
    }

    private fun assertTransient(r: KeychainReply) {
        assertEquals("error", r.status)
        assertFalse(r.permanent)
        assertNull(r.value)
    }

    // ---- persistence, logout, account switch, deletion ----

    @Test fun neverWrittenIsAbsent() {
        assertEquals("absent", vault().read(ITEM).status)
        assertEquals(0, keys.creates)
    }

    @Test fun writeSurvivesProcessRestart() {
        assertEquals("ok", vault().write(ITEM, SESSION_A).status)
        val again = vault().read(ITEM) // a new vault over the same file and key
        assertEquals("found", again.status)
        assertEquals(SESSION_A, again.value)
    }

    @Test fun accountSwitchAndLogoutOverwrite() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        v.write(ITEM, SESSION_B)
        assertEquals(SESSION_B, v.read(ITEM).value)
        v.write(ITEM, TOMBSTONE)
        assertEquals(TOMBSTONE, vault().read(ITEM).value)
        assertEquals(1, keys.creates)
    }

    @Test fun itemsAreIndependent() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        v.write(OTHER, SESSION_B)
        assertEquals(SESSION_A, v.read(ITEM).value)
        assertEquals(SESSION_B, v.read(OTHER).value)
    }

    @Test fun deleteRemovesOnlyThatItem() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        v.write(OTHER, SESSION_B)
        assertEquals("ok", v.delete(ITEM).status)
        assertEquals("absent", vault().read(ITEM).status)
        assertEquals(SESSION_B, vault().read(OTHER).value)
        assertEquals("ok", v.delete(ITEM).status) // already gone
    }

    // ---- at rest ----

    @Test fun noPlaintextAtRest() {
        vault().write(ITEM, SESSION_A)
        val raw = file.readText()
        assertFalse(raw.contains("synthetic-refresh-A"))
        assertFalse(raw.contains("11111111-aaaa"))
        assertFalse(raw.contains("refresh_token"))
        assertFalse(File(dir, file.name + ".tmp").exists())
    }

    @Test fun sealIsRandomizedPerWrite() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        val first = file.readText()
        v.write(ITEM, SESSION_A)
        assertTrue(first != file.readText())
    }

    @Test fun envelopeMovedToAnotherItemFailsAuthentication() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        v.write(OTHER, SESSION_B)
        val lines = file.readLines().toMutableList()
        val a = Hex.encode(SessionVault.itemName(ITEM).toByteArray())
        val b = Hex.encode(SessionVault.itemName(OTHER).toByteArray())
        val ia = lines.indexOfFirst { it.startsWith("$a ") }
        val ib = lines.indexOfFirst { it.startsWith("$b ") }
        val envA = lines[ia].substringAfter(' ')
        lines[ib] = "$b $envA"
        file.writeText(lines.joinToString("\n", postfix = "\n"))
        assertPermanent(vault().read(OTHER), "item_damaged")
        assertEquals(SESSION_A, vault().read(ITEM).value)
    }

    @Test fun tamperedItemWithGoodKeyIsDamaged() {
        vault().write(ITEM, SESSION_A)
        val a = Hex.encode(SessionVault.itemName(ITEM).toByteArray())
        val lines = file.readLines().map {
            if (it.startsWith("$a ")) it.dropLast(2) + (if (it.endsWith("00")) "11" else "00") else it
        }
        file.writeText(lines.joinToString("\n", postfix = "\n"))
        assertPermanent(vault().read(ITEM), "item_damaged")
    }

    // ---- unavailable / invalidated keys ----

    @Test fun keyLostIsPermanentAndAWriteRecovers() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        v.write(OTHER, SESSION_B)
        keys.key = null // e.g. Keystore wiped while the file survived
        assertPermanent(v.read(ITEM), "key_lost")
        // An explicit sign-in writes a new record under a NEW key.
        assertEquals("ok", v.write(ITEM, SESSION_B).status)
        assertEquals(2, keys.creates)
        assertEquals(SESSION_B, vault().read(ITEM).value)
        // The other item was sealed with the lost key: still never readable,
        // still not reported absent.
        val other = vault().read(OTHER)
        assertEquals("error", other.status)
        assertTrue(other.permanent)
    }

    @Test fun invalidatedKeyIsPermanentAndAWriteRecovers() {
        val v = vault()
        v.write(ITEM, SESSION_A)
        keys.invalidated = true
        assertPermanent(v.read(ITEM), "key_invalidated")
        assertEquals("ok", v.write(ITEM, SESSION_B).status)
        assertEquals(SESSION_B, v.read(ITEM).value)
    }

    @Test fun swappedKeyIsAMismatchNotDamage() {
        vault().write(ITEM, SESSION_A)
        keys.key = newKey()
        assertPermanent(vault().read(ITEM), "key_mismatch")
    }

    @Test fun unansweringKeystoreIsTransientAndWritesNothing() {
        vault().write(ITEM, SESSION_A)
        val before = file.readText()
        keys.answering = false
        assertTransient(vault().read(ITEM))
        assertTransient(vault().write(ITEM, SESSION_B))
        assertEquals(before, file.readText())
        keys.answering = true
        assertEquals(SESSION_A, vault().read(ITEM).value)
    }

    @Test fun unansweringKeystoreNeverMintsAKey() {
        keys.answering = false
        assertTransient(vault().write(ITEM, SESSION_A))
        assertEquals(0, keys.creates)
        assertFalse(file.exists())
    }

    // ---- damaged / unreadable store ----

    @Test fun damagedStoreIsPermanentNeverAbsent() {
        vault().write(ITEM, SESSION_A)
        file.writeText("garbage\n")
        assertPermanent(vault().read(ITEM), "store_damaged")
        assertPermanent(vault().delete(ITEM), "store_damaged")
        assertEquals("garbage\n", file.readText()) // read/delete leave it as is
        assertEquals("ok", vault().write(ITEM, SESSION_B).status)
        assertEquals(SESSION_B, vault().read(ITEM).value)
    }

    @Test fun unreadableStoreIsTransient() {
        file.mkdirs() // a directory where the file should be: reads fail with I/O
        assertTransient(vault().read(ITEM))
        assertTransient(vault().write(ITEM, SESSION_A))
    }

    // ---- reply shape (what Dart parses) ----

    @Test fun replyMapShape() {
        assertEquals(mapOf("status" to "found", "code" to "found", "value" to "v"), KeychainReply.found("v").toMap())
        assertEquals(mapOf("status" to "absent", "code" to "absent"), KeychainReply.absent.toMap())
        assertEquals(
            mapOf("status" to "error", "code" to "key_lost", "permanent" to true),
            KeychainReply.permanent("key_lost").toMap(),
        )
        assertEquals(mapOf("status" to "error", "code" to "store_io"), KeychainReply.transient("store_io").toMap())
    }

    @Test fun hexRoundTrip() {
        val b = ByteArray(256) { it.toByte() }
        assertTrue(b.contentEquals(Hex.decode(Hex.encode(b))))
        assertNull(Hex.decode("abc"))
        assertNull(Hex.decode("zz"))
    }
}
