# Version 1 — issues register

Consolidated and deduplicated from the specialist audits in [`evidence/audits/`](evidence/audits/). Each row keeps the source finding IDs; the audit report holds the full evidence (file and line, commands, reproduction), root cause and proposed fix.

- Candidate assessed: `ab5dc10a` (see [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)).
- Severity and class definitions: [`docs/release-process/SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md).
- Status values: `OPEN` · `FIXED` (local commit named) · `VERIFIED` · `OWNER DECISION` · `OPERATOR CHECK` · `DEFERRED` · `NOT A DEFECT`.
- "Fixed" here always means fixed on the local branch `release-readiness/v1`. Nothing has been pushed, deployed or submitted.

## S1 — blockers

| ID | Title | Sources | Class | Platforms | Status |
|---|---|---|---|---|---|
| V1-001 | Declined / failed card transactions are saved as confirmed payments and counted as spending | DATA-01 | REPRODUCED | iOS, Android, Backend | FIXED IN CODE, NOT CLOSED — `d35fc044` + `668f4d64` (second fix after independent review REV-01..04; 69 shared device/server cases). Still needed before it is closed: an owner-authorized deploy of `process-ios-sms`, a new app build, device verification. Installed builds including TestFlight 147 stay unprotected; rows already stored stay counted (V1-056). Known residual wordings are listed in KNOWN-LIMITATIONS |
| V1-002 | Production migration state is unknown for about 32 migrations, including those account deletion depends on | BE-01 | ENV-LIMITATION | Backend | OPERATOR CHECK |
| V1-003 | Store privacy disclosures (App Store privacy details, privacy manifest collected-data, Play Data safety draft) omit data the app sends: SMS text, profile photo, user ID, product interaction, advertising data | REL-02, SEC-04, IOS-10, AND-02 | CODE-SUPPORTED; console entries not visible | iOS, Android | OPEN |
| V1-004 | Android is not releasable and its V1 status is undecided: no sign-in method in a release build, Play SMS declaration and Data safety not submitted and stale, no release bundle ever built, no device run | AND-01, AND-02, AND-05, REL-01, PROD-04, AND-09, REL-15, AND-10, AND-11, REL-20 | PRODUCT-DECISION + CODE-SUPPORTED | Android | OWNER DECISION |
| V1-007 | Privacy Policy and Terms cannot be opened in-app while Cloud is off (the default), including from the consent sheet before consenting Re-rated S2 → S1 by the independent review (REV-12): an unmet store requirement. | SEC-02 | CODE-SUPPORTED | iOS, Android | OWNER DECISION |
| V1-014 | iPad and iPhone landscape are enabled with no decision, no layout evidence and no iPad screenshots Re-rated S2 → S1 (REV-13): an iPad device family without iPad screenshots blocks App Store submission. | PROD-01, IOS-08, REL-08 | PRODUCT-DECISION | iOS | OWNER DECISION |
| V1-015 | App Store reviewer notes contradict the build; no reviewer account or way to exercise capture Re-rated S2 → S1 (REV-12): reviewer access is a store requirement. | PROD-02, REL-12, REL-21 | CODE-SUPPORTED | iOS | OPEN |
| V1-020 | Restore does not reconcile with cloud sync: restored rows can be overwritten or removed rows can return when Cloud is re-enabled Re-rated S2 → S1 SUSPECTED (REV-14): rated by impact (data loss) because likelihood is unknown. | DATA-02 | SUSPECTED (mechanism in code, not executed) | All | OPEN |

## S2 — must fix or be accepted by the owner

| ID | Title | Sources | Class | Platforms | Status |
|---|---|---|---|---|---|
| V1-005 | Google AdMob / UMP is in the binary and can be enabled remotely, but the privacy policy, consent sheet and store drafts do not mention ads (S1 if any ad placement is enabled at launch) | SEC-01, REL-13 | CODE-SUPPORTED + PRODUCT-DECISION | iOS, Android | OWNER DECISION |
| V1-006 | Privacy policy promises 30-day undoable deletion; the app deletes immediately and permanently | SEC-03, REL-12 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-008 | Privacy manifests miss required-reason API declarations (disk space in app and share extension; file timestamp in the extension; App Group UserDefaults reason) | IOS-01 | CODE-SUPPORTED | iOS | FIXED locally `d70ba396` (reason codes from model knowledge — confirm against Apple's list before upload) |
| V1-009 | No hardened pipeline can produce an App Store–submittable build: `ios-signed` is internal-TestFlight-only and pinned to a personal beta branch; `ios-signed-release` lacks the checks and may fail build-number resolution | IOS-02, REL-03, REL-16, REL-18 | CODE-SUPPORTED | iOS | OWNER DECISION |
| V1-010 | `APP_VERSION` is passed as an empty string in three CI workflows (wrong path to `pubspec.yaml`) | REL-04, AND-04 | REPRODUCED | iOS (legacy workflows), Android | FIXED locally `64e571e5` |
| V1-011 | Flutter test skips are outside the skip manifest; six suites never run in CI while the run reports all tests passed | REL-05 | REPRODUCED | All | FIXED locally `64e571e5` + the define-gated stage commit: Flutter skip sites are counted against the manifest and the six define-gated suites now run in a mandatory gate stage (+143 tests). The gate can still be bypassed by `testOn`, an excluded tag or an early return (REV-06) — residual S3 |
| V1-012 | Native tests (194 iOS XCTests, Android Kotlin) run in no CI | REL-06, AND-05 | CODE-SUPPORTED | iOS, Android | OPEN |
| V1-013 | No CI gate executes backend behavior (row-level security, RPCs, migrations) | REL-07 | CODE-SUPPORTED | Backend | OPEN |
| V1-016 | Sign-in providers for V1 are set by CI variables that are not visible in the repository | PROD-03 | PRODUCT-DECISION / ENV-LIMITATION | iOS | OWNER DECISION |
| V1-017 | Consent sheet says either permission can be withdrawn separately; Settings only withdraws both together | PROD-05 | CODE-SUPPORTED | iOS, Android | OWNER DECISION |
| V1-018 | Help says the backup export is "an encrypted copy"; the ZIP export is not password-protected | PROD-06 | CODE-SUPPORTED | iOS, Android | FIXED locally `2f2c4707` |
| V1-019 | Onboarding offers 8 countries; the bundled bank catalog covers Saudi Arabia and Egypt only | PROD-08 | PRODUCT-DECISION | All | OWNER DECISION |
| V1-021 | No written deploy order for the November backend set; Auth hook, about 15 function secrets and 8 Vault entries are manual | BE-02 | CODE-SUPPORTED | Backend | OPEN |
| V1-022 | AI spend has no global ceiling; per-identity caps can be multiplied with free anonymous device identities | BE-03 | CODE-SUPPORTED | Backend | OPEN |
| V1-023 | Backup / point-in-time-recovery status is not recorded; the rollback story assumes it | BE-04 | ENV-LIMITATION | Backend | OPERATOR CHECK |
| V1-024 | No backend monitoring or alerting | BE-05 | CODE-SUPPORTED | Backend | OPEN |
| V1-025 | Admin panel uses Next.js 14.2.29 with 1 critical and 3 high advisories | REL-10, BE-07 | REPRODUCED | Admin | PARTIAL `f9c5be75`, `f6dc5076`: next 14.2.29 → 14.2.35; remote image hosts removed and image optimization turned off. Still 25 advisories on `next` (3 critical, 9 high) with no fix on 14.x — major upgrade is an OWNER DECISION; keep the panel off the public internet |
| V1-026 | Export compliance is declared "no non-exempt encryption" although the app encrypts backups itself | REL-11, IOS-09 | PRODUCT-DECISION | iOS | OWNER DECISION |
| V1-027 | Android: SMS received while the app is force-stopped or killed by a battery manager are lost with no user guidance | AND-03 | CODE-SUPPORTED | Android | OWNER DECISION |
| V1-054 | Data removal through startup is not tested in a configured build (real SDK and the native session keychain — the production configuration). Diagnosis of the reviewer's 7 failures: a harness limit, not a removal defect — the same 7 tests pass in the normal run, and fail under the synthetic defines because the group was written for an unconfigured build. Rated S2 (coverage gap on a privacy-critical journey), down from the provisional S1 | REV-06 | REPRODUCED and diagnosed | All | OPEN — needs the group ported to a configured harness; device check MDT covers it meanwhile |
| V1-055 | Nothing on this branch has been built by CI, compiled for iOS, deployed, or run on a device; no strict gate run exists at the final commit until the one recorded in TEST-EVIDENCE. TestFlight 147 contains none of the fixes | REV-18 | ENV-LIMITATION | All | OPEN |

## S3 — fix if cheap and safe, otherwise known limitation

| ID | Title | Sources | Class | Platforms | Status |
|---|---|---|---|---|---|
| V1-028 | Sync conflict date normalization depends on the device timezone for zone-less timestamps. The two reviewers disagreed on severity (S2 vs S4); resolved by evidence: no current writer emits a zone-less timestamp and the diff is display-only, so it is latent | REL-09, DATA-07 | REPRODUCED (function); reachability not shown | All | FIXED locally `ff1fc292`. Its regression test cannot fail on a UTC host (REV-11); run the sync suites under a non-UTC zone as well |
| V1-029 | Year-less SMS dates take the processing-time year and can land up to a year in the future | DATA-04 | REPRODUCED | All | FIXED locally `d35fc044` |
| V1-030 | On-device AI amount grounding is a substring match | DATA-03 | REPRODUCED | iOS, Android | FIXED locally `d35fc044` |
| V1-031 | A message with no currency token is auto-confirmed in the account currency (default flow) | DATA-05 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-032 | Account "current balance" is displayed but not derived from transactions | DATA-06 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-033 | No real upgrade fixtures for local schema versions 27–42 | DATA-08 | CODE-SUPPORTED | All | OPEN |
| V1-034 | App-switcher privacy cover never runs under the scene lifecycle; balances can show in the app switcher | IOS-03 | CODE-SUPPORTED | iOS | FIXED locally `d70ba396` — not compiled into the app and not run. The cover appears only once the app is in the background, so the live screen can still show while the app switcher opens (REV-08): covering earlier is an OWNER DECISION |
| V1-035 | Legacy capture notification is Arabic-only for English users | IOS-04 | CODE-SUPPORTED | iOS | OPEN |
| V1-036 | Amount, merchant and card last-4 show on the lock screen by default | IOS-05 | PRODUCT-DECISION | iOS | OWNER DECISION |
| V1-037 | Shortcut captures while signed out are dropped silently | IOS-06 | PRODUCT-DECISION | iOS | OWNER DECISION |
| V1-038 | Shared text that also carries a URL may be filed under Offers and reported as success | IOS-07 | SUSPECTED | iOS | OPEN |
| V1-039 | Force-update block does not re-check the version range on device; a cached row can keep blocking an updated app | PROD-11 | CODE-SUPPORTED | All | FIXED locally `7597bb42`. A malformed version bound now fails open on device (REV-10); the server applies the same rule before sending the row |
| V1-040 | Forced update and update notices cannot tell builds of the same marketing version apart; the app does not expose its build number at runtime | BE-06, REL-14 | CODE-SUPPORTED | All | OPEN |
| V1-041 | Help says the user always confirms before saving; high-confidence parses are auto-confirmed | PROD-07 | CODE-SUPPORTED | All | FIXED locally `2f2c4707` |
| V1-042 | Encrypted-backup screen, savings ledger and bank-discovery confirmation ship but cannot be reached | PROD-09 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-043 | Several remote flags shown in the admin panel are read by no code | PROD-10 | CODE-SUPPORTED | Admin | OPEN |
| V1-044 | Language screen preselects English | PROD-12 | PRODUCT-DECISION | All | OWNER DECISION |
| V1-045 | Policy statements about catalog and telemetry retention no longer match the code; Cloud-off users never receive a force-update notice | SEC-05 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-046 | Cloud backup passphrase minimum is 6 characters | SEC-06 | CODE-SUPPORTED | All | OWNER DECISION |
| V1-047 | Server consent on the user-token path is per account, not per device | SEC-08 | CODE-SUPPORTED | Backend | OPEN |
| V1-048 | Shared category learning is on by default once Cloud and AI are accepted, and publishes fleet-wide at 6 accounts | SEC-14, BE-09 | PRODUCT-DECISION | All | OWNER DECISION |
| V1-049 | Push auto-retry rollback runbook contradicts its rollback SQL | BE-08 | CODE-SUPPORTED | Backend | FIXED locally `f9c5be75` (document only; the rollback itself is unrehearsed) |
| V1-050 | Engagement triggers fire two HTTP calls per transaction write; migration 0104 backfill takes strong locks on 17 tables in one transaction | BE-10, BE-11 | CODE-SUPPORTED | Backend | OPEN |
| V1-051 | Self-attested CI revision check; no independent CI evidence on GitHub | REL-16, REL-17 | CODE-SUPPORTED | CI | OPEN |
| V1-052 | Licenses page, dependency hygiene | REL-19 | CODE-SUPPORTED | All | OPEN |
| V1-053 | Android (only if Android ships): share activity accepts forged "bank messages" from any foreground app; captures for an owner who never returns are kept without limit; Ads SDK may start outside the Cloud gate; decision document promises signed-out capture | AND-07, AND-08, SEC-07, AND-06 | SUSPECTED / CODE-SUPPORTED | Android | DEFERRED with V1-004 |
| V1-056 | Declined purchases stored before the fix stay counted as spending; there is no review list for existing rows | REV-05 | CODE-SUPPORTED | All | OPEN — known limitation; needs an owner decision on a one-off review list |
| V1-057 | On-device AI amount grounding does not treat the Arabic comma as a thousands separator | REV-17 | REPRODUCED by the reviewer | iOS, Android | OPEN |
| V1-058 | AI model and prompt versions are not recorded server-side, so an AI-parsed result cannot be reproduced later | BE-03 (part) | CODE-SUPPORTED | Backend | OPEN |
| V1-059 | Coverage matrix Part B marked some runtime behavior PASS on code reading alone | REV-16 | Records defect | Records | FIXED in the final matrix |
| V1-060 | The server AI fallback in `parse-sms` (`money.ts`) may accept an AI amount without checking it against the message text; V1-030 fixed only the on-device check | Records refresh (not from an audit) | SUSPECTED — not verified | Backend | OPEN — verify before release |
| V1-061 | Notification-preview rules match a declined cue anywhere in the text, so a real purchase at a merchant whose name contains a cue word probably shows the generic notification; the transaction itself is unaffected | Records refresh | SUSPECTED — Swift preview not run | iOS | OPEN |

## S4 — backlog

PROD-13 (Delete account row opens Privacy), PROD-14 (What's new reads as a beta changelog), PROD-15 / BE-12 / AND-12 / REL-21 (documentation drift), PROD-16 (English-only diagnostic string), PROD-17 (Podfile platform 15.0 vs target 16.0), PROD-18 (268 unused localization keys), IOS-11 (stamped captures for a non-active owner never expire), IOS-12, SEC-09 (wording of "withdraw AI only"), SEC-10 (no data delimiter around SMS text in the AI prompt), SEC-11 (stray files in the repository), SEC-12 (function grants not provable statically), SEC-13 (URL scheme into the router), BE-13 (no server-side kill switch for AI or capture endpoints).

## UI/UX findings

Recorded in [UI-UX-REVIEW.md](UI-UX-REVIEW.md) with the `UX-` prefix.

## Baseline (pre-existing) test failures

Recorded in [TEST-EVIDENCE.md](TEST-EVIDENCE.md).
