package com.youssefsafwat.mali

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    // MALI-013: shared/received messages are persisted in DurableCaptureQueue
    // (survives process death) — no process-memory-only list any more.

    companion object {
        /** Arbitrary but stable; must not collide with a plugin's request code. */
        private const val REQUEST_RECEIVE_SMS = 4713
    }

    /**
     * Held across the runtime-permission round trip. The Android dialog is
     * asynchronous and can outlive a configuration change, so the Dart caller is
     * answered from onRequestPermissionsResult rather than inline.
     */
    private var pendingSmsPermissionResult: MethodChannel.Result? = null

    /** The capture channel of the live engine; null when there is none. */
    private var nativeCaptureChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        captureSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureSharedText(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val captureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "money_companion/native_capture",
        )
        nativeCaptureChannel = captureChannel
        // The background capture worker drives THIS engine's drain, and only
        // once Dart reports a drain handler (setBackgroundDrainReady).
        CaptureDrainHost.attach(captureChannel)
        // Foreground-only wake-up: while this activity (and its engine) is
        // alive, a newly stored capture tells Dart to drain. Nothing runs when
        // the process is not alive — the next launch/resume drains instead.
        DurableCaptureQueue.onStored = { notifyPendingCaptures() }
        captureChannel.setMethodCallHandler(
            NativeCaptureChannelHandler(
                context = this,
                onDrainReady = { ready -> CaptureDrainHost.setReady(captureChannel, ready) },
                activityCall = ::handleActivityCaptureCall,
            ),
        )

        // The device's IANA timezone identifier, for scheduling local
        // notifications in the user's own zone.
        //
        // Replaces the flutter_timezone package, which was removed because its
        // iOS public header carries an unused `#import <CoreLocation/
        // CoreLocation.h>` that put a location-framework reference in an app
        // with no location feature (Apple ITMS-90683). Android was never the
        // problem, but the package is cross-platform, so its one call site
        // needs an implementation on both sides.
        //
        // A SEPARATE channel from the capture drain, deliberately: that one
        // carries per-controller rebind logic on iOS and is the path a previous
        // data-loss defect ran through. A timezone lookup has no business
        // sharing it.
        registerDeviceTimezoneChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    /**
     * The capture-channel methods that need this ACTIVITY (a permission dialog,
     * the Settings screen). A headless engine has none: they are not
     * implemented there.
     */
    private fun handleActivityCaptureCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            // MALI-013 — the runtime RECEIVE_SMS request.
            //
            // Dart is responsible for showing the prominent disclosure BEFORE
            // calling this; Play requires disclosure immediately before the
            // system dialog. This method deliberately does not show any UI of
            // its own, so the disclosure cannot be bypassed by calling it.
            //
            // Returns a JSON status rather than a bare bool so Dart can tell
            // "denied, ask again" apart from "denied permanently" — those need
            // different UX (retry vs. send the user to Settings).
            "requestReceiveSmsPermission" -> {
                when {
                    !CaptureSettings.receiveSmsDeclared(this) ->
                        // Build does not ship the permission at all.
                        result.success(smsPermissionStatus("unavailable"))

                    CaptureSettings.hasReceiveSmsPermission(this) ->
                        result.success(smsPermissionStatus("granted"))

                    pendingSmsPermissionResult != null ->
                        // A dialog is already up; never queue two.
                        result.success(smsPermissionStatus("in_progress"))

                    else -> {
                        pendingSmsPermissionResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.RECEIVE_SMS),
                            REQUEST_RECEIVE_SMS,
                        )
                    }
                }
            }
            "openAppSettings" -> {
                openAppSettings()
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DurableCaptureQueue.onStored = null
        nativeCaptureChannel?.let { CaptureDrainHost.detach(it) }
        nativeCaptureChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Tells Dart the durable queue changed. A no-op without a live engine; the
     * channel must be used on the main thread (an SMS broadcast and a share
     * intent both arrive there, `runOnUiThread` keeps that explicit).
     */
    private fun notifyPendingCaptures() {
        runOnUiThread {
            nativeCaptureChannel?.invokeMethod("pendingSharedMessagesAvailable", null)
        }
    }

    /**
     * MALI-013 — deliver the runtime permission outcome to the waiting Dart call.
     *
     * `shouldShowRequestPermissionRationale` is false AFTER a denial only when the
     * user chose "don't ask again" (or the OS blocks the prompt), which is the
     * only reliable signal for that state on Android. Reported as
     * `permanently_denied` so Dart can offer the Settings route instead of a
     * retry that would never show a dialog.
     *
     * Denial never disables share capture: it needs no permission and keeps
     * working. Auto-capture simply stays OFF.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_RECEIVE_SMS) return

        val pending = pendingSmsPermissionResult ?: return
        pendingSmsPermissionResult = null

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val status = when {
            granted -> "granted"
            ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                Manifest.permission.RECEIVE_SMS,
            ) -> "denied"
            else -> "permanently_denied"
        }
        pending.success(smsPermissionStatus(status))
    }

    /**
     * One shape for every permission answer, so Dart never has to infer state
     * from a bare boolean. `enabled` is included because a granted permission is
     * NOT consent — the user opt-in is a separate key (CaptureSettings).
     */
    private fun smsPermissionStatus(status: String): String {
        val json = JSONObject()
        json.put("status", status)
        json.put("declared", CaptureSettings.receiveSmsDeclared(this))
        json.put("granted", CaptureSettings.hasReceiveSmsPermission(this))
        json.put("enabled", CaptureSettings.isAutoCaptureEnabled(this))
        return json.toString()
    }

    private fun openAppSettings() {
        val intent =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        startActivity(intent)
    }

    private fun captureSharedText(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") {
            return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (text.isNullOrEmpty()) {
            return
        }

        // COUPONS Phase 5 — route BEFORE enqueueing.
        //
        // Until now every shared text/plain landed in the financial capture
        // queue, which was correct when a bank message was the only thing
        // anyone shared. A merchant link reaching that queue would be read as a
        // transaction by the SMS parser, persisted in the store built for bank
        // messages, and drained under financial consent. Classifying here is
        // what keeps the two paths from ever touching — by the time Dart sees
        // it, it is already in whichever store it was put.
        when (val routed = SharedContentRouter.classify(text)) {
            is SharedContentRouter.Result.OfferUrl -> {
                OfferIntentStore.enqueue(
                    this,
                    OfferIntentStore.Item(
                        id = java.util.UUID.randomUUID().toString(),
                        url = routed.sanitizedUrl,
                        host = routed.host,
                        receivedAt = OfferIntentStore.isoNow(),
                    ),
                )
            }
            is SharedContentRouter.Result.Capture -> {
                val sender = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
                // Durable enqueue — survives process death until Flutter acks
                // the import. Unchanged behaviour for the bank-message path.
                val stored = DurableCaptureQueue.get(this).enqueue(
                    DurableCaptureQueue.Item(
                        id = java.util.UUID.randomUUID().toString(),
                        text = routed.text,
                        sender = sender?.takeIf { it.isNotEmpty() },
                        source = "share",
                        receivedAt = DurableCaptureQueue.isoNow(),
                    ),
                )
                if (stored == DurableCaptureQueue.EnqueueResult.STORED) {
                    CaptureBackgroundScheduler.request(this, 0L)
                }
                if (stored != DurableCaptureQueue.EnqueueResult.STORED) {
                    // The share was NOT saved (queue full / store unwritable).
                    // The queue counted it; wake Dart so the drain shows the
                    // "could not be saved" notice now rather than at next launch.
                    notifyPendingCaptures()
                }
            }
            SharedContentRouter.Result.Ignored -> Unit
        }

        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_SUBJECT)
    }
}

/**
 * The `money_companion/native_capture` channel: durable queue, owner scope,
 * removal barrier, process-wide drain lease and background scheduling.
 * Installed on the activity's engine AND on the headless cold-start engine
 * ([CaptureDrainWorker]), so both reach the same process-wide stores through
 * the same code. Methods that need an activity (a permission dialog, the
 * Settings screen) are answered by [activityCall]; a headless engine has none
 * and reports them not implemented.
 */
class NativeCaptureChannelHandler(
    private val context: Context,
    private val onDrainReady: (Boolean) -> Unit,
    private val activityCall: ((MethodCall, MethodChannel.Result) -> Boolean)? = null,
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (activityCall?.invoke(call, result) == true) return
        when (call.method) {
            // MALI-013: honest capability reporting. hasSmsPermission used
            // to return the NOTIFICATION permission — a lie. Notification
            // permission is reported separately and never as SMS.
            "captureCapabilities" -> {
                val caps = JSONObject()
                caps.put("supportsShareCapture", CaptureSettings.supportsShareCapture())
                caps.put("receiveSmsDeclared", CaptureSettings.receiveSmsDeclared(context))
                caps.put("hasReceiveSmsPermission", CaptureSettings.hasReceiveSmsPermission(context))
                caps.put("canUseAutomaticSmsCapture", CaptureSettings.canUseAutomaticSmsCapture(context))
                caps.put("isAutomaticSmsCaptureEnabled", CaptureSettings.isAutoCaptureEnabled(context))
                caps.put("hasNotificationPermission", hasNotificationPermission())
                result.success(caps.toString())
            }

            // COUPONS Phase 5 — hand over shared merchant links.
            //
            // A SEPARATE channel method from the capture drain, reading a
            // SEPARATE store. One method returning a mixed list would put a
            // shopping URL one missed switch case away from the SMS parser,
            // which is the whole thing this split exists to prevent.
            "drainOfferIntents" -> {
                val items = OfferIntentStore.drain(context)
                val array = org.json.JSONArray()
                for (item in items) {
                    array.put(
                        JSONObject()
                            .put("id", item.id)
                            .put("url", item.url)
                            .put("host", item.host)
                            .put("receivedAt", item.receivedAt),
                    )
                }
                result.success(array.toString())
            }

            "setAutomaticSmsCaptureEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                CaptureSettings.setAutoCaptureEnabled(
                    context,
                    enabled,
                    DurableCaptureQueue.get(context).activeOwnerHash(),
                )
                result.success(CaptureSettings.isAutoCaptureEnabled(context))
            }



            // Legacy destructive drain — kept for the Dart compat method
            // consumePendingSharedMessages(); prefer peek + ack.
            "consumePendingSharedMessages" -> {
                try {
                    result.success(DurableCaptureQueue.get(context).drainJson())
                } catch (_: QueueUnreadableException) {
                    result.error("queue_unreadable", null, null)
                }
            }

            // Per-item lease (MALI-012 + MALI-013): peek returns the durable
            // queue without clearing it; Dart acknowledges each message by id
            // after its import commits, so a crash/process death mid-import
            // re-delivers only the unacknowledged remainder.
            // A store that cannot be READ is an error for Dart, never an
            // empty queue: nothing is written, acknowledged or overwritten.
            "peekPendingSharedMessages" -> {
                try {
                    result.success(DurableCaptureQueue.get(context).peekJson())
                } catch (_: QueueUnreadableException) {
                    result.error("queue_unreadable", null, null)
                }
            }

            "acknowledgeSharedMessage" -> {
                val payloadId = call.argument<String>("payloadId")
                result.success(
                    payloadId != null &&
                        DurableCaptureQueue.get(context).acknowledge(payloadId),
                )
            }

            // Counts only (size, bound, refusals, quarantined blobs).
            "captureQueueHealth" -> {
                result.success(DurableCaptureQueue.get(context).healthJson())
            }

            "acknowledgeCaptureQueueNotice" -> {
                result.success(DurableCaptureQueue.get(context).acknowledgeNotice())
            }

            // The single process-wide drain lease: foreground and
            // background-triggered drains of every engine never overlap.
            "acquireCaptureDrainLease" -> {
                val ttlMs = call.argument<Number>("ttlMs")?.toLong() ?: 600_000L
                val token = CaptureDrainLease.acquire(ttlMs)
                result.success(mapOf("granted" to (token != null), "token" to token))
            }

            "releaseCaptureDrainLease" -> {
                val token = call.argument<String>("token")
                result.success(token != null && CaptureDrainLease.release(token))
            }

            // Captures remain queued: one unique, network-constrained
            // background work no earlier than the earliest is due.
            "scheduleBackgroundCaptureDrain" -> {
                val delayMs = call.argument<Number>("delayMs")?.toLong() ?: 0L
                CaptureBackgroundScheduler.request(context, delayMs)
                result.success(null)
            }

            // Sign-out / Remove data / account switch.
            "cancelBackgroundCaptureDrain" -> {
                CaptureBackgroundScheduler.cancel(context)
                result.success(null)
            }

            "setBackgroundDrainReady" -> {
                onDrainReady(call.argument<Boolean>("ready") == true)
                result.success(null)
            }

            // ── Account isolation (owner scope). Hashes only cross back;
            // a uid arrives from Dart and is never stored. Refusals are
            // error codes Dart treats as "did not happen".
            "captureOwnerEpoch" -> ownerCall(result) {
                DurableCaptureQueue.get(context).ownerEpoch()
            }

            "publishCaptureOwner" -> ownerCall(result) {
                val uid = call.argument<String>("uid")
                    ?: throw CaptureOwnerException("bad_args")
                val expectedEpoch = call.argument<Number>("expectedEpoch")?.toInt()
                    ?: throw CaptureOwnerException("bad_args")
                val queue = DurableCaptureQueue.get(context)
                val decision = CaptureOwnerPolicy.onOwnerPublished(
                    CaptureSettings.isOptedIn(context),
                    CaptureSettings.optInOwner(context),
                    queue.hashOf(uid),
                )
                // Another account's SMS opt-in is never inherited: it is
                // reset BEFORE this owner can be stamped on anything.
                if (decision == CaptureOwnerPolicy.OptIn.RESET &&
                    !CaptureSettings.reset(context)
                ) {
                    throw CaptureOwnerException("queue_unavailable")
                }
                val record = queue.publishOwner(uid, expectedEpoch)
                if (decision == CaptureOwnerPolicy.OptIn.ADOPT) {
                    CaptureSettings.adoptOwner(context, record.uidHash)
                }
                mapOf("uidHash" to record.uidHash, "generation" to record.generation)
            }

            // Only the record of the uid asked about (null otherwise).
            "getCaptureOwner" -> ownerCall(result) {
                val uid = call.argument<String>("uid")
                if (uid == null) {
                    null
                } else {
                    DurableCaptureQueue.get(context).ownerFor(uid)?.let {
                        mapOf("uid" to uid, "uidHash" to it.uidHash, "generation" to it.generation)
                    }
                }
            }

            "clearCaptureOwner" -> ownerCall(result) {
                val clearHint = call.argument<Boolean>("clearHint") == true
                // An account change never carries an opt-in nobody owns.
                if (clearHint && CaptureOwnerPolicy.resetAtAccountChange(
                        CaptureSettings.isOptedIn(context),
                        CaptureSettings.optInOwner(context),
                    ) && !CaptureSettings.reset(context)
                ) {
                    throw CaptureOwnerException("queue_unavailable")
                }
                DurableCaptureQueue.get(context).clearOwner(clearHint)
                // Nothing scheduled for the released owner may run.
                CaptureBackgroundScheduler.cancel(context)
                null
            }

            "unboundCaptureSummary" -> ownerCall(result) {
                val uid = call.argument<String>("uid")
                    ?: throw CaptureOwnerException("bad_args")
                val summary = DurableCaptureQueue.get(context).unboundSummary(uid)
                mapOf(
                    "ids" to summary.ids,
                    "senders" to summary.senders,
                    "count" to summary.ids.size,
                )
            }

            "claimUnboundCaptures", "discardUnboundCaptures" -> ownerCall(result) {
                val outcome = DurableCaptureQueue.get(context).claimUnbound(
                    uid = call.argument<String>("uid")
                        ?: throw CaptureOwnerException("bad_args"),
                    generation = call.argument<Number>("generation")?.toInt()
                        ?: throw CaptureOwnerException("bad_args"),
                    replicaOwnerUid = call.argument<String>("replicaOwnerUid")
                        ?: throw CaptureOwnerException("bad_args"),
                    sessionUid = call.argument<String>("sessionUid")
                        ?: throw CaptureOwnerException("bad_args"),
                    ids = call.argument<List<String>>("ids")
                        ?: throw CaptureOwnerException("bad_args"),
                    discard = call.method == "discardUnboundCaptures",
                )
                mapOf(
                    "status" to when (outcome.status) {
                        DurableCaptureQueue.ClaimStatus.APPLIED -> "applied"
                        DurableCaptureQueue.ClaimStatus.STALE -> "stale"
                        DurableCaptureQueue.ClaimStatus.OWNER_MISMATCH -> "owner_mismatch"
                    },
                    "count" to outcome.count,
                )
            }

            // Remove data (§4.4 on Android): begin → (replica teardown in
            // Dart) → finish. The SMS opt-in is reset and background work
            // cancelled at BOTH ends, so nothing is captured or drained for
            // the owner being removed, also when a crashed removal resumes.
            "beginCaptureRemoval" -> ownerCall(result) {
                val uid = call.argument<String>("uid")
                    ?: throw CaptureOwnerException("bad_args")
                CaptureBackgroundScheduler.cancel(context)
                if (!CaptureSettings.reset(context)) throw CaptureOwnerException("queue_unavailable")
                DurableCaptureQueue.get(context).beginRemoval(uid).toMap()
            }

            "getCaptureRemovalBarrier" -> ownerCall(result) {
                try {
                    DurableCaptureQueue.get(context).removalBarrier()?.toMap()
                } catch (e: CaptureOwnerException) {
                    // Present but unreadable: Dart reads a non-map as
                    // "malformed", which blocks admission like a barrier.
                    if (e.code == "barrier_malformed") "malformed" else throw e
                }
            }

            "finishCaptureRemoval" -> ownerCall(result) {
                val uid = call.argument<String>("uid")
                    ?: throw CaptureOwnerException("bad_args")
                CaptureBackgroundScheduler.cancel(context)
                if (!CaptureSettings.reset(context)) throw CaptureOwnerException("removal_incomplete")
                DurableCaptureQueue.get(context).finishRemoval(uid)
            }

            "purgeAllCaptureState" -> {
                // MALI-054n: purge this identity's capture residue + reset the
                // SMS auto-capture opt-in. Both use commit() so success is
                // verified before a new user is admitted. Report the AND of both.
                val purged = DurableCaptureQueue.get(context).purge()
                val settingsReset = CaptureSettings.reset(context)
                // Nothing scheduled for the purged identity may run.
                CaptureBackgroundScheduler.cancel(context)
                result.success(purged && settingsReset)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Runs one owner-scope call. A refusal is its error code only (never a uid,
     * hash or content); an unreadable store is `queue_unavailable`.
     */
    private fun ownerCall(result: MethodChannel.Result, body: () -> Any?) {
        try {
            result.success(body())
        } catch (e: CaptureOwnerException) {
            result.error(e.code, null, null)
        } catch (_: QueueUnreadableException) {
            result.error("queue_unavailable", null, null)
        } catch (_: Throwable) {
            result.error("queue_unavailable", null, null)
        }
    }

    // Honest: this is the NOTIFICATION permission, never reported as SMS.
    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    }
}

/**
 * The device's IANA timezone identifier, for scheduling local notifications in
 * the user's own zone (Dart asks during `notifications_init`, on the activity's
 * engine and on the headless cold-start engine alike).
 *
 * Replaces the flutter_timezone package, which was removed because its iOS
 * public header carries an unused `#import <CoreLocation/CoreLocation.h>` that
 * put a location-framework reference in an app with no location feature (Apple
 * ITMS-90683). A SEPARATE channel from the capture drain, deliberately.
 */
fun registerDeviceTimezoneChannel(messenger: BinaryMessenger) {
    MethodChannel(messenger, "mali/device_timezone").setMethodCallHandler { call, result ->
        when (call.method) {
            "getLocalTimezone" -> result.success(java.util.TimeZone.getDefault().id)
            else -> result.notImplemented()
        }
    }
}
