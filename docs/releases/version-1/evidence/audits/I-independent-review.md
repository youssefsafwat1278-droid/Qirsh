# I — Independent review of the Version 1 release-readiness fixes

- Reviewer model: `claude-opus-5-5` (Opus 5.5). Wrote none of the fixes or audits A–H.
- Date: 2026-11-17. Worktree `.claude/worktrees/v1-readiness`, branch `release-readiness/v1`, HEAD `d35fc044`.
- Scope: the seven local commits `ab5dc10a..d35fc044` (`64e571e5`, `f9c5be75`, `d70ba396`, `2f2c4707`, `ff1fc292`, `7597bb42`, `d35fc044`); the register and records in `docs/releases/version-1/`; the rules in `docs/release-process/`. Uncommitted UI edits under `app/lib/features/**` were not reviewed.
- Method: read every diff; ran throwaway probes from the scratchpad against the real code (`dart run --packages=app/.dart_tool/package_config.json <probe>`; `deno run` importing `process-ios-sms/parse.ts`); ran targeted tests. No tracked file was changed; `supabase/functions/deno.lock` was left unchanged.
- Nothing here was run on a device or simulator. No CI build exists for any of these commits. TestFlight 147 is `b6fc0dad`, which is older than every fix.

## Commands run (results)

| Command | Result |
|---|---|
| `flutter test --no-pub` declined, yearless, ai_candidate_validator, meridiem, parser_engine, sync_conflict_store, ios privacy manifest, ios snapshot scene, help copy, force_update_version_range | 122 passed |
| `TZ=Asia/Riyadh flutter test --no-pub` sync_conflict_store + yearless | 15 passed |
| `deno test --allow-all process-ios-sms/` | 124 passed |
| `node --test` codemagic_app_version_contract, skip_manifest_node, ci_gates_contract | 25 passed |
| `node tools/check_test_skips.mjs --flutter app/test` | 38 sites, all matched |
| Never-run suites run with their own documented synthetic defines (`SUPABASE_ENV=local SUPABASE_URL=https://example.supabase.co SUPABASE_ANON_KEY=anon`) | user_activity_consent +6, immediate_account_deletion +39, smart_inbox_status_cycle +24, startup_reconcile_default_rpc_refusal +15, local_read_host +56 all pass; **bootstrap_remove_data_integration +3 −7 FAIL** (`BootstrapAuthDeferred(protected_data)` at `bootstrap_runner.dart:1890`) |
| `cd admin && npm audit --omit=dev --json` | `next@14.2.35`: 25 advisories apply (3 critical, 9 high, 11 moderate, 2 low); `postcss` high |
| Probes `cues_probe.dart`, `g2.dart`, `atm.dart`, `prev.dart`, `srv_probe.ts` | outputs quoted in the findings |

## Findings

### REV-01 — S1 — V1-001 is not closed: some common declined wordings are still counted, and one is recorded as income
- Wrong: `TransactionStateCues.isNotCompleted` (`app/lib/engine/parser/transaction_state_cues.dart:50-54`) ignores the declined cue whenever any `creditAction` word appears anywhere in the message (`refund`, `reversed`, `credited`, `استرداد` …). Bank boilerplate on declined messages often includes these words. When the exemption fires, the message is parsed as before the fix, and the AI path is not blocked either (`ai_candidate_validator.dart:69`, `add_transaction_usecase.dart:857`).
- Evidence (probe, `ParserEngine().parse`, cue result → parse):
  - `Your purchase of SAR 250.00 at Shop X was declined. If amount was deducted it will be refunded.` → cue `false`, **isTransaction=true, type=refund, 250.0**. Refunds reduce spend (`SYSTEM-MAP.md:53`), so this subtracts 250 from spend that never happened.
  - `Purchase of SAR 100 at Shop X declined. Any held amount will be reversed.` → cue `false`, **payment 100.0**.
  - `Purchase of SAR 100 at Shop X declined. Your account was not credited or debited.` → cue `false`, **payment 100.0**.
  - `عملية شراء مرفوضة. لاسترداد المبلغ اتصل بنا` → cue `false`.
  - `Transfer of SAR 300 to Ali was rejected. Amount credited back to your account.` → transfer 300.0.
  - Wordings the list misses, all parsed as payment 100.0: `لم تتم العملية`, `العملية لم تكتمل`, `could not be processed`, `denied`, `not approved`, `غير مقبولة`, `ملغاة`, `cancelled`, `مرفوضه` (final ha instead of ta marbuta; the normalizer does not fold ة/ه), `رفض عملية شراء` (bare `رفض`), `عملية فاشله`.
  - Caught correctly: `was DECLINED`, `Txn declined:`, `Status: Declined`, `الحالة: مرفوضة`, `was not successful`, `unsuccessful`, `تم رفض`.
- Required action: fix and re-verify. Apply the exemption only when the credit verb is the message's own action, not anywhere in the text (for example, only when no declined cue precedes it, or only on a leading refund/reversal construction), and add the missing wordings. Test against synthetic messages modelled on the actual declined templates of the banks in `assets/catalog/banks.json`. Until then, V1-001 stays OPEN at S1.

### REV-02 — S2 — The declined fix diverts real completed purchases out of spend (false positives)
- Wrong: whole-token cues such as `failed`, `rejected`, `unsuccessful`, `declined`, `مرفوض` also appear in merchant names and in standard footer text on successful purchases. Those purchases now become `notTransaction` and are never sent to AI.
- Evidence (probe, cue `true` → isTransaction=false): `Purchase of SAR 100 at Failed Ventures card *1234`; `شراء بمبلغ 100 SAR لدى مرفوض للتجارة`; `Purchase SAR 100 at Rejected Records Store`; `… If you did not make this transaction, it can be rejected by calling us.`; `… Report unsuccessful or unauthorized transactions to 8001234`; `… Transactions exceeding limit will be declined.`; `… للاعتراض على العمليات المرفوضة اتصل بنا`.
- Impact: monthly spend is under-counted until the user acts on a Smart Inbox card. The workaround is real but costs effort: Smart Inbox is reachable with flags at their defaults (`transactions_screen.dart:302-305` renders `_SmartInboxBanner` whenever there are items; the item is saved by `SharedCaptureHandoffService` → `persistUnprocessableCapture`, not gated by a flag).
- Required action: fix together with REV-01. Restrict cues to a status position (for example, near the transaction verb or amount) rather than anywhere in the text, and add FP fixtures to `declined_transaction_test.dart`.

### REV-03 — S1 (deploy-dependent) — On iOS with Cloud on, V1-001 depends entirely on a function deploy; installed builds are unprotected
- Wrong: captures the server marks `processed` are imported through `_validates` → `validateCaptureCandidate` (`capture_import_service.dart:539-560`, `domain/capture/validated_capture.dart:235`), which has no declined check. `TransactionStateCues` is used only in `parser_engine.dart:191`, `ai_candidate_validator.dart:69` and `add_transaction_usecase.dart:857`. Until `process-ios-sms` is redeployed, the server keeps returning declined purchases as `processed` payments, and the new client imports them. After the deploy, build 147 and older clients re-parse a server-rejected capture locally with the old parser (`forceLocalAutoConfirm: true`, `capture_import_service.dart:153-159`) and confirm it.
- Evidence: the code above; commit message `d35fc044` ("needs a function deploy"); `RELEASE-PLAN.md` has no step that names deploying `process-ios-sms` for V1-001 (only mentions at :271).
- Required action: document and fix. Add the `process-ios-sms` deploy to the release plan's ordered steps. Add the declined check to `_validates` as defence in depth. State in the register that V1-001 is fixed only for builds after `d35fc044`, and only after the deploy.

### REV-04 — S3 — Server and client cue matching disagree; the notification preview still shows a declined purchase as a purchase
- Server drift: the cue lists are identical (Python comparison of `transaction_state_cues.dart` vs `process-ios-sms/parser_rules.json`: `True True`), but the server's `normalize` (`parse.ts:415-423`) does not strip tashkeel or tatweel, while the Dart `Normalizer.normalize` does. Probe (`srv_probe.ts`): `رُفضت عملية شراء …` → server `false`, payment 100; `عملية شراء مـرفوضة …` → server `false`, payment 100. Dart returns `true` for both.
- Preview: `app/assets/catalog/parser_rules.json` was not changed. It feeds the Swift `PreviewParser` (`BankMessageShortcuts.swift:1183-1276`) and its Dart mirror. Probe: `تم رفض عملية شراء بمبلغ 250.00 ريال …` → `PreviewOutcome.debit 250.0 SAR isHighConfidence=true`. With Cloud off (the default), `scheduleLocalParsedOrGenericNotification` (`:479-517`) shows "تم رصد عملية شراء 🛒 / المبلغ: 250.00" for a purchase the app will then put in Smart Inbox.
- Required action: fix. Normalize tashkeel and tatweel on the server before the cue test. Add the declined keys to the app asset and make the Swift and Dart preview parsers honour them (or suppress the detailed preview when a cue matches).

### REV-05 — S3 — Declined purchases stored before the fix stay counted
- No migration or repair reclassifies existing confirmed transactions whose raw text matches a declined cue (the commit touches no `app_database.dart` migration). Every TestFlight tester's ledger keeps the wrong totals.
- Required action: document as a known limitation, or add a one-time local pass that moves matching confirmed rows to review. This needs an owner decision because it changes stored financial data.

### REV-06 — S2 — V1-011 is only partly fixed: the gate reports "satisfied" while a recorded skip hides a failing data-removal suite
- Wrong: `tools/check_test_skips.mjs:124-174` now lists all 38 Flutter skip sites, which improves visibility. No suite was made to run, though. Five of the six "never run in CI" suites need only synthetic defines and pass when given them. The sixth fails: `test/core/startup/bootstrap_remove_data_integration_test.dart` (the "configured real-sender remove-data bootstrap group" in the manifest) runs **+3 −7** with its own documented defines (`BootstrapAuthDeferred(protected_data)`, `bootstrap_runner.dart:1890`). The gate prints `manifest: satisfied` for this state.
- The gate can also be bypassed: a `testOn:` / `@TestOn` restriction, a tag excluded in `ci_gates.sh:145`, an early `return` inside a test body, or changing a conditional `skip: !configured` to `skip: true` all leave the skip check satisfied, because entries match on file + kind + `contextContains`, not on the condition.
- Required action: fix. Add a CI stage that runs the define-gated suites with the synthetic defines (they need no network). Investigate the 7 failures in the data-removal suite: they are either a real removal defect or a stale test, and either way the result is a REPRODUCED failure in a critical journey. Keep V1-011 OPEN until both are done.

### REV-07 — S2 — Admin: the remaining advisory exposure is understated
- Wrong: the commit and V1-025 describe the result as "clears two of the four production advisories; the remaining critical one has no fix on 14.x". The "four" counted packages, not advisories. At `next@14.2.35`, `npm audit` lists 25 applicable advisories (3 critical, 9 high), including two unauthenticated RCEs in the Image Optimization API (AVIF and SVG). `/_next/image` is excluded from the auth middleware (`admin/middleware.ts:64`). Removing `remotePatterns` is safe: every `<Image>` uses a local `/brand/*.png` (`login/page.tsx:60`, `not-authorized/page.tsx:21`, `sidebar.tsx:26`). It reduces the attacker-supplied-image surface, but the optimizer endpoint is still served.
- Required action: re-rate and document. Record the advisory count and the two optimizer RCEs in V1-025. Cheap mitigation: `images: { unoptimized: true }` (removes the optimizer), plus written proof that the admin is bound to loopback. Otherwise owner exception or an upgrade to Next 15.5.x.

### REV-08 — S3 — iOS app-switcher cover: never compiled, and inactive-state gap
- `d70ba396` is a source-text change checked only by string-matching tests (`ios_privacy_snapshot_scene_test.dart`). Unverified: that it compiles (`installPrivacySnapshotView` is now internal with a default parameter); that the cover appears in the switcher snapshot; that it is removed on every return path. Removal is wired on `sceneWillEnterForeground` and `sceneDidBecomeActive` (`SceneDelegate.swift:62-86`), so I found no path that leaves the cover installed (single scene: `UIApplicationSupportsMultipleScenes=false`, `Info.plist:58-59`).
- Gap: the cover is installed only on `sceneDidEnterBackground`. While the user is in the app switcher and has not left the app, the scene is inactive and the live UI, including balances, shows on its card. Choosing background over resign-active does avoid covering the app during the Face ID prompt. That is a defensible trade-off, but it should be written down, not implied as "fixed".
- A scene launched directly into the background (background capture launch) never gets `sceneDidEnterBackground`, so its snapshot is uncovered.
- Required action: re-verify on a simulator and on a device (MDT-IOS). Document the inactive-state behaviour.

### REV-09 — S4 — Disk-space reason 85F4.1 is defensible but thin
- `deviceCapacityState` (`SharedCaptureStore.swift:4771-4778`) is used only by `queueStats` → `captureQueueStats` → the Sync diagnostics screen, which exists only in debug builds (`sync_diagnostics_screen.dart:31`, `app_router.dart:402`). In a release build the API is linked but its value is never shown. In debug builds it is shown and can be copied to the clipboard by the user (`:121`). A user-initiated copy is not the app sending data off the device, so 85F4.1 is not false. Still, the native code's own purpose ("needs a temp copy … full") reads like E174.1, and the share extension never displays anything.
- Required action: document. Better: remove the probe from the release build or compile it out of the extension. Generate Xcode's privacy report from the archive before upload (STORE-READINESS A1). The other reasons (1C8F.1 for the App Group suite, CA92.1 for `.standard` in `AppDelegate.swift:501,1202,1547`, C617.1 for `modificationDate` in the App Group container at `SharedCaptureStore.swift:4152`) match the code.

### REV-10 — S3 — Force-update: malformed range now fails open; same-version builds still cannot be targeted
- `7597bb42` adds `a.targetsVersion(kAppVersion)` (`app_providers.dart:379-383`). `compareAppVersions` reads non-numeric parts as 0 (`catalog_daos.dart:1756`), so an admin entry such as `max_app_version = "v1.0.1"` now stops blocking 1.0.0. Before this commit, any cached force-update row blocked. An empty `kAppVersion` still blocks. Every CI workflow now passes a non-empty version (`codemagic.yaml:96-111, 326, 507-519, 886`). The default without a define is `kPubspecVersion` = `1.0.0` (`app_version.dart:30-38`). A real force-update of 1.0.0 (147) to a later 1.0.0 build is still impossible (V1-040).
- Required action: validate the version format in the admin form or the server, and add a test with a malformed bound. V1-040 stays open.

### REV-11 — S4 — The zone-less timestamp regression test cannot fail on a UTC host
- `sync_conflict_store_test.dart` (the `ff1fc292` hunk) passes before the fix whenever the host time zone is UTC; the comment asks for `TZ=Africa/Cairo` by hand. The fix itself is consistent with the writers: `dateTimeToSql` emits `Z` (`sql_value_codec.dart:5`), and `localSnapshot` returns raw SQL rows (`sync_conflict_store.dart:152-170`). I found no zone-less local-time writer. Not checked: server `date`-typed columns (deadline, start/end date) compared with a local value written as a UTC instant of local midnight could still show a one-day difference.
- Required action: pin the zone inside the test (for example, construct the zone-less value from a non-UTC offset or run the case in a `TZ` subprocess). Check the plan/goal date columns.

### REV-12 — S1 (re-rate) — V1-007 and V1-015 are unmet store requirements and are rated S2
- `SEVERITY-AND-GATES.md` defines "unmet applicable store requirement" as S1. `STORE-READINESS.md` A4 records the privacy policy as unreachable in the app while Cloud is off (Apple 5.1.1(i), NOT MET), and A8 records no reviewer access or way to exercise the core feature (Apple 2.1, NOT MET). The register rates them S2 (V1-007, V1-015).
- Required action: re-rate both to S1.

### REV-13 — S1 (re-rate) — V1-014: an iPad device family without iPad screenshots blocks submission
- `TARGETED_DEVICE_FAMILY = "1,2"` (STORE-READINESS A16). App Store Connect requires iPad screenshots for an app that supports iPad, and none exist. Until the owner decides iPhone-only, this is an unmet store requirement.
- Required action: re-rate to S1 pending the owner decision.

### REV-14 — S1 (re-rate) — V1-020 is rated by likelihood, against the rule
- Restore versus cloud sync can overwrite restored rows or resurrect removed ones; class SUSPECTED, rated S2. The rule says to rate by impact and class SUSPECTED when likelihood is unknown. The impact is data loss or corruption, which is S1.
- Required action: re-rate to S1 SUSPECTED and resolve by running it (restore with Cloud off, then enable Cloud, on a local stack).

### REV-15 — S2 — Records are stale against the commits, and three referenced records do not exist
- `ISSUES.md` lists V1-001, V1-008, V1-010, V1-011, V1-018, V1-025, V1-028, V1-029, V1-030, V1-034, V1-039, V1-041, V1-049 as OPEN with no commit named, although its header defines `FIXED (local commit named)`. `PROGRESS.md` ends at 03:45 and records neither the seven commits nor the impact assessment that `RELEASE-POLICY.md` §4 requires. `SYSTEM-MAP.md:20,50` and `RELEASE-PLAN.md:129,288` still describe `next 14.2.29`, "no declined handling", and the old runbook step 6.
- `RELEASE-MANIFEST.md`, `TEST-EVIDENCE.md` and `UI-UX-REVIEW.md` are linked from `ISSUES.md` but do not exist, so G0 (manifest) has no record.
- The parser changed in `d35fc044`, so parser evidence recorded at `ab5dc10a` has expired. This affects `COVERAGE-MATRIX.md:213-214` (digits, European decimal PASS) and DATA-02/03/04.
- Required action: update the register (FIXED with commit, or PARTIAL per REV-01/02/06), write the impact assessment, re-verify the expired rows, and create the manifest.

### REV-16 — S3 — Coverage matrix Part B shows PASS for runtime behaviour verified only by reading code
- The matrix's own rule (`COVERAGE-MATRIX.md:12`, line 201) says runtime behaviour checked only by inspection is NOT TESTED. Yet rows marked PASS by inspection include: "Sync pull vs local edit — pending edit never overwritten" (:297), "Conflict keep-cloud … apply atomically" (:298), "Restore validation" (:300), "Prompt injection — SMS cannot steer persisted output" (:319, while SEC-10 is open), "Notification visibility Android … device not tested" (:330), "Crash reports … no event while OFF" (:334), "Onboarding routing … no loop" (:342).
- Required action: re-rate those rows to NOT TESTED ("I consistent").

### REV-17 — S3 — AI grounding does not handle the Arabic comma as a thousands separator
- `GroundingCheck` tokenizes the raw text and accepts only `[,٬.٫]` as separators (`grounding_check.dart:17-18`). The parser's `Normalizer` maps `،` to `,` (`normalizer.dart:105`). Probe: `شراء 1،250.00 SAR` grounds 250 (`true`) and not 1250 (`false`), so a fragment is accepted. This behaved the same before the fix, so it is not a regression. Year-less dates: probes with now=2026-01-02 give `31/12 23:00` → 2025-12-31 and `03/01 09:00` → 2026-01-03 (within the one-day tolerance), as intended. Grounding of `1,250.00` vs `250.00` and Arabic-Indic `١٬٢٥٠٫٠٠` behave correctly. An amount equal to the balance figure is grounded (`balance 500.00` → 500 `true`); that limitation is inherent to grounding and is constrained elsewhere by local money.
- Required action: fix if cheap (normalize `،` between digits before tokenizing, on both client and server).

### REV-18 — S2 — Nothing on this branch has been built, run on a device, or gated in full
- No strict `REQUIRE_ALL_GATES=1 tools/ci_gates.sh` run exists at `d35fc044`. The baseline run 2 at `ab5dc10a` had 33 bulk failures attributed to load, with "a clean full run still owed" (`PROGRESS.md:24`). No CI build includes these commits, the iOS changes were never compiled, and the server change is not deployed. The only device evidence is TestFlight 147 (`b6fc0dad`), which contains none of the fixes.
- Required action: re-verify. Freeze a candidate, run the strict gate, build it through the release workflow, then run MDT-IOS on that artifact.

## Commit verdicts

| Commit | Subject | Verdict | Reason |
|---|---|---|---|
| `64e571e5` | CI app version + Flutter skip gate | ACCEPT WITH FOLLOW-UP | Version fix correct in all three workflows (contract test 25/25). The skip gate adds visibility but runs nothing; it is bypassable and hides a failing suite (REV-06). |
| `f9c5be75` | Next.js 14.2.35 + runbook | ACCEPT WITH FOLLOW-UP | Patch and `remotePatterns` removal are safe, and the runbook now matches the rollback SQL (`…_rollback.sql:42,142`). The residual risk is understated (REV-07); `RELEASE-PLAN.md:288` is stale. |
| `d70ba396` | iOS required-reason APIs + scene cover | ACCEPT WITH FOLLOW-UP | Reasons match the code (REV-09). The cover was never compiled or run, and there is an inactive-state gap (REV-08). |
| `2f2c4707` | Help copy | ACCEPT | Copy now matches the ZIP export and auto-confirm behaviour, in both languages. |
| `ff1fc292` | Zone-less as UTC | ACCEPT WITH FOLLOW-UP | Consistent with every writer found. The test cannot fail on a UTC host (REV-11). |
| `7597bb42` | Force-update version range | ACCEPT WITH FOLLOW-UP | A malformed bound now fails open; V1-040 unchanged (REV-10). |
| `d35fc044` | Declined, year-less dates, AI grounding | ACCEPT WITH FOLLOW-UP — does **not** close V1-001 | A net improvement with passing tests, but false negatives through the exemption (one becomes a fabricated refund), false positives, server/preview drift, a deploy dependency, and existing data unrepaired (REV-01–05). Dates and grounding are acceptable (REV-17). Pre-existing test edits only pin `now` (`meridiem_time_test.dart`, `parser_engine_test.dart:200-212`), with no assertion weakened. |

## Release decision recommendation (by SEVERITY-AND-GATES.md)

- **iOS: NOT READY.** Open S1: V1-001 (REV-01, REV-03), V1-003, and, after re-rating, V1-007, V1-015, V1-014 and V1-020 (REV-12–14). Gates unmet: G0 (no manifest), G1 (no strict run at HEAD; REV-06 failing suite), G2 (expired evidence, REV-15/16), G3, G4 (no release-workflow build, V1-009), G5 (no device run of any fix), G6 (A1–A4, A8, A12, A16), G7 (V1-002, V1-021, V1-023), G9.
- **Android: NOT READY.** V1-004 (S1, owner decision on scope), plus V1-001 and V1-003. No release AAB, no device run; every Play row in STORE-READINESS is NOT MET or CANNOT JUDGE.
- **Backend: NOT READY.** V1-002 (S1, production migration state unknown). The `process-ios-sms` deploy that V1-001 depends on is not in the plan (REV-03). V1-021, V1-023 and V1-024 are open S2s with no exception. G7 is unmet.
- **Combined: NOT READY.** Precise blockers: V1-001, V1-002, V1-003, V1-004, V1-007, V1-014, V1-015, V1-020, and gates G0–G7 and G9 as listed above.
