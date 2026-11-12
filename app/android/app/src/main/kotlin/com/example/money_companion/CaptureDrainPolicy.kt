package com.youssefsafwat.mali

import java.util.UUID

/**
 * The single process-wide capture drain lease.
 *
 * Every drain of every Flutter engine in this process (the activity's engine,
 * a rebuilt one after an activity recreation) asks for it over the capture
 * channel before touching the queue; a second drain gets `null` and skips. The
 * lease expires after its TTL so an engine that died while holding it cannot
 * block the queue for longer than that. Payload idempotency (`tx.id =
 * payloadId` + receipt in one transaction) remains the backstop.
 *
 * Pure Kotlin (no Android types) so the JVM harness can execute it.
 */
object CaptureDrainLease {
    const val MIN_TTL_MS = 1_000L
    const val MAX_TTL_MS = 15 * 60_000L

    private var token: String? = null
    private var expiresAtMs = 0L

    /** A fresh token, or null while another holder's lease is unexpired. */
    @Synchronized
    fun acquire(ttlMs: Long, nowMs: Long = System.currentTimeMillis()): String? {
        if (token != null && nowMs < expiresAtMs) return null
        val next = UUID.randomUUID().toString()
        token = next
        expiresAtMs = nowMs + ttlMs.coerceIn(MIN_TTL_MS, MAX_TTL_MS)
        return next
    }

    /** Releases only the holder's own lease; a stale token changes nothing. */
    @Synchronized
    fun release(token: String): Boolean {
        if (token != this.token) return false
        this.token = null
        expiresAtMs = 0L
        return true
    }

    @Synchronized
    fun debugReset() {
        token = null
        expiresAtMs = 0L
    }
}

/**
 * How a request for a background drain maps onto the ONE unique background
 * work, so there is never more than one worker for the capture queue.
 */
object CaptureDrainSchedulePolicy {
    enum class Decision {
        /** A work that will run no later than requested is already enqueued. */
        KEEP_EXISTING,

        /** Nothing usable is enqueued (or it runs later than requested). */
        REPLACE,

        /**
         * The worker is running now: replacing it would cancel it. The request
         * is remembered and chained after it (APPEND_OR_REPLACE) when it ends.
         */
        FOLLOW_UP_AFTER_RUN,
    }

    /**
     * A recorded schedule this far in the past is not trusted to still exist
     * (the work may have run in a process that died before clearing the
     * record): re-enqueueing is harmless under the unique name.
     */
    const val STALE_AFTER_MS = 15 * 60_000L

    fun decide(
        workerRunning: Boolean,
        scheduledRunAtMs: Long?,
        requestedRunAtMs: Long,
        nowMs: Long,
    ): Decision {
        if (workerRunning) return Decision.FOLLOW_UP_AFTER_RUN
        if (scheduledRunAtMs != null &&
            scheduledRunAtMs <= requestedRunAtMs &&
            scheduledRunAtMs >= nowMs - STALE_AFTER_MS
        ) {
            return Decision.KEEP_EXISTING
        }
        return Decision.REPLACE
    }

    /**
     * Dart's outcome name -> whether the worker succeeded. `done` / `pending`
     * (Dart already asked for the next run at the right time) / `deferred`
     * (signed out, not admitted, no host engine: nothing may run here) end the
     * work; `busy` / `cancelled` / `failed` / no answer retry with the work's
     * exponential backoff.
     */
    fun succeeded(outcome: String?): Boolean =
        outcome == "done" || outcome == "pending" || outcome == "deferred"
}
