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
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO_ENABLED, false) // OFF by default
    }

    /**
     * The opt-in belongs to [ownerHash], the active capture owner when the user
     * turned it on, so a different account never inherits it
     * ([CaptureOwnerPolicy.onOwnerPublished]).
     */
    fun setAutoCaptureEnabled(context: Context, enabled: Boolean, ownerHash: String?) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_AUTO_ENABLED, enabled)
        if (enabled && ownerHash != null) {
            editor.putString(KEY_OPT_IN_OWNER, ownerHash)
        } else {
            editor.remove(KEY_OPT_IN_OWNER)
        }
        editor.apply()
    }

    /** The stored opt-in alone (no permission check): the owner rule's input. */
    fun isOptedIn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO_ENABLED, false)

    /** Who owns the opt-in; null when off or recorded before owners existed. */
    fun optInOwner(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_OPT_IN_OWNER, null)

    /** An ownerless (pre-upgrade) opt-in becomes [ownerHash]'s. */
    fun adoptOwner(context: Context, ownerHash: String): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_OPT_IN_OWNER, ownerHash).commit()

    /**
     * MALI-054n/059n: reset the SMS auto-capture opt-in on an identity change so
     * one user's consent is never inherited by the next. commit() is used so the
     * purge boundary can confirm completion. Returns true on verified reset.
     */
    fun reset(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_AUTO_ENABLED).remove(KEY_OPT_IN_OWNER).commit()
    }
}
