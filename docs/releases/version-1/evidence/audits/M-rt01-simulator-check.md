# M — RT-01 (tab bar missing after e-mail sign-in): simulator check of the fix

Date: 2026-11-17. Role: runtime verification only. Nothing in the app was changed; no tracked file
was edited apart from this report and the screenshots in `../ui/signed-in/rt01/`.

**Verdict: CONFIRMED FIXED ON SIMULATOR** (e-mail one-time-code sign-in, debug build, iOS 26.5
Simulator). The control build with only the old observer restored reproduces the defect with the same
harness, so the "fixed" observation is meaningful.

## 1. What was run

| Item | Value |
|---|---|
| Commit built | `0095a239bc54827cc6789e430261a6b0ab770f47` (tip of `release-readiness/v1`; contains the fix `45ea901a`). Built in a separate detached scratch worktree; uncommitted changes in the readiness worktree were not part of the build. |
| Control build | Same commit with ONLY `app/lib/core/router/modal_route_observer.dart` replaced by its pre-fix version (`45ea901a^`). Restored afterwards. |
| Build | Flutter 3.47.3, **debug** simulator build via `flutter test integration_test/…` on the device. Not the store artifact. |
| Defines | `SUPABASE_URL`=local stack, `SUPABASE_ANON_KEY`=local anon key, `SUPABASE_ENV=local`, `QIRSH_EMAIL_AUTH_ENABLED=true` (as in J), plus test-only defines for the QA address and the local admin key used to mint the code. |
| Simulator | "Qirsh V1 RT01" — iPhone 17, iOS 26.5 (23F77). Created for this check and deleted afterwards. |
| Backend | Local Supabase stack `qirsh_v1_verify` (127.0.0.1:56321). Synthetic account `qa+v1@example.test`. No production access. |
| Fresh install | Before every run: app uninstalled (`simctl uninstall`) and the simulator keychain reset, so no session or local data carried over. |

### Harness (same as J)

A temporary integration test (scratch worktree only, deleted) launched the real `main()` and drove the
real UI by widget taps: language (Arabic) → welcome story → brand CTA → auth screen → "email" →
typed the QA address → "Send code" (the app's own `signInWithOtp`) → code field appeared → the 6-digit
code was **minted through the LOCAL admin API (`generate_link`)** and typed into the app's code field →
the app's own confirm button ran `verifyOTP`.

On each fresh install the app then showed the onboarding setup route (no `AppShell` within 90 s);
as in J, setup was completed by calling `AppSession.finishOnboarding()` rather than walking it. After
landing, a first-use coach-mark dialog (`showDialog`, "سجّل أول عملية") is open over Home; it was
dismissed with its own "تخطّي" (Skip) button (two pages). Only then was the "nothing open" state read.

The test never wrote `modalRouteOpen`. At each checkpoint it logged: `modalRouteOpen.value`, whether
`NativeTabBar` is in the widget tree, whether `AppShell` is mounted, and the number of `ModalBarrier`s
(1 = the page route alone, 2 = a live sheet/dialog on top). Screenshots were taken host-side with
`xcrun simctl io <udid> screenshot`, so they include the native UIKit tab bar.

The re-sign-in in run 1 went straight from the code sheet to the shell (no setup route, no coach mark),
so that leg is fully real UI.

## 2. Results

### Fixed build (commit `0095a239`)

| Run | Checkpoint | `modalRouteOpen` | `NativeTabBar` in tree | Live overlay | Screenshot | Result |
|---|---|---|---|---|---|---|
| 1 | Signed in, coach mark open | true | no | yes (coach-mark dialog) | — | Correct (bar hidden under a dialog) |
| 1 | Signed in, nothing open | **false** | **yes** | no | 01 | **Bar visible** |
| 1 | Add sheet open ("+") | true | no | yes | 02 | Bar hidden while open — correct |
| 1 | Add sheet closed with its X | **false** | **yes** | no | 03 | **Bar visible** |
| 1 | Sign-out sheet open (Settings → Sign out) | true | no | yes | — | Correct |
| 1 | Signed out → e-mail sign-in again, nothing open | **false** | **yes** | no | 04 | **Bar visible** |
| 2 | Signed in, nothing open (fresh install) | **false** | **yes** | no | 05 | **Bar visible** |
| 3 | Signed in, nothing open (fresh install) | **false** | **yes** | no | 06 | **Bar visible** |

All three fresh installs and the re-sign-in: tab bar present and visible (5 tabs, RTL, Home selected).

### Control build (old observer only)

| Run | Checkpoint | `modalRouteOpen` | `NativeTabBar` in tree | Live overlay | Screenshot | Result |
|---|---|---|---|---|---|---|
| C1 | Signed in, nothing open | **true** | **no** | no (barriers = 1) | 07 | **Bar missing — defect reproduced** |
| C1 | Add sheet closed | true | no | no | — | Bar still missing |
| C1 | After sign-out and e-mail sign-in again, nothing open | true | no | no | 08 | Bar still missing |

The control reproduces RT-01 exactly as J described (flag stuck `true` with no live overlay), so the
harness can see the defect and the fixed-build observations are not a harness artefact.

Screenshots (`docs/releases/version-1/evidence/ui/signed-in/rt01/`, synthetic data only):
`01-fixed-run1-signed-in-bar-visible`, `02-fixed-run1-add-sheet-open-bar-hidden`,
`03-fixed-run1-add-sheet-closed-bar-visible`, `04-fixed-run1-after-resignin-bar-visible`,
`05-fixed-run2-signed-in-bar-visible`, `06-fixed-run3-signed-in-bar-visible`,
`07-control-old-observer-signed-in-bar-missing`, `08-control-old-observer-after-resignin-bar-missing`.

## 3. Observations (not new findings)

- On these fresh installs the first screen after sign-in was a first-use coach-mark dialog, not the
  Cloud/AI consent sheet J saw. Both are real overlays; the bar is correctly hidden while either is open.
- After sign-in on a fresh install the app routed to the onboarding setup for the already-onboarded QA
  account; setup was completed programmatically (as in J), not walked.

## 4. NOT TESTED

- **App-lock path** (sheet open → background > 30 s → return): NOT TESTED. The lock is presented by the
  native biometric prompt, which stops frame delivery inside an integration test (see the note in
  `app/integration_test/applock_arm_test.dart`); not attempted in the time available.
- **Apple and Google sign-in**: need real provider accounts; not possible against the local stack.
- **Physical device**: none used; simulator + debug build only. Not the Codemagic/store artifact.
- **Tapping the native tab bar items**: not done (the test framework cannot tap the UIKit view);
  visibility only.
- **The 6 onboarding setup steps**: completed programmatically, not walked.
- **Cold relaunch behaviour**: not exercised.

## 5. Cleanup

Scratch simulator deleted, scratch worktree removed and pruned, build output deleted. No Docker
container was started, stopped or reset; the local stack was only used, not changed (apart from new
auth sessions and one magic-link token per sign-in for the synthetic account).
