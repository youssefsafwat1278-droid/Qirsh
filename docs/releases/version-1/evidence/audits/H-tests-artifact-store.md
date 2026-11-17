# Test quality, release artifact and store readiness audit — Qirsh V1
Model: claude-opus-5-5
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: Test quality / release artifact / store readiness specialist (AI agent)

## 1. Scope covered / not covered

Covered (read-only, at ab5dc10a):
- Test inventory and quality for critical journeys (976 Flutter `_test.dart` files, `supabase/tests`, native test targets). Flutter skips/`markTestSkipped`, Deno/Node manifest, tagged stages.
- CI gates: `tools/ci_gates.sh`, `.github/workflows/ci.yml`, `codemagic.yaml` (all 5 workflows).
- Release configuration: version/build sources, `--dart-define` sets per workflow, auth-method flags, debug-only hooks, provenance stamp.
- Supply chain: `pubspec.yaml/lock`, `third_party/file_picker`, `tools/check_deps_policy.sh`, `Podfile.lock`, `flutter pub outdated`, `npm audit --omit=dev` (admin), license scan of the resolved package set.
- Store readiness: `docs/v1-release/V1_APP_STORE_{SUBMISSION,CHECKLIST}.md`, `docs/MANUAL_RELEASE_PREREQUISITES.md`, `docs/project/EXTERNAL_REQUIREMENTS.md`, `Qirsh Production/18_Android_SMS_Capture/data_safety_draft.md`, `docs/legal/PRIVACY_POLICY.md`, the live `https://qirsh.site` pages (HTTP GET only), `ios/Runner/Info.plist`, `PrivacyInfo.xcprivacy`, `AndroidManifest.xml`, `build.gradle.kts`, `project.pbxproj`.

Not covered: App Store Connect / Play Console state (no access), Codemagic run history (no access), any Android build (no Java), any device run, full Flutter suite (forbidden by brief; the baseline run is separate). Store-policy statements below come from my knowledge of Apple/Google policy as of my training; items marked **[verify]** should be checked against the current primary source.

## 2. What is established (verified behavior, with evidence)

- **A red gate cannot produce a signed upload** in any Codemagic release workflow: `ios-signed` (`codemagic.yaml:793-803`), `ios-signed-release` (`:227-251`) and `android-release` (`:426-449`) run `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` before provisioning/keystore/build steps; no step has `ignore_failure`. `grep -n "ignore_failure\|allow_failure" codemagic.yaml` → no hits. Strict mode makes tool-missing and `SKIP_FLUTTER_TEST` fatal (`tools/ci_gates.sh:52-66, 249-254`).
- `ios-signed` (the workflow that produced TestFlight 1.0.0 (147)) asserts the production Supabase URL identity (`:835-846`), verifies both App Store profiles, entitlements, signing certificate, `CFBundleShortVersionString`/`CFBundleVersion` inside the IPA (`:882-939`), and stamps an external provenance sidecar binding IPA SHA-256 to `git_commit` (`tools/stamp_ios_provenance.sh:29-44`).
- Build number for `ios-signed` = ASC latest for the marketing version + 1, floored at 146 (`codemagic.yaml:759-791`). Sound for 1.0.0.
- `kAppVersion` falls back to `kPubspecVersion = '1.0.0'` (`app/lib/core/backend/app_version.dart:30-38`); the stale `+44` build part of `pubspec.yaml:4` is not read by Dart code. `ios-signed` passes `APP_VERSION="$IOS_MARKETING_VERSION"` (`codemagic.yaml:876`) — correct for that workflow.
- Debug-only capabilities are release-inert by construction: UMP debug/ads override ANDed with `!kReleaseMode` (`app/lib/features/report_ads/report_ads_debug_config.dart:24-32`), QA local identity returns on `kReleaseMode` (`app/lib/core/startup/qa_local_identity.dart:16`), design gallery and sync-diagnostics routes only in debug (`app/lib/core/router/app_router.dart:401-415`).
- Ads: every request is non-personalised (`app/lib/features/ads/banner_ad_controller.dart:154`, `report_export_ad_gateway.dart:123`); no ATT string in `Info.plist`.
- Sign in with Apple is offered on iOS whenever Google is (`auth_screen.dart:49, 332`); Apple token-revocation gateway exists for deletion (`supabase/functions/_shared/apple_deletion_gateway.ts`). In-app immediate account deletion exists (`app/lib/features/settings/delete_account_screen.dart:37`).
- Android `targetSdk = flutter.targetSdkVersion` = 36 under Flutter 3.47.3 (`/opt/homebrew/share/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34`) — meets the current Play target-API requirement. Only `RECEIVE_SMS` (no `READ_SMS`) is declared (`AndroidManifest.xml:44`); `allowBackup="false"` (`:72`).
- Privacy policy and support pages are live: `curl` → `/privacy 200`, `/terms 200`, `/en/privacy 200`, `/support 200`, `/en/support 200`.
- Supply chain: `pubspec.lock` and `Podfile.lock` committed; no `git:` deps; two allowlisted path deps (`tools/check_deps_policy.sh:34`). `third_party/file_picker` is a verbatim 11.0.3 copy plus one AGP-9 registration backport, MIT-licensed, with documented reason (`third_party/file_picker/QIRSH_FORK.md`). License scan of the 236 resolved packages: only `dbus` and `gtk` carry (L)GPL-family text, both Linux-desktop-only and not shipped on iOS/Android; no GPL/AGPL in the mobile artifact.
- The suggested timezone check passes in every zone: `TZ=Africa/Cairo|UTC|America/Los_Angeles|Asia/Kolkata flutter test --no-pub test/core/sync/sync_conflict_store_test.dart` → `+9: All tests passed!` each. That is because the suite only uses zoned timestamps — see REL-09.

## 3. Findings

### REL-01 — Android release build has no sign-in method (auth flags not passed)
- Severity: S1 · Class: CODE-SUPPORTED · Platforms: Android
- User impact: An AAB from `android-release` shows no sign-in button. Android has no Apple sign-in and no guest path, so nobody can sign in. This is a broken critical journey on the first Android release.
- Evidence: `AuthMethodsConfig` reads `bool.fromEnvironment('QIRSH_GOOGLE_AUTH_ENABLED' / 'QIRSH_EMAIL_AUTH_ENABLED' / 'QIRSH_ALTERNATE_SIGNUP_ENABLED')`, which default to `false` (`app/lib/core/auth/auth_methods_config.dart:7-9`). The Google button needs `methods.google` (`app/lib/features/onboarding/auth_screen.dart:194-198`), email needs `methods.email` (`:266`, `:395`), Apple is iOS-only (`:49`). `android-release` passes none of the three defines (`codemagic.yaml:501-512`); all iOS workflows do (`:103-105, 318-320, 873-875`). The workflow's own comment says "Google is the sole way into the app on Android" (`:456-466`) and checks only `GOOGLE_SERVER_CLIENT_ID`. No test guards this: `grep -rn QIRSH_GOOGLE_AUTH_ENABLED app/test` → no hits.
- Root cause: the auth-method flags were added to the iOS workflows only.
- Proposed fix: add `--dart-define=QIRSH_GOOGLE_AUTH_ENABLED=…` (plus email/signup as the owner decides) to `android-release`, and add a guard test that every release workflow passes the define set. No compatibility impact.
- Verification required after fix: build the AAB, install it, and confirm the Google button shows and sign-in completes. Add a test that parses `codemagic.yaml`.

### REL-02 — Store privacy disclosures (App Privacy labels, Play Data safety) do not match what the app collects
- Severity: S1 · Class: CODE-SUPPORTED (what was entered in the consoles: ENV-LIMITATION) · Platforms: iOS, Android
- User impact: An inaccurate privacy label or Data safety form breaks Apple Guideline 5.1.1/5.1.2 and Google Play's User Data policy. Either store can reject or remove the app.
- Evidence:
  - The prepared iOS label (`docs/v1-release/V1_APP_STORE_SUBMISSION.md:19-28`) and `ios/Runner/PrivacyInfo.xcprivacy` (6 types: OtherFinancialInfo, EmailAddress, Name, PhoneNumber, DeviceID, CrashData) leave out several things the code does:
    - Sanitised bank SMS text, sender and time go to the backend and to the Gemini API: `capture_backend_client.dart:175` (`process-ios-sms`) and the privacy policy table at `docs/legal/PRIVACY_POLICY.md:206-207`. In Apple's categories this is User Content → "Emails or Text Messages".
    - The profile photo is uploaded to cloud storage (`app/lib/features/settings/profile_photo_sync_service.dart:27-66`; policy `:188`). Apple: Photos or Videos.
    - Activity timestamps are written (`profiles.last_seen_at`, `app/lib/core/tracking/user_activity_service.dart:1-14`), along with engagement events. Apple: Usage Data → Product Interaction, first-party.
  - The Play Data safety draft (`Qirsh Production/18_Android_SMS_Capture/data_safety_draft.md:88-102`, dated 2026-09-02) marks "Photos/videos" as **Not collected**. It has no Email/Name (Personal info) row, no App activity row, and no advertising row.
  - `play-services-ads` is linked and the manifest does not remove `com.google.android.gms.permission.AD_ID` (`grep AD_ID AndroidManifest.xml` → no hits). Play's advertising-ID declaration and the ads rows are therefore owed. `docs/MANUAL_RELEASE_PREREQUISITES.md:91-93,111-112` instead says "Ads declaration: No ads for v1". That conflicts with the remote-flag reasoning in `V1_APP_STORE_SUBMISSION.md:42-45`, which says the label must declare ads anyway.
- Proposed fix: rebuild both disclosures from the code as it is now: SMS text, photos, product interaction, email/name, device IDs, and ads (iOS: Device ID + Product Interaction, third-party advertising, not linked; Play: advertising ID). Update `PrivacyInfo.xcprivacy` to match. No app compatibility impact.
- Verification required after fix: owner screenshots of the App Store Connect App Privacy and Play Data safety pages, checked line by line against a data-flow inventory.

### REL-03 — No hardened App Store–eligible iOS pipeline: the vetted workflow is internal-TestFlight-only, and the App Store one is weaker
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: iOS
- User impact: Build 147 (`ios-signed`) is exported with `testFlightInternalTestingOnly: true` (`codemagic.yaml:833`). Its publishing step says Apple rejects external review for such builds (`:948-953`). So 147, and any build from this workflow, cannot go to external TestFlight or App Review. The only App Store–capable workflow is `ios-signed-release`. It lacks the `ios-signed` protections:
  - It checks only that `SUPABASE_URL` is non-empty, not that it is the production URL (`:270-277` vs `:835-842`).
  - It has no reviewed-SHA, branch or clean-tree check.
  - It does no post-export signing or entitlement verification (`:331-350` vs `:882-939`).
  - It does not set `QIRSH_*_AUTH_ENABLED` by default, so Google and email default off.
  - It ships an empty `APP_VERSION` (REL-04).
  - It auto-submits to TestFlight. The comment says it "does NOT submit for App Review" (`:358-373`), yet `submit_to_testflight: true` is the action the `ios-signed` comment says requests external beta review (`:949-950`).
- Proposed fix: give the store build one hardened path. Either remove the internal-only export option from a copy of `ios-signed` used for App Store builds, or port all of `ios-signed`'s checks into `ios-signed-release`.
- Verification required after fix: a dry Codemagic run on the candidate SHA. Confirm the uploaded build is eligible for external testing and submission in App Store Connect.

### REL-04 — `APP_VERSION` is defined as an empty string in three workflows (version targeting, What's new and the Settings version silently broken)
- Severity: S2 · Class: REPRODUCED · Platforms: iOS (`ios-signed-release`, `ios-unsigned-sideload`), Android (`android-release`)
- User impact:
  - `X-App-Version` is sent as `''`, so version-targeted announcements, flags and force-update rows match nothing. This is the same defect F-024 was meant to fix (`app_version.dart:1-12`).
  - `targetsVersion(kAppVersion)` filters out update banners and release notes (`whats_new_screen.dart:25`, `announcement_banner.dart:35`).
  - The What's new trigger stores `''` (`whats_new_trigger.dart:47-49`).
  - Settings shows an empty version (`settings_screen.dart:566`).
- Evidence: these steps run with `working_directory: app` but read `app/pubspec.yaml` (`codemagic.yaml:92-106, 296-321, 496-509`). Reproduced: `cd app && sed -n 's/^version: *\([0-9.]*\).*/\1/p' app/pubspec.yaml` → `sed: app/pubspec.yaml: No such file or directory`, empty output. Dart semantics, reproduced in a scratch program: `dart run -DAPP_VERSION= m.dart` → `[]`, while with no define → `[1.0.0]`. So the empty define beats the fallback. `set -eu` does not catch a failing command substitution inside an argument.
- Proposed fix: use `pubspec.yaml` (relative to `app/`) or reuse `$IOS_MARKETING_VERSION`. Also make `kAppVersion` treat an empty define as absent, the way `legal_urls.dart:38-60` already does for `LEGAL_BASE_URL`.
- Verification required after fix: a unit test with `--dart-define=APP_VERSION=` that expects `1.0.0`, and a guard test over `codemagic.yaml` working directories.

### REL-05 — Flutter test skips are outside the skip manifest; six suites never run in any CI and the run still reports "All tests passed"
- Severity: S2 · Class: REPRODUCED · Platforms: All
- User impact: These suites only run with `--dart-define=SUPABASE_ENV=local SUPABASE_URL=https://example.supabase.co SUPABASE_ANON_KEY=anon`, and nothing passes those defines (`grep -rn "SUPABASE_ENV=local\|example.supabase.co" tools codemagic.yaml .github` → no hits):
  - consent barrier ("denied activity is not throttled…", `test/core/tracking/user_activity_consent_test.dart:100-154`)
  - QD003 configured legacy deletion RPC (`test/core/auth/immediate_account_deletion_test.dart:383-447`)
  - configured real-sender remove-data bootstrap (`test/core/startup/bootstrap_remove_data_integration_test.dart:482-782`)
  - default-RPC refusal (`test/features/planning_sync/startup_reconcile_default_rpc_refusal_test.dart:312-321`)
  - smart-inbox status cycle (`test/features/app/smart_inbox_status_cycle_test.dart:270-273`)
  - three `local_read_host` cases (`test/core/session/local_read_host_test.dart:284,313,350`)

  `tools/check_test_skips.mjs` governs only Node `# SKIP` and Deno `ignored` (`tools/test_skip_manifest.json`; the script never references flutter or dart). New Flutter skips are therefore invisible to the gate.
- Evidence: `flutter test --no-pub test/core/tracking/user_activity_consent_test.dart test/features/planning_sync/startup_reconcile_default_rpc_refusal_test.dart test/core/auth/immediate_account_deletion_test.dart` → `+39 ~7: All tests passed!` (7 skipped). The `markTestSkipped('openssl unavailable')` paths (`refresh_transport_test.dart`, `owned_tls_socket_test.dart`, `asr_production_path_test.dart:807`) and `vendored_file_picker_test.dart:74` likewise turn into a silent pass when a host tool is missing.
- Proposed fix: add a Flutter stage to `ci_gates.sh` that runs the synthetic-define suites with the exact defines. Extend the manifest checker to parse `flutter test --reporter json` skip events.
- Verification required after fix: the gate fails when a new `skip:` is added and passes with the defines stage running these suites.

### REL-06 — Native code (iOS 194 XCTests, Android Kotlin) is never tested in CI; Android owner isolation and consent gating are covered only by Dart models and source-text checks
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: iOS, Android
- User impact: Regressions in native capture-queue ownership, consent gating and the share extension can ship green. Account ownership of queued captures is a cross-account data risk.
- Evidence:
  - `app/ios/RunnerTests/RunnerTests.swift` has 194 `func test…` (5,712 lines, last changed 2026-11-16, including owner/revocation tests at `:131-245`). `android/app/src/test/.../CaptureOptInPolicyTest.kt` and `SessionVaultTest.kt` exist. `grep -n "xcodebuild test\|gradlew test\|testDebugUnitTest" codemagic.yaml tools .github` → no hits.
  - `test/features/capture/android_capture_owner_isolation_test.dart:1-12` tests a hand-written Dart model of `DurableCaptureQueue.kt` (`_AndroidNative`, `:68-80`), i.e. a mock of the thing under test. Its header says the Kotlin side ran in a "scratchpad kt_harness" that is not in the repository.
  - `test/features/capture/android_sms_permission_test.dart:71-82` "verifies" Android auto-capture defaults and permission gating by `contains('getBoolean(KEY_AUTO_ENABLED, false)')` on Kotlin source.
  - Overall, 89 Flutter test files read `lib/`, `ios/` or `android/` source as text (30 in `test/architecture`).
  - The ~45 device suites in `app/integration_test/` (including `cloud_off_egress_test.dart`, `backup_restore_roundtrip_test.dart`) are never run by CI.
- Proposed fix: add `xcodebuild test -scheme Runner` (simulator) to the Codemagic quality workflow and `./gradlew testDebugUnitTest` to its Android stage. Commit the Kotlin harness as real JVM unit tests for `DurableCaptureQueue` owner/ack semantics.
- Verification required after fix: an intentionally broken owner check in `DurableCaptureQueue.kt` / the Swift store fails CI.

### REL-07 — Backend behavior (RLS, RPCs, migrations) is not executed by any CI gate
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: Backend
- User impact: A migration or RLS policy that is wrong at runtime but textually plausible passes every gate. That covers cross-account access, deletion completeness and the capture state machine.
- Evidence: `ci_gates.sh` runs only `supabase/tests/*.mjs`. 26 of 40 `.mjs` files use `readFileSync` over SQL/TS and assert with regex/`includes`; for example `owner_table_grants_contract_test.mjs:64-118` (`assert.match(GRANTS, /TO authenticated/i)`, `raw.includes('ROLLBACK')`). The live cases self-skip without credentials (`tools/test_skip_manifest.json` node/deno entries, `mustRunWhenPrereq`), and CI deliberately unsets those credentials (`codemagic.yaml:240-251`). The 31 `.sql`/`.sh` harnesses (for example `capture_state_machine_p1.sql`, `capture_expiry_fence.sh`) are wired into no gate. `check_migrations.sh` is a lint.
- Proposed fix: add a CI stage that starts `supabase start` (local stack), applies all migrations from zero, and runs the SQL harnesses and the live node/deno cases against it with service-role credentials for that local stack only.
- Verification required after fix: a deliberately wrong RLS predicate in a scratch migration fails the gate.

### REL-08 — Universal (iPhone + iPad) target with only iPhone screenshots and no iPad QA evidence
- Severity: S2 (S1 if submitted as-is) · Class: PRODUCT-DECISION · Platforms: iOS
- User impact: App Store Connect requires iPad screenshots for an app that supports iPad, and review runs on iPad too (Guideline 2.4.1) **[verify current screenshot sizes]**. Removing iPad support after the first public release is not possible.
- Evidence: `TARGETED_DEVICE_FAMILY = "1,2"` in all target configs (`app/ios/Runner.xcodeproj/project.pbxproj:637,783,838,926,953`). Screenshot evidence is 13 iPhone 6.9" captures only (`docs/v1-release/V1_APP_STORE_SUBMISSION.md:118-122`), produced by `integration_test/store_screenshots_test.dart`, which was last changed 2026-09-16, before the later UI redesign work.
- Proposed fix: the owner decides whether to set iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) before first release, or to produce iPad screenshots and run iPad QA. Regenerate the screenshots from the candidate UI either way.
- Verification required after fix: App Store Connect accepts the media set, and an iPad simulator walk passes.

### REL-09 — Conflict date normalisation is timezone-dependent; the tests cannot detect it
- Severity: S2 · Class: REPRODUCED (function); production reachability SUSPECTED · Platforms: All (Egypt/KSA users run at UTC+2/+3)
- User impact: A goal deadline or plan date that is identical on both sides is shown as a false "date" conflict for users outside UTC. This matches the known unresolved issue in the team's notes.
- Evidence: `_norm` with `ConflictFieldKind.date` does `DateTime.tryParse(v).toUtc()` (`app/lib/core/sync/conflict_fields.dart:145-152`); a zone-less string is parsed as local time. Scratch probe calling `diffConflictFields('goal', {'deadline':'2026-03-01T00:00:00.000'}, {'deadline':'2026-03-01T00:00:00+00:00'})`:
  - `TZ=UTC` → `diffs=0`
  - `TZ=Africa/Cairo` → `diffs=1 2026-02-28 22:00|2026-03-01`

  The suite's fixtures are all zoned (`test/core/sync/sync_conflict_store_test.dart:32,41,58-59`), so it passes in every zone (established in §2).
- Proposed fix: parse zone-less values as UTC (or compare date-only fields as calendar dates). Add zone-less fixtures and run that test file under `TZ=Africa/Cairo` in CI.
- Verification required after fix: the probe gives 0 diffs in Cairo, UTC and LA.

### REL-10 — Admin panel depends on Next.js 14.2.29 with critical/high advisories
- Severity: S2 · Class: REPRODUCED · Platforms: Admin
- User impact: Known Next.js advisories include middleware redirect SSRF, cache poisoning, image-optimizer issues and Server Components DoS. Their exposure depends on how the admin is deployed (not verified).
- Evidence: `admin/package.json:15` `"next": "14.2.29"`. `cd admin && npm audit --omit=dev` → `4 vulnerabilities (3 high, 1 critical)`: next (critical, 20+ GHSAs including GHSA-4342-x723-ch2f and GHSA-g5qg-72qw-gw5v), postcss, nanoid, source-map-js. `next.config.mjs:3-4` configures `images.remotePatterns`, and `next/image` is used. No CVE/advisory scan exists in any gate (`check_deps_policy.sh:5-9` defers it "out-of-band").
- Proposed fix: upgrade to a patched Next line (breaking upgrade; run the admin auth suite). Add `npm audit --omit=dev --audit-level=high` as an informational CI step.
- Verification required after fix: `npm audit --omit=dev` is clean of high/critical, and `npm run test:auth` passes.

### REL-11 — Export compliance is hard-coded as "no non-exempt encryption" despite app-level cryptography
- Severity: S2 · Class: PRODUCT-DECISION · Platforms: iOS
- User impact: A wrong export-compliance declaration is a legal attestation on every build.
- Evidence: `ITSAppUsesNonExemptEncryption` = `false` (`app/ios/Runner/Info.plist:103-104`). The app implements its own Argon2id + symmetric backup encryption through the `cryptography` package (`app/dart_test.yaml` header; `BackupCrypto v3`) and SQLCipher at rest. The submission doc itself says to answer the questionnaire rather than hard-code the key (`V1_APP_STORE_SUBMISSION.md:66-73`). Under App Store Connect's current questionnaire, "standard encryption algorithms instead of, or in addition to, Apple's OS encryption" may carry documentation / French-distribution obligations **[verify]**.
- Proposed fix: the owner (with export-control advice) answers the ASC questionnaire, then aligns the Info.plist key with that answer.
- Verification required after fix: the ASC export-compliance record matches the plist.

### REL-12 — Reviewer access and review notes do not match the build
- Severity: S2 · Class: CODE-SUPPORTED (account state: ENV-LIMITATION) · Platforms: iOS, Android
- User impact: Guideline 2.1 rejection ("unable to review the core feature") is likely. A reviewer cannot receive bank SMS.
- Evidence:
  - The demo account is `NEEDS_USER_ACTION`, with an explicit warning to supply a "manual-paste walkthrough" (`docs/MANUAL_RELEASE_PREREQUISITES.md:97`). No demo/sample-message feature exists in `lib/` (grep for demo/sample hits only the design gallery and QA identity).
  - The prepared notes (`V1_APP_STORE_SUBMISSION.md:77-104`) claim things the code no longer matches:
    - "Email/password, Apple and Google are all supported". Actually build-flag dependent; REL-01, REL-03.
    - "local financial database is wiped on sign-out". The current flow is Sign out → Remove data as a separate choice (`PRIVACY_POLICY.md:156-160`).
    - "listing declares Arabic only". The app now ships ar + en (`app/lib/l10n/app_localizations.dart:95-96`).
  - The privacy policy says account deletion is "scheduled for permanent deletion after 30 days. You can undo it…" (`docs/legal/PRIVACY_POLICY.md:162-166`, same text live at `https://qirsh.site/privacy`). The app performs an "immediate, permanent" deletion (`delete_account_screen.dart:37`).
- Proposed fix: create a seeded reviewer account. Write notes that walk through the iOS Share-extension / Shortcut path with a synthetic bank message. Correct the policy's deletion section.
- Verification required after fix: a fresh install signs in with the reviewer account on iPhone and iPad and completes the walkthrough. The live policy text matches the app.

### REL-13 — Privacy policy omits Google AdMob / UMP although the SDK is linked and ads are remote-flag enabled
- Severity: S2 (S1 if any ad placement is enabled at launch) · Class: CODE-SUPPORTED · Platforms: iOS, Android
- Evidence: the third-party table (`docs/legal/PRIVACY_POLICY.md:204-210`) lists Supabase, Gemini, Places, Sentry, and Google/Apple sign-in. `grep -i admob` of the policy and of the live page returns nothing. Meanwhile `GADApplicationIdentifier`/`SKAdNetworkItems` are in `Info.plist`, the `admob` group is attached to `ios-signed-release` and `android-release`, and the banner flags are remote (`V1_APP_STORE_CHECKLIST.md:104-130`). AdMob program policy and both stores expect the privacy policy to disclose ad SDK data use **[verify wording]**.
- Proposed fix: add an AdMob/UMP row (data: device/advertising identifiers, IP, interaction; non-personalised), or remove the SDK from V1.
- Verification required after fix: the live page shows the row.

### REL-14 — App reports only the marketing version; build-level identity is unavailable at runtime
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: All
- User impact: Every TestFlight build (44…147+) and the store 1.0.0 report `X-App-Version: 1.0.0`. As a result:
  - force-update and announcements cannot target beta builds or move them to the store build;
  - What's new does not fire between same-version builds;
  - support cannot tell builds apart from the Settings screen.
- Evidence: `app_version.dart:30-38` (marketing version only, `package_info_plus` avoided by design); `settings_screen.dart:566`; `whats_new_sheet.dart:22`; `CI_GATES_JSON` carries no commit or version (`tools/ci_gates.sh:271`).
- Proposed fix: add the build number (dart-define `APP_BUILD`) to the header and to Settings. Add the commit and version to `CI_GATES_JSON`.
- Verification required after fix: the header shows `1.0.0+N` in a CI build.

### REL-15 — Android `versionCode` comes from the stale pubspec build number
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Android
- Evidence: `versionCode = flutter.versionCode` (`app/android/app/build.gradle.kts:114`). `android-release` passes no `--build-number` (`codemagic.yaml:501-512`), so every AAB is versionCode 44 (`app/pubspec.yaml:4`). Play rejects a second upload with the same code.
- Proposed fix: resolve the next versionCode (Play API or a monotonic CI counter) and pass `--build-number`.
- Verification required after fix: two consecutive AABs carry increasing versionCodes (`bundletool dump manifest`).

### REL-16 — The "approved immutable CI revision" check is self-attested and pinned to a personal beta branch
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: iOS
- Evidence: `EXPECTED_REVIEWED_CI_SHA` is a variable supplied by whoever starts the build (`codemagic.yaml:734-753`). It proves the trigger typed the SHA being built, not that anyone reviewed it; there is no signed approval or protected-branch link. The branch is hard-coded to `release/ios-beta1-personal-20261013` (`:737`), so a V1 build from `main` or a release branch is refused. The QA-source rejection regex covers only 5 files (`:745-751`). `xcode: latest` is not pinned (`:723`).
- Proposed fix: bind approval to a protected branch or tag plus a required review. Parameterise the branch. Pin the Xcode version.
- Verification required after fix: a build from an unapproved SHA or branch fails.

### REL-17 — No independent CI evidence on GitHub
- Severity: S3 · Class: REPRODUCED · Platforms: All
- Evidence: `gh run list --limit 8` → `[]`, `gh pr list --state all` → `[]`, while the `CI` workflow is `active`. `ci.yml` triggers only on pushes to main/master/develop and on PRs (`.github/workflows/ci.yml:3-7`). It uses an unpinned Flutter `channel: stable` (`:21-24`, vs 3.47.3 everywhere else) and runs non-strict. All gate evidence therefore lives in Codemagic, which I cannot see.
- Proposed fix: pin Flutter 3.47.3, run with `REQUIRE_ALL_GATES=1` on the release branch, and confirm Actions is actually executing.
- Verification required: the orchestrator obtains the Codemagic `backend-and-quality-gates` and `ios-signed` logs for ab5dc10a/b6fc0dad.

### REL-18 — `ios-signed-release` build-number resolution likely fails for a new marketing version
- Severity: S3 · Class: SUSPECTED · Platforms: iOS
- Evidence: the workflow calls `get-latest-build-number --version-string "$MARKETING_VERSION"` with no fallback and fails when the output is empty or non-numeric (`codemagic.yaml:207-215`). For a version with no builds yet (for example 1.0.1) this probably aborts. `ios-signed` has a floor (`:784-788`); this workflow has none.
- Proposed fix: fall back to the latest build across all versions, or to the floor.
- Verification required: a dry run with an unused version string.

### REL-19 — Licences, localisation and dependency hygiene
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: iOS, Android
- Evidence and fixes:
  - (a) There is no in-app licences page. `showLicensePage` and `LicensePage` are never called; fonts are registered with `LicenseRegistry` (`app/lib/core/theme/font_licenses.dart:51`) but cannot be reached. MIT/BSD/Apache/OFL notice obligations for the binary are therefore unmet. Fix: add a Settings → Licences entry.
  - (b) iOS declares no `CFBundleLocalizations` and has no `ar.lproj` (`find ios/Runner -name "*.lproj"` → `Base.lproj` only; `developmentRegion = en`, `project.pbxproj:356`). iOS shows its own dialogs and the per-app language setting as English-only, the App Store listing infers English only, and permission strings are English. Fix: add `CFBundleLocalizations` [ar, en] plus `ar.lproj/InfoPlist.strings`.
  - (c) The production app uses the dev pre-release `liquid_glass_renderer 0.2.0-dev.4`. Two transitive packages are discontinued (`flutter_secure_storage_macos`, `js`). 75 locked-older dependencies (`flutter pub outdated --no-dev-dependencies`). No advisory scan exists for pub. Record this as a known limitation or plan upgrades.

### REL-20 — Play account-deletion URL and SMS declaration still open
- Severity: S3 · Class: ENV-LIMITATION / PRODUCT-DECISION · Platforms: Android
- Evidence:
  - There is no dedicated web deletion page: `https://qirsh.site/delete-account` → 404, `/account-deletion` → 404. The policy's §5 (in-app steps plus an email request, `PRIVACY_POLICY.md:146-170`) may be usable as the Play deletion URL if it names the app and the steps **[verify]**.
  - The Play SMS Permissions Declaration under the "SMS-based money management" exception is `EXTERNAL APPROVAL` (`docs/project/EXTERNAL_REQUIREMENTS.md`, first table row) **[verify the exception is still listed]**.
  - The Financial features declaration is `NEEDS_USER_ACTION` (`MANUAL_RELEASE_PREREQUISITES.md:114`).
  - The 16 KB page-size requirement for new uploads targeting Android 15+ cannot be checked without a build **[verify]**.

### REL-21 — Documentation drift in release documents
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: All
- Evidence:
  - `V1_APP_STORE_SUBMISSION.md:7` and `V1_APP_STORE_CHECKLIST.md:13` say 1.0.0 (40); the current build is 147.
  - The checklist claims an Arabic-only listing with 11% coverage (`:31-38`).
  - `MANUAL_RELEASE_PREREQUISITES.md:88-89` says the privacy URL is "NXDOMAIN" and that no support URL exists; both are live (200).
  - `EXTERNAL_REQUIREMENTS.md` ("As of 2026-09-03") contradicts MANUAL on keystore state.
  - The `ios-signed-release` publishing comment is wrong (REL-03).
  - The live policy lags the repository (the repo lists "your profile photo" in §5; the live text does not).
- Fix: refresh or retire these documents after the fixes above.

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| CI gating | All | Red mandatory gate blocks signing/upload | codemagic.yaml, ci_gates.sh | Code inspection | PASS | §2 | — |
| CI gating | All | Caller cannot skip Flutter tests in release | ci_gates.sh strict | Code inspection | PASS | ci_gates.sh:52-66,249-254 | — |
| CI gating | All | Flutter test skips governed | check_test_skips.mjs | Ran 3 suites + inspection | FAIL | `+39 ~7: All tests passed!` | REL-05 |
| Native tests | iOS/Android | XCTest / Kotlin tests run in CI | codemagic.yaml | grep | FAIL | no xcodebuild/gradle test | REL-06 |
| Backend tests | Backend | RLS/migrations executed | supabase/tests | Inspection | FAIL | 26/40 source-contract; SQL harnesses unwired | REL-07 |
| Sync conflicts | All | Date conflict TZ-independent | conflict_fields.dart | Scratch probe, 2 TZ | FAIL | Cairo diffs=1, UTC diffs=0 | REL-09 |
| Sync conflicts | All | Existing suite TZ-stable | sync_conflict_store_test | Ran in 4 TZ | PASS | all `+9` | (blind spot REL-09) |
| Auth | Android | Release build offers a sign-in method | auth_methods_config, android-release | Code inspection | FAIL | REL-01 | REL-01 |
| Auth | iOS | SIWA offered with Google | auth_screen.dart | Code inspection | PASS | :49,:332 | — |
| Versioning | iOS (ios-signed) | APP_VERSION = marketing version | codemagic.yaml:876 | Inspection | PASS | — | — |
| Versioning | iOS/Android (other workflows) | APP_VERSION non-empty | codemagic.yaml | Reproduced sed + dart | FAIL | REL-04 | REL-04 |
| Versioning | Android | versionCode increments | build.gradle.kts | Inspection | FAIL | REL-15 | REL-15 |
| Store pipeline | iOS | Build eligible for App Review | ios-signed export options | Inspection | FAIL | codemagic.yaml:833 | REL-03 |
| Provenance | iOS | IPA bound to commit | stamp_ios_provenance.sh | Inspection | PASS | :29-44 | — |
| Debug hooks | All | Inert in release | report_ads_debug_config, qa_local_identity, router | Inspection | PASS | §2 | — |
| Privacy labels | iOS | Label matches collection | PrivacyInfo.xcprivacy, submission doc | Inspection | FAIL | REL-02 | REL-02 |
| Data safety | Android | Form matches collection | data_safety_draft.md | Inspection | FAIL | REL-02 | REL-02 |
| Privacy policy | All | Live, accurate on deletion and ads | qirsh.site/privacy | HTTP GET + diff | FAIL | REL-12, REL-13 | REL-12/13 |
| Account deletion | iOS/Android | In-app deletion present | delete_account_screen.dart | Inspection | PASS (code) | :37 | — |
| Account deletion | Android | Web deletion URL | qirsh.site | HTTP GET | NOT TESTED (no dedicated page) | 404 | REL-20 |
| Export compliance | iOS | Declaration correct | Info.plist:103 | Inspection | NOT TESTED (legal) | — | REL-11 |
| Screenshots | iOS | iPhone + iPad media from current UI | store_screenshots_test | Inspection | FAIL | REL-08 | REL-08 |
| Reviewer access | iOS/Android | Reviewer can exercise core feature | — | Docs inspection | FAIL | REL-12 | REL-12 |
| Target API | Android | targetSdk meets Play | FlutterExtension.kt | Inspection | PASS | 36 | — |
| Dependencies | App | No git deps, lockfiles, vendored fork documented | check_deps_policy.sh | Inspection | PASS | §2 | — |
| Licences | App | No GPL/AGPL shipped | package_config scan | Script | PASS | dbus/gtk Linux-only | — |
| Licences | App | Notices reachable in app | — | grep | FAIL | REL-19a | REL-19 |
| Admin deps | Admin | No high/critical advisories | admin/package-lock | npm audit | FAIL | 3 high, 1 critical | REL-10 |
| Capture→parse→categorize→persist | All | Behavioral Dart tests exist | test/engine, test/domain, test/features/capture | Inventory | NOT TESTED (baseline run separate) | sms_sanitizer_test, engine/parser/*, dedup_test | — |
| Backup/restore | All | Behavioral tests exist | test/core/backup (20+ files) | Inventory | NOT TESTED (baseline) | restore_* tests | — |
| Drift migrations | All | Data-survival tests exist | test/data/db/migration_* | Inventory | NOT TESTED (baseline) | — | — |

## 5. Could not verify here (exact scenarios, what is needed)

1. App Store Connect state: App Privacy answers, export compliance, age rating (Apple's 2025 age-rating questionnaire revision **[verify]**), reviewer account, screenshots, TestFlight group type for 147. Needs owner ASC access.
2. Play Console: Data safety, SMS Permissions Declaration status, advertising-ID declaration, financial features declaration, deletion URL, app signing enrolment. Needs Play Console access.
3. Codemagic run logs for ab5dc10a / b6fc0dad (gates green? strict summary JSON?). Needs Codemagic access.
4. Android merged manifest (AD_ID, permissions), 16 KB alignment, AAB versionCode. Needs Java/AGP build plus `bundletool`.
5. Whether Apple's minimum-SDK rule for uploads (iOS 26 SDK / Xcode 26) is met by `xcode: latest` **[verify]**. The IPA's `DTSDKName` would show it.
6. Whether zone-less timestamps actually reach `diffConflictFields` in production snapshots (REL-09 reachability). Needs a device sync trace or the sync specialist's review.
7. Whether the admin panel is internet-exposed (REL-10 exposure).

## 6. Manual device test steps you recommend

1. Build `android-release` (after the REL-01 fix) and install it on a clean Android device → the auth screen shows the Google button, and sign-in reaches onboarding. Before the fix, expect **no** sign-in button.
2. Install the App Store–eligible iOS build on iPhone **and** iPad → Settings shows `1.0.0` (non-empty) and ideally the build number. The app is usable on iPad in both orientations.
3. Sign in with the reviewer account on a fresh iPhone. Share a synthetic bank message (e.g. "Purchase SAR 25.00 at SHOP1 card **** 0000") through the Share extension → a transaction appears with the right amount and category. This is the path reviewers must follow.
4. With the device timezone set to Cairo, edit a goal deadline on device A and leave it unchanged on device B, then sync → no conflict should appear for the deadline field.
5. Delete the account from Settings → the account is gone immediately (sign-in fails or creates a new account). Check that the in-app wording, the live policy §5 and the store deletion disclosure all say the same thing.
6. With cloud consent OFF, use the app for 5 minutes behind a recording proxy → no requests to the Supabase REST/functions endpoints (consent egress). The only device proof of this is `integration_test/cloud_off_egress_test.dart`, which CI never runs.
7. Open Settings → look for a Licences entry. Expected today: none (REL-19a).
