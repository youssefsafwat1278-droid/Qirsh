# Version 1 — release manifest

What exactly was assessed, to the extent it can be verified from this machine. Unknown means unknown; nothing here is inferred from an older document.

## Candidate

| Item | Value | How verified |
|---|---|---|
| Repository | `youssefsafwat1278-droid/Qirsh` | `git remote -v` |
| Audit baseline commit | `ab5dc10a24d393ffe80bb1d459af3aa385b83ba7` — tip of `origin/feat/post-beta-features`, 2026-11-17 02:27 +0200 | `git fetch`; every local feature branch is an ancestor of it |
| Candidate with local fixes | `af675aec4450b646db21b1dc48d736a25c31d023` on local branch `release-readiness/v1` (12 commits after the baseline) | `git log ab5dc10a..HEAD` |
| Pushed? | No. The branch exists only in the worktree `.claude/worktrees/v1-readiness`. | — |
| Marketing version | 1.0.0 (`app/pubspec.yaml`) | file |
| Build number | Not assigned. Codemagic takes the latest App Store Connect build number and adds one; the `ios-signed` floor is 146. `pubspec.yaml` says `+44` and is not the real number. | `codemagic.yaml` |
| Last distributed build | iOS 1.0.0 (147), TestFlight internal testing, from `b6fc0dad` (one commit before the audit baseline), Codemagic `ios-signed`, finished 2026-11-16 17:15 EET | Codemagic build log line "1.0.0 (146) exists; building (147)"; GitHub check run on `b6fc0dad` |
| Android | No release bundle has ever been built; `versionCode` would be the stale 44 | audit D |

**The assessed candidate is not the distributed build.** Build 147 contains none of the fixes listed in [CHANGELOG.md](CHANGELOG.md). No CI build, signed build, or device run exists for `af675aec`.

## Commits after the baseline

| Commit | Subject |
|---|---|
| `64e571e5` | Pass a real app version in every CI build and count Flutter skips in the skip gate |
| `f9c5be75` | Move the admin panel to the last Next.js 14.2 patch and correct the push rollback runbook |
| `d70ba396` | Declare the required-reason APIs both iOS targets use and run the app-switcher cover under scenes |
| `2f2c4707` | Make the Help text match what export and capture actually do |
| `ff1fc292` | Read zone-less timestamps as UTC when comparing sync conflict dates |
| `7597bb42` | Stop a cached force-update notice from blocking a build it no longer targets |
| `d35fc044` | Never record a declined purchase as spending; fix year-less dates and AI amount grounding |
| `f6dc5076` | Serve admin images unoptimized so the unauthenticated image optimizer does no decoding |
| `29cb1819` | Run the define-gated Flutter suites in the gate instead of only counting their skips |
| `668f4d64` | Close the gaps in declined-transaction detection found by independent review |
| `23499229` | Fix small UI and accessibility defects found on the running app |
| `af675aec` | Update the onboarding page-label test to the Western digits the Arabic strings now use |

The release records under `docs/release-process/` and `docs/releases/version-1/` are committed after these; that commit changes documentation only.

## Components and versions at the candidate

| Component | Version / state | Source |
|---|---|---|
| Flutter / Dart used here | 3.47.3 / 3.13.3 | `flutter --version` |
| Xcode used here | 27.2 (27B52); simulators iOS 26.5 | `xcodebuild -version` |
| CI toolchain | Flutter 3.47.3, `xcode: latest` (unpinned) | `codemagic.yaml` |
| iOS bundle IDs | `com.youssefsafwat.mali`, `com.youssefsafwat.mali.ShareBankMessage`; team `5TWARK8A23` | `codemagic.yaml` verification step |
| Device database schema | Drift v43, forward-only | `app/lib/data/db/app_database.dart:24` |
| Supabase migrations in the repository | 134 files, `0001_init` … `20261117010000_push_broadcast_auto_retry`; `0118_record_metric_ad_keys` deferred | `supabase/migrations`, `supabase/deferred` |
| Migrations applied in production | **UNKNOWN** beyond "continuous through 0092" recorded 2026-09-02 (V1-002) | `docs/project/MIGRATION_LEDGER.md` (stale) |
| Edge Functions in the repository | 33 | `supabase/functions/*/` |
| Edge Functions deployed in production | **UNKNOWN** (versions, which revision) | no production access |
| Server parser rules (`process-ios-sms/parser_rules.json`) | `version: 2` at the candidate (1 at the baseline). Nothing reads this field at runtime | file |
| Notification-preview rules (`app/assets/catalog/parser_rules.json`) | Updated in `668f4d64`; ships only in a new app build | file |
| AI model for SMS parsing | `gemini-3.8-flash` unless `GEMINI_SMS_MODEL` overrides it; production value **UNKNOWN** | `process-ios-sms/parse.ts:38` |
| AI model for bank discovery | `gemini-2.5-flash-lite` unless `GEMINI_MODEL` overrides it; production value **UNKNOWN** | `bank-discovery/index.ts:24` |
| AI prompt version | Not versioned and not recorded per result (V1-058) | audit F |
| Admin panel | Next.js 14.2.35 (was 14.2.29); deployment location and exposure **UNKNOWN** | `admin/package.json` |
| Remote feature flags (production values) | **UNKNOWN** | no production access |
| Codemagic variable groups (sign-in providers, AdMob IDs, Supabase keys) | Values **UNKNOWN**; `ios-signed` attaches `supabase` only, `ios-signed-release` and `android-release` also attach `admob` | `codemagic.yaml` |
| Sign-in providers in a V1 build | Apple always; Google and email only when the build variables enable them — `ios-signed` sets both to `true` | `codemagic.yaml` |

## Release scope

Proposed, not approved: see [SCOPE.md](SCOPE.md). Open scope decisions (Android in or out, iPad, countries, ads at launch) are listed in [RELEASE-DECISION.md](RELEASE-DECISION.md).

## Environment of this assessment

macOS (Darwin 27.0.0), Apple silicon. No Java runtime and no `adb`: Android was neither built nor run. No physical device of either platform. No production, App Store Connect or Play Console access. Codemagic was read once, by the owner's sign-in, for the build number of 147 only.

## Reviewers

Orchestration, integration, final verification and these records: Claude Fable 5.2 (AI). Specialist audits, fixes, records compilation and the independent review: AI agents that each reported the model identifier `claude-opus-5-5`. No human review has taken place. AI review is an additional control, not a certification.
