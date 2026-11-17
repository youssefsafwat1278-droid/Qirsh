# J — Signed-in app shell, runtime verification on iOS Simulator

Date: 2026-11-17. Role: UI runtime verification only. Nothing in the app was fixed. Every item below is
either **SEEN ON SIMULATOR** (with a screenshot in `../ui/signed-in/`) or **NOT REACHED** (with the
reason). Nothing here is inferred from code unless it is labelled *code-supported*.

## 1. What was run

| Item | Value |
|---|---|
| Commit built | `8e953d14a18ac88f4edb07d44821d7fbab6751db` (HEAD of `release-readiness/v1`), built in a separate detached worktree. **Uncommitted changes in the readiness worktree were NOT in this build** (parser/declined cues, `parse.ts`, backfill service, restore use case, etc.). Item 6 results describe the committed parser only. |
| Build | Flutter 3.47.3, **debug** simulator build (`flutter test integration_test/…` on device). Not a release/profile build; not the store artifact. |
| Defines | `SUPABASE_URL`=local stack, `SUPABASE_ANON_KEY`=local stack anon key, `SUPABASE_ENV=local`, `QIRSH_EMAIL_AUTH_ENABLED=true` (the Codemagic default for this flag is `false`; it was turned on so the email one-time-code sign-in could be driven). No Sentry DSN, no Google client ID. |
| Simulators | "Qirsh V1 Shell" — iPhone 17, iOS 26.5 (main walk). "Qirsh V1 Shell SE" — iPhone SE (3rd generation), iOS 26.5 (small screen). Both created for this run and deleted afterwards. |
| Backend | Local Supabase stack `qirsh_v1_verify` (API 127.0.0.1:56321, Mailpit 56324), candidate migrations applied. Synthetic account `qa+v1@example.test`. |
| Backend limits | Edge Functions are **not served** by this stack (`/functions/v1/*` returns 503): AI parsing, catalog sync, push and anything function-backed were unavailable — environment limit, not an app defect. Cloud and AI consent stayed **unset/off** for the whole run, so no sync or AI egress was exercised. The local stack's magic-link e-mail uses the CLI default template (link only, no numeric code): `supabase/templates/magic_link.html` in the repo contains `{{ .Token }}` but `config.toml` does not wire it, so the local e-mail carried no code. |
| Data | Synthetic only: "Test Cafe 1" 42.50, "Test Grocer 2" 19.75, "Test Fuel 3" 120.00, "Test Cafe 4" 8.25, "Test Store 5" 300.00 (SAR), budget 1,500.00, goal "Test Goal" 5,000.00, four synthetic pasted messages. |

### How sign-in was achieved (real UI, one assisted step)

A temporary integration test (in the scratch worktree only, now deleted) launched the real `main()` and
drove the **real onboarding and sign-in UI** with widget taps: language screen → welcome story → brand
CTA → auth screen → "email" button → typed the QA address → "Send code". The app's own
`signInWithOtp` call succeeded and Mailpit received the e-mail ("Your sign-in link") — but, because of the
local template above, it contained no code. The 6-digit code was therefore **minted through the local
admin API (`generate_link`, local dev key) for the same address and typed into the app's code field**,
then the app's own "Confirm code" button ran `verifyOTP`. Result: signed in through the shipping UI and
code path; only the delivery of the code was substituted. This was done on four separate fresh installs
(and once more after sign-out). Programmatic password sign-in (the existing walk tests' mechanism) was
also tried and is **refused by the app's egress gate** before consent (`egress_denied:off`), so it was not
used.

Post-sign-in setup: on the first fresh account the app routed to `/onboarding/setup` (6-step setup); that
setup was completed by calling `AppSession.finishOnboarding()` rather than tapping through it (setup
screens were not walked). On later installs the account was already onboarded and the app went straight
to `/` after the code — fully real UI. Tab switching was done by setting the shell's own tab provider
(`shellIndexProvider`), not by tapping the native `UITabBar` (the test framework cannot tap a UIKit
platform view, and the simulator-control tool was not granted access to these simulators). Back
navigation was done with `Navigator.pop`, not the edge-swipe gesture. Screenshots were taken host-side
with `xcrun simctl io … screenshot`, so they include native views.

## 2. Results

`Shot` = file in `docs/releases/version-1/evidence/ui/signed-in/`.

### Item 1 — signed-in shell

| Check | Result | Shot | Observation |
|---|---|---|---|
| Real sign-in UI (auth screen, e-mail code sheet) | SEEN | 01, 02 | Works end to end with the code supplied as described. |
| Landing after sign-in | SEEN | 03 | A Cloud/AI consent sheet ("التحليل الذكي والمزامنة السحابية") opens over Home; "المتابعة محليًا" closes it. |
| **Native tab bar present** | SEEN — **ABSENT** | 04, 06, 14 | After e-mail sign-in the tab bar is **not shown** (`NativeTabBar` not in the tree) even with no sheet/dialog open. See **RT-01**. |
| Native tab bar when the stuck flag is cleared | SEEN (diagnostic only) | 05, 45 | Setting the app's `modalRouteOpen` flag back to `false` from the test immediately brings the native Liquid Glass tab bar back (5 tabs, RTL order, Home at the right; on SE, labelled Home/Activity/Budgets/Insights/More). Diagnostic, not a user action. |
| Each tab opens | SEEN (via tab provider, not native taps) | 06/07, 08, 28, 17 | Home, Transactions, Budgets/Planning, Reports/Insights, More all render. Tapping the native bar: NOT REACHED (see above). |
| Back navigation | SEEN (programmatic pop) | 16, 23 | Pushed pages show a back chevron on the correct side for RTL (right) and LTR (left). Edge-swipe back: NOT REACHED. |
| Add (+) button and its sheet | SEEN | 11 | "+" found by its screen-reader label (`homeQuickAdd`); opens "إضافة عملية جديدة" with Paste / Manual / Automatic capture. |
| Sheet close (X) button | SEEN | 11, 12 | Close button found by its tooltip (`closeButtonTooltip`), tap closed the capture sheet. |
| Safe areas | SEEN | all | No content under the status bar or home indicator observed on iPhone 17 or SE. |
| Arabic (RTL) / English | SEEN | 06–27 / 28–31, 33–39 | Both directions render correctly. User data (default account name «حساب SAR») stays Arabic in English UI, as expected for data. |
| Light / dark | SEEN | 14 vs 31, 32, 44, 45 | Dark theme renders on Home, Transactions, Budgets, manual sheet. |

### Item 2 — primary screens with data

| Check | Result | Shot | Observation |
|---|---|---|---|
| 5 manual transactions added through the UI | SEEN | 13, 14, 15 | All five saved; ledger = 5 confirmed payments, total 490.50. |
| Home totals | SEEN | 14 | "مصروف الشهر 490.50", income 0.00, net −490.50 — matches the inputs exactly. |
| Transactions list | SEEN | 15 | Five rows, day total −490.50, correct categories. |
| Transaction details | SEEN | 16 | "Test Cafe 1", −42.50, "مؤكدة", category, account; source shows "غير محدد" (manual entries have no source value — observation only). |
| Reports | SEEN | 10 (empty), 17 | 490.50 total, 5 operations, category donut. |
| Budgets — create one | SEEN | 18, 45 | 1,500.00 "كل المصروفات" budget created via the form; 33 % used, 1,009.50 left. |
| Goals — create one | SEEN | 19 | "Test Goal" 5,000.00 created. |
| Subscriptions / Bills | SEEN | 20 | Empty state, with a first-use coach mark. |
| Accounts / Cards | SEEN | 21, 22 | Render. |
| Settings ("More") | SEEN | 28 | Renders in EN; AXXXL variant 38. |
| Privacy (consent state and withdraw control) | SEEN (screen); consent controls partially | 23 | Privacy & data screen with explanation, policy/terms links, "Data processing" section with the Cloud+AI row. The individual toggle/withdraw control was not opened (below the fold; consent was never granted, so there was nothing to withdraw). |
| Data transfer / backup export screen | SEEN | 24 | PDF report, CSV, full ZIP export, import; warns the export is not password-protected. Export itself not run. |
| Help | SEEN | 27, 29, 30 | See item 4. |
| What's new | SEEN | 25 | Version 1.0.0 notes. |
| Delete account — entry | SEEN | 26 | Entry page with explanation and red "حذف الحساب" button. |
| Delete account — confirmation dialog | NOT REACHED | — | A tap on "حذف الحساب" (SE run) produced no dialog within 8 s and no error; the finder matched two identical texts (title and button), so the tap may have hit the title. Not retried to avoid starting a deletion. Not a defect claim. |
| Sign out — confirmation | SEEN | 42 | Sheet: "Your data stays on this device…", unsynced-data notice, "Sign out" / "Cancel". |
| Sign out, then sign back in; local data kept? | SEEN | 43 | Signed out (→ `/onboarding/auth`), signed back in with the same account through the e-mail UI: the transaction made before sign-out was still there (ledger 1 → 1). Claim holds for keep-data sign-out. |

### Item 3 — states

| Check | Result | Shot | Observation |
|---|---|---|---|
| Empty states before data | SEEN | 06, 07, 08, 09, 10, 20 | Home "أضف أول عملية" + 3-step starter card (digits now Western "3"); empty Transactions, Budgets, Goals, Reports, Bills. |
| Error / offline state | NOT REACHED | — | Network toggling of the simulator was not available and stopping the stack is not allowed. No failing request surfaced in the UI during the run (function calls were never triggered with consent off). |
| Notifications permission-denied state | NOT REACHED | — | No notification prompt appeared in the walked flows and `simctl privacy` cannot set notification permission. |

### Item 4 — release fixes needing runtime confirmation

| Fix | Result | Shot | Observation |
|---|---|---|---|
| Manual add opens with NO category pre-selected | **CONFIRMED** | 12 | Category field empty on open (AR light 12; EN AXXXL 39; also seen EN dark in the walk). |
| Category validation fires | **CONFIRMED** | 13 | Saving 42.50 without a category shows "اختر تصنيف العملية." and the sheet stays open; selecting a category then saves. |
| Add (+) and sheet close buttons exist and respond | **CONFIRMED** | 11, 12 | Both found by their accessibility names and both respond. VoiceOver itself not run. |
| Tap-target fixes do not shift layouts badly | **CONFIRMED (visual)** | 06 vs `before/21-…`, 45 vs `before/46-…` | Home header and budgets header look the same as before apart from the intended changes; no overlap seen. |
| Budget chips and page titles on a small screen | **CONFIRMED** | 44, 45 vs `before/45-…`, `before/46-…` | SE, EN dark: "Transactions" title on one line; status chips show "On track / Close to limit / Over limit / Budgets" in full (previously "On tra… / Close … / Over li… / Budge…"); "Budget history" segment no longer wraps. |
| Help shows the corrected sentences | **CONFIRMED** | 30, 29, 27 | EN: "Messages it reads with confidence are saved directly; anything it is unsure about waits in the Smart Inbox…" and "The ZIP is not password-protected, so store it somewhere private."; the old "Export an encrypted copy" wording is absent. AR Help add-transaction body found as well. |
| App-switcher privacy cover | **CONFIRMED via the iOS-stored snapshot** | 40, 41 | The app was sent to the background (another app launched). The snapshot iOS saved for the app switcher (`Library/SplashBoard/Snapshots/…ktx`, converted to PNG) shows only the «قرش» cover — dark and light variants — with no financial data, on iPhone 17 and on SE. The live switcher UI itself was NOT opened (no tool to swipe-and-hold). |

### Item 5 — text size

| Check | Result | Shot | Observation |
|---|---|---|---|
| Largest accessibility size (`accessibility-extra-extra-extra-large`) | SEEN | 38, 39 | Platform text scale reported 3.12; the app's effective scaler was **1.25×** (14 pt → 17.5 pt): the cap works. Layouts wrap (two-line tile labels, two-line sheet title) without clipping on the screens captured. **This shows the capped rendering only; it does NOT verify behaviour at full device accessibility sizes, which the cap deliberately does not honour.** |

### Item 6 — paste-a-message capture, Cloud OFF, on-device only

Consent: Cloud `unset`, AI `unset`, cloud processing `false` (logged from settings). Month spend before: 490.50.

| Sample (synthetic) | Lands in | Month spend after | Shot |
|---|---|---|---|
| `Purchase of SAR 75.00 with card ending 4521 at TEST SHOP on 2026-11-16` | **Transactions, status pending ("Under review")** via the review sheet "Read on your device — AI is off"; also listed under Home "To review (1)" | **490.50 (unchanged)** — pending is not counted until confirmed | 33, 37 |
| `Purchase of SAR 250.00 at Test Shop was declined.` | **Nowhere** — not saved, not in Smart Inbox; toast "It could not be read as a transaction — add it manually." | 490.50 | 34 |
| `Your purchase of SAR 180.00 at Test Shop was declined. If amount was deducted it will be refunded.` | **Nowhere** — same toast | 490.50 | 35 |
| `Refund failed: SAR 60.00 from Test Shop` | **Nowhere** — same toast | 490.50 | 36 |

Smart Inbox open items stayed 0 throughout. So on this build none of the three not-completed messages
changes spend or creates a refund — the release fix holds for manual paste. They do **not** land in Smart
Inbox (the shared case table describes Smart Inbox review for on-device *capture*; manual paste rejects
instead). See RT-02 for the wording.

## 3. New findings

| ID | Severity | Class | Objective / subjective | Finding |
|---|---|---|---|---|
| **RT-01** | **S2** (raise to S1 if e-mail sign-in ships enabled and no relaunch happens before use) | REPRODUCED (5 fresh installs on 2 devices, plus after re-sign-in); cause SUSPECTED | Objective | **After signing in with the e-mail one-time code, the native tab bar never appears.** `modalRouteOpen` (the flag that hides the bar while a sheet is open) is already `true` right after `verifyOTP` with the code sheet gone, and stays `true` after every later sheet/dialog is closed; `NativeTabBar` is absent from the tree (04, 06, 14). Clearing the flag from the test shows the bar at once (05). With no tab bar, the other tabs are reachable only through Home shortcuts ("See all", Budget, Goals, Paste); whether the Home avatar leads to Settings (sign-out, privacy, delete account) was not checked. Suspected cause: the e-mail code sheet (a `PopupRoute`) is discarded by the router's redirect after authentication without the observer's `didPop`/`didRemove` decrement, so `ModalRouteObserver._openCount` leaks. *Code-supported*: the flag is a process-global that starts `false`, so a cold relaunch should restore the bar — not verified here. Apple/Google sign-in not exercised; whether they leak the same way is unknown. `QIRSH_EMAIL_AUTH_ENABLED` defaults to `false` in `codemagic.yaml`, which limits exposure if left off. |
| RT-02 | S3 | REPRODUCED | Subjective (wording) | Pasting a **declined purchase** or a **failed refund** shows "It could not be read as a transaction — add it manually." The money handling is correct (nothing saved), but the copy invites the user to record a declined purchase by hand, which would put money that never moved into spend. A "this payment was declined / not completed — nothing was recorded" message would match the release intent. |
| RT-03 | S3 | REPRODUCED (text); the "never syncs" part SUSPECTED | Objective | The sign-out sheet, with Cloud consent unset (Cloud off), says "Some data has not reached the cloud yet: 1 change to accounts/budgets/goals/bills. It stays on this device and syncs when you sign back in." (42). With Cloud off nothing syncs on sign-in either; the sentence is not true for this user's state. |
| RT-04 | S4 | REPRODUCED | Objective | Arabic digits are still mixed: transaction rows and the Home/Transactions date lines render dates with Arabic-Indic digits («١٧ نوفمبر ٢٠٢٦ · ١٠:١٥ ص») while amounts, the details screen date (16) and the starter card use Western digits. |
| RT-05 | S4 | REPRODUCED | Subjective | E-mail code sheet mixes Egyptian colloquial with Modern Standard Arabic ("اكتب الكود اللي وصلك على البريد ده. راجع الرسائل غير المرغوب فيها كمان.") (02). |

Environment notes (not app defects): local magic-link template carries no code (production template not
verified); Edge Functions not served; the app's log redactor masks numbers in `debugPrint` output, which
the harness had to bypass.

## 4. NOT TESTED, and why

- **Physical device**: none available; all results are iOS Simulator, debug build. Liquid Glass rendering, performance, haptics and Face ID were not checked on hardware.
- **Store/release artifact**: a debug simulator build of `8e953d14` with local-stack defines was used, not the Codemagic IPA (G4/G5 untouched).
- **Native tab bar taps, edge-swipe back, live app-switcher UI**: no tool could tap UIKit views or perform system gestures on these simulators (simulator-control access was not granted; idb not installed).
- **Apple and Google sign-in**: require real provider accounts; not possible against a local stack. Only the e-mail code path was exercised, with the code minted locally.
- **The 6 onboarding setup steps** after first sign-in (country/currency, consent, account, SMS/Shortcut): completed programmatically on the first fresh account, not walked.
- **VoiceOver focus order and spoken labels**: not run (labels were only located through the semantics tree).
- **Push notifications**: Edge Functions and APNs unavailable.
- **iOS Shortcuts automation and the share extension** ("ShareBankMessage"): need device automation / the share sheet; not exercised.
- **Cloud sync, AI parsing, catalog sync, backup upload/restore**: consent stayed off and functions were not served.
- **Error/offline state, notification permission denied**: see item 3.
- **Delete-account confirmation dialog**: see item 2.
- **Android**: out of scope for this run (iOS simulators only).
- **Uncommitted working-tree changes** in the readiness worktree (parser declined cues and others) were not part of the build.
