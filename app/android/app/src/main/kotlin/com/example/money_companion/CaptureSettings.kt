package com.youssefsafwat.mali

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * MALI-013 — capture capability + opt-in state (Android).
 *
 * Automatic SMS capture is a two-key lock: it runs only when RECEIVE_SMS is
 * granted AND the user has explicitly enabled it. A granted permission alone is
 * never treated as consent to read. Share capture is always available and needs
 * no permission.
 */
object CaptureSettings {
    private const val PREFS = "mali_capture_settings_v1"
    private const val KEY_AUTO_ENABLED = "auto_capture_enabled"
    /**
     * The capture owner (HMAC of the uid, never the uid) whose explicit action
     * turned the opt-in on. Absent on an opt-in recorded before owners existed.
     */
    private const val KEY_OPT_IN_OWNER = "auto_capture_owner_hash"
    /**
     * Every owner hash whose own explicit action turned capture on and that
     * has not turned it off or removed its data since: restored for exactly
     * that owner when it is published again ([CaptureOwnerPolicy.onOwnerPublished]).
     */
    private const val KEY_REMEMBERED_OWNERS = "auto_capture_remembered_owner_hashes"
    /** The owner hash whose opt-in was restored and who has not been told yet. */
    private const val KEY_RESTORED_NOTICE = "auto_capture_restored_notice_owner_hash"

    /** Share-to-Mali capture is always supported; it needs no permission. */
    fun supportsShareCapture(): Boolean = true

    /**
     * Whether RECEIVE_SMS is even declared in this build. A Play-safe,
     * share-only build omits the permission at the manifest level, so the whole
     * automatic path is "not included in this build" regardless of runtime.
     */
    fun receiveSmsDeclared(context: Context): Boolean {
        return try {
            val info = context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_PERMISSIONS,
            )
            info.requestedPermissions?.contains(Manifest.permission.RECEIVE_SMS) == true
        } catch (_: Throwable) {
            false
        }
    }

    fun hasReceiveSmsPermission(context: Context): Boolean {
        if (!receiveSmsDeclared(context)) return false
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECEIVE_SMS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /** Automatic capture is possible only if the build declares + grants SMS. */
    fun canUseAutomaticSmsCapture(context: Context): Boolean =
        hasReceiveSmsPermission(context)

    fun isAutoCaptureEnabled(context: Context): Boolean {
        // Enabled only when the user turned it on AND the permission holds.
        if (!hasReceiveSmsPermission(context)) return false
        // The opt-in (OFF by default) counts only for the ACTIVE owner whose
        // own action turned it on: never while signed out.
        return CaptureOwnerPolicy.captureAllowed(
            optInState(context),
            DurableCaptureQueue.get(context).activeOwnerHash(),
        )
    }

    /** Who owns the active opt-in; null when off or recorded before owners existed. */
    fun optInOwner(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_OPT_IN_OWNER, null)

    /** The per-account opt-in state ([CaptureOwnerPolicy.OptInState]). Hashes only. */
    @Synchronized
    internal fun optInState(context: Context): CaptureOwnerPolicy.OptInState {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return CaptureOwnerPolicy.OptInState(
            active = prefs.getBoolean(KEY_AUTO_ENABLED, false), // OFF by default
            activeOwner = prefs.getString(KEY_OPT_IN_OWNER, null),
            // A copy: the set SharedPreferences returns must not be modified.
            remembered = prefs.getStringSet(KEY_REMEMBERED_OWNERS, null)?.toSet() ?: emptySet(),
            restoredNotice = prefs.getString(KEY_RESTORED_NOTICE, null),
        )
    }

    /**
     * Applies [transition] to the stored state and persists the result with
     * commit(), so a caller can refuse to proceed (e.g. stamp a new owner)
     * unless the narrowing is durable. Returns the state written, or null when
     * the write could not be confirmed (nothing is assumed changed then).
     */
    @Synchronized
    internal fun update(
        context: Context,
        transition: (CaptureOwnerPolicy.OptInState) -> CaptureOwnerPolicy.OptInState,
    ): CaptureOwnerPolicy.OptInState? {
        val before = optInState(context)
        val next = transition(before)
        if (next == before) return next
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_AUTO_ENABLED, next.active)
        if (next.activeOwner != null) {
            editor.putString(KEY_OPT_IN_OWNER, next.activeOwner)
        } else {
            editor.remove(KEY_OPT_IN_OWNER)
        }
        if (next.remembered.isEmpty()) {
            editor.remove(KEY_REMEMBERED_OWNERS)
        } else {
            editor.putStringSet(KEY_REMEMBERED_OWNERS, HashSet(next.remembered))
        }
        if (next.restoredNotice != null) {
            editor.putString(KEY_RESTORED_NOTICE, next.restoredNotice)
        } else {
            editor.remove(KEY_RESTORED_NOTICE)
        }
        val ok = try { editor.commit() } catch (_: Throwable) { false }
        return if (ok) next else null
    }

    /**
     * MALI-054n/059n: deactivate the SMS auto-capture opt-in so nothing is
     * captured across an identity boundary. Remembered per-account opt-ins are
     * kept (each is restored only for its own account). commit() is used so
     * the purge boundary can confirm completion. Returns true on verified reset.
     */
    fun reset(context: Context): Boolean =
        update(context) { CaptureOwnerPolicy.onOwnerCleared(it) } != null

    /** Purge: every opt-in, remembered or active, and any pending notice. */
    fun resetAll(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_AUTO_ENABLED).remove(KEY_OPT_IN_OWNER)
            .remove(KEY_REMEMBERED_OWNERS).remove(KEY_RESTORED_NOTICE).commit()
    }
}
