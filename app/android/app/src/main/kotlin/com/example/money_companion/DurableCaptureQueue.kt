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
 */

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
        private const val TAG = "QirshCaptureQueue"

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
        return o
    }

    private fun fromJson(o: JSONObject): Item = Item(
        id = o.getString("id"),
        text = o.getString("text"),
        sender = if (o.isNull("sender")) null else o.optString("sender"),
        source = o.optString("source", "share"),
        receivedAt = o.optString("receivedAt", ""),
        receivedAtEpochMs = o.optLong("receivedAtEpochMs", 0L),
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
        val items = readAll() ?: return notPersisted()
        val admission = try {
            CaptureQueuePolicy.admit(
                mainIds = items.map { it.id },
                overflowCount = overflowFiles().size,
                idInOverflow = overflowFileFor(item.id) != null,
                newId = item.id,
            )
        } catch (_: Throwable) {
            return notPersisted()
        }
        val stored = when (admission) {
            CaptureQueuePolicy.Admission.DUPLICATE_ID -> return EnqueueResult.DUPLICATE_ID
            CaptureQueuePolicy.Admission.MAIN -> {
                items.add(item)
                // commit() can fail transiently (disk pressure): one immediate retry.
                writeAll(items) || writeAll(items)
            }
            CaptureQueuePolicy.Admission.OVERFLOW ->
                writeOverflow(item) || writeOverflow(item)
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

    /** Main items, then up to [OVERFLOW_PEEK] overflow items, in arrival order. */
    private fun peekItems(): Pair<List<Item>, List<File>> {
        val main = readAll() ?: throw QueueUnreadableException()
        val out = ArrayList<Item>(main)
        val files = ArrayList<File>()
        for (file in overflowFiles()) {
            if (files.size >= OVERFLOW_PEEK) break
            val item = readOverflow(file) ?: continue
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
        if (!prefs.edit().remove(KEY_ITEMS).commit()) throw QueueUnreadableException()
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
        if (items.removeAll { it.id == id }) return writeAll(items)
        val file = try { overflowFileFor(id) } catch (_: Throwable) { null } ?: return false
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
        val prefsCleared = prefs.edit().clear().commit()
        var filesCleared = true
        (overflowDir.listFiles() ?: emptyArray()).forEach {
            if (!it.delete()) filesCleared = false
        }
        return prefsCleared && filesCleared
    }

    @Synchronized
    fun size(): Int =
        (readAll()?.size ?: 0) + (try { overflowFiles().size } catch (_: Throwable) { 0 })
}
