package com.youssefsafwat.mali

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import javax.crypto.Mac
import org.json.JSONArray
import org.json.JSONObject

/**
 * MALI-013 — durable, retry-safe queue for captured bank messages on Android.
 *
 * Replaces the old process-memory-only list: captured messages (shared-to-Mali
 * or, when enabled, received SMS) are persisted so they survive process death,
 * app restart, and Flutter engine recreation. A message is only removed once
 * Flutter acknowledges a successful local import (peek → import → ack), so a
 * crash mid-import re-delivers only the unacknowledged remainder.
 *
 * Storage has two tiers, drained in order:
 *   1. the MAIN segment — a JSON array in SharedPreferences, at most
 *      [CaptureQueuePolicy.MAIN_CAPACITY] items (a bounded blob, because every
 *      change rewrites it);
 *   2. the OVERFLOW — one file per capture under `files/capture_overflow/`,
 *      written atomically (temp file, fsync, rename), named by a monotonic
 *      sequence so order is preserved. It has no item bound: only the disk does.
 *
 * A legitimate capture is never discarded silently and never refused for
 * capacity:
 *   - duplicates are detected by id ONLY (two purchases with identical wording
 *     are two captures);
 *   - nothing queued is ever evicted or overwritten to make room;
 *   - an unreadable main blob or overflow file is QUARANTINED (kept verbatim
 *     under another name; readable items are salvaged), never deleted;
 *   - a write that could not be made durable (commit()==false, disk full, I/O
 *     error) is retried once, then reported as NOT_PERSISTED — never as saved;
 *   - a store that cannot be read is an ERROR for the reader
 *     ([QueueUnreadableException]), never an empty queue.
 * Failures are surfaced to Dart as counts only ([healthJson]). Raw bodies are
 * never logged.
 *
 * Account isolation (the Android counterpart of the iOS queue's owner model):
 *   - Dart publishes the admitted account as the ACTIVE OWNER; the queue keeps
 *     only an HMAC of its uid (key in the Android Keystore, [CaptureOwnerKey]),
 *     never the uid itself;
 *   - every capture is stamped at enqueue with the active owner, or is
 *     `unbound` when there is none (with the hint of the consent owner / last
 *     admitted owner, an HMAC too). Items written before this model existed
 *     carry no stamp and read as unbound WITHOUT a hint;
 *   - peek / drain / acknowledge see ONLY the active owner's stamped items.
 *     Another owner's items wait, invisible, until that owner is published
 *     again; unbound items are imported only after an explicit claim, bound
 *     `localOnly` (on-device parse only, never AI);
 *   - Remove data runs behind a persisted barrier (begin → finish) that sweeps
 *     that owner's items, main and overflow, and the unattributable
 *     quarantined residue.
 */

/** Owner-scope vocabulary and the opt-in rule, free of Android types. */
internal object CaptureOwnerPolicy {
    const val STAMPED = "stamped"
    const val UNBOUND = "unbound"

    /** iOS parity (`SharedCaptureStore.normalizedUID`). */
    fun normalize(uid: String): String = uid.trim().lowercase(Locale.ROOT)

    /** What the SMS auto-capture opt-in does when an owner is published. */
    enum class OptIn { KEEP, ADOPT, RESET }

    /**
     * The opt-in belongs to the account that turned it on. A different account
     * never inherits it (RESET). An opt-in recorded before owners existed (no
     * owner) is adopted by the first owner published WITHOUT an account change
     * in between: the upgrade of a signed-in user. An account change first
     * resets such an ownerless opt-in ([resetAtAccountChange]).
     */
    fun onOwnerPublished(optedIn: Boolean, optInOwner: String?, newOwner: String): OptIn =
        when {
            !optedIn -> OptIn.KEEP
            optInOwner == null -> OptIn.ADOPT
            optInOwner == newOwner -> OptIn.KEEP
            else -> OptIn.RESET
        }

    /** At an account transition an opt-in nobody owns is not inherited. */
    fun resetAtAccountChange(optedIn: Boolean, optInOwner: String?): Boolean =
        optedIn && optInOwner == null

    /** Visible to the drain: stamped to exactly the active owner. */
    fun visible(state: String, ownerHash: String?, activeOwner: String?): Boolean =
        activeOwner != null && state == STAMPED && ownerHash == activeOwner

    /**
     * Offered to [ownerHash] through the explicit claim: unbound and hinted to
     * it, or unbound with NO hint (pre-upgrade items, captures between an
     * account-change clear and the next publish). Never an item hinted to
     * another owner.
     */
    fun claimable(state: String, hint: String?, ownerHash: String): Boolean =
        state == UNBOUND && (hint == null || hint == ownerHash)

    /** Swept by [ownerHash]'s Remove data: stamped or hinted to it. */
    fun sweptBy(ownerHash: String?, hint: String?, removed: String): Boolean =
        ownerHash == removed || hint == removed
}

/**
 * The admission rule, free of Android types so it can be read and tested in
 * isolation.
 */
internal object CaptureQueuePolicy {
    /** Items kept in the SharedPreferences blob; the rest overflows to files. */
    const val MAIN_CAPACITY = 200

    enum class Admission { MAIN, OVERFLOW, DUPLICATE_ID }

    /**
     * Where a new capture goes. It joins the overflow as soon as the main
     * segment is full OR the overflow is non-empty, so arrival order is kept.
     */
    fun admit(
        mainIds: Collection<String>,
        overflowCount: Int,
        idInOverflow: Boolean,
        newId: String,
        mainCapacity: Int = MAIN_CAPACITY,
    ): Admission = when {
        idInOverflow || mainIds.contains(newId) -> Admission.DUPLICATE_ID
        overflowCount > 0 || mainIds.size >= mainCapacity -> Admission.OVERFLOW
        else -> Admission.MAIN
    }
}

/** The queue storage exists but cannot be read. Nothing was changed. */
class QueueUnreadableException : Exception("capture queue unreadable")

/** Owner calls refused: nothing was changed. [code] is the Dart error code. */
class CaptureOwnerException(val code: String) : Exception(code)

class DurableCaptureQueue private constructor(
    private val prefs: SharedPreferences,
    private val overflowDir: File,
) {

    companion object {
        private const val PREFS_NAME = "mali_capture_queue_v1"
        private const val OVERFLOW_DIR = "capture_overflow"
        private const val KEY_ITEMS = "items"
        /** An unreadable `items` blob is moved here verbatim, never deleted. */
        private const val QUARANTINE_PREFIX = "items_quarantine_"
        private const val FILE_SUFFIX = ".json"
        private const val TEMP_SUFFIX = ".tmp"
        /** An unreadable overflow file is renamed with this, never deleted. */
        private const val QUARANTINE_SUFFIX = ".quarantine"
        /** Overflow items returned by one peek; the rest follow on later drains. */
        private const val OVERFLOW_PEEK = 300
        // Privacy-safe counters (counts only, never content).
        private const val KEY_NOT_PERSISTED = "not_persisted_count"
        private const val KEY_QUARANTINED = "quarantined_count"
        /** Failures not yet shown to the user. */
        private const val KEY_UNSEEN = "unseen_refusal_count"
        // Owner scope. Hashes only (HMAC of the uid), never a uid.
        private const val KEY_OWNER = "active_owner_hash"
        private const val KEY_OWNER_GENERATION = "active_owner_generation"
        private const val KEY_GENERATION_COUNTER = "owner_generation_counter"
        /** Bumped by every owner clear: a publish that read an older epoch is refused. */
        private const val KEY_EPOCH = "owner_epoch"
        /** The last published owner; kept at sign-out so it can claim back. */
        private const val KEY_HINT = "last_admitted_owner_hash"
        /** The persisted Remove-data barrier (JSON: nonce, uidHash, startedAt). */
        private const val KEY_BARRIER = "removal_barrier"
        private const val TAG = "QirshCaptureQueue"

        /**
         * The HMAC that turns a uid into its owner hash. Production: a
         * non-exportable Android Keystore key ([CaptureOwnerKey]). A JVM test
         * substitutes a fixed key.
         */
        @Volatile
        internal var macFactory: () -> Mac = { CaptureOwnerKey.newMac() }

        /**
         * Called (on the caller's thread) after an item was durably stored, so a
         * live activity can tell Dart to drain. Null when no activity is alive.
         */
        @Volatile
        var onStored: (() -> Unit)? = null

        @Volatile
        private var instance: DurableCaptureQueue? = null

        fun get(context: Context): DurableCaptureQueue {
            return instance ?: synchronized(this) {
                instance ?: DurableCaptureQueue(
                    context.applicationContext
                        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
                    File(context.applicationContext.filesDir, OVERFLOW_DIR),
                ).also { instance = it }
            }
        }

        /** ISO-8601 UTC timestamp — the format the Dart parser expects
         *  (DateTime.tryParse). API-safe (no java.time). */
        fun isoNow(): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            return fmt.format(Date())
        }

        /** ISO-8601 UTC string for a specific epoch (the SMS receipt time). */
        fun isoOf(epochMs: Long): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            return fmt.format(Date(epochMs))
        }

        private fun sha256Hex(value: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        /**
         * The stable identity of one received SMS: SHA-256 over the sender, the
         * SMS's own service-centre timestamp and the full body.
         *
         * A broadcast the platform delivers twice (OEM/dual-SIM re-delivery, a
         * receiver restarted mid-delivery) carries exactly the same three
         * values, so it produces the same id and is deduplicated here by id —
         * and, once imported, by the receipt (the transaction id IS this id).
         *
         * Collision behaviour: two messages are treated as one only when sender,
         * timestamp AND every character of the body are identical. Two real
         * purchases differ in at least one of them (time, amount, balance,
         * reference) in every format seen; if a bank ever sent two byte-identical
         * alerts with the same timestamp they would be indistinguishable from a
         * re-delivery and are kept once. Anything less certain (same text at a
         * different time, or through the share sheet) gets a different id and is
         * kept as its own capture.
         */
        fun smsId(sender: String?, smsEpochMs: Long, body: String): String =
            sha256Hex("sms\u0000${sender.orEmpty()}\u0000$smsEpochMs\u0000$body")
    }

    enum class EnqueueResult {
        /** Durably committed before return. */
        STORED,
        /** The same id is already queued (idempotent replay). */
        DUPLICATE_ID,
        /** The store could not be read, or the write could not be made durable. */
        NOT_PERSISTED,
    }

    /** Process-lifetime mirror of [KEY_UNSEEN] for when prefs cannot be written. */
    @Volatile
    private var volatileUnseen = 0

    data class Item(
        val id: String,
        val text: String,
        val sender: String?,
        val source: String, // "share" | "sms"
        val receivedAt: String, // ISO-8601 UTC (legacy/display fallback)
        // MALI-068n §11 — authoritative native epoch (SMS timestampMillis / share
        // time). Dart prefers this over parsing receivedAt. 0 = legacy item.
        val receivedAtEpochMs: Long = System.currentTimeMillis(),
        // Owner scope, set by [enqueue] (callers never choose it). A stored item
        // without these fields is a pre-upgrade item: unbound, no hint.
        val ownerState: String = CaptureOwnerPolicy.UNBOUND,
        val ownerHash: String? = null,
        val ownerHint: String? = null,
        /** Bound by an explicit claim: parsed on device only, never sent to AI. */
        val localOnly: Boolean = false,
    )

    // ── encoding ──────────────────────────────────────────────────────────────

    private fun toJson(item: Item): JSONObject {
        val o = JSONObject()
        o.put("id", item.id)
        o.put("text", item.text)
        if (item.sender != null) o.put("sender", item.sender)
        o.put("source", item.source)
        o.put("receivedAt", item.receivedAt)
        o.put("receivedAtEpochMs", item.receivedAtEpochMs)
        o.put("ownerState", item.ownerState)
        if (item.ownerHash != null) o.put("ownerHash", item.ownerHash)
        if (item.ownerHint != null) o.put("ownerHint", item.ownerHint)
        if (item.localOnly) o.put("localOnly", true)
        return o
    }

    private fun fromJson(o: JSONObject): Item = Item(
        id = o.getString("id"),
        text = o.getString("text"),
        sender = if (o.isNull("sender")) null else o.optString("sender"),
        source = o.optString("source", "share"),
        receivedAt = o.optString("receivedAt", ""),
        receivedAtEpochMs = o.optLong("receivedAtEpochMs", 0L),
        // Only a complete stamp is a stamp; anything else (a pre-upgrade item
        // included) is unbound.
        ownerState = if (o.optString("ownerState") == CaptureOwnerPolicy.STAMPED &&
            o.optString("ownerHash").isNotEmpty()
        ) CaptureOwnerPolicy.STAMPED else CaptureOwnerPolicy.UNBOUND,
        ownerHash = o.optString("ownerHash").takeIf {
            it.isNotEmpty() && o.optString("ownerState") == CaptureOwnerPolicy.STAMPED
        },
        ownerHint = o.optString("ownerHint").takeIf {
            it.isNotEmpty() && o.optString("ownerState") != CaptureOwnerPolicy.STAMPED
        },
        localOnly = o.optBoolean("localOnly", false),
    )

    private fun encode(items: List<Item>): String {
        val array = JSONArray()
        items.forEach { array.put(toJson(it)) }
        return array.toString()
    }

    // ── main segment (SharedPreferences) ──────────────────────────────────────

    /**
     * Reads the main segment. Null means it is unreadable AND could not be
     * quarantined: the caller must not write, or it would overwrite the blob.
     *
     * A blob that does not parse (or holds a malformed element) is copied
     * verbatim to a quarantine key and the well-formed items are written back
     * as the live segment, in ONE commit. Nothing is deleted.
     */
    @Synchronized
    private fun readAll(): MutableList<Item>? {
        val stored: String? = try {
            prefs.getString(KEY_ITEMS, null)
        } catch (_: Throwable) {
            return null
        }
        val raw = stored ?: return mutableListOf()
        val out = ArrayList<Item>()
        var damaged = false
        try {
            val array = JSONArray(raw)
            for (i in 0 until array.length()) {
                try {
                    out.add(fromJson(array.getJSONObject(i)))
                } catch (_: Throwable) {
                    damaged = true
                }
            }
        } catch (_: Throwable) {
            damaged = true
        }
        if (!damaged) return out
        val quarantined = prefs.edit()
            .putString(QUARANTINE_PREFIX + System.currentTimeMillis(), raw)
            .putString(KEY_ITEMS, encode(out))
            .putInt(KEY_QUARANTINED, prefs.getInt(KEY_QUARANTINED, 0) + 1)
            // The quarantined part will not be imported: the user is told.
            .putInt(KEY_UNSEEN, prefs.getInt(KEY_UNSEEN, 0) + 1)
            .commit()
        volatileUnseen++
        android.util.Log.w(TAG, "unreadable queue blob quarantined=$quarantined salvaged=${out.size}")
        if (!quarantined) return null
        return out
    }

    /**
     * MALI-068n: writes are SYNCHRONOUS (`commit()`), not `apply()`. A broadcast
     * receiver / App-Intent process can be killed the instant it returns, so the
     * enqueue and the per-item acknowledge must be durably on disk before the
     * caller proceeds — otherwise a captured message is lost, or a re-delivered
     * one resurrects an already-acknowledged item. Returns whether the write was
     * durably committed.
     */
    @Synchronized
    private fun writeAll(items: List<Item>): Boolean {
        return prefs.edit().putString(KEY_ITEMS, encode(items)).commit()
    }

    // ── overflow (one atomically written file per capture) ────────────────────

    /** `<20-digit sequence>_<sha256(id)>.json`, sorted by name == arrival order. */
    private fun overflowFiles(): List<File> =
        (overflowDir.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(FILE_SUFFIX) }
            .sortedBy { it.name }

    private fun overflowFileFor(id: String): File? {
        val tail = "_" + sha256Hex(id) + FILE_SUFFIX
        return overflowFiles().firstOrNull { it.name.endsWith(tail) }
    }

    private fun nextSequence(): Long {
        val last = overflowFiles().lastOrNull()?.name?.substringBefore('_')?.toLongOrNull()
        return (last ?: 0L) + 1L
    }

    /**
     * Writes one capture to its own file: temp file → fsync → rename. Either
     * the complete file exists under its final name or nothing does; an existing
     * capture file is never opened for writing. False on ANY failure (disk
     * full, I/O error, directory not creatable).
     */
    private fun writeOverflow(item: Item): Boolean {
        return try {
            if (!overflowDir.isDirectory && !overflowDir.mkdirs()) return false
            val name = "%020d_%s".format(Locale.US, nextSequence(), sha256Hex(item.id))
            val temp = File(overflowDir, name + TEMP_SUFFIX)
            val target = File(overflowDir, name + FILE_SUFFIX)
            if (target.exists()) return false
            try {
                FileOutputStream(temp).use { stream ->
                    stream.write(toJson(item).toString().toByteArray(Charsets.UTF_8))
                    stream.flush()
                    stream.fd.sync()
                }
                temp.renameTo(target)
            } finally {
                if (temp.exists()) temp.delete() // only ever the unfinished temp
            }
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Replaces one overflow capture's content (a claim binding it): temp file →
     * fsync → rename over the same name, so the file is either the old or the
     * new complete capture. False on any failure (the old one is then intact).
     */
    private fun replaceOverflow(file: File, item: Item): Boolean {
        val temp = File(file.path + TEMP_SUFFIX)
        return try {
            FileOutputStream(temp).use { stream ->
                stream.write(toJson(item).toString().toByteArray(Charsets.UTF_8))
                stream.flush()
                stream.fd.sync()
            }
            temp.renameTo(file)
        } catch (_: Throwable) {
            false
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    /**
     * Reads one overflow file. An unreadable file is renamed (kept verbatim,
     * never deleted) so it stops blocking the queue; if it cannot even be
     * renamed the store is unreadable.
     */
    private fun readOverflow(file: File): Item? {
        return try {
            fromJson(JSONObject(file.readText(Charsets.UTF_8)))
        } catch (_: Throwable) {
            val moved = file.renameTo(File(file.path + QUARANTINE_SUFFIX))
            // The quarantined capture will not be imported: the user is told.
            volatileUnseen++
            prefs.edit()
                .putInt(KEY_QUARANTINED, prefs.getInt(KEY_QUARANTINED, 0) + 1)
                .putInt(KEY_UNSEEN, prefs.getInt(KEY_UNSEEN, 0) + 1)
                .commit()
            android.util.Log.w(TAG, "unreadable overflow file quarantined=$moved")
            if (!moved) throw QueueUnreadableException()
            null
        }
    }

    // ── public API ────────────────────────────────────────────────────────────

    /**
     * Idempotent enqueue: a duplicate id is ignored. Returns [EnqueueResult.STORED]
     * only when the new item was durably persisted before return. Capacity never
     * refuses a capture: beyond the main segment it goes to its own overflow
     * file. Nothing already queued is removed or rewritten to make room.
     */
    @Synchronized
    fun enqueue(item: Item): EnqueueResult {
        // Owner scope, stamped under this lock so an owner change cannot
        // interleave. The caller's [Item.ownerHint] is only a suggestion (the
        // SMS receiver passes the opt-in owner) used when nobody is active.
        // During a Remove-data barrier nothing is persisted (iOS parity): the
        // capture is counted and the user told, never stored for a
        // half-removed owner.
        val stamped = try {
            if (prefs.getString(KEY_BARRIER, null) != null) return notPersisted()
            val owner = prefs.getString(KEY_OWNER, null)
            if (owner != null) {
                item.copy(
                    ownerState = CaptureOwnerPolicy.STAMPED,
                    ownerHash = owner,
                    ownerHint = null,
                    localOnly = false,
                )
            } else {
                item.copy(
                    ownerState = CaptureOwnerPolicy.UNBOUND,
                    ownerHash = null,
                    ownerHint = item.ownerHint ?: prefs.getString(KEY_HINT, null),
                    localOnly = false,
                )
            }
        } catch (_: Throwable) {
            return notPersisted()
        }
        val items = readAll() ?: return notPersisted()
        val admission = try {
            CaptureQueuePolicy.admit(
                mainIds = items.map { it.id },
                overflowCount = overflowFiles().size,
                idInOverflow = overflowFileFor(stamped.id) != null,
                newId = stamped.id,
            )
        } catch (_: Throwable) {
            return notPersisted()
        }
        val stored = when (admission) {
            CaptureQueuePolicy.Admission.DUPLICATE_ID -> return EnqueueResult.DUPLICATE_ID
            CaptureQueuePolicy.Admission.MAIN -> {
                items.add(stamped)
                // commit() can fail transiently (disk pressure): one immediate retry.
                writeAll(items) || writeAll(items)
            }
            CaptureQueuePolicy.Admission.OVERFLOW ->
                writeOverflow(stamped) || writeOverflow(stamped)
        }
        if (!stored) return notPersisted()
        onStored?.invoke()
        return EnqueueResult.STORED
    }

    /** Counts a capture that could not be stored (count only — never the message). */
    private fun notPersisted(): EnqueueResult {
        volatileUnseen++
        val counted = try {
            prefs.edit()
                .putInt(KEY_NOT_PERSISTED, prefs.getInt(KEY_NOT_PERSISTED, 0) + 1)
                .putInt(KEY_UNSEEN, prefs.getInt(KEY_UNSEEN, 0) + 1)
                .commit()
        } catch (_: Throwable) {
            false
        }
        android.util.Log.w(TAG, "capture not stored counted=$counted")
        return EnqueueResult.NOT_PERSISTED
    }

    /**
     * Counts only, for Dart diagnostics and the "a message could not be saved"
     * notice: queued items (main + overflow; -1 when unreadable), failed
     * writes, quarantined blobs/files, and the failures the user has not been
     * told about yet.
     */
    @Synchronized
    fun healthJson(): String {
        val o = JSONObject()
        val main = readAll()?.size
        val overflow = try { overflowFiles().size } catch (_: Throwable) { 0 }
        o.put("size", if (main == null) -1 else main + overflow)
        o.put("capacity", CaptureQueuePolicy.MAIN_CAPACITY)
        o.put("overflow", overflow)
        o.put("refusedFull", 0) // capacity never refuses a capture any more
        o.put("notPersisted", prefs.getInt(KEY_NOT_PERSISTED, 0))
        o.put("quarantined", prefs.getInt(KEY_QUARANTINED, 0))
        o.put("unseen", maxOf(prefs.getInt(KEY_UNSEEN, 0), volatileUnseen))
        return o.toString()
    }

    /** The user was told about the failures counted so far. */
    @Synchronized
    fun acknowledgeNotice(): Boolean {
        volatileUnseen = 0
        return prefs.edit().remove(KEY_UNSEEN).commit()
    }

    /**
     * The ACTIVE owner's stamped items: main, then up to [OVERFLOW_PEEK]
     * overflow items, in arrival order. Another owner's items and unbound items
     * are never returned; with no active owner nothing is.
     */
    private fun peekItems(): Pair<List<Item>, List<File>> {
        val main = readAll() ?: throw QueueUnreadableException()
        val owner = try {
            prefs.getString(KEY_OWNER, null)
        } catch (_: Throwable) {
            throw QueueUnreadableException()
        } ?: return emptyList<Item>() to emptyList()
        fun mine(item: Item) = CaptureOwnerPolicy.visible(item.ownerState, item.ownerHash, owner)
        val out = ArrayList<Item>(main.filter(::mine))
        val files = ArrayList<File>()
        for (file in overflowFiles()) {
            if (files.size >= OVERFLOW_PEEK) break
            val item = readOverflow(file) ?: continue
            if (!mine(item)) continue
            out.add(item)
            files.add(file)
        }
        return out to files
    }

    /**
     * Non-destructive read of the queue as a JSON array (null if empty).
     * Throws [QueueUnreadableException] when the storage cannot be read: the
     * caller must report an error, not an empty queue.
     */
    @Synchronized
    fun peekJson(): String? {
        val items = peekItems().first
        if (items.isEmpty()) return null
        return encode(items)
    }

    /**
     * Destructive drain — returns the queue as JSON and removes exactly what it
     * returned. Only for the legacy `consumePendingSharedMessages` compat path;
     * the durable path is peek + per-item acknowledge.
     */
    @Synchronized
    fun drainJson(): String? {
        val (items, files) = peekItems()
        if (items.isEmpty()) return null
        val returned = items.map { it.id }.toSet()
        val main = readAll() ?: throw QueueUnreadableException()
        // Only what was returned (the active owner's) leaves; the rest stays.
        if (!writeAll(main.filterNot { it.id in returned })) throw QueueUnreadableException()
        files.forEach { it.delete() }
        return encode(items)
    }

    /**
     * Remove exactly the acknowledged id. Returns true only when the removal was
     * durably committed, so a kill after ack never resurrects the item.
     */
    @Synchronized
    fun acknowledge(id: String): Boolean {
        val items = readAll() ?: return false
        val owner = try { prefs.getString(KEY_OWNER, null) } catch (_: Throwable) { null }
            ?: return false
        fun mine(item: Item) = CaptureOwnerPolicy.visible(item.ownerState, item.ownerHash, owner)
        // Only an item the active owner can see can be acknowledged by it.
        if (items.any { it.id == id && mine(it) }) {
            items.removeAll { it.id == id }
            return writeAll(items)
        }
        if (items.any { it.id == id }) return false
        val file = try { overflowFileFor(id) } catch (_: Throwable) { null } ?: return false
        val item = try { readOverflow(file) } catch (_: Throwable) { null } ?: return false
        if (!mine(item)) return false
        return file.delete()
    }

    /**
     * MALI-054n: purge ALL queued capture payloads so a previous account's bank
     * messages can never be imported under a new identity. Uses commit()
     * (synchronous + verified) rather than apply(), because the purge runs on a
     * destructive user-lifecycle boundary whose success the caller must be able
     * to confirm before admitting a new user. Returns true on verified removal.
     * Overflow files, quarantined blobs/files and the counters belong to the
     * same identity and go with it.
     */
    @Synchronized
    fun purge(): Boolean {
        volatileUnseen = 0
        // The owner, hint and barrier go too; the epoch only moves forward, so a
        // publish that read it before this purge is refused.
        val epoch = try { prefs.getInt(KEY_EPOCH, 0) } catch (_: Throwable) { 0 }
        val prefsCleared = prefs.edit().clear().commit() &&
            prefs.edit().putInt(KEY_EPOCH, epoch + 1).commit()
        var filesCleared = true
        (overflowDir.listFiles() ?: emptyArray()).forEach {
            if (!it.delete()) filesCleared = false
        }
        return prefsCleared && filesCleared
    }

    // ── owner scope (account isolation) ──────────────────────────────────────

    data class OwnerRecord(val uidHash: String, val generation: Int)

    data class RemovalBarrier(val nonce: String, val uidHash: String, val startedAt: String) {
        fun toMap(): Map<String, Any> =
            mapOf("nonce" to nonce, "uidHash" to uidHash, "startedAt" to startedAt)
    }

    enum class ClaimStatus { APPLIED, STALE, OWNER_MISMATCH }

    data class ClaimOutcome(val status: ClaimStatus, val count: Int)

    data class UnboundSummary(val ids: List<String>, val senders: List<String>)

    /** HMAC-SHA256 of the normalized uid, hex. Throws when the key is unavailable. */
    fun hashOf(uid: String): String {
        val normalized = CaptureOwnerPolicy.normalize(uid)
        if (normalized.isEmpty()) throw CaptureOwnerException("owner_changed")
        val mac = try {
            macFactory()
        } catch (_: Throwable) {
            throw CaptureOwnerException("queue_unavailable")
        }
        return mac.doFinal(normalized.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun commitOrThrow(editor: SharedPreferences.Editor) {
        val ok = try { editor.commit() } catch (_: Throwable) { false }
        if (!ok) throw CaptureOwnerException("queue_unavailable")
    }

    /** Bumped by every owner clear; Dart reads it BEFORE a publish. */
    @Synchronized
    fun ownerEpoch(): Int = prefs.getInt(KEY_EPOCH, 0)

    /** The active owner's hash, or null when nobody is published. */
    @Synchronized
    fun activeOwnerHash(): String? = prefs.getString(KEY_OWNER, null)

    /**
     * Publishes [uid] as the active owner. Compare-and-swap on [expectedEpoch]
     * (a clear since Dart read it refuses: `owner_changed`); refused during a
     * Remove-data barrier (`removal_in_progress`). Re-publishing the current
     * owner keeps its generation. Writes the owner, generation and hint in one
     * commit.
     */
    @Synchronized
    fun publishOwner(uid: String, expectedEpoch: Int): OwnerRecord {
        if (readBarrier() != null) throw CaptureOwnerException("removal_in_progress")
        if (prefs.getInt(KEY_EPOCH, 0) != expectedEpoch) throw CaptureOwnerException("owner_changed")
        val hash = hashOf(uid)
        if (prefs.getString(KEY_OWNER, null) == hash) {
            if (prefs.getString(KEY_HINT, null) != hash) {
                commitOrThrow(prefs.edit().putString(KEY_HINT, hash))
            }
            return OwnerRecord(hash, prefs.getInt(KEY_OWNER_GENERATION, 0))
        }
        val generation = prefs.getInt(KEY_GENERATION_COUNTER, 0) + 1
        commitOrThrow(
            prefs.edit()
                .putString(KEY_OWNER, hash)
                .putInt(KEY_OWNER_GENERATION, generation)
                .putInt(KEY_GENERATION_COUNTER, generation)
                .putString(KEY_HINT, hash),
        )
        return OwnerRecord(hash, generation)
    }

    /** The active owner record iff it is [uid]'s; null otherwise. */
    @Synchronized
    fun ownerFor(uid: String): OwnerRecord? {
        val hash = hashOf(uid)
        if (prefs.getString(KEY_OWNER, null) != hash) return null
        return OwnerRecord(hash, prefs.getInt(KEY_OWNER_GENERATION, 0))
    }

    /**
     * Sign-out ([clearHint] false: the hint stays so the same account can claim
     * what arrives meanwhile) or an account transition ([clearHint] true).
     * Nothing queued is deleted: the owner's items wait for it.
     */
    @Synchronized
    fun clearOwner(clearHint: Boolean) {
        val editor = prefs.edit()
            .remove(KEY_OWNER)
            .remove(KEY_OWNER_GENERATION)
            .putInt(KEY_EPOCH, prefs.getInt(KEY_EPOCH, 0) + 1)
        if (clearHint) editor.remove(KEY_HINT)
        commitOrThrow(editor)
    }

    /** Every queued item with its overflow file (null = main segment). */
    private fun allEntries(): Pair<MutableList<Item>, List<Pair<File, Item>>> {
        val main = readAll() ?: throw QueueUnreadableException()
        val overflow = ArrayList<Pair<File, Item>>()
        for (file in overflowFiles()) {
            val item = readOverflow(file) ?: continue
            overflow.add(file to item)
        }
        return main to overflow
    }

    /** The items [uid] may claim: ids (the CAS snapshot) and distinct senders. */
    @Synchronized
    fun unboundSummary(uid: String): UnboundSummary {
        val hash = hashOf(uid)
        val (main, overflow) = allEntries()
        val mine = (main + overflow.map { it.second })
            .filter { CaptureOwnerPolicy.claimable(it.ownerState, it.ownerHint, hash) }
        return UnboundSummary(
            ids = mine.map { it.id },
            senders = mine.mapNotNull { it.sender }.distinct().sorted(),
        )
    }

    /**
     * "Add them to my account" ([discard] false) / "Discard them" ([discard]
     * true): applied iff [uid], [replicaOwnerUid] and [sessionUid] agree, the
     * active owner is exactly `{hash(uid), generation}`, and EVERY id is still
     * claimable by it. Otherwise nothing changes. Added items are bound
     * `localOnly` (on device only, never AI).
     */
    @Synchronized
    fun claimUnbound(
        uid: String,
        generation: Int,
        replicaOwnerUid: String,
        sessionUid: String,
        ids: List<String>,
        discard: Boolean,
    ): ClaimOutcome {
        if (readBarrier() != null) throw CaptureOwnerException("removal_in_progress")
        val target = CaptureOwnerPolicy.normalize(uid)
        if (CaptureOwnerPolicy.normalize(replicaOwnerUid) != target ||
            CaptureOwnerPolicy.normalize(sessionUid) != target
        ) {
            return ClaimOutcome(ClaimStatus.OWNER_MISMATCH, 0)
        }
        val hash = hashOf(target)
        if (prefs.getString(KEY_OWNER, null) != hash ||
            prefs.getInt(KEY_OWNER_GENERATION, 0) != generation
        ) {
            return ClaimOutcome(ClaimStatus.OWNER_MISMATCH, 0)
        }
        val wanted = ids.toSet()
        val (main, overflow) = allEntries()
        val hitsMain = main.filter { it.id in wanted }
        val hitsOverflow = overflow.filter { it.second.id in wanted }
        val all = hitsMain + hitsOverflow.map { it.second }
        if (wanted.isEmpty() || all.size != wanted.size ||
            !all.all { CaptureOwnerPolicy.claimable(it.ownerState, it.ownerHint, hash) }
        ) {
            return ClaimOutcome(ClaimStatus.STALE, 0)
        }
        fun bound(item: Item) = item.copy(
            ownerState = CaptureOwnerPolicy.STAMPED,
            ownerHash = hash,
            ownerHint = null,
            localOnly = true,
        )
        for ((file, item) in hitsOverflow) {
            val ok = if (discard) file.delete() else replaceOverflow(file, bound(item))
            if (!ok) throw CaptureOwnerException("queue_unavailable")
        }
        if (hitsMain.isNotEmpty()) {
            val next = if (discard) {
                main.filterNot { it.id in wanted }
            } else {
                main.map { if (it.id in wanted) bound(it) else it }
            }
            if (!writeAll(next)) throw CaptureOwnerException("queue_unavailable")
        }
        return ClaimOutcome(ClaimStatus.APPLIED, all.size)
    }

    /** The barrier in force; malformed is an error (fail closed), never absent. */
    private fun readBarrier(): RemovalBarrier? {
        val raw = try {
            prefs.getString(KEY_BARRIER, null)
        } catch (_: Throwable) {
            throw CaptureOwnerException("queue_unavailable")
        } ?: return null
        return try {
            val o = JSONObject(raw)
            RemovalBarrier(o.getString("nonce"), o.getString("uidHash"), o.getString("startedAt"))
        } catch (_: Throwable) {
            throw CaptureOwnerException("barrier_malformed")
        }
    }

    /** The barrier left by a removal that did not finish, or null. */
    @Synchronized
    fun removalBarrier(): RemovalBarrier? = readBarrier()

    /**
     * Remove data, step 1: persists the barrier (from now on nothing is
     * enqueued, published or claimed) and clears the owner if it is [uid]'s, in
     * ONE commit. Idempotent for the same uid (a resumed removal).
     */
    @Synchronized
    fun beginRemoval(uid: String): RemovalBarrier {
        val hash = hashOf(uid)
        val existing = readBarrier()
        if (existing != null && existing.uidHash != hash) {
            throw CaptureOwnerException("removal_in_progress")
        }
        val barrier = existing ?: RemovalBarrier(
            nonce = UUID.randomUUID().toString().lowercase(Locale.ROOT),
            uidHash = hash,
            startedAt = isoNow(),
        )
        val editor = prefs.edit().putString(
            KEY_BARRIER,
            JSONObject(barrier.toMap()).toString(),
        )
        if (prefs.getString(KEY_OWNER, null) == hash) {
            editor.remove(KEY_OWNER)
                .remove(KEY_OWNER_GENERATION)
                .putInt(KEY_EPOCH, prefs.getInt(KEY_EPOCH, 0) + 1)
        }
        commitOrThrow(editor)
        return barrier
    }

    /**
     * Remove data, final sweep: deletes every item stamped or hinted to [uid]
     * (main + overflow), every quarantined blob/file and unfinished temp file
     * (unreadable, so unattributable: they may hold this owner's messages and
     * can never be imported by anyone), the hint and owner if they are [uid]'s,
     * VERIFIES nothing of [uid] remains, and only then clears the barrier.
     * Anything left throws `removal_incomplete` with the barrier KEPT, so the
     * next launch resumes. Returns the number of captures deleted.
     */
    @Synchronized
    fun finishRemoval(uid: String): Int {
        val barrier = readBarrier() ?: return 0
        val hash = hashOf(uid)
        if (barrier.uidHash != hash) throw CaptureOwnerException("removal_in_progress")
        val main = readAll() ?: throw CaptureOwnerException("removal_incomplete")
        var removed = 0
        var failed = false
        for (file in overflowFiles()) {
            val item = try {
                readOverflow(file)
            } catch (_: Throwable) {
                failed = true
                null
            } ?: continue
            if (CaptureOwnerPolicy.sweptBy(item.ownerHash, item.ownerHint, hash)) {
                if (file.delete()) removed++ else failed = true
            }
        }
        // Quarantined (unreadable) files and leftover temp files: unattributable.
        for (file in overflowDir.listFiles() ?: emptyArray()) {
            val name = file.name
            if (name.endsWith(QUARANTINE_SUFFIX) || name.endsWith(TEMP_SUFFIX)) {
                if (!file.delete()) failed = true
            }
        }
        val keep = main.filterNot { CaptureOwnerPolicy.sweptBy(it.ownerHash, it.ownerHint, hash) }
        removed += main.size - keep.size
        val editor = prefs.edit().putString(KEY_ITEMS, encode(keep))
        val quarantineKeys = try {
            prefs.all.keys.filter { it.startsWith(QUARANTINE_PREFIX) }
        } catch (_: Throwable) {
            failed = true
            emptyList()
        }
        quarantineKeys.forEach { editor.remove(it) }
        if (prefs.getString(KEY_HINT, null) == hash) editor.remove(KEY_HINT)
        if (prefs.getString(KEY_OWNER, null) == hash) {
            editor.remove(KEY_OWNER)
                .remove(KEY_OWNER_GENERATION)
                .putInt(KEY_EPOCH, prefs.getInt(KEY_EPOCH, 0) + 1)
        }
        val committed = try { editor.commit() } catch (_: Throwable) { false }
        if (!committed || failed || remainsFor(hash)) {
            android.util.Log.w(TAG, "removal sweep incomplete committed=$committed")
            throw CaptureOwnerException("removal_incomplete")
        }
        commitOrThrow(prefs.edit().remove(KEY_BARRIER))
        return removed
    }

    /** Verification read: anything of [hash], or any quarantined residue, left. */
    private fun remainsFor(hash: String): Boolean {
        val main = readAll() ?: return true
        if (main.any { CaptureOwnerPolicy.sweptBy(it.ownerHash, it.ownerHint, hash) }) return true
        val files = overflowDir.listFiles() ?: emptyArray()
        for (file in files) {
            val name = file.name
            if (name.endsWith(QUARANTINE_SUFFIX) || name.endsWith(TEMP_SUFFIX)) return true
            if (!file.isFile || !name.endsWith(FILE_SUFFIX)) continue
            val item = try {
                fromJson(JSONObject(file.readText(Charsets.UTF_8)))
            } catch (_: Throwable) {
                return true
            }
            if (CaptureOwnerPolicy.sweptBy(item.ownerHash, item.ownerHint, hash)) return true
        }
        val quarantined = try {
            prefs.all.keys.any { it.startsWith(QUARANTINE_PREFIX) }
        } catch (_: Throwable) {
            true
        }
        return quarantined || prefs.getString(KEY_HINT, null) == hash ||
            prefs.getString(KEY_OWNER, null) == hash
    }

    @Synchronized
    fun size(): Int =
        (readAll()?.size ?: 0) + (try { overflowFiles().size } catch (_: Throwable) { 0 })
}
