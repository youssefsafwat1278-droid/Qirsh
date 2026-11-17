# Android audit — Qirsh V1
Model: claude-opus-5-5 (Claude Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: Android specialist (AI agent)

## 1. Scope covered / not covered

Covered, by reading the code and documents at the candidate commit:
- Release status evidence: `docs/ANDROID_SMS_CAPTURE_DECISION.md`, `docs/privacy/ANDROID_SMS_AI_DISCLOSURE_PROPOSAL.md`, `docs/ANDROID_RELEASE_SIGNING.md`, `docs/project/DECISIONS.md` (D-1..D-3), `Qirsh Production/{01_Current_Status,06_Android,16_Android_Signing,18_Android_SMS_Capture}`, `codemagic.yaml` (`android-release`, `backend-and-quality-gates`), and `git log --since=2026-10-01 -- app/android`.
- `app/android/**`: the three manifests, `data_extraction_rules.xml`, the Gradle files, `key.properties.example`, `.gitignore`, all 11 Kotlin sources and the 2 Kotlin JVM tests.
- The Dart capture side as far as it touches Android: `android_sms_capture_service.dart`, the owner hooks in `bootstrap_runner.dart`, `app_version.dart`, and notification visibility in `local_notification_service.dart`.
- The resolved plugin manifests in the pub cache (`flutter_local_notifications 22.0.0`, `flutter_secure_storage 9.2.4`, `google_mobile_ads 9.0.0`, etc.) and the Flutter 3.47.3 Gradle defaults.
- The current Google Play target-API requirement (developer.android.com/google/play/requirements/target-sdk, fetched 2026-11-17).

Not covered:
- Anything at runtime. There is no Java runtime and no `adb` on this machine, so I could not run a Gradle build, the Kotlin JVM tests, a merged-manifest check, R8, or any device scenario.
- Codemagic build history. I cannot see whether `backend-and-quality-gates` (the only Android compile) ran or passed on this commit.
- Play Console state and the live text of `qirsh.site/privacy`.
- The iOS, backend and admin sides, apart from one cross-reference in AND-04.

## 2. What is established (verified behavior, with evidence)

**Release status according to the repository**
- Owner decision D-1 (2026-08-31): automatic SMS capture is a required core feature of Android V1, and the "share-only" position is revoked. Evidence: `docs/project/DECISIONS.md:11-24` and `Qirsh Production/18_Android_SMS_Capture/README.md:1-18`.
- Publication is gated on Google Play approval. The Play Permissions Declaration and the Data Safety form are drafted but not submitted, and physical-device SMS QA is still pending. Evidence: `docs/ANDROID_SMS_CAPTURE_DECISION.md:1-27` and the "Still required before publishing" list at the end of that document; `18_Android_SMS_Capture/README.md:13-17`; `01_Current_Status/current_release_status.md:78-80` (upload keystore not enrolled in Play App Signing; "no Android device has ever been connected").
- The disclosure proposal is a "FINAL DRAFT, NOT SUBMITTED". Several facts are still marked OWNER MUST CONFIRM, and the policy website "has not been regenerated". Evidence: `docs/privacy/ANDROID_SMS_AI_DISCLOSURE_PROPOSAL.md:3-20`.
- Recent Android work was all committed on 2026-11-12: `0b91574f` (durable queue), `8866dd13` (WorkManager + owner isolation), `6cd4fa37` (queue encryption), `dedce944` (cold-start drain), `6fd7000a` (session keychain) and `bd3bfe4e` (opt-in remembered per account). No Android build has been released since. TestFlight is the only distribution channel that has been used.
- **What is undecided:** no document says whether V1 is iOS-only or iOS plus Android. Nothing in the repository says Android was dropped from V1. Every Android document says it must not be published without Play approval, and that approval has not been requested.

**Code facts (inspection only, not run)**
- Only `RECEIVE_SMS` is declared. `READ_SMS`, `SEND_SMS`, `WRITE_SMS` and MMS/WAP are absent (`AndroidManifest.xml:44`).
- The SMS receiver is `exported="true"` and guarded by `android:permission="android.permission.BROADCAST_SMS"`, so only the system can deliver to it (`AndroidManifest.xml:145-152`).
- Two-key rule:
  - `SmsCaptureReceiver.onReceive` returns before reading the intent unless `CaptureSettings.isAutoCaptureEnabled` is true (`SmsCaptureReceiver.kt:39`).
  - That check re-reads the OS permission on every call (`CaptureSettings.kt:65-74`).
  - The opt-in defaults to false (`CaptureSettings.kt:86`).
  - It also requires an active owner whose own action turned capture on (`DurableCaptureQueue.kt:208-210`).
- Disclosure ordering:
  - `requestAndEnable` cannot reach the system dialog without `showDisclosure()` returning true (`android_sms_capture_service.dart:52-71`).
  - The production callers are `settings_screen.dart` and `sms_auto_capture_enable.dart`.
- A denied permission is reported as `denied` or `permanently_denied`. A permanent denial routes the user to App Settings (`MainActivity.kt:178-223`). Share capture keeps working.
- Backup and device transfer are off:
  - `allowBackup="false"` and `fullBackupContent="false"` (`AndroidManifest.xml:72-74`).
  - `data_extraction_rules.xml` excludes every domain from both cloud backup and device transfer.
  - The session vault lives in `noBackupFilesDir` (`SessionKeychain.kt:480`).
- `FLAG_SECURE` is set on the activity (`MainActivity.kt:42-45`).
- No `usesCleartextTraffic`, `networkSecurityConfig` or `debuggable` attribute is set anywhere. With target 36, cleartext traffic is off by default.
- Signing:
  - No keystore or password is committed. `key.properties`, `*.jks` and `*.keystore` are gitignored (`app/android/.gitignore:12-14`).
  - The example file contains only `CHANGE_ME` placeholders.
  - A release task with no signing configuration fails the build instead of falling back to the debug key (`app/build.gradle.kts:149-173`).
  - CI materialises the upload key in a temporary location, checks the signer is not the debug key, and deletes the key afterwards (`codemagic.yaml:470-538`).
  - The keystore record lists only certificate fingerprints, no secrets (`Qirsh Production/16_Android_Signing/keystore_record.md:5-9`).
- AdMob app ID: there is no committed literal. A release build validates the shape `^ca-app-pub-[0-9]{16}~[0-9]{10}$` and refuses Google's test publisher (`build.gradle.kts:36-86`).
- SDK levels and shrinking:
  - `applicationId` and `namespace` are `com.youssefsafwat.mali`.
  - `minSdk`, `targetSdk` and `compileSdk` come from the Flutter defaults: 24, 36 and 36 (`/opt/homebrew/share/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:23,26,34`).
  - Target 36 meets Play's current rule: new apps and updates must target API 36 from 31 Aug 2026.
  - The Flutter plugin enables R8 and resource shrinking for release (`FlutterPlugin.kt:216-226`). There is no app `proguard-rules.pro`.
- The exact-alarm permissions are deliberately not declared (`AndroidManifest.xml:8-14`). `POST_NOTIFICATIONS` is declared and requested at runtime through `requestNotificationsPermission()` (`local_notification_service.dart:363-372,1095`).
- Capture and review notifications use `NotificationVisibility.private` (`local_notification_service.dart:416,492,637`). Other notifications use the platform default, which is private.
- Account isolation in the queue:
  - Each capture is stamped with the active owner at enqueue (`DurableCaptureQueue.kt:897-949`).
  - The drain sees only the active owner's stamped items (`:213-214`).
  - Unbound items can be claimed only through the explicit claim, and only by the hinted account.
  - On sign-out or account switch: owner cleared, opt-in deactivated, background work cancelled (`MainActivity.kt:492-502`; `bootstrap_runner.dart:1426-1452`).
  - Remove data uses the persisted barrier (`MainActivity.kt:545-583`).
- The queue is sealed with AES-256-GCM under a non-exportable Keystore key. A capture during a removal barrier, or one with an unreadable store, is counted as `NOT_PERSISTED` and not stored (`DurableCaptureQueue.kt:904-946`).
- Session keychain (`6fd7000a`), reviewed:
  - One serial executor per process.
  - A dedicated AES-GCM Keystore key with no user-authentication requirement.
  - An atomic temp-file, fsync and rename write.
  - `absent` is returned only when the store confirms the item does not exist; a lost or invalidated key produces `permanent` errors.
  - Read-only access to `flutter_secure_storage` that never mints a master key (`SessionKeychain.kt:180-338,395-461`).
  - I found no defect in it. The JVM tests that cover it (`SessionVaultTest.kt`) have never been run in CI (see AND-05).
- Share intent: `ACTION_SEND` with `text/plain` only, and no deep-link or VIEW filters. A merchant URL is routed to a separate offer store that keeps at most 20 items, with query and fragment stripped. Everything else goes to the capture queue. The extras are removed after use (`MainActivity.kt:225-283`; `SharedContentRouter.kt`; `OfferIntentStore.kt:53,83`).
- Dart tests I ran (they use a fake native side and do not execute Kotlin):
  `flutter test --no-pub test/features/capture/android_sms_permission_test.dart test/features/capture/android_capture_owner_isolation_test.dart test/android`
  Result: `+50: All tests passed!`

## 3. Findings

### AND-01 — Android's V1 status is undecided, and every gate the repository sets for publishing it is still open
- Severity: S1 (if Android is in V1 scope; otherwise it becomes a scope decision to record) · Class: PRODUCT-DECISION · Platforms: Android
- User impact: An Android V1 cannot ship now. The restricted SMS permission requires an approved Play Permissions Declaration, which has not been submitted. No Android device has ever run the app, and no signed release AAB has ever been produced.
- Evidence:
  - `docs/ANDROID_SMS_CAPTURE_DECISION.md:1-27` and its "Still required before publishing" items 1-4.
  - `18_Android_SMS_Capture/README.md:13-17`.
  - `01_Current_Status/current_release_status.md:78-80`.
  - `01_Current_Status/QIRSH_RELEASE_TRACK.md:253,257,260` (keystore, device QA, and "Android release build validation — blocked").
  - `AndroidManifest.xml:28-30` ("must not be published to production").
  - Since 2026-10-01, the only distributed builds are iOS TestFlight builds.
- Root cause: The work has been on the iOS/TestFlight track. Android is code-complete but has never been verified on a device and has not been submitted to Play.
- Proposed fix: The owner records in `DECISIONS.md` one of two positions.
  - (a) V1 = iOS only, with Android following once Play approval and device QA are done.
  - (b) Android is in V1. Then AND-02..AND-08 and the full device matrix in §6 become release blockers.
- Verification required after fix: a decision entry. For (b), Play approval, a passing device matrix, and a signed AAB built by `android-release`.

### AND-02 — The Play submission inputs are stale and inconsistent with the shipped code (Data Safety omits AdMob; the declaration says 30-day retention)
- Severity: S1 if Android ships in V1 (unmet store requirement); S2 otherwise · Class: CODE-SUPPORTED · Platforms: Android
- User impact: A Data Safety form or SMS declaration that does not match the binary is a Play policy violation. The likely outcomes are rejection or removal, and the user sees inaccurate privacy labels.
- Evidence:
  - `Qirsh Production/18_Android_SMS_Capture/data_safety_draft.md` has no mention of AdMob, advertising, or advertising/device IDs (grep for `admob|advertis|AD_ID` matches only line 171 "advertising", which is about Gemini/Sentry). The release build does integrate ads, though: `google_mobile_ads 9.0.0` in `pubspec.lock`, the `APPLICATION_ID` meta-data at `AndroidManifest.xml:83-85`, and the `admob` group in `codemagic.yaml:406`.
  - `play_declaration_draft.md:54` says "The sanitized copy is retained for 30 days". The phase-4 Android path stores no text and keeps only the extracted result for ≤ ~25 h (`ANDROID_SMS_AI_DISCLOSURE_PROPOSAL.md` §4 text; `docs/legal/PRIVACY_POLICY.md:180`). The 18_ folder was last changed on 2026-09-04 (`85579ac9`), before the Nov-12 phase-4 changes.
  - `data_safety_draft.md:49` says "Merchant keywords … not wired".
  - The disclosure proposal says the website "has not been regenerated" (`:5-8`), so the live policy may not describe the Android Gemini path.
- Root cause: The drafts were written before the AI route, queue encryption and per-account opt-in landed on 2026-11-12.
- Proposed fix: Before submission, regenerate the Data Safety draft from the release AAB's merged manifest and SDK list. Add the Google Mobile Ads entries (device or other IDs, app interactions, diagnostics, and advertising purpose as applicable). Rewrite the declaration retention text to match §8 of the proposal. Publish the updated policy. Resolve the OWNER MUST CONFIRM items. This is a documents-only change with no compatibility impact.
- Verification required after fix: a side-by-side check of the merged manifest permissions and SDKs, the Data Safety answers, the declaration text and the live `qirsh.site/privacy`.

### AND-03 — SMS received while the app is force-stopped or killed by an OEM "cleaner" are lost for good, with no user guidance
- Severity: S2 · Class: CODE-SUPPORTED (design) / PRODUCT-DECISION · Platforms: Android
- User impact: On Xiaomi, Huawei, Oppo and Vivo devices, which often force-stop apps through battery managers, bank SMS that arrive while the app is stopped never become transactions. Nothing tells the user. With `RECEIVE_SMS` only, there is no inbox catch-up.
- Evidence:
  - The code itself says a force-stop means Android "delivers no broadcast (no SMS either) until the user opens the app again" (`CaptureDrainWorker.kt:73-75`).
  - `READ_SMS` is deliberately absent (`AndroidManifest.xml:32-35`).
  - `grep -rli 'battery|IGNORE_BATTERY|autostart' lib android/app/src/main` finds no capture-related guidance (only two unrelated files).
- Root cause: A broadcast-only design, which is the correct choice for Play minimisation, combined with no mitigation UX.
- Proposed fix (smallest):
  - Add one-time, opt-in-time guidance on OEM autostart and battery settings.
  - Document "messages received while Qirsh is force-stopped are not captured; share them manually" in Settings and in the declaration's core-functionality description.
  - No manifest change.
- Verification required after fix: device test §6 steps 9-10 on at least one Xiaomi or Huawei device.

### AND-04 — The Android release build sends an empty `X-App-Version`, so version-targeted force-update, flags and announcements cannot match it
- Severity: S2 · Class: REPRODUCED (Dart semantics) + CODE-SUPPORTED (path) · Platforms: Android (also the legacy iOS workflows at `codemagic.yaml:106,321`)
- User impact: A force-update or kill-switch row targeted at "clients below X" never reaches Android release users. `app_version.dart:3-12` describes this exact failure as "a safety control that reports success while doing nothing".
- Evidence:
  - `codemagic.yaml:497` sets `working_directory: app`.
  - `:509` runs `--dart-define=APP_VERSION="$(sed -n '…' app/pubspec.yaml)"`, which resolves to `app/app/pubspec.yaml`. `ls app/app/pubspec.yaml` gives "No such file or directory", so `sed` prints nothing.
  - `app_version.dart:30-33` uses `String.fromEnvironment('APP_VERSION', defaultValue: kPubspecVersion)`. A define that is present but empty yields `''`, not the default.
  - Reproduced in the scratch directory with `dart run --define=APP_VERSION= v.dart`, which printed `[]`, while running without the define printed `[1.0.0]`.
  - The current iOS path (`ios-signed`, `:876`) uses `$IOS_MARKETING_VERSION` and is not affected.
  - No test covers the workflow string (`grep -rl APP_VERSION app/test` finds only `app_version_test.dart`, which checks the constant).
- Root cause: A path relative to the repository root is used inside an `app/` working directory.
- Proposed fix: change the path to `pubspec.yaml` at `codemagic.yaml:509` (and `:106`, `:321`), or drop the define so the compiled fallback applies. No compatibility impact.
- Verification required after fix: build log shows a non-empty `APP_VERSION`; a request from the build carries `X-App-Version: 1.0.0`.

### AND-05 — No release AAB has ever been built; the Kotlin JVM tests run nowhere; R8 is unproven
- Severity: S2 · Class: ENV-LIMITATION / CODE-SUPPORTED · Platforms: Android
- User impact: A release-only failure could block shipping or crash in production without warning. Possible causes are an R8 missing-class error from Tink/errorprone via `security-crypto` (`build.gradle.kts:189`), an R8-stripped class used reflectively, or AGP 9.0.1 with `android.newDsl=false`.
- Evidence:
  - The only Android compile in CI is `flutter build apk --debug` (`codemagic.yaml:87-115`). Debug builds do not run R8.
  - `grep -n 'UnitTest|gradlew|:app:test'` over `codemagic.yaml`, `tools/ci_gates.sh` and `.github/workflows/ci.yml` finds nothing, so `SessionVaultTest.kt` and `CaptureOptInPolicyTest.kt` are never executed.
  - `QIRSH_RELEASE_TRACK.md:260` says release build validation is "blocked in this sandbox".
  - I cannot see whether the debug compile ran or passed on `ab5dc10a`.
- Root cause: No Java toolchain locally, and the release workflow is run by hand.
- Proposed fix: Run `android-release` once on the candidate, or a signed-less `flutter build appbundle --release` on a JDK host. Add `./gradlew :app:testDebugUnitTest` to the quality workflow.
- Verification required after fix: an AAB artifact, `mapping.txt`, a green JVM test report, and a cold start of the release build on a device.

### AND-06 — The decision document still promises SMS capture while signed out; the code stops capture at sign-out and session expiry
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Android
- User impact: The code behaviour is the more privacy-safe one, but users and reviewers are told something different. After sign-out, or when Supabase emits `signedOut` because a refresh token expired, every incoming bank SMS is dropped in `onReceive` until the user signs in again. Nothing tells the user that capture paused.
- Evidence:
  - `docs/ANDROID_SMS_CAPTURE_DECISION.md`, owner-reset table: "Sign-out | kept (the account's SMS keep arriving as *unbound*…)".
  - Code: `clearCaptureOwner` calls `CaptureSettings.reset` (`MainActivity.kt:492-502`), which calls `onOwnerCleared` and then `deactivated()` (`DurableCaptureQueue.kt:147-152`). `captureAllowed` requires `activeQueueOwner != null` (`:208-210`). The receiver comment agrees with the code: "nothing is read while signed out" (`SmsCaptureReceiver.kt:36-39`).
  - The doc was last changed in `6cd4fa37`, before `bd3bfe4e` changed these semantics.
- Proposed fix: Update the doc table and the declaration's behaviour text. Optionally add a signed-out notice when the remembered opt-in exists.
- Verification required after fix: doc review, plus §6 step 6.

### AND-07 — Any foreground app can inject "bank messages" (with a chosen sender) into the active account's capture queue through the exported share activity
- Severity: S3 · Class: SUSPECTED · Platforms: Android
- User impact: A malicious app installed on the device and running in the foreground can call `startActivity` with an explicit `ACTION_SEND` intent. Text and a spoofed `EXTRA_SUBJECT` sender are stored and stamped to the signed-in account, then drained into transactions and, with AI consent, sent to the backend. The user does not have to pick Qirsh in the share sheet; the activity opens visibly. Share items have no length limit and no financial prefilter, unlike SMS at `SmsCaptureReceiver.kt:124-136`.
- Evidence:
  - `AndroidManifest.xml:86-111` (exported, SEND filter).
  - `MainActivity.kt:225-277` (no size cap; sender taken from `EXTRA_SUBJECT`).
  - `legacy_capture_drain.dart:304-313` processes items regardless of source.
- Proposed fix: Cap the shared text length (for example 2-4 KB). Do not trust `EXTRA_SUBJECT` as a bank sender, or mark share items for review before import.
- Verification required after fix: an `adb shell am start -n com.youssefsafwat.mali/.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "<synthetic>"` test (§6 step 13).

### AND-08 — Captured raw SMS for an account that never signs in again, or unclaimed unbound items, stay on the device indefinitely; overflow is unbounded
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Android
- User impact: Sealed raw bank SMS of a former account are kept with no age limit. They are removed only by that account's Remove data or by a full identity purge. On a shared or second-hand device this is a retention gap. The privacy policy and Data Safety retention statements should cover it.
- Evidence:
  - The queue header says "It has no item bound: only the disk does" and nothing is evicted (`DurableCaptureQueue.kt:31-37`).
  - Items are visible only to their owner (`:213-214`) and swept only by their owner (`:226-227`).
  - There is no timestamp-based expiry anywhere in the file.
- Proposed fix: Add an age cap, for example 90 days, for stamped items of non-active owners and for unbound items. Alternatively, document the behaviour as a known limitation.
- Verification required after fix: a unit test with an aged fixture, and §6 step 7.

### AND-09 — The Android versionCode is fixed at 44 by `pubspec.yaml`; the release workflow never sets `--build-number`
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Android
- User impact: The first upload is accepted, but every later upload is rejected by Play as a duplicate versionCode until someone bumps it by hand.
- Evidence: `pubspec.yaml:4` (`1.0.0+44`), `build.gradle.kts:114`, and `codemagic.yaml:502-512` (no `--build-number`, unlike iOS at `:866`).
- Proposed fix: Derive `--build-number` from Play's latest versionCode + 1, or from a CI counter.
- Verification required after fix: two successive AAB uploads to the internal track.

### AND-10 — `AD_ID` permission and Advertising ID declaration not accounted for
- Severity: S3 · Class: SUSPECTED · Platforms: Android
- User impact: `play-services-ads` normally merges `com.google.android.gms.permission.AD_ID`. Play requires the Advertising ID declaration to match, and the drafts do not mention it (see AND-02). D-6 says every ad request is non-personalized, but the permission would still be present.
- Evidence: There is no `tools:node="remove"` for `AD_ID` in `AndroidManifest.xml`. I could not inspect the merged manifest here (no Gradle).
- Proposed fix: Inspect `app/build/intermediates/merged_manifests/release/AndroidManifest.xml`. Then either declare Advertising ID usage in Play Console or remove the permission explicitly.
- Verification required after fix: merged-manifest check, and the Play Console Advertising ID form.

### AND-11 — The account-deletion web resource required by Play is not identified
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: Android
- User impact: Play requires an in-app deletion path, which exists (`delete_account_screen.dart`, `supabase/functions/delete-account-immediate`). It also requires a public web URL where a user can request deletion without the app. The privacy policy offers email (`docs/legal/PRIVACY_POLICY.md:168`), but no dedicated URL is named in the Play drafts (`data_safety_draft.md:209`).
- Proposed fix: Name the URL in the Play drafts, for example a `qirsh.site` page or the policy section with the email procedure.
- Verification required after fix: the URL is reachable and entered in Play Console.

### AND-12 — Hygiene and documentation drift
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: Android
- Items:
  - `targetSdk`/`minSdk` are implicit Flutter defaults (`build.gradle.kts:112-113`), so a Flutter upgrade or downgrade silently changes the target API. Pin 36 explicitly.
  - `CaptureSettings.kt:36-40` documents a "Play-safe, share-only build" that does not exist (the receiver comment at `SmsCaptureReceiver.kt:12-19` says so).
  - `SharedContentRouter.kt:69-71` says credentialed URLs must not be stored, yet routes them to the capture queue as text.
  - `key.properties.example:11` uses alias `mali`, but the real upload key alias is `qirsh-upload` (`keystore_record.md:22`).
  - The `google_play` env group is attached to `android-release` (`codemagic.yaml:399`), but the workflow has no Play publishing step.
  - The Kotlin sources live under `com/example/money_companion/` while their package is `com.youssefsafwat.mali`. This is harmless, but it is drift.
  - `app/CLAUDE.md` lists two Codemagic workflows; there are five.

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Release scope | Android | Is Android in V1, and are the publication gates met? | docs, codemagic | Document + git review | FAIL (gates open) | §2 | AND-01 |
| SMS permission minimisation | Android | Only RECEIVE_SMS declared | AndroidManifest.xml:44 | Code inspection | PASS (inspection) | manifest | — |
| Receiver spoof protection | Android | Only the OS can deliver SMS_RECEIVED | AndroidManifest.xml:145-152 | Code inspection | PASS (inspection) | BROADCAST_SMS | — |
| Two-key rule | Android | Granted permission with opt-in off → nothing read | SmsCaptureReceiver.kt:39, CaptureSettings.kt:65 | Code inspection + Dart tests (fake native) | PASS (inspection); device NOT TESTED | 50 tests passed | — |
| Disclosure before dialog | Android | No path to the dialog without the disclosure | android_sms_capture_service.dart:52-71 | Code inspection + Dart test | PASS (inspection) | — | — |
| Permission denied / permanently denied / revoked | Android | Fails closed; Settings route | MainActivity.kt:178-223 | Code inspection | NOT TESTED on device | — | — |
| Default-off opt-in | Android | Fresh install → capture off | CaptureSettings.kt:86 | Code inspection | PASS (inspection) | — | — |
| Killed process → queue → drain | Android | Cold-start headless drain | CaptureDrainWorker.kt | Code inspection | NOT TESTED | — | AND-05 |
| Force-stop / OEM killer | Android | SMS during stopped state | design | Code inspection | FAIL (silent loss, no UX) | CaptureDrainWorker.kt:73-75 | AND-03 |
| Doze / standby / reboot | Android | Work runs after Doze/reboot | WorkManager | — | NOT TESTED | — | — |
| Queue corruption / key loss | Android | Quarantine, no silent loss | DurableCaptureQueue.kt | Code inspection | NOT TESTED | — | — |
| Queue age / overflow | Android | Bounded retention | DurableCaptureQueue.kt:31-37 | Code inspection | FAIL (unbounded) | — | AND-08 |
| Account switch isolation | Android | B never sees A's captures; opt-in not inherited | DurableCaptureQueue.kt:135-214, MainActivity.kt:453-502 | Code inspection + Dart tests | PASS (inspection); device NOT TESTED | — | — |
| Sign-out / session expiry | Android | Capture behaviour matches docs | MainActivity.kt:492-502 | Code inspection | FAIL (doc drift) | — | AND-06 |
| Remove data / account deletion | Android | Queue swept, opt-in reset | MainActivity.kt:545-583 | Code inspection | NOT TESTED on device | — | — |
| Session keychain | Android | Status-preserving session store | SessionKeychain.kt | Code review (JVM tests not run) | NOT TESTED | — | AND-05 |
| Share intent | Android | Untrusted input handling | MainActivity.kt:225-283 | Code inspection | FAIL (suspected injection) | — | AND-07 |
| Deep links | Android | None exposed | AndroidManifest.xml | Code inspection | N-A (none declared) | — | — |
| Notifications | Android | POST_NOTIFICATIONS, private visibility | local_notification_service.dart | Code inspection | PASS (inspection); device NOT TESTED | :363-372, :416 | — |
| Backup / D2D | Android | Financial data excluded | manifest + data_extraction_rules.xml | Code inspection | PASS (inspection) | — | — |
| Cleartext / debuggable | Android | Off in release | manifest | Code inspection | PASS (inspection) | — | — |
| Signing secrets | Android | Nothing committed; no debug-key fallback | build.gradle.kts, .gitignore | Code inspection | PASS (inspection) | — | — |
| Target API | Android | Meets Play's 2026 rule (36) | Flutter default 36 | Inspection + Play docs | PASS (implicit) | FlutterExtension.kt:34 | AND-12 |
| Release build / R8 | Android | AAB builds, R8 passes | android-release | — | NOT TESTED | — | AND-05 |
| App version header | Android | X-App-Version set | codemagic.yaml:509 | Repro of Dart define semantics | FAIL | `[]` output | AND-04 |
| versionCode | Android | Increments per upload | codemagic.yaml:502 | Code inspection | FAIL | — | AND-09 |
| Data Safety / declaration | Android | Matches binary | Qirsh Production/18_* | Document review | FAIL | — | AND-02, AND-10 |
| Account deletion URL | Android | Web deletion resource | — | Document review | NOT TESTED / undecided | — | AND-11 |

## 5. Could not verify here (exact scenarios, what is needed)

Everything below needs a JDK 17, the Android SDK, a Play Console account, or a physical device (ideally one Pixel plus one Xiaomi or Huawei, with a SIM that receives bank SMS or with `adb emu sms send` on an emulator):

1. `flutter build appbundle --release` with R8. This would surface missing-class errors from Tink/errorprone and confirm `mapping.txt` is produced.
2. `./gradlew :app:testDebugUnitTest`, covering `SessionVaultTest` and `CaptureOptInPolicyTest`.
3. Merged release manifest: the `AD_ID` permission, `SCHEDULE_EXACT_ALARM` absent, and every component's `exported` value.
4. The receiver under a cold process, Doze (`adb shell dumpsys deviceidle force-idle`), app standby buckets, force-stop, reboot before first unlock (direct boot), and OEM battery managers.
5. Keystore AES-GCM cost on the main thread in `onReceive` with a full 200-item main segment (ANR risk), and key survival across reboot and lock-screen changes.
6. Migrating an older install that has a plaintext queue to the sealed queue.
7. A live run of the session-expiry path (an invalid refresh token, then `signedOut`, then capture paused).
8. The status of the Codemagic `backend-and-quality-gates` run on `ab5dc10a`.
9. The live `qirsh.site/privacy` text and the Play Console forms.

## 6. Manual device test steps you recommend (numbered, with expected outcome)

Use synthetic SMS only, for example: sender `TESTBANK`, body "Purchase 12.50 SAR at Cafe X card *1234".

1. Fresh install of the release AAB (internal track). Open Settings → «رصد العمليات». **Expected:** the automatic capture switch is OFF and no system SMS dialog has appeared.
2. Turn the switch on and decline the disclosure. **Expected:** no system dialog appears and the switch stays OFF.
3. Turn it on, accept the disclosure, and deny in the system dialog. **Expected:** the switch is OFF; on a second denial the app offers App Settings.
4. Turn it on, accept, grant, then send the synthetic SMS with the app (a) in the foreground, (b) in the background, (c) swiped away. **Expected:** one transaction in each case. In (c) it arrives within a few minutes of network being available, via WorkManager.
5. Send a personal SMS ("bring your card") from a numeric sender, and an OTP from `TESTBANK`. **Expected:** neither is imported or queued.
6. Sign out, then send the synthetic SMS. Sign in as account B. **Expected:** B imports nothing and B's switch reads OFF. Sign back in as A. **Expected:** A's switch is restored with the one-time notice. The SMS sent while signed out was not captured (current code), which confirms AND-06.
7. As A with an SMS queued while offline, switch to B, keep using the app for a while, then return to A. **Expected:** A imports the SMS exactly once; B never sees it.
8. As A, run Remove data / Delete account with an item queued. **Expected:** the queue holds none of A's items, the switch is OFF, and no WorkManager job remains (`adb shell dumpsys jobscheduler | grep qirsh`).
9. Force-stop Qirsh in App info, send the SMS, then open the app. **Expected (current code):** the SMS is NOT captured. Record this as a known limitation for AND-03.
10. On a Xiaomi or Huawei device with default battery settings, lock the phone for more than 1 hour, then send the SMS. **Expected:** it is captured. Note any loss caused by the OEM.
11. `adb shell dumpsys deviceidle force-idle`, send the SMS, then `unforce`. **Expected:** queued during Doze and imported after Doze ends.
12. Reboot, and before the first unlock send the SMS. Unlock. **Expected:** captured after unlock (or a documented loss).
13. `adb shell am start -n com.youssefsafwat.mali/.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "Purchase 99 SAR" --es android.intent.extra.SUBJECT TESTBANK`. **Expected after the fix:** no silent import. Current code imports it, which is AND-07.
14. Revoke SMS in system settings while the switch is ON, then return to the app and send the SMS. **Expected:** the switch reads OFF and nothing is captured.
15. Android 13+: on a fresh install, deny notifications. **Expected:** capture still works and no crash. Grant notifications, capture an SMS, and check the lock screen with "hide sensitive content". **Expected:** the amount and merchant are hidden.
16. `adb backup` / Google One backup, then restore to a second device. **Expected:** no capture queue, session or opt-in is restored, and the app asks for sign-in.
17. Check that the release build's network requests carry a non-empty `X-App-Version` header (AND-04).
