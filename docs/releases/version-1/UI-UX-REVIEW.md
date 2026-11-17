# UI/UX review — Qirsh V1

Model: claude-opus-5-5 (Claude Opus 5.5) · Date: 2026-11-17 · Branch `release-readiness/v1` (worktree `v1-readiness`), uncommitted working-tree changes.

Source audit: `evidence/audits/G-ui-ux.md` (findings UX-01 … UX-23). Before images: `evidence/ui/before/`. After images: `evidence/ui/after/` (same file names as the matching before image).

## 1. What was exercised and how

| Method | What it covered | Limit |
|---|---|---|
| Running app on a simulator (audit, before) | Onboarding to the consent step, AR/EN, light/dark, iPhone 17 and iPhone SE at the largest text size. Shell screens rendered on the simulator through a temporary integration test over an in-memory database. | No backend: the signed-in `AppShell` was never reached (audit §1). |
| Running on a simulator (this fix, after) | A new simulator "Qirsh V1 Fix" (iPhone SE 3rd gen, iOS 26.5, Larger Text at the accessibility maximum, which the app clamps to 1.25x; deleted afterwards). A temporary integration test (deleted afterwards) pumped the real `TransactionsScreen`, `BudgetsScreen`, `ReportsScreen` and `TransactionDetailsScreen` with the real theme, l10n and the app's text-scale clamp over an in-memory database seeded with one account, and recorded every `FlutterError`: 0 on all four screens. Screenshots were taken with `simctl io screenshot`. | Same harness limit as the audit: no `AppShell`, no signed-in session, no real navigation stack. Only the four screens above were captured after the fix; all other visual changes are verified by widget tests only. |
| Widget tests (this fix) | Every change below has a regression test. Small-screen checks run at 320×568 and 375×667 logical size at 1.25x text (the app's maximum, `app.dart`), with the bundled Vazirmatn font loaded. | Widget tests do not run the native glass tab bar, real navigation stacks, VoiceOver itself, or real photo pixels behind headers. |
| Code inspection only | Contrast ratios (computed from the theme tokens, WCAG 2.x), the `all_expenses` category handling, close-button labels in sheets not opened in tests. | — |

Nothing in this round was exercised with VoiceOver, Switch Control, a physical device, or Android.

## 2. Findings and status

Legend. Class: O = objective, S = subjective. Fix: (a) directly fixable, (b) owner decision. Status: FIXED (with proving test), PARTIAL, OPEN (not done, no decision needed), OWNER DECISION.

| ID | Sev | Class | Fix | Status | Proof |
|---|---|---|---|---|---|
| UX-01 | S2 | O | (a) after investigation | FIXED | `test/features/transactions/manual_category_default_test.dart` |
| UX-02 | S3 | O | (b) legal surface | OWNER DECISION (not touched, per brief) | — |
| UX-03 | S3 | O | (a) | FIXED | `test/features/common/small_screen_headers_test.dart` (Transactions), `test/features/subscriptions/subscriptions_header_test.dart` (Bills) |
| UX-04 | S3 | O | (a) | FIXED | `test/features/common/close_button_labels_test.dart` |
| UX-05 | S3 | O | (a) | PARTIAL | `small_screen_headers_test.dart`, `transaction_details_small_screen_test.dart` |
| UX-06 | S3 | O | (a) | FIXED | `small_screen_headers_test.dart`; after image 45 |
| UX-07 | S3 | O | (a) / (b) brand green | PARTIAL; item 1 OWNER DECISION | ratios in §4 |
| UX-08 | S3 | O | (a) | FIXED | `small_screen_headers_test.dart`; after image 46 |
| UX-09 | S3 | O | (b) | OWNER DECISION (cap kept) | probe results in §5 |
| UX-10 | S3 | O | (a) | FIXED (truncation and 44 pt); overflow NOT REPRODUCED in tests | `transaction_details_small_screen_test.dart`; after image 47 |
| UX-11 | S3 | S | (b) onboarding flow | OWNER DECISION | — |
| UX-12 | S4 | O | (a) | FIXED | `test/features/reports/reports_empty_overview_test.dart`; after image 48 |
| UX-13 | S4 | O | (a) | FIXED | `test/features/dashboard/home_redesign_render_test.dart` (updated assertion) |
| UX-14 | S4 | O | (b) data model | OWNER DECISION | — |
| UX-15 | S3 | mixed | (b) consent flow | OWNER DECISION (not touched, including item 3, per brief) | — |
| UX-16 | S4 | O | (a) | FIXED | `test/features/settings/capture_health_tile_style_test.dart` |
| UX-17 | S4 | O | (a) | FIXED | `test/features/onboarding/onboarding_motion_alignment_test.dart` |
| UX-18 | S4 | O | (a) | FIXED | `test/features/onboarding/onboarding_motion_alignment_test.dart` |
| UX-19 | S4 | S | (b) design | OWNER DECISION | — |
| UX-20 | S4 | S | (b) consistency | OWNER DECISION | — |
| UX-21 | S4 | product | (b) copy | OWNER DECISION | — |
| UX-22 | S4 | env | — | OPEN (debug-only, no user impact; docs note) | — |
| UX-23 | S4 | docs drift | — | OPEN (documentation, outside this fix's paths) | — |

Every new or changed test was run against the unfixed code first (the library diff reversed with `git apply -R`, then reapplied): all of them failed there and pass with the fix.

## 3. Changes, the user problem, and the improvement

### UX-01 — manual expense defaulted to «كل المصروفات / All expenses»
- User problem: the add-transaction sheet opened with the budget-only category «All expenses» already chosen. A user who did not touch the field saved every expense under it, and Reports then showed "All expenses 100%".
- Existing notion reused: `BudgetEntity.allExpensesCategoryKey` is a budget-scope sentinel. The change-category sheet (`change_category_sheet.dart:210`) and the budget form (`budget_form_screen.dart:313`) already exclude it, and `category_catalog.dart:40-48` documents it as "deliberately absent … so it never appears in a category picker".
- Change (`features/transactions/manual_transaction_sheet.dart`): the manual sheet now applies the same exclusion and no longer pre-selects any category, so the existing `mtPickCategory` ("Pick a category") check fires on Save for a new entry.
- Not changed: stored transactions, budgets, sync, the seed. No migration. Editing an older transaction that is already stored under «All expenses» keeps that category unless the user picks another one (the field then shows empty, because the sentinel is no longer listed).
- Behaviour change to note: income and transfer entries also start with no category, so the user picks one (previously the first category of that type was pre-selected).

### UX-03 — unnamed "+" on Transactions and Bills
- User problem: VoiceOver announced only "button" for the main Add action.
- Change: `semanticLabel: context.l10n.mtAddTransaction` (Transactions) and `txnAddSub` (Bills) on the existing `CalmHeaderAction`. No visual change.

### UX-04 — unnamed close (X) buttons in sheets and forms
- Change: `tooltip: MaterialLocalizations.of(context).closeButtonTooltip` ("Close" / «إغلاق») on the 10 close buttons the audit lists: shared `AppSheetScaffold`, goal form, goal details, budget form, manual paste, SMS permission, merchant offers, savings, sign-in methods sheet, email-code sheet. VoiceOver reads the tooltip as the name; `labeledTapTargetGuideline` passes on the shared sheet. No visual change (tooltip appears only on long-press).

### UX-05 — targets under 44 pt (partial)
- Fixed: Transactions header search and "+" and every `CalmHeaderAction` 42 → 44 pt; Budgets/Goals/History segmented tabs now at least 44 pt tall each (track 52 pt); transaction details «Change category» pill `minHeight` 36 → 44.
- Visual change: header buttons 2 pt larger; the planning tab track 8 pt taller at default text size; the pill 8 pt taller.
- OPEN: Subscriptions filter chips (93×36), budget-form period chips (88×36), Settings "Edit" (71×36), Settings → Account name text (90×26). Not changed: these are separate widgets whose height is part of their chip styling; enlarging them changes several screens and was not needed for the other fixes.

### UX-06 — page titles breaking mid-word
- User problem: at large text on iPhone SE, "Transactions" wrapped as "Transaction / s" (before 45).
- Change: `CalmPageHeader` passes `fitTitle: true` to `QirshSectionHero`, the option Bills already used. Titles stay on one line and shrink to fit only when they would not fit. Affects every photo-header page (Transactions, Reports, Budgets, Accounts, Cards, Goals).

### UX-08 — truncated budget chips and "Budget history" tab
- User problem: "On tra…", "Close …", "Over li…", "Budge…" and a clipped "Budget history" (before 35, 46).
- Change: summary chip labels may take up to 3 lines (needed at 320 pt width for "Close to limit") and wrap only between words; a single word wider than the chip (for example "Budgets" on iPhone SE at 1.25x) is shrunk just enough to fit instead of being split ("Budget / s" was seen on the first after-capture and fixed). The chips in that row share one height (`IntrinsicHeight` + stretch). The tab track height now uses the caption's real 18 pt line height: `scale(18) × 2 + 8`, minimum 52.

### UX-10 — transaction details on small screens
- User problem: «تغيير التصني…» truncated (before 47); the audit also logged a 4 px RenderFlex overflow.
- Change: the «Change category» pill allows 2 centred lines and is 44 pt high.
- The 4 px overflow was not reproduced in widget tests at 320×568 or 375×667 at 1.25x (AR and EN, real font, manual transaction, real account row). On the simulator (iPhone SE, 1.25x, AR light) the details screen rendered with 0 FlutterErrors after the fix (after image 47). The original overflow is therefore not reproduced after the fix, but its exact cause was never isolated, so the claim is "not observed", not "root-caused".

### UX-07 — contrast (partial)
- Photo-header subtitle (light theme): subtitle is now solid white (was 80% white) and the scrim's middle stop is held at 60% navy (was 55%; the top stop was already 60%). Dark theme unchanged.
- Goal form "Deadline: optional" value and the manual-paste placeholder: `textFaint` → `textMuted` (existing token).
- Budget "On track" chip (light `success` on `successBg`): OWNER DECISION — the only passing fix changes the shared brand green (`success`/`income` `#12855C` → e.g. `#0F7650`).
- Light `textMuted` on `surfaceMuted` (4.09): OPEN — the audit names no specific usage; none was changed.
- Dark `neutral`: NOT A DEFECT. The audit computed `#667085` (the light-theme value) on the dark surface; the dark token is `#9AA3B2` (7.30:1).

### UX-12 — blank Reports overview for a new user
- Change: when the Overview has no cards, it shows the existing "Quick tip" card with the existing copy `rptAddMoreTx` (the same card the Trends tab already shows). No new strings.

### UX-13 — mixed digits in Arabic
- Change: the 8 Arabic ARB strings with Arabic-Indic digits now use Western digits like every formatted number in the app (`الصفحة 1 من 2`, `متوسط 7 أيام`, `أعلى 3 اليوم`, `آخر 7 أيام`, `ابدأ في 3 خطوات`, `1 · عملة الرسائل`, `2 · الكلمة المطلوبة`). `flutter gen-l10n` regenerated. English unchanged. The existing dashboard test that asserted `ابدأ في ٣ خطوات` now asserts the Western-digit form.

### UX-16 — green "success" capture status before any capture
- Change: when no bank message has ever been captured (and there is no failure or nudge), the tile uses the info colours (`infoBg`, `info`, `actionText`) and an info icon instead of the green shield. Captured, nudge and failure states are unchanged.

### UX-17 — restore prompt animation under Reduce Motion
- Change: the illustration's fade/scale runs only when `shouldReduceMotion(context)` is false (the same helper other screens use).

### UX-18 — brand tagline alignment
- Change: `textAlign: TextAlign.center` on the tagline, matching the centred title.

## 4. Contrast ratios (WCAG 2.x, computed from tokens)

| Pair | Before | After |
|---|---|---|
| Photo-header subtitle over a white photo area, light theme, at the scrim middle stop (worst case) | 3.25 (80% white on 55% navy) | 4.86 (white on 60% navy) |
| Same, at the scrim top stop | 3.78 | 4.86 |
| Goal form deadline value, light (on `surface` #FFFFFF) | 3.05 (`textFaint`) | 4.93 (`textMuted`) |
| Goal form deadline value, dark (on `surfaceMuted` #0C0D11) | 3.32 | 6.37 |
| Manual paste placeholder, light (on #FFFFFF) | 3.05 | 4.93 |
| Manual paste placeholder, dark (on #0C0D11) | 3.32 | 6.37 |
| Budget "On track" chip, light `#12855C` on `#E1F3EC` | 4.02 | unchanged (owner decision; `#0F7650` would give 4.89) |
| Light `textMuted` on `surfaceMuted` | 4.09 | unchanged (no usage identified) |
| Dark `neutral` `#9AA3B2` on surface `#121317` | 7.30 (audit's 3.73 used the light value) | unchanged |

The header numbers assume the worst case (a pure-white area of the photo directly behind the text). Real photo pixels were not sampled in this round.

## 5. UX-09 — text-scale cap (1.25x): what breaks above it

The cap was kept. The new small-screen tests were re-run, as temporary copies, at higher scales:

- 1.6x: at 320 pt width the transaction-details «Change category» label needs a third line and is truncated. Budgets header, tabs and chips and the Transactions header passed at 320 and 375 pt.
- 2.0x: additionally the «Budget history» / «سجل الميزانيات» tab label is cut off at 320 and 375 pt, and transaction details truncates at 375 pt too.
- Not probed above 1.25x: Dashboard, add-transaction sheet, Settings, Goals, Accounts, Cards, forms, onboarding.

Recommendation: keep 1.25x for V1 and record it as a known limitation, or raise the cap only after the remaining primary screens have overflow tests at the new value. Raising it is not shown to be safe by this round.

## 6. After images

Captured on the simulator described in §1, same names as the before images, resized to at most 400 KB each:

| Before | After | What to compare |
|---|---|---|
| `before/45-se-en-dark-transactions-title-break.png` | `after/45-se-en-dark-transactions-title-break.png` | "Transactions" on one line; search and "+" at 44 pt |
| `before/46-se-en-dark-budgets-truncation.png` | `after/46-se-en-dark-budgets-truncation.png` | "Budget history" fully visible; "On track", "Close to limit", "Over limit", "Budgets" not truncated; taller tab track |
| `before/47-se-ar-light-tx-details-overflow.png` | `after/47-se-ar-light-tx-details-overflow.png` | «تغيير التصنيف» on two full lines in a 44 pt pill. The category shows «Groceries»: the after transaction was saved under a real category because UX-01 no longer allows «All expenses». The English category name in the Arabic UI comes from the synthetic test row, not from the fix. |
| `before/48-se-en-dark-reports-empty.png` | `after/48-se-en-dark-reports-empty.png` | Overview shows the "Quick tip" card instead of blank space |

Not captured after the fix (widget tests only): Bills "+" label (UX-03, not visual), close-button names (UX-04, not visual), photo-header subtitle contrast on Accounts (before 28), budget/goal form text colour, capture status tile (before 30), brand tagline, restore illustration, Arabic digits on the dashboard (before 21).

## 7. NOT TESTED

These stay NOT TESTED after this round:

- `AppShell` and the native glass tab bar, tab switching and real back stacks.
- Everything that needs a signed-in session: cold-start consent re-ask, Settings → Account signed in, sign-out, delete-account flow beyond its entry screen, sync status sheet, backup restore end to end, cloud consent ON states.
- The Privacy screen.
- VoiceOver and Switch Control navigation and focus order (only semantics labels and tooltips were checked in tests).
- Capture via Shortcuts / Share extension, push and local notifications, App Lock (Face ID), permission-denied states.
- Keyboard over long forms on iPhone SE (goal and budget forms).
- Offline and error states of network-backed surfaces (coupons, announcements, catalog sync).
- Android (TalkBack, back gesture, SMS permission sheet).
- Real photo pixels behind header subtitles (contrast is computed for the worst case only).
- The UX-10 4 px overflow on a device (not reproduced in widget tests).
- Text scales above 1.25x on any screen not listed in §5.
