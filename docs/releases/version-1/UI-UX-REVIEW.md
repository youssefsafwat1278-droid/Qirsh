# UI/UX review — Qirsh V1

Model: claude-opus-5-5 (Claude Opus 5.5) · Date: 2026-11-17 · Branch `release-readiness/v1` (worktree `v1-readiness`). Round 1 is committed; round 2 (same model) is committed as `34ccc9e9`, referred to below as commit "round 2".

Assessed at: the candidate **`a157e68e`** ([RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)). Round 3 changed the UI substantially; see §8. Sections 1–7 describe rounds 1 and 2 as written (originally assessed at `50957c06`).

How each item is verified is labelled: **widget test** (Flutter test harness, no device), **simulator** (rendered on an iOS simulator), or **computed** (ratio from tokens). Round 2 itself used widget tests and computation only. Afterwards, runtime verifier J walked the signed-in app on iOS simulators at `8e953d14` (which contains round 2), and runtime verifier M checked the RT-01 fix at `0095a239` (§2a). No device was used.

Source audit: `evidence/audits/G-ui-ux.md` (findings UX-01 … UX-23). Before images: `evidence/ui/before/`. After images: `evidence/ui/after/` (same file names as the matching before image).

## 1. What was exercised and how

| Method | What it covered | Limit |
|---|---|---|
| Running app on a simulator (audit, before) | Onboarding to the consent step, AR/EN, light/dark, iPhone 17 and iPhone SE at the largest text size. Shell screens rendered on the simulator through a temporary integration test over an in-memory database. | No backend: the signed-in `AppShell` was never reached (audit §1). |
| Running on a simulator (this fix, after) | A new simulator "Qirsh V1 Fix" (iPhone SE 3rd gen, iOS 26.5, Larger Text at the accessibility maximum, which the app clamps to 1.25x; deleted afterwards). A temporary integration test (deleted afterwards) pumped the real `TransactionsScreen`, `BudgetsScreen`, `ReportsScreen` and `TransactionDetailsScreen` with the real theme, l10n and the app's text-scale clamp over an in-memory database seeded with one account, and recorded every `FlutterError`: 0 on all four screens. Screenshots were taken with `simctl io screenshot`. | Same harness limit as the audit: no `AppShell`, no signed-in session, no real navigation stack. Only the four screens above were captured after the fix; all other visual changes are verified by widget tests only. |
| Widget tests (this fix) | Every change below has a regression test. Small-screen checks run at 320×568 and 375×667 logical size at 1.25x text (the app's maximum, `app.dart`), with the bundled Vazirmatn font loaded. | Widget tests do not run the native glass tab bar, real navigation stacks, VoiceOver itself, or real photo pixels behind headers. |
| Code inspection only | Contrast ratios (computed from the theme tokens, WCAG 2.x), the `all_expenses` category handling, close-button labels in sheets not opened in tests. | — |
| Widget tests (round 2) | A shared harness (`test/features/common/primary_screen_harness.dart`) pumps 10 primary screens — Home, Transactions, Budgets, Goals, Budget history, Reports, Bills, Budget form, Settings hub, Settings → Account — with the real theme, l10n and bundled Vazirmatn font over an in-memory database seeded with 3 synthetic transactions (plus 3 synthetic budgets and 2 synthetic bills injected at the provider level). It walks the semantics tree screenful by screenful for tap targets, and records every `FlutterError` and every cut-off paragraph at a given text scale. | Widget tests only. No `AppShell`/native tab bar, no signed-in session, no network-backed content (coupons, offers and ads are off), no keyboard, no real photos. A pass is not runtime verification. |

Nothing in this round was exercised with VoiceOver, Switch Control, a physical device, or Android.

## 2. Findings and status

Legend. Class: O = objective, S = subjective. Fix: (a) directly fixable, (b) owner decision. Status: FIXED (with proving test), PARTIAL/PARTLY, OPEN (not done, no decision needed), OWNER DECISION.

| ID | Sev | Class | Fix | Status | Proof |
|---|---|---|---|---|---|
| UX-01 | S2 | O | (a) after investigation | FIXED | `test/features/transactions/manual_category_default_test.dart` |
| UX-02 | S3 | O | (b) legal surface | OWNER DECISION (not touched, per brief) | — |
| UX-03 | S3 | O | (a) | FIXED | `test/features/common/small_screen_headers_test.dart` (Transactions), `test/features/subscriptions/subscriptions_header_test.dart` (Bills) |
| UX-04 | S3 | O | (a) | FIXED | `test/features/common/close_button_labels_test.dart` |
| UX-05 | S3 | O | (a) | PARTLY: FIXED (round 2) on the 10 primary screens scanned; sheets and secondary screens not scanned | widget test: `test/features/common/primary_screens_tap_targets_test.dart` (+ round-1 tests); table §4b |
| UX-06 | S3 | O | (a) | FIXED | `small_screen_headers_test.dart`; after image 45 |
| UX-07 | S3 | O | (a) | FIXED (round 2) with existing tokens, no brand-colour change; photo-header pixels still computed for the worst case only | widget test: `test/core/theme/round2_contrast_test.dart`, `test/features/referrals/referrals_entitlement_contrast_test.dart`; ratios §4 |
| UX-08 | S3 | O | (a) | FIXED | `small_screen_headers_test.dart`; after image 46 |
| UX-09 | S3 | O | (b) | OWNER DECISION (cap kept). Round 2: cap guarded by test, 1 above-cap breakage fixed, remaining list measured | widget test: `test/features/common/primary_screens_text_scale_test.dart`; list §5 |
| UX-10 | S3 | O | (a) | FIXED (truncation and 44 pt); overflow NOT REPRODUCED in tests | `transaction_details_small_screen_test.dart`; after image 47 |
| UX-11 | S3 | S | (b) onboarding flow | OWNER DECISION (re-checked in round 2, §3b) | — |
| UX-12 | S4 | O | (a) | FIXED | `test/features/reports/reports_empty_overview_test.dart`; after image 48 |
| UX-13 | S4 | O | (a) | FIXED | `test/features/dashboard/home_redesign_render_test.dart` (updated assertion) |
| UX-14 | S4 | O | (b) data model | OWNER DECISION (re-checked in round 2, §3b) | — |
| UX-15 | S3 | mixed | (b) consent flow | OWNER DECISION (not touched, including item 3, per brief) | — |
| UX-16 | S4 | O | (a) | FIXED | `test/features/settings/capture_health_tile_style_test.dart` |
| UX-17 | S4 | O | (a) | FIXED | `test/features/onboarding/onboarding_motion_alignment_test.dart` |
| UX-18 | S4 | O | (a) | FIXED | `test/features/onboarding/onboarding_motion_alignment_test.dart` |
| UX-19 | S4 | S | (b) design | OWNER DECISION (re-checked in round 2, §3b) | — |
| UX-20 | S4 | S | (b) consistency | OWNER DECISION (re-checked in round 2, §3b) | — |
| UX-21 | S4 | product | (b) copy | OWNER DECISION (re-checked in round 2, §3b) | — |
| UX-22 | S4 | env | — | OPEN (debug-only, no user impact; docs note) | — |
| UX-23 | S4 | docs drift | — | OPEN (documentation, outside this fix's paths) | — |

Every new or changed test was run against the unfixed code first (the library diff reversed with `git apply -R`, then reapplied): all of them failed there and pass with the fix. Round 2 repeated this for its own diff (§3a, "Fail-before").

## 2a. Status reconciliation after the simulator runs

Simulator evidence: `evidence/audits/J-signed-in-runtime.md` (J, `8e953d14`, local stack, Cloud and AI off, functions not served) and `evidence/audits/M-rt01-simulator-check.md` (M, `0095a239`). Screenshots: `evidence/ui/signed-in/`. Issue IDs refer to ISSUES.md.

| Item | Status | Evidence |
|---|---|---|
| UX-01 manual category | FIXED; seen on a simulator | J: the category field is empty on open and validation fires |
| UX-05 tap targets, UX-07 contrast (round 2) | Widget tests as above; on a simulator no visible layout shift from the tap-target changes and coherent light/dark rendering on the walked screens (J). Contrast was not measured on a simulator | J |
| UX-09 text-scale cap | OWNER DECISION. J: at the largest system size the app rendered at its 1.25× cap without clipping on the captured screens, iPhone 17 and SE. That is the capped rendering, not full accessibility sizes | J |
| UX-13 Arabic digits | FIXED for the dashboard amounts; dates elsewhere still use Arabic-Indic digits beside Western amounts — new finding RT-04 | J; V1-068 |
| RT-01 tab bar missing after email sign-in | FIXED IN CODE `45ea901a`; seen fixed on a simulator for email sign-in, with a control build reproducing the defect (M). Apple/Google sign-in, app lock, cold relaunch and a device NOT TESTED; build 147 has the defect | J, M; V1-065 |
| RT-02 paste of a declined payment invited a manual add | PARTLY FIXED (`0095a239`, `1be44623`, single-message text; unit test). Batch paste still "Not understood". NOT TESTED at runtime after the fix | J; V1-066 |
| RT-03 sign-out sheet with Cloud off says changes sync on sign-in | OWNER DECISION on wording (B26) | J; V1-067 |
| RT-04 dates in Arabic-Indic digits next to Western amounts | OPEN | J; V1-068 |
| RT-05 email code sheet mixed Egyptian and Modern Standard Arabic | FIXED IN CODE `0095a239` (strings read by reviewer L); NOT TESTED on screen after the fix | J; V1-069 |
| App-switcher cover | The snapshot iOS stores shows only the cover (J). Live switcher, inactive state and a device NOT TESTED | J; V1-034 |

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

### UX-05 — targets under 44 pt (round 1 part; the rest is in §3a)
- Fixed: Transactions header search and "+" and every `CalmHeaderAction` 42 → 44 pt; Budgets/Goals/History segmented tabs now at least 44 pt tall each (track 52 pt); transaction details «Change category» pill `minHeight` 36 → 44.
- Visual change: header buttons 2 pt larger; the planning tab track 8 pt taller at default text size; the pill 8 pt taller.
- Left OPEN in round 1, fixed in round 2 (§3a): Subscriptions filter chips (93×36), budget-form period chips (88×36), Settings "Edit" (71×36), Settings → Account name text (90×26).

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

### UX-07 — contrast (round 1 part; the rest is in §3a)
- Photo-header subtitle (light theme): subtitle is now solid white (was 80% white) and the scrim's middle stop is held at 60% navy (was 55%; the top stop was already 60%). Dark theme unchanged.
- Goal form "Deadline: optional" value and the manual-paste placeholder: `textFaint` → `textMuted` (existing token).
- Budget "On track" chip: round 1 recorded this as needing the brand green. Round 2 found a passing combination of existing tokens and fixed it without touching the brand colour (§3a).
- Light `textMuted` on `surfaceMuted` (4.09): round 2 identified the usage (the app-wide default text-field label and hint) and fixed it (§3a).
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

## 3a. Round 2 changes (commit "round 2")

All round-2 items are verified by **widget test** only. None was run on a simulator.

### UX-05 — remaining tap targets
- Method: `primary_screen_harness.dart` lists every tappable semantics node below 44×44 on the 10 primary screens (each screen scrolled through, EN and AR, 390×844 and 320×568). It uses the skip rules of Flutter's `iOSTapTargetGuideline` with one correction: the guideline skips any node touching a scrollable's edge, which hides every chip in a horizontal chip row (the chips touch the row's top and bottom). The harness only skips nodes touching a scrollable's edge along its scroll axis. Before the fix this scan found the audit's four controls plus eight more (table §4b).
- Changes (visible size kept; hit area enlarged), reusing the existing widgets:
  - `ActivityChip` (Transactions kind/filter chips, Bills «Subscriptions / Instalments» chips): a 44×44 minimum hit box around the unchanged 36 pt pill. Bills chip `Wrap.runSpacing` 8 → 0 so wrapped rows keep the same 8 pt gap. The Transactions chip row is 8 pt taller.
  - `SegmentedControl` (budget-form period, add-transaction type, change-category sheet): the 4 pt inset now applies to the sliding thumb only; each segment's hit area is the full 44 pt track. No visual change.
  - `AppPillTabBar` (Transactions «Transactions / Bills», Reports «Overview / Trends / Details»): track and lens drawn as before; the tab row spans the full 44 pt height (it was 36 inside the border and inset). No visual change.
  - Budget history period filter chips (32 pt tall): 44×44 hit box around the unchanged chip; `runSpacing` 8 → 0.
  - Budget row «Delete» menu button: 40 → 44 wide.
  - `SectionHeader` and Home's large-text section title: the trailing link («See all», «Details», «All») gets a 44×44 hit box around the unchanged text. Home section title rows become up to about 18 pt taller.
  - Home range selector («This month»): minimum 44 pt tall; the two 8 pt gaps above and below were removed, so the layout moves by about 2 pt.
  - Home insight action («Add to a goal», «Details»): `minimumSize` 40 → 44 pt tall.
  - Settings hub profile «Edit»: 36 → 44 pt (visibly 8 pt taller). Settings → Account «Edit»: 40 → 44 pt.
  - Settings → Account name: the tap area is full width and at least 44 pt tall; the 12 pt / 2 pt gaps around the name became its padding (layout moves 4 pt).
- Test: `primary_screens_tap_targets_test.dart` (40 cases) asserts no target below 44×44 and names any that is.
- Not scanned: sheets (add transaction, bill form, goal form), Accounts, Cards, Goal details, Privacy, onboarding. Their controls are not claimed.

### UX-07 — remaining contrast, fixed with existing tokens
Local fixes were tried first; each pair below passes with a token already in the design system, so no brand-colour change was needed.
- Budgets «On track» chip (number and label, light): `success` → `textSecondary` on the same `successBg` (4.02 → 8.13). Dark keeps `success` (7.29). The chip stays green-tinted; its text matches the neutral «Budgets» chip.
- Shared `AppStatusPill`, success tone (e.g. «Confirmed» on transaction details, Home deltas, goal and consent status; 12 pt text): same change, light only (4.02 → 8.13). Dark unchanged (7.29).
- Referrals active-entitlement line: text was `onSuccess` (white in light) on `successBg`, 1.15:1. Now `textSecondary` in both states (light 8.13, dark 9.18); the icon uses `success` (a 3:1 graphic, 4.02).
- App-wide default text field (`AppTheme` input decoration; used by fields that do not set their own styles, e.g. bill, card, account, plan, allocation forms): label `textMuted` and hint `textMuted` at 60% → both `textSecondary`. See §4 for each theme. Trade-off: the hint is now the same colour as the label and closer to typed text (typed text stays `textPrimary`).
- If the owner prefers green text on the light chips instead, the alternative is the brand change: light `success` and `income` `#12855C` → `#0F7650` (4.89 on `successBg`, 5.63 on white). Blast radius: the token is shared, 66 `success` references in 33 files and 23 `income` references in 7 files, plus every place `budgetState()` returns `success`. Not done.

### UX-09 — text scale (cap kept at 1.25x)
- The cap in `app.dart` is unchanged.
- New guard: `primary_screens_text_scale_test.dart` asserts that the 10 primary screens lay out with no Flutter error at 1.25x, EN and AR, 320×568 and 390×844 (40 cases).
- Above the cap the same test file only measures (1.5x, 2.0x, 3.1x ≈ the largest iOS accessibility size) and prints the breakages; it asserts nothing there. The list is in §5.
- Fixed (small): Settings hub destination tiles had a fixed 88 pt height and overflowed by 8 pt at 2x; they now have a minimum of 88 pt, the title may take 2 lines, and the two tiles in a row share the taller height. Regression test: «Settings hub tiles do not overflow at 2.0x» (320 and 390 wide).

### Fail-before
The round-2 library diff (11 files) was reversed with `git apply -R`, the four new test files were run, and the diff was reapplied:
- Before: 44 failures. Tap targets: 36 of 40 cases failed, listing the controls in §4b (for example `"Daily" 86x36`, `"See all" 42x20`, `"Delete" 40x44`, `"Edit" 140x40`). Contrast: «On track» chip (light), success pill (light), referrals line (light) and the default text field (light, dark and sheet) failed. Settings hub at 2.0x failed (320 and 390 wide). The dark chip and pill cases and the 1.25x cap cases passed before, as expected (those pairs and layouts were already fine).
- After: all 97 cases in the four files pass (**widget test**).
- The harness also lets a failing case end cleanly: tests give `FlutterError.onError` back (`stopCollectingErrors()`) before any `expect`, because flutter_test otherwise hangs the run after a failure.

## 3b. Round 2 decisions on UX-11, UX-14, UX-19, UX-20, UX-21

- **UX-11 (disabled «Start» on every setup step) — OWNER DECISION.** The disabled state is deliberate and correct for its meaning: «Start» finishes onboarding and is enabled once all 6 steps are done (`setup_screen.dart` `_finishBar`; the label colour is styled as "readable, still clearly off"). No one-line state or label correction fixes the affordance problem; every fix changes the onboarding flow (when the bar appears, a new «Continue» on step 1, or auto-advancing the pre-selected country). Question: how should a user move through setup? Options: (1) hide the finish bar until the last step; (2) keep it and add a «Continue» on step 1 that accepts the pre-selected country; (3) leave as is. Recommendation: (2), the smallest flow change.
- **UX-14 (manual entry shows Source «Unspecified») — OWNER DECISION.** Manual entries are saved with `TransactionSourceEntity.unknown`, which the parser and backfill paths also produce, and the raw message is the note or the literal `Manual transaction`. The details screen cannot tell a manual entry from an unparsed one, so any label such as the existing «You added it yourself» would sometimes be false. Options: (1) add a `manual` source (data model + sync mapping + migration); (2) hide the Source row when it is unknown; (3) leave. Recommendation: (2) for V1 (display only, nothing false), (1) later.
- **UX-19 (story copy over the illustration and coin dots) — OWNER DECISION.** Subjective layout/art direction; no text is cut off or unreadable by a measurable rule in the audit. Options: narrow the text column on small screens, or lower the art opacity behind the text. Recommendation: lower art opacity behind the text block on screens under 375 pt.
- **UX-20 (inconsistent "+", hug-width «Create goal», «SAR» vs «ريال», floating field labels) — OWNER DECISION.** These are consistency preferences between existing, working patterns; none fails a measurable rule. Choosing one pattern is a design decision. Recommendation: one currency label style in Arabic (the Currency helper's Arabic label) and full-width form buttons, decided once and applied together.
- **UX-21 (What's new 1.0.0 lists beta deltas) — OWNER DECISION.** Product copy. Recommendation: a short «Welcome to Qirsh 1.0» note for 1.0.0.

## 4. Contrast ratios (WCAG 2.x, computed from tokens)

| Pair | Before | After |
|---|---|---|
| Photo-header subtitle over a white photo area, light theme, at the scrim middle stop (worst case) | 3.25 (80% white on 55% navy) | 4.86 (white on 60% navy) |
| Same, at the scrim top stop | 3.78 | 4.86 |
| Goal form deadline value, light (on `surface` #FFFFFF) | 3.05 (`textFaint`) | 4.93 (`textMuted`) |
| Goal form deadline value, dark (on `surfaceMuted` #0C0D11) | 3.32 | 6.37 |
| Manual paste placeholder, light (on #FFFFFF) | 3.05 | 4.93 |
| Manual paste placeholder, dark (on #0C0D11) | 3.32 | 6.37 |
| Budget "On track" chip, light: text on `successBg` `#E1F3EC` (round 2) | 4.02 (`success` `#12855C`) | 8.13 (`textSecondary` `#3D4660`) |
| Budget "On track" chip, dark: `success` `#2FCB78` on `#0E2A18` | 7.29 | 7.29 (unchanged) |
| `AppStatusPill` success tone, light (round 2) | 4.02 | 8.13 |
| `AppStatusPill` success tone, dark | 7.29 | 7.29 (unchanged) |
| Referrals active-entitlement text, light (round 2) | 1.15 (white on `#E1F3EC`) | 8.13 |
| Referrals active-entitlement text, dark (round 2) | 15.41 | 9.18 |
| Default text-field label, light, on the field fill (`surfaceMuted` 86% over white = `#EAEDF4`) (round 2) | 4.20 (`textMuted`) | 7.99 (`textSecondary`) |
| Default text-field hint, light (round 2) | 2.18 (`textMuted` at 60%) | 7.99 |
| Default text-field label, dark, fill `#0E0F13` (round 2) | 6.28 | 11.41 |
| Default text-field hint, dark (round 2) | 2.99 | 11.41 |
| Default text-field label, navy sheet theme, fill `#113497` (round 2) | 3.31 | 5.94 |
| Default text-field hint, navy sheet theme (round 2) | 2.04 | 5.94 |
| Light `textMuted` on `surfaceMuted` (the 4.09 pair) | 4.09 | its usage (the default field fill) is fixed above |
| Dark `neutral` `#9AA3B2` on surface `#121317` | 7.30 (audit's 3.73 used the light value) | unchanged |
| Budget-form amount placeholder, `textFaint` (amountHero, large text, 3:1 applies) | 3.05 | unchanged (passes 3:1 as large text) |
| Disabled button text (`disabledFg`) | 3.05 | unchanged (WCAG exempts inactive controls) |

Round-2 rows are asserted on the rendered widgets (chip, pill, referrals line) or on the theme's own values (text field) by **widget test**: `test/core/theme/round2_contrast_test.dart`, `test/features/referrals/referrals_entitlement_contrast_test.dart`.

## 4b. Tap targets on the primary screens (widget test, 390×844, EN, 1.0x)

| Control | Screen | Before (pt) | After (pt) | Visible change |
|---|---|---|---|---|
| Filter chips «Subscriptions / Instalments» (`ActivityChip`) | Bills | 130×36, 117×36 | 130×44, 117×44 | none (row 8 pt taller) |
| Kind and filter chips (`ActivityChip`) | Transactions | 36 tall (icon-only filter 38×36) | ≥ 44×44 | none (row 8 pt taller) |
| «Transactions / Bills» tabs (`AppPillTabBar`) | Transactions | 171×36 | 171×44 | none |
| «Overview / Trends / Details» tabs (`AppPillTabBar`) | Reports | 114×36 | 114×44 | none |
| Period segments (`SegmentedControl`) | Budget form | 86×36 | 86×44 | none |
| Period filter chips | Budget history | 41–73×32 | ≥ 44×44 | none (rows re-spaced) |
| Row «Delete» menu | Budgets | 40×44 | 44×44 | none |
| «See all», «Details», «All» section links | Home | 16–43×20 | ≥ 44×44 | section title rows taller |
| Range selector «This month» | Home | 108×26 | 108×44 | ~2 pt layout shift |
| «Add to a goal» / «Details» insight action | Home | 91×40 | 91×44 | 4 pt taller |
| Profile «Edit» | Settings hub | 59×36 | 59×44 | 8 pt taller |
| «Edit» | Settings → Account | 140×40 | 140×44 | 4 pt taller |
| Name text | Settings → Account | 212×26 | full width × 44 | 4 pt layout shift |

After the fix the scan reports no target below 44×44 on any of the 10 screens, EN and AR, at 390×844 and 320×568 (**widget test**).

The header numbers assume the worst case (a pure-white area of the photo directly behind the text). Real photo pixels were not sampled in this round.

## 5. UX-09 — text-scale cap (1.25x): what breaks above it

The cap was kept. The new small-screen tests were re-run, as temporary copies, at higher scales:

- 1.6x: at 320 pt width the transaction-details «Change category» label needs a third line and is truncated. Budgets header, tabs and chips and the Transactions header passed at 320 and 375 pt.
- 2.0x: additionally the «Budget history» / «سجل الميزانيات» tab label is cut off at 320 and 375 pt, and transaction details truncates at 375 pt too.
- Not probed above 1.25x: Dashboard, add-transaction sheet, Settings, Goals, Accounts, Cards, forms, onboarding.

Recommendation: keep 1.25x for V1 and record it as a known limitation, or raise the cap only after the remaining primary screens have overflow tests at the new value. Raising it is not shown to be safe by this round.

### 5a. Round 2 measurement (widget test, not a support claim)

**Important.** The app clamps text to 1.25x. Testing at 1.25x tests the app's capped scale; it is NOT verification of the device's full accessibility text sizes. Text sizes above the cap remain unsupported by the app, and above-cap layouts are NOT TESTED on any simulator or device. The rows below come from widget tests that pump the 10 primary screens with the scale forced above the cap (`primary_screens_text_scale_test.dart`, "above-cap measurement" cases, which print and assert nothing).

At the cap (1.25x), all 10 screens lay out with no Flutter error in EN and AR at 320×568 and 390×844 (asserted).

Fixed in round 2: Settings hub destination tiles overflowed by 8 pt at 2.0x (fixed height 88 pt) — now a minimum height, 2-line title (asserted at 2.0x).

Remaining layout errors (RenderFlex overflow) above the cap:

| Screen | 1.5x | 2.0x | 3.1x (≈ largest iOS size) | Where |
|---|---|---|---|---|
| Transactions list rows | 320: 5.7 px right (EN) | 320: 42–62 px right | 320 and 390: 86–182 px right | meta line of `AppTransactionRow` (`app_transaction_row.dart`): the «Under review» badge is not flexible |
| Settings → Account | — | 320 EN: 40 px right | 320 and 390: 20–158 px right | `SettingsV2Row` (`settings_v2.dart`): the non-flexible «Add your number» value widget on the phone row |
| Settings hub | — | fixed | 30 px bottom | another fixed-height block on the hub at 3.1x (not isolated) |
| Budget form | — | — | 320: 68–132 px; 390 EN: 62 px right | segmented period control / category grid row |
| Bills | — | — | 320: 10–54 px right | bills list rows |
| Reports | — | — | 320: 22–35 px right | tab track / category rows |
| Home | — | — | 320: 10 px right | hero row |

Text cut off (ellipsis) above the cap, not errors: one-line list rows (merchant names, «time · category» meta lines, the greeting name), Home quick-action labels («Paste SMS», «Budget», «Goals») and hero labels, Settings hub tile subtitles, the «Budget history» tab label (from 2.0x), the budget-form segment labels and category tiles (from 2.0x), and the Budget history / Goals empty-state description at 320 pt.

Why the rest was not fixed now: each remaining overflow needs a layout change in a shared row (`AppTransactionRow`, `SettingsV2Row`, `SegmentedControl`) that alters every screen at the default size (for example making the badge or value flexible halves the title's width), which is beyond a small fix. They are the work list for raising the cap.

Also seen during the measurement (not a text-scale issue, outside UX-09): Home in Arabic formats transaction dates with Arabic-Indic digits («١٧ نوفمبر ٢٠٢٦ · 5:28 ص»), next to Western-digit times and amounts — the same mixed-digit inconsistency as UX-13, in date formatting rather than in the ARB strings. Not changed in round 2.

## 6. After images

Round 2 added no images: its changes were verified by widget tests only, and these images predate it (for example image 46 shows the pre-round-2 «On track» colour and 36 pt chips).

Captured on the simulator described in §1, same names as the before images, resized to at most 400 KB each:

| Before | After | What to compare |
|---|---|---|
| `before/45-se-en-dark-transactions-title-break.png` | `after/45-se-en-dark-transactions-title-break.png` | "Transactions" on one line; search and "+" at 44 pt |
| `before/46-se-en-dark-budgets-truncation.png` | `after/46-se-en-dark-budgets-truncation.png` | "Budget history" fully visible; "On track", "Close to limit", "Over limit", "Budgets" not truncated; taller tab track |
| `before/47-se-ar-light-tx-details-overflow.png` | `after/47-se-ar-light-tx-details-overflow.png` | «تغيير التصنيف» on two full lines in a 44 pt pill. The category shows «Groceries»: the after transaction was saved under a real category because UX-01 no longer allows «All expenses». The English category name in the Arabic UI comes from the synthetic test row, not from the fix. |
| `before/48-se-en-dark-reports-empty.png` | `after/48-se-en-dark-reports-empty.png` | Overview shows the "Quick tip" card instead of blank space |

Not captured after the fix (widget tests only): Bills "+" label (UX-03, not visual), close-button names (UX-04, not visual), photo-header subtitle contrast on Accounts (before 28), budget/goal form text colour, capture status tile (before 30), brand tagline, restore illustration, Arabic digits on the dashboard (before 21).

## 7. Not exercised on a running app (NOT TESTED)

Updated after the simulator runs J and M (§2a). Seen on a simulator since round 2, and therefore removed from this list: the signed-in `AppShell` and the native tab bar (J, M; tabs switched through the tab provider, not native taps), the Settings hub signed in, sign-out sheet and sign-back-in, delete-account entry screen, the Privacy screen (J), and the round-2 screens as part of J's walk. Simulator only; no device. These stay NOT TESTED:

- Round-2 contrast and tap targets measured on a running app (J saw the screens; it did not measure ratios or target sizes). The after-images in §6 predate round 2.
- Text sizes above the app's 1.25x cap on any simulator or device (unsupported; §5a lists widget-test measurements only).
- Tap targets on screens outside the 10 scanned (sheets, Accounts, Cards, Goal details, Privacy, onboarding).

- Tab bar after Apple or Google sign-in, after app lock, and after a cold relaunch.
- Cold-start consent re-ask, the delete-account confirmation dialog and later steps, sync status sheet, backup restore end to end, Cloud or AI consent ON states (J ran with consent off and no functions).
- The consent withdraw control on the Privacy screen (not opened by J).
- Paste copy (RT-02) and the email code sheet text (RT-05) after their fixes.
- VoiceOver and Switch Control navigation and focus order (only semantics labels and tooltips were checked in tests).
- Capture via Shortcuts / Share extension, push and local notifications, App Lock (Face ID), permission-denied states.
- Keyboard over long forms on iPhone SE (goal and budget forms).
- Offline and error states of network-backed surfaces (coupons, announcements, catalog sync).
- Android (TalkBack, back gesture, SMS permission sheet).
- Real photo pixels behind header subtitles (contrast is computed for the worst case only).
- The UX-10 4 px overflow on a device (not reproduced in widget tests).
- Text scales above 1.25x on any screen not listed in §5.

## 8. Round 3 (closure round, 2026-11-17 to 2026-11-18)

Implemented by the accessibility and consent specialists (AI agents, `claude-opus-5-5`); details in [`evidence/closure/a11y.md`](evidence/closure/a11y.md) and [`evidence/closure/consent.md`](evidence/closure/consent.md). Reviewed by T at `7577f347` and `7dd6efa8` (accessibility: ACCEPT at `7dd6efa8`). Verification is widget tests and computed contrast only; **nothing in round 3 was seen on a simulator or a device.**

| Item | Round-3 state | Verification |
|---|---|---|
| UX-09 text scale | **Cap removed** (`clamp(minScaleFactor: 0.8)`); §5 and §3a "cap kept" are superseded. A gate over 32 screens at 1.0×–3.1×, Arabic and English, fails on any ellipsis truncation; 3 collapsed navigation titles allowlisted | 128/128 (a11y); T re-ran it and a planted truncation failed it. Clipping **without** an ellipsis is not detected (V1-105) |
| UX-05 tap targets | 80 of 80 measured targets ≥ 44 pt | widget test |
| UX-07 contrast for new text | Hero "Manually entered balance" fixed 3.91 → 5.25:1; other new texts 4.52–8.58:1 | computed |
| UX-02 legal links | Privacy Policy and Terms open with Cloud off, before consent (decision 3.5) | unit tests |
| UX-11 country step | All countries with a verified-coverage note (3.7) | tests |
| UX-15 consent step | First-run consent with "Agree and enable" / "Continue locally" (3.8) | tests; T probed both panels at 3.1× (no layout error) |
| UX-13 / RT-04 digits | Western digits in Arabic dates on Home and charts (V1-068) | tests |
| Balance labels | "Manually entered balance" / "Last balance reported by the bank" with time (3.14) | tests |
| Move to review | New control on transaction details | tests |
| Stacked selectors at large text | Keep button semantics and selection (SP-13) | `stacked_choices_test` (implementer only) |
| FR-12 | Legacy `all_expenses` row fixed; label/hint colour, income/transfer tests, overlap not done | test |

Not exercised in round 3: VoiceOver, any device, the native tab bar and system UI at large sizes, onboarding sub-steps on a running app. Device checks: MANUAL-DEVICE-TESTS.md MDT-IOS-31 (new expectations) and MDT-IOS-R3-14 … -16.

