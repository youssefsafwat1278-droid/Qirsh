# UI/UX and accessibility audit — Qirsh V1
Model: claude-opus-5-5 (Claude Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: UI/UX and accessibility specialist (AI agent)

Screenshots: `docs/releases/version-1/evidence/ui/before/` (40 PNGs, synthetic data only; "h17" = iPhone 17 at default text size, "se" = iPhone SE 3rd gen at the largest accessibility text size, which the app clamps to 1.25x). Build and runs were done in the worktree `.claude/worktrees/v1-ui-audit` (detached at `ab5dc10a`). No tracked file was edited. Two temporary integration-test files were created there for the run, then deleted (`git status` clean afterwards).

## 1. Scope covered / not covered

### How the running interface was exercised (and its limit)

1. **Build.** `PUB_CACHE=$HOME/.pub-cache flutter build ios --simulator --debug` in `v1-ui-audit/app` → `✓ Built build/ios/iphonesimulator/Runner.app` (Xcode build 364 s, exit 0). No backend keys were passed, so Cloud is off and auth runs on `StubAuthService` (debug only; `core/auth/auth_service.dart:39`, which is local and makes no network calls).
2. **Real app, driven by taps.** I installed the app on two new simulators that I created, booted and later deleted: "Qirsh V1 Audit" (iPhone 17, iOS 26.5) and "Qirsh V1 Audit SE" (iPhone SE 3rd gen). On those I walked language choice, the welcome story (2 pages), the brand screen, sign-in, setup step 1 (country) and setup step 2 (the cloud/AI consent step). I covered Arabic and English, light and dark, and default text size plus `accessibility-extra-extra-extra-large`.
3. **Hard limit: the signed-in shell cannot be reached without a backend.** The consent step's "Continue locally" always fails with "Your settings could not be saved" (screens 10, 19). The consent capability is only issued when a real SDK session exists (`core/session/app_session.dart:1427-1440`), so in a build with no credentials onboarding can never finish. Setting the session directly from an integration test also hung (`setIdentity` never returned). Signing in to a real or production account was out of scope.
4. **Shell screens, rendered on the simulator.** To still exercise the post-onboarding screens on a device, I used a temporary integration test (since deleted). It pumped the REAL screen widgets (`DashboardScreen`, `TransactionsScreen`, `TransactionDetailsScreen`, `ReportsScreen`, `BudgetsScreen`, `BudgetFormScreen`, `GoalsScreen`, `GoalFormScreen`, `SubscriptionsScreen`, `MyCardsScreen`, `AccountsScreen`, `SettingsScreen` hub/account/appearance/capture/security, `HelpScreen`, `WhatsNewScreen`, `DataTransferScreen`, `DeleteAccountScreen`) on both simulators, using:
   - the real `AppTheme`, the real l10n and the app's own 0.8–1.25 text-scale clamp;
   - an in-memory `AppDatabase.open(...)` seeded like a brand-new user with one account (`test/harness/seed_test_account.dart`).

   On every screen it ran Flutter's `labeledTapTargetGuideline`, `iOSTapTargetGuideline` and `textContrastGuideline` and captured every `FlutterError`. It also added a synthetic transaction through the real `ManualTransactionSheet` UI (amount 87.50, merchant "Synthetic Cafe"): empty-save validation, then a double-tap on Save, then the row count in the DB.
5. **What that harness does not cover.** It does not include `AppShell` (the native glass tab bar), real navigation stacks or back buttons, or the signed-in account state. Settings → Account therefore shows "Signed out" in these shots. `/privacy` and the dashboard with data threw `FeatureFlagService not initialised`, which is an artifact of the harness, not an app defect.

### Covered, per area

| Area | What I actually did on the running app | Inspected in code only |
|---|---|---|
| Onboarding, language, story, brand, sign-in, setup country, consent step | Tapped through in AR and EN, light and dark, iPhone 17 and SE, default text and AX5 | Consent copy order, button prominence, Terms link |
| Dashboard, Transactions (list/empty/with data), details, add transaction, Reports, Budgets, Budget form, Goals, Goal form, Subscriptions/Bills, Cards, Accounts, Settings + 4 sub-pages, Help, What's new, Data transfer, Delete-account entry | Rendered on the simulator (harness above) in AR light, EN light, AR dark (iPhone 17) and AR light / EN dark at 1.25x (SE); guideline checks on AR and EN light | Close-button labels in sheets, reduced motion, double-submit guards |
| Contrast | Flutter `textContrastGuideline` on device plus WCAG ratios computed from the theme tokens (script below) | — |
| RTL / mixed direction | Visual check of mirrored layouts, chevrons, progress bars, amounts and currency, dates | ARB digit usage |
| Reduced motion | Not toggled on device | `disableAnimations` / `shouldReduceMotion` usage reviewed |

Not covered: `AppShell` and its tab bar, cold-start consent re-ask, the Privacy screen, backup restore, sign-out, the delete-account flow beyond its entry screen, App Lock, notifications, capture (Shortcuts, Share extension), Android. See §5.

## 2. What is established (verified behavior, with evidence)

- **Build and launch.** The app builds and launches without backend keys (debug). Shader warnings for `liquid_glass_renderer` SkSL are build-time only and do not affect iOS (Impeller).
- **RTL mirroring is correct on every surface walked.** Language rows, setup progress bars (fill right-to-left), back chevrons (point right, placed at the right in AR), country grid order, header actions, list rows, summary cards. Amounts render LTR inside RTL (`-87.50 SAR`, `87.50 ريال`) with no bidi reordering errors seen (screens 02, 07, 41, 42, 43).
- **Light and dark themes render coherently.** Dark mode was checked on onboarding, dashboard, reports, settings and budgets (screens 17, 18, 37, 38, 46).
- **No overflow at default size.** No `RenderFlex overflowed` was reported on any of the 20 screens on iPhone 17 at 1.0x (AR light, EN light, AR dark).
- **One overflow at the large size.** On iPhone SE at 1.25x it occurred once (UX-10).
- **Double-submit guard works.** Two Save taps on the add-transaction sheet produced exactly 1 row (`[UXS] ar-light add-tx rows in db after double save: 1`, same for EN). Guards exist on goal, budget, bill and account forms (`_busy`/`_saving` in `goal_form_screen.dart`, `budget_form_screen.dart`, `bill_form_sheet.dart`, `account_form_sheet.dart`).
- **Validation feedback is shown and input is kept.** Empty-amount save shows the toast "اكتب مبلغًا صحيحًا" and keeps the sheet open (screen 39). Typed fields were preserved: the amount and merchant typed after the error remained and saved (screen 40).
- **Empty states exist for a brand-new user** on Dashboard (3-step checklist), Transactions, Budgets, Goals, Subscriptions and Cards, each with a CTA (screens 21–27). Reports is the exception (UX-12).
- **Reduced motion is honored broadly.** `MediaQuery.disableAnimations` / `shouldReduceMotion` gate the story, coin rain, brand fades, tab indicators, loading shimmer, vault, toasts and banners (16 files). One gap: UX-17.
- **Contrast of the core text tokens passes** (computed with WCAG 2.x relative luminance):

  | Pair | Ratio |
  |---|---|
  | light textPrimary / bg | 16.7 |
  | light textSecondary / bg | 8.6 |
  | light textMuted / bg | 4.52 |
  | light textMuted / surface | 4.93 |
  | dark textMuted / surface | 6.1 |
  | dark textSecondary / surface | 11.1 |
  | white / CTA blue | 5.25 |
  | expense / surface | 5.37 |
  | income / surface | 4.63 |

  Failures are listed in UX-07.

## 3. Findings

Counts: S1 0 · S2 1 · S3 11 · S4 11.

### UX-01 — Manual "add transaction" pre-selects the budget pseudo-category «كل المصروفات / All expenses» and saves real transactions into it
- Severity: S2 · Class: REPRODUCED · Platforms: All · OBJECTIVE · Fix type (b) owner decision (changes financial meaning of categorisation)
- User impact:
  - A user who does not touch the category field (it looks already filled) files every manual expense under "All expenses".
  - Reports then show "Spending by category: All expenses 100%" (screen 44), and the transaction detail shows Category = All expenses (screens 42, 43).
  - The validation `mtPickCategory` ("pick a category") can never fire for new expenses.
- Evidence:
  - `data/db/database_seed.dart:26-34` seeds `BudgetEntity.allExpensesCategoryKey` as a real non-income category with `sort: -1`, so it sorts first.
  - `features/transactions/manual_transaction_sheet.dart:336-345` takes `categories.first` as the default.
  - Run log: `[UXS] ar-light add-tx rows in db after double save: 1`; screens 40, 42, 44.
- Root cause: the budget-scope sentinel category is not excluded from the transaction category list.
- Proposed fix (smallest):
  - At `manual_transaction_sheet.dart:336`, add `&& category.key != BudgetEntity.allExpensesCategoryKey` to the `where` filter.
  - Either leave `_categoryKey` null (so `mtPickCategory` applies) or default to the existing "other" category.
  - Check the change-category sheet and import for the same leak.
  - Rows already saved need an owner decision.
- Verification: add a manual expense without touching category → either the validation shows or "Other" is used; Reports no longer lists "All expenses" as a slice.

### UX-02 — Sign-in says "By continuing you agree to the Terms of Service and Privacy Policy" but neither is tappable
- Severity: S3 · Class: CODE-SUPPORTED + seen on device (screens 06, 13) · Platforms: All · OBJECTIVE (missing affordance) · Fix (b) consent/legal surface
- User impact: the user is asked to agree to documents they cannot open from that screen. The links exist only later, in Privacy (`features/settings/privacy_screen.dart:38,91`).
- Evidence: `features/onboarding/auth_screen.dart:447-449` renders `l.authTermsNotice` as plain `Text`.
- Proposed fix: make the two phrases links using the existing `kTermsUrl` and the privacy URL, with the same `_openExternalLink` helper used by `PrivacyScreen`. This needs owner and legal sign-off on the wording.
- Verification: VoiceOver announces two links; tapping opens each document.

### UX-03 — Icon-only "+" header buttons on Transactions and Bills have no accessible name
- Severity: S3 · Class: REPRODUCED (Flutter `labeledTapTargetGuideline` on device) · Platforms: All · OBJECTIVE · Fix (a)
- User impact: VoiceOver announces only "button" for the main Add action on two primary screens.
- Evidence:
  - Run log: `ar-light /transactions LABELS … SemanticsNode#37(Rect 20,74,62,116) … expected tappable node to have semantic label, but none was found`; the same node in EN.
  - Code: `features/transactions/transactions_screen.dart:1415` and `features/subscriptions/subscriptions_screen.dart:195` build `CalmHeaderAction` without `semanticLabel`.
- Proposed fix:
  - Transactions: add `semanticLabel: context.l10n.mtAddTransaction`.
  - Subscriptions: add `semanticLabel: context.l10n.txnAddSub`.
  - Both keys already exist.
- Verification: rerun `labeledTapTargetGuideline` on `/transactions` and `/subscriptions`.

### UX-04 — Close (X) buttons in sheets and forms have no tooltip or label
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: All · OBJECTIVE · Fix (a)
- User impact: VoiceOver reads "button" with no name for the dismiss control of the add-transaction, goal, budget, paste, SMS-permission, sign-in-methods and email-code sheets.
- Evidence: `IconButton` without `tooltip` at:
  - `features/common/app_sheet_scaffold.dart:141` (shared by many sheets)
  - `features/goals/goal_form_screen.dart:120`
  - `features/goals/goal_details_screen.dart:148`
  - `features/budgets/budget_form_screen.dart:123`
  - `features/capture/manual_paste_screen.dart:106`
  - `features/capture/sms_permission_screen.dart:86`
  - `features/coupons/merchant_offers_screen.dart:69`
  - `features/coupons/savings_screen.dart:57`
  - `features/settings/sign_in_methods_sheet.dart:180`
  - `features/onboarding/widgets/email_code_sheet.dart:186`
- Proposed fix: add `tooltip: MaterialLocalizations.of(context).closeButtonTooltip` (already localized for AR and EN by `GlobalMaterialLocalizations`) to each.
- Verification: `labeledTapTargetGuideline` with each sheet open.

### UX-05 — Tap targets below 44×44 pt on primary controls
- Severity: S3 · Class: REPRODUCED (`iOSTapTargetGuideline` on device) · Platforms: All · OBJECTIVE · Fix (a)
- Evidence (run log `TAP` lines):

  | Control | Measured size (pt) | Where | Code |
  |---|---|---|---|
  | Header search and "+" | 42×42 | Transactions | `core/theme/widgets/calm_page_header.dart:549-550` |
  | Segmented pill tabs | 118×36 | Reports, Budgets, Goals | `features/budgets/widgets/planning_hero_tabs.dart:35-38`: inner height 44.5 − 8 padding |
  | Filter chips | 93×36 | Subscriptions | — |
  | Period chips | 88×36 | Budget form | — |
  | "Change category" pill | 104×36 | Transaction details | `features/transactions/transaction_details_screen.dart:956` (`minHeight: 36`) |
  | "Edit" | 71×36 | Settings | — |
  | Name text | 90×26 | Settings → Account | — |

- Proposed fix (minimal):
  - `CalmHeaderAction` 42 → 44.
  - `_TintedPill` `minHeight` 36 → 44.
  - `PlanningHeroTabs` container height `max(scaled + 8, 52)` so each tab is at least 44.
  - Chip rows: `materialTapTargetSize: MaterialTapTargetSize.padded` or `minimumSize: Size(0, 44)`.
- Verification: rerun `iOSTapTargetGuideline` on those routes.

### UX-06 — Page titles break mid-word on small screens with large text ("Transaction s")
- Severity: S3 · Class: REPRODUCED · Platforms: All (seen iOS SE, EN, 1.25x) · OBJECTIVE (clipping/wrap) · Fix (a)
- Evidence:
  - Screen 45 (`45-se-en-dark-transactions-title-break.png`).
  - `core/theme/widgets/calm_page_header.dart:211-216` builds `QirshSectionHero` for photo headers without `fitTitle`. The hero already supports `fitTitle` (`section_photo_header.dart:158-176`) and Bills uses it (`subscriptions_screen.dart:47`).
- Proposed fix: pass `fitTitle: true` in that `QirshSectionHero(...)` call (one line). This affects every `CalmPageHeader` photo page (Transactions, Reports, Budgets, Accounts, Cards, Goals).
- Verification: iPhone SE, Larger Text at maximum, EN → titles stay on one line.

### UX-07 — Text contrast below 4.5:1 in several places
- Severity: S3 · Class: REPRODUCED (guideline) + computed · Platforms: All · OBJECTIVE · Fix (a) for tokens and scrim, (b) if brand colours change
- Evidence:
  - (1) **Budget status chips, light theme.** `success #12855C` on `successBg #E1F3EC` = **4.02** (guideline: `/budgets … found 4.02 for font size 17`). The "On track" chip, the number "0" and "Safe" labels use this pair (`budgets_screen.dart:668-671`). `app_colors.dart:337`.
  - (2) **Photo-header subtitles.** They are `Colors.white` at 80% opacity (`section_photo_header.dart:203`) over a light-theme scrim that is only 55–60% navy at mid-height (`section_photo_header.dart:113-117`). Over light parts of the photo the ratio falls to about **3.3** (computed for a white backdrop) and was measured at 1.83 on Accounts and 1.78 on Transactions. The guideline samples pixels, so treat those numbers as approximate. The Accounts subtitle visibly sits on the beige paper of the photo (screen 28).
  - (3) **`textFaint`** (`#8B94A7`, 3.05 on white) used as hint/placeholder text: `budget_form_screen.dart:255`, `manual_paste_screen.dart:475`, `goal_form_screen.dart:254` (deadline value when empty).
  - (4) **Dark `neutral`** `#667085` on surface `#121317` = 3.73 (`app_colors.dart`, dark set).
  - (5) **Light `textMuted` on `surfaceMuted`** = 4.09.
- Proposed fix:
  - Darken light `success` to `#0F7650` (4.89 on `successBg`, 5.63 on white). `income` shares the value; keep them together.
  - Raise the light scrim middle stop from `0x8C011341` to `0xB3011341`, and the subtitle alpha to 0.9.
  - Use `textMuted` instead of `textFaint` for the deadline value.
  - Changing the brand green needs owner sign-off.
- Verification: `textContrastGuideline` on `/budgets`, `/accounts`, `/transactions`; visual check of the header photos.

### UX-08 — Truncated labels: budget summary chips and the "Budget history" tab
- Severity: S3 · Class: REPRODUCED · Platforms: All · OBJECTIVE · Fix (a)
- Evidence:
  - iPhone 17, EN, 1.0x: "Close to l…" (screen 35).
  - SE, EN, 1.25x: "On tra…", "Close …", "Over li…", "Budge…", and "Budget history" wraps and is cut off at the bottom (screen 46).
  - `features/budgets/budgets_screen.dart:867-871` (`maxLines: 1, overflow: ellipsis`).
  - `features/budgets/widgets/planning_hero_tabs.dart:35` (height formula `scale(13)*2+12` ignores line height).
- Proposed fix:
  - `_SummaryChip` label: `maxLines: 2`, or wrap it in `FittedBox(fit: BoxFit.scaleDown)` as the value already is.
  - Tab height: `MediaQuery.textScalerOf(context).scale(13) * 2 * 1.35 + 16`.
- Verification: SE at maximum text, EN and AR.

### UX-09 — Dynamic Type is capped at 1.25x app-wide
- Severity: S3 · Class: CODE-SUPPORTED, observed (AX5 renders the same as about XL; screens 11–18) · Platforms: All · OBJECTIVE vs WCAG 1.4.4 / Apple accessibility sizes · Fix (b)
- User impact: users of the iOS Accessibility text sizes (up to about 3x) get 1.25x. The brand doc's own target ("Dynamic Type +2 steps", `docs/design/BRAND_AND_DESIGN_SYSTEM.md` §14) is roughly met, but accessibility sizes are not honored.
- Evidence: `app/lib/app.dart:57-60` `textScaler.clamp(minScaleFactor: 0.8, maxScaleFactor: 1.25)`.
- Proposed fix: owner decision, either:
  - raise the cap (for example 1.6) after the overflow tests at that scale pass (UX-06, UX-08 and UX-10 show the layouts are already tight at 1.25); or
  - accept and document it as a known limitation.

### UX-10 — Transaction details overflows on iPhone SE at 1.25x (RenderFlex 4 px), and "Change category" is truncated
- Severity: S3 · Class: REPRODUCED · Platforms: iOS seen (layout is shared) · OBJECTIVE · Fix (a)
- Evidence:
  - Run log on SE: `FLUTTER-ERROR [ar-light details] A RenderFlex overflowed by 4.0 pixels on the bottom.` (3 times).
  - Screen 47 shows «تغيير التصني…».
  - `features/transactions/transaction_details_screen.dart:338-345` (the `Flexible` `_TintedPill`) and `:956-966` (`maxLines: 1`, fixed vertical padding).
  - The overflowing Flex was not isolated: the run captured only the first line of the error. Likely candidates are the hero amount column or the category row.
- Proposed fix:
  - Let `_TintedPill` take 2 lines with `minHeight: 44`.
  - Run `flutter run` on an SE simulator with Larger Text at maximum to read the full overflow trace, then give the offending Column a `mainAxisSize.min` or a scroll.
- Verification: no overflow in the run log; full label visible.

### UX-11 — Onboarding setup: the only visible primary button is a disabled "Start", and step controls are below the fold on small screens
- Severity: S3 · Class: REPRODUCED · Platforms: All · SUBJECTIVE-leaning (affordance) · Fix (b) owner (onboarding/consent flow)
- User impact:
  - On step 1 the country is pre-selected (SAR highlighted), but nothing advances until that chip is tapped again.
  - On step 2 the consent buttons sit under long copy.
  - On SE with large text, the first screen shows only the illustration, title and a greyed "Start" (screens 14, 17). Users read the disabled button as the next step.
- Evidence: `features/onboarding/setup_screen.dart:682-701` (`_finishBar`, disabled until all 6 steps are done) is pinned under every step; `_countryStep` advances only on chip tap (`:489`).
- Proposed fix (owner): hide `_finishBar` until the last step, or relabel it; add an explicit "Continue" on step 1.

### UX-12 — Reports has no empty state for a new user
- Severity: S4 · Class: REPRODUCED · Platforms: All · OBJECTIVE (missing state) · Fix (a)
- Evidence: screens 23 and 48 show a card of zeros, then a blank page. `features/reports/reports_screen.dart:291-345`: `_OverviewTab` builds `cards` conditionally and renders nothing when all are empty.
- Proposed fix: when `cards.isEmpty`, append `AppEmptyState` (`features/common/app_empty_state.dart`) with the existing `rptAddMoreTx` string.

### UX-13 — Mixed Arabic-Indic and Western digits in Arabic
- Severity: S4 · Class: REPRODUCED · Platforms: All · OBJECTIVE (inconsistency) · Fix (a)
- Evidence:
  - The dashboard checklist reads «ابدأ في ٣ خطوات» next to "0/3", "1" and "2" (screen 21).
  - The app formats every number with `en_US` (`core/utils/formatters.dart:9-10`).
  - Literals in `lib/l10n/app_ar.arb` at lines 89, 90, 2030, 2034, 3677, 3707, 3951, 3952 use ١ ٢ ٣ ٧.
- Proposed fix: replace them with Western digits (3, 7, 1, 2), then run `flutter gen-l10n`.

### UX-14 — A user-entered transaction shows Source "Unspecified / غير محدد"
- Severity: S4 · Class: REPRODUCED · Platforms: All · OBJECTIVE (unhelpful/untrue label) · Fix (b) (data model)
- Evidence:
  - Screens 42 and 43.
  - `domain/usecases/add_transaction_usecase.dart:2417` saves manual entries with `TransactionSourceEntity.unknown`.
  - `transaction_details_screen.dart:68` maps that to `txdTypeUnknown`.
- Proposed fix: add a "manual" source, or show "Entered by you" when there is no raw message (owner).

### UX-15 — Consent step presentation (copy order, CTA balance, wrapped label)
- Severity: S3 · Class: REPRODUCED · Platforms: All · mixed · Fix (b) (consent flow) except item 3
- Evidence:
  1. **Copy order.** The first paragraph shown starts with "Also"/«كما» ("Your transactions… are **also** synced") because the bullets render in the order `[smartConsentBullet2, smartConsentBullet1, smartConsentBullet3]` (`features/consent/smart_analysis_consent_sheet.dart:507`; screens 08, 17).
  2. **Prominence.** Accept is a full-width filled button. "Continue locally" is a small text link (screens 08, 18). Equal-prominence choices are the usual expectation for consent.
  3. **Wrapped label.** At large text the Accept label wraps and is start-aligned against the top edge (screen 18). Fix (a): `textAlign: TextAlign.center` on the `Text` at `smart_analysis_consent_sheet.dart:517`.
  4. **Platform-specific copy on iOS.** On iOS the copy mentions SMS "read automatically on Android".
- Proposed fix: owner and privacy review of order and prominence; apply item 3 directly.

### UX-16 — Capture status shows green "success" styling when no bank message has ever been captured
- Severity: S4 · Class: REPRODUCED · Platforms: All · OBJECTIVE (status styling contradicts content) · Fix (a)
- Evidence: screen 30 shows a green shield-check over "We have not detected a bank message yet". `features/settings/settings_screen.dart:2745-2753` falls through to `(c.successBg, c.success, c.success)` when `lastCaptureAt == null` and `!shouldNudge`.
- Proposed fix: when `status.lastCaptureAt == null`, use `(c.infoBg, c.info, c.actionText)` and a neutral icon.

### UX-17 — The restore prompt's illustration animation ignores Reduce Motion
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: All · OBJECTIVE · Fix (a)
- Evidence: `features/onboarding/restore_prompt_screen.dart:205-211`: `.animate().fade(800ms).scale(easeOutBack)` runs unconditionally. Compare `coupons_screen.dart:219` (guarded with `shouldReduceMotion`).
- Proposed fix: wrap it in `if (!shouldReduceMotion(context))`, the same pattern.

### UX-18 — Brand screen tagline is start-aligned when it wraps
- Severity: S4 · Class: REPRODUCED (SE, EN, large text) · Platforms: All · OBJECTIVE (alignment) · Fix (a)
- Evidence: the title is centered and the wrapped tagline is left-aligned (observed on the SE run; not kept as a screenshot). `features/onboarding/brand_screen.dart:102-105`.
- Proposed fix: add `textAlign: TextAlign.center` to that `Text`.

### UX-19 — Story copy overlaps the illustration and coin particles on small screens
- Severity: S4 · Class: REPRODUCED · Platforms: All · SUBJECTIVE · Fix (b) design
- Evidence: screens 03 and 12. Body text runs over the halftone hand illustration, and the decorative coin-rain dots drift across words (they are excluded under Reduce Motion).
- Proposed fix (design): constrain the text width away from the art on narrow screens, or lower the art opacity behind the text.

### UX-20 — Inconsistent header and CTA patterns, and inconsistent currency presentation
- Severity: S4 · Class: REPRODUCED · Platforms: All · SUBJECTIVE/consistency · Fix (b)
- Evidence:
  - The "+" action is a filled blue circle on Transactions, Bills and Budgets but a bare glyph on Goals and Cards (screens 22, 24–27).
  - The goal form's "Create goal" is a hug-width button while every other form uses full width (SE run).
  - In Arabic, amounts show "SAR" on Transactions but "ريال" on Reports, Budgets and Goals (screens 22–25).
  - The add-transaction field labels («الحساب», «التصنيف») float above the field edge and crowd the field above.

### UX-21 — What's new 1.0.0 lists changes relative to beta builds
- Severity: S4 · Class: REPRODUCED · Platforms: All · PRODUCT-DECISION
- Evidence: screen 33 lists items such as "Clearer screens when you're offline…" and "Saved rules page". These are deltas a first-time V1 user never experienced.
- Proposed fix: owner to decide the V1 copy (for example, a short "Welcome to Qirsh 1.0" summary).

### UX-22 — The credential-free build cannot finish onboarding, and the error message promises a retry that cannot succeed
- Severity: S4 · Class: ENV-LIMITATION (and copy) · Platforms: debug without backend only
- Evidence: screens 10 and 19. `ConsentLocalWork.capture()` returns null without an SDK session (`app_session.dart:1402-1411`), and `_decline` shows `setupSaveFailed` "Please try again" (`smart_analysis_consent_sheet.dart:476-482`).
- Release builds require backend config, so this does not affect users. It does block anyone doing UI QA without credentials. Worth a debug-only note in `CLAUDE.md`, which currently says the app launches and works locally without keys.

### UX-23 — Design-system documents contradict the shipped design
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: docs · Documentation drift
- Evidence:
  - `docs/design/DESIGN_SYSTEM.md` §2 specifies Royal Purple `#7C3AED` / coral; the code uses blue `#155DFC` / `#0336BF` (`core/theme/app_colors.dart:19-41,282-376`).
  - `BRAND_AND_DESIGN_SYSTEM.md` names IBM Plex Sans Arabic; the code uses Vazirmatn (`core/theme/app_typography.dart:20`).
  - `app/CLAUDE.md` still lists `google_fonts` as the font stack.
- Proposed fix: mark the documents superseded or update the token tables.

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Language choice | iOS | AR/EN select, RTL mirror | `onboarding/language_screen.dart` | Simulator tap-through | PASS | 02, 11 | — |
| Welcome story + brand | iOS | Read, continue, small screen | `story_screen.dart`, `brand_screen.dart` | Simulator | PASS with issues | 03, 04, 12 | UX-18, UX-19 |
| Sign-in screen | iOS | Layout, Terms notice | `auth_screen.dart` | Simulator (stub auth) | FAIL (Terms not linked) | 06, 13 | UX-02 |
| Setup step 1 country | iOS | Select, advance, small screen | `setup_screen.dart` | Simulator | PASS with issues | 07, 14, 15 | UX-11 |
| Consent step | iOS | Accept / Continue locally | `smart_analysis_consent_sheet.dart` | Simulator | NOT TESTED to completion (env) | 08, 10, 17–19 | UX-15, UX-22 |
| Dashboard empty | iOS | New user state | `dashboard_screen.dart` | Device render harness | PASS | 21, 37 | UX-13 |
| Transactions list | iOS | Empty, with data, AR/EN, SE | `transactions_screen.dart` | Device render harness | FAIL (label, title wrap) | 22, 41, 45 | UX-03, UX-05, UX-06 |
| Add transaction | iOS | Validation, retention, double submit | `manual_transaction_sheet.dart` | Device render harness + DB count | PASS (submit/validation); FAIL (default category) | 39, 40 | UX-01 |
| Transaction details | iOS | Labels, SE large text | `transaction_details_screen.dart` | Device render harness | FAIL (overflow on SE) | 42, 43, 47 | UX-10, UX-14 |
| Reports | iOS | Empty and with data | `reports_screen.dart` | Device render harness | FAIL (no empty state) | 23, 38, 44, 48 | UX-12 |
| Budgets / budget form | iOS | Empty, chips, SE | `budgets_screen.dart`, `budget_form_screen.dart` | Device render harness | FAIL (truncation, contrast) | 24, 35, 46 | UX-07, UX-08 |
| Goals / goal form | iOS | Empty, form | `goals_screen.dart`, `goal_form_screen.dart` | Device render harness | PASS with issues | 25 | UX-20 |
| Subscriptions/Bills | iOS | Empty | `subscriptions_screen.dart` | Device render harness | FAIL (unlabeled +) | 26 | UX-03 |
| Cards, Accounts | iOS | Empty / default account | `my_cards_screen.dart`, `accounts_screen.dart` | Device render harness | PASS with issues | 27, 28 | UX-07 |
| Settings hub + sub-pages | iOS | Layout, tap targets | `settings_screen.dart` | Device render harness | PASS with issues | 29, 30 | UX-05, UX-16 |
| Data transfer | iOS | Entry layout | `data_transfer_screen.dart` | Device render harness | PASS | (run log, SE shots) | — |
| Delete account entry | iOS | Entry layout | `delete_account_screen.dart` | Device render harness | PASS (entry only) | 32 | — |
| What's new, Help | iOS | Content | `whats_new_screen.dart`, `help_screen.dart` | Device render harness | PASS with copy issue | 33 | UX-21 |
| Privacy screen | iOS | Layout | `privacy_screen.dart` | — | NOT TESTED (harness lacks FeatureFlagService) | — | — |
| App shell / tab bar | iOS | Navigation, glass bar | `app_shell.dart` | — | NOT TESTED (needs session) | — | — |
| Dark mode | iOS | All walked screens | `AppColors.dark` | Simulator + harness | PASS | 17, 18, 37, 38, 46 | — |
| Large text | iOS | AX5 (clamped 1.25x) on SE | `app.dart:57` | Simulator | FAIL (cap + 3 layout defects) | 11–18, 45–47 | UX-06, UX-08, UX-09, UX-10 |
| Contrast | All | Body ≥ 4.5:1 | `app_colors.dart` | Guideline on device + computed | FAIL (4 pairs) | run log | UX-07 |
| Screen-reader labels | All | Icon-only buttons named | various | Guideline + code | FAIL | run log | UX-03, UX-04 |
| Tap targets | All | ≥ 44×44 | various | Guideline | FAIL | run log | UX-05 |
| Reduced motion | All | Animations honor setting | `motion.dart` and others | Code inspection | PASS except 1 | — | UX-17 |
| Android | Android | Any | — | — | NOT TESTED (no Java/adb) | — | — |

## 5. Could not verify here (exact scenarios, what is needed)

- **Signed-in shell and everything behind a real session.** This covers `AppShell` with the native glass tab bar, tab switching, back stacks, the cold-start consent re-ask sheet, Settings → Account signed in, sign-out, delete-account confirmation and Apple re-auth, cloud consent ON states, sync status sheet states, and backup restore. Needed: a build with a local or staging Supabase (`SUPABASE_URL` / `SUPABASE_ANON_KEY` for a test project) and a QA test account. The existing `integration_test/bilingual_walk_test.dart` and `accessibility_audit_test.dart` cover this once `QA_EMAIL` / `QA_PASSWORD` / `QA_USER_ID` are supplied.
- **Privacy screen.** It was not rendered (harness artifact). Check it in the signed-in build.
- **Capture via Apple Shortcuts / Share extension, push notifications, App Lock (Face ID), local notifications.** Needed: a physical device, or a simulator with the Shortcuts app and APNs.
- **Keyboard covering fields in long forms with the real keyboard on SE.** Only partly seen (the add-transaction sheet scrolls and the Save button is reachable). The goal and budget forms with the keyboard open were not checked.
- **Offline and error states for network-backed surfaces** (coupons, announcements, catalog sync). They need a backend to fail against.
- **Permission-denied states** (notifications denied, Face ID denied). They need the system permission prompts in a signed-in run.
- **Focus order with VoiceOver and Switch Control.** Not navigated with VoiceOver; only semantic labels were checked.
- **Android** (TalkBack, back gesture, SMS permission sheet). No Java or adb on this machine.

## 6. Manual device test steps you recommend

1. Fresh install, Arabic. Go through language → story → sign in (TestFlight build) → setup. Expected: on step 1 the user can tell how to continue; Terms and Privacy are tappable on sign-in (UX-02, UX-11).
2. Add an expense manually without touching Category. Expected: either a "pick a category" prompt or "Other". Never "All expenses" (UX-01).
3. Turn on VoiceOver. On Transactions, swipe to the "+" button. Expected: "Add transaction, button". Open the add sheet and swipe to X. Expected: "Close, button" (UX-03, UX-04).
4. iPhone SE, Settings → Accessibility → Larger Text at maximum, English. Open Transactions, Budgets and a transaction's details. Expected: titles on one line, chip labels readable, no clipped "Change category" (UX-06, UX-08, UX-10).
5. Light mode, Budgets with one budget on track. Expected: the green "On track" chip text is clearly readable (UX-07).
6. New account, Reports. Expected: an empty-state message with guidance, not a blank page (UX-12).
7. Settings → Transaction capture before any capture. Expected: neutral styling, not a green success shield (UX-16).
8. Settings → Accessibility → Motion → Reduce Motion ON, then open "Restore backup". Expected: no scale or bounce animation (UX-17).
9. Dark mode: repeat steps 1, 4 and 6. Expected: same results; no low-contrast captions.
10. Check the What's new copy for 1.0.0 with the owner (UX-21).
