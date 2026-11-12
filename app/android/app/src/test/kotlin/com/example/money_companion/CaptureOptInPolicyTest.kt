package com.youssefsafwat.mali

import com.youssefsafwat.mali.CaptureOwnerPolicy.OptInState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-account SMS auto-capture opt-in ([CaptureOwnerPolicy]), the pure
 * decision MainActivity persists in CaptureSettings. Owner "hashes" here are
 * synthetic strings; nothing Android is involved.
 */
class CaptureOptInPolicyTest {
    private val a = "hash-a"
    private val b = "hash-b"

    private fun enabledFor(owner: String) =
        CaptureOwnerPolicy.onToggled(OptInState(), true, owner)

    /** Sign-out / transition clear, then [owner] published. */
    private fun signIn(state: OptInState, owner: String) =
        CaptureOwnerPolicy.onOwnerPublished(CaptureOwnerPolicy.onOwnerCleared(state), owner)

    @Test
    fun `A on, then B published - B is not enabled and A stays remembered`() {
        val s = signIn(enabledFor(a), b)
        assertFalse(s.active)
        assertNull(s.activeOwner)
        assertEquals(setOf(a), s.remembered)
        assertNull(s.restoredNotice)
        assertFalse(CaptureOwnerPolicy.captureAllowed(s, b))
    }

    @Test
    fun `B published WITHOUT a clear in between still never inherits A`() {
        val s = CaptureOwnerPolicy.onOwnerPublished(enabledFor(a), b)
        assertFalse(s.active)
        assertEquals(setOf(a), s.remembered)
        assertFalse(CaptureOwnerPolicy.captureAllowed(s, b))
    }

    @Test
    fun `A then B then A - A is restored with a one-shot notice for A only`() {
        val onB = signIn(enabledFor(a), b)
        val backOnA = signIn(onB, a)
        assertTrue(backOnA.active)
        assertEquals(a, backOnA.activeOwner)
        assertEquals(a, backOnA.restoredNotice)
        assertTrue(CaptureOwnerPolicy.captureAllowed(backOnA, a))

        // B asking never sees (or consumes) A's notice.
        val (bSees, untouched) = CaptureOwnerPolicy.consumeRestoredNotice(backOnA, b, true)
        assertFalse(bSees)
        assertEquals(a, untouched.restoredNotice)

        val (shown, after) = CaptureOwnerPolicy.consumeRestoredNotice(backOnA, a, true)
        assertTrue(shown)
        assertNull(after.restoredNotice)
        val (again, _) = CaptureOwnerPolicy.consumeRestoredNotice(after, a, true)
        assertFalse("one-shot", again)
        assertTrue("consuming the notice never changes capture", after.active)
    }

    @Test
    fun `a restored opt-in without RECEIVE_SMS is not announced and the notice is spent`() {
        val backOnA = signIn(signIn(enabledFor(a), b), a)
        val (shown, after) = CaptureOwnerPolicy.consumeRestoredNotice(backOnA, a, false)
        assertFalse(shown)
        assertNull(after.restoredNotice)
    }

    @Test
    fun `the notice does not survive its owner signing out`() {
        val backOnA = signIn(signIn(enabledFor(a), b), a)
        val out = CaptureOwnerPolicy.onOwnerCleared(backOnA)
        assertNull(out.restoredNotice)
        val onB = CaptureOwnerPolicy.onOwnerPublished(out, b)
        assertFalse(CaptureOwnerPolicy.consumeRestoredNotice(onB, a, true).first)
    }

    @Test
    fun `a relaunch republishing the active owner keeps everything as is`() {
        val on = enabledFor(a)
        assertEquals(on, CaptureOwnerPolicy.onOwnerPublished(on, a))
        assertNull(CaptureOwnerPolicy.onOwnerPublished(on, a).restoredNotice)
    }

    @Test
    fun `signed out - inactive, nothing allowed, remembered kept`() {
        val out = CaptureOwnerPolicy.onOwnerCleared(enabledFor(a))
        assertFalse(out.active)
        assertNull(out.activeOwner)
        assertEquals(setOf(a), out.remembered)
        assertFalse(CaptureOwnerPolicy.captureAllowed(out, null))
        // Even an active opt-in is never effective without an active owner.
        assertFalse(CaptureOwnerPolicy.captureAllowed(enabledFor(a), null))
    }

    @Test
    fun `enabling while signed out turns nothing on and remembers nobody`() {
        val s = CaptureOwnerPolicy.onToggled(OptInState(), true, null)
        assertFalse(s.active)
        assertTrue(s.remembered.isEmpty())
        val kept = CaptureOwnerPolicy.onToggled(
            CaptureOwnerPolicy.onOwnerCleared(enabledFor(a)), true, null)
        assertFalse(kept.active)
        assertEquals(setOf(a), kept.remembered)
    }

    @Test
    fun `turning it off forgets the active owner only`() {
        val both = signIn(signIn(enabledFor(a), b).let {
            CaptureOwnerPolicy.onToggled(it, true, b)
        }, a)
        assertEquals(setOf(a, b), both.remembered)
        val off = CaptureOwnerPolicy.onToggled(both, false, a)
        assertFalse(off.active)
        assertEquals(setOf(b), off.remembered)
        assertNull(off.restoredNotice)
        assertFalse("A turned it off: not restored", signIn(off, a).active)
        assertTrue("B's own choice is untouched", signIn(off, b).active)
    }

    @Test
    fun `remove data of A forgets A only`() {
        val onB = CaptureOwnerPolicy.onToggled(signIn(enabledFor(a), b), true, b)
        val backOnA = signIn(onB, a)
        val removed = CaptureOwnerPolicy.onOwnerRemoved(backOnA, a)
        assertFalse(removed.active)
        assertEquals(setOf(b), removed.remembered)
        assertNull(removed.restoredNotice)
        assertFalse("A's removed data never restores capture", signIn(removed, a).active)
        assertTrue(signIn(removed, b).active)
    }

    @Test
    fun `B enabling, then A returning, leaves B's entry alone`() {
        val bOn = CaptureOwnerPolicy.onToggled(signIn(enabledFor(a), b), true, b)
        assertTrue(bOn.active)
        assertEquals(b, bOn.activeOwner)
        assertNull("B turned it on itself: nothing to announce", bOn.restoredNotice)
        val aBack = signIn(bOn, a)
        assertEquals(a, aBack.activeOwner)
        assertEquals(setOf(a, b), aBack.remembered)
        assertFalse(CaptureOwnerPolicy.captureAllowed(aBack, b))
        val bBack = signIn(aBack, b)
        assertEquals(b, bBack.activeOwner)
        assertEquals(b, bBack.restoredNotice)
    }

    @Test
    fun `legacy ownerless opt-in is adopted by the first owner published without a clear`() {
        val legacy = OptInState(active = true)
        val adopted = CaptureOwnerPolicy.onOwnerPublished(legacy, a)
        assertTrue(adopted.active)
        assertEquals(a, adopted.activeOwner)
        assertEquals(setOf(a), adopted.remembered)
        assertNull("nothing was off: nothing to announce", adopted.restoredNotice)
        // ... and is then A's alone.
        assertFalse(signIn(adopted, b).active)
        assertTrue(signIn(signIn(adopted, b), a).active)
    }

    @Test
    fun `a legacy ownerless opt-in is dropped by any owner clear`() {
        val legacy = OptInState(active = true)
        val cleared = CaptureOwnerPolicy.onOwnerCleared(legacy)
        assertFalse(cleared.active)
        assertTrue(cleared.remembered.isEmpty())
        assertFalse(CaptureOwnerPolicy.onOwnerPublished(cleared, b).active)
    }

    @Test
    fun `an owned opt-in stored before the per-account memory is migrated`() {
        // Pre-upgrade storage: active + owner, no remembered set.
        val old = OptInState(active = true, activeOwner = a)
        val onB = signIn(old, b)
        assertEquals(setOf(a), onB.remembered)
        assertTrue(signIn(onB, a).active)
    }

    @Test
    fun `the gate admits only the active owner's own opt-in`() {
        val on = enabledFor(a)
        assertTrue(CaptureOwnerPolicy.captureAllowed(on, a))
        assertFalse(CaptureOwnerPolicy.captureAllowed(on, b))
        assertTrue(CaptureOwnerPolicy.captureAllowed(OptInState(active = true), a))
        assertFalse(CaptureOwnerPolicy.captureAllowed(OptInState(), a))
    }
}
