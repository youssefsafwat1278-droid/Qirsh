package com.youssefsafwat.mali

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.util.UUID

/**
 * MALI-013 — optional automatic bank-SMS capture (opt-in).
 *
 * RECEIVE_SMS is declared UNCONDITIONALLY in AndroidManifest.xml. This comment
 * used to claim the declaration sat behind a build-level manifest placeholder so
 * a share-only build could omit it; no such placeholder exists — build.gradle.kts
 * defines only `admobAppId`. That was a comment describing a safety mechanism
 * that was never built, which is worse than no comment: it invites someone to
 * believe a Play-safe variant is one Gradle property away. If a share-only
 * variant is ever needed, it has to be BUILT (a placeholder on the
 * <uses-permission> node plus a receiver `tools:node="remove"`), not flipped.
 *
 * Even when the permission is granted, capture stays OFF until the user
 * explicitly enables it (CaptureSettings.autoCaptureEnabled) — permission alone
 * never starts reading, and `onReceive` below returns before touching the intent
 * unless that opt-in is true.
 *
 * Received messages are pre-filtered locally to plausible financial/bank
 * messages and routed through the SAME DurableCaptureQueue as share capture, so
 * everything downstream (parser, dedup, atomic local import, peek/ack) is
 * identical. Unrelated SMS are dropped here and never stored or uploaded. Raw
 * bodies are never logged.
 */
class SmsCaptureReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // Gate: user opt-in required; a granted permission is not consent to read.
        if (!CaptureSettings.isAutoCaptureEnabled(context)) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        // Multipart SMS arrive as several parts of one logical message.
        val body = StringBuilder()
        var sender: String? = null
        for (part in messages) {
            body.append(part.messageBody ?: "")
            if (sender == null) sender = part.originatingAddress
        }
        val text = body.toString().trim()
        // Privacy prefilter — unrelated SMS are dropped here and never stored.
        if (text.isEmpty() || !shouldRetain(text, sender)) return

        // MALI-068n §11 — the SMS's own receipt epoch is authoritative, not the
        // (possibly later) time this receiver runs. Fall back to now only if the
        // platform did not supply one.
        val platformEpochMs = messages.firstOrNull()?.timestampMillis?.takeIf { it > 0 }
        val smsEpochMs = platformEpochMs ?: System.currentTimeMillis()
        val cleanSender = sender?.trim()?.takeIf { it.isNotEmpty() }
        // A stable id (sender + the SMS's own timestamp + body) so a broadcast
        // the platform delivers twice is ONE capture. Without a platform
        // timestamp there is no stable identity: a random id keeps it distinct.
        val id = if (platformEpochMs != null) {
            DurableCaptureQueue.smsId(cleanSender, platformEpochMs, text)
        } else {
            UUID.randomUUID().toString()
        }

        val result = DurableCaptureQueue.get(context).enqueue(
            DurableCaptureQueue.Item(
                id = id,
                text = text,
                sender = cleanSender,
                source = "sms",
                receivedAt = DurableCaptureQueue.isoOf(smsEpochMs),
                receivedAtEpochMs = smsEpochMs,
                // With no active owner (signed out, mid account change) the SMS
                // is unbound, hinted to the account that consented to its
                // capture. Ignored when an owner is active (stamped instead).
                ownerHint = CaptureSettings.optInOwner(context),
            ),
        )
        if (result == DurableCaptureQueue.EnqueueResult.STORED) {
            // One unique, network-constrained background drain. It runs the
            // live engine's drain only (none is ever started for it); the
            // drain re-checks the signed-in admission and consent itself.
            CaptureBackgroundScheduler.request(context, 0L)
        }
        if (result == DurableCaptureQueue.EnqueueResult.NOT_PERSISTED) {
            // A receiver has no UI and may be killed on return: the queue has
            // already retried the write once and counted the refusal, and the
            // app shows the "could not be saved" notice the next time it is in
            // the foreground. Outcome name only — never the message.
            android.util.Log.w("QirshSmsCapture", "sms capture not stored: $result")
        }
    }

    /**
     * Privacy prefilter: should this message be retained at all?
     *
     * This is NOT a parser. It decides only whether a message may enter the
     * durable queue; the authoritative parse still happens in the Dart engine.
     * Keeping it dumb is deliberate — a second parser here would drift from the
     * real one and would be invisible when it did.
     *
     * The gate is sender-aware, because sender shape is the strongest signal
     * available at this layer without importing catalogue data:
     *
     *   • Alphanumeric sender ("AlRajhiBank", "SABB", "stc pay") — banks and
     *     businesses send from sender IDs, which ordinary people cannot use.
     *     A single strong financial signal is enough.
     *
     *   • Numeric sender (+9665…, a real phone number) — this is where personal
     *     messages come from. Require an amount AND a transaction keyword, so a
     *     friend writing "bring your card" is not retained on the word "card"
     *     alone. That was a real false-positive in the previous `amount OR
     *     keyword` rule.
     *
     * Erring toward retention for sender IDs is intentional: a missed bank SMS
     * is a silently absent transaction, which users do not notice and cannot
     * correct. A retained personal SMS is a privacy cost, which is why the
     * numeric-sender path is strict.
     */
    private fun shouldRetain(text: String, sender: String?): Boolean {
        val lower = text.lowercase()
        val hasAmount = hasAmountLike(lower)
        val hasKeyword = hasTransactionKeyword(lower)

        // OTP / verification codes are never financial records, whatever the
        // sender. Banks send these from the same sender ID as real alerts, so
        // this has to be checked before the sender split.
        if (isLikelyOtp(lower) && !hasAmount) return false

        return if (isAlphanumericSender(sender)) hasAmount || hasKeyword
        else hasAmount && hasKeyword
    }

    /**
     * True when the sender is a sender ID rather than a phone number.
     *
     * Unknown/absent senders are treated as numeric (the strict path): absent
     * evidence must not buy the loose rule.
     */
    private fun isAlphanumericSender(sender: String?): Boolean {
        val s = sender?.trim().orEmpty()
        if (s.isEmpty()) return false
        // Any letter — Latin or Arabic — means it cannot be a dialable number.
        return s.any { it.isLetter() }
    }

    private fun hasAmountLike(lower: String): Boolean =
        Regex("""\d[\d,]*\.?\d*\s?(sar|aed|egp|kwd|bhd|omr|qar|jod|usd|eur|gbp|ر\.س|ريال|درهم|جنيه|دينار|\$|€|£)""")
            .containsMatchIn(lower) ||
            Regex("""(sar|aed|egp|kwd|bhd|omr|qar|jod|usd|eur|gbp|ر\.س|ريال|درهم|جنيه|دينار)\s?\d""")
                .containsMatchIn(lower)

    private fun hasTransactionKeyword(lower: String): Boolean {
        val keywords = listOf(
            "purchase", "payment", "transaction", "withdraw", "deposit", "transfer",
            "debited", "credited", "balance", "pos", "refund", "atm", "invoice",
            "شراء", "دفع", "عملية", "سحب", "إيداع", "تحويل", "خصم", "رصيد",
            "مشتريات", "فاتورة", "استرداد", "بطاقة",
        )
        return keywords.any { lower.contains(it) }
    }

    /**
     * One-time codes are the highest-volume non-financial traffic on a bank
     * sender ID. Dropping them keeps the queue — and anything downstream — free
     * of credentials the app has no reason to hold.
     */
    private fun isLikelyOtp(lower: String): Boolean {
        val markers = listOf(
            "otp", "one-time", "one time password", "verification code",
            "security code", "login code", "رمز التحقق", "كلمة المرور المؤقتة",
            "رمز الدخول", "لا تشارك",
        )
        return markers.any { lower.contains(it) }
    }
}
