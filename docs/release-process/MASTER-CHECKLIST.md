# Master checklist

Fourteen categories. Every release reviews every category. Depth follows risk and change impact (§0). Item IDs are stable: never renumber, only append; retire an item by marking it retired with a reason.

Each release copies the IDs into its own coverage matrix and records a result per item using [EVIDENCE-TEMPLATE.md](EVIDENCE-TEMPLATE.md). Statuses: `PASS` / `FAIL` / `NOT TESTED` / `NOT APPLICABLE`.

Legend — **Risk**: C critical, H high, M medium. **Method**: A automated test, I code inspection, R runtime on simulator/emulator, D physical device, P production read-only check, S store console check. **Kind**: M mandatory store/platform requirement, E recommended engineering practice, Q Qirsh policy.

## 0. Change impact (do this first)

For each category write: what changed since the last released build, and an impact rating.

| Impact | Meaning | Minimum depth |
|---|---|---|
| High | Category's code, configuration or policy changed materially, or this is the first release. | Every item verified fresh. |
| Medium | Adjacent changes. | Critical (C) items fresh; others may reuse evidence with a written reason. |
| Low | No relevant change. | Reuse allowed for all items with a written reason; C items still need a current automated run. |

A first public release rates every category High.

## 1. Scope and change impact

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| SCOPE-01 | Candidate identified | One commit, clean tree, recorded with the last released build it is compared against. | H | I | Q |
| SCOPE-02 | Feature inventory current | Every feature is classed reachable / flagged off / incomplete / dev-only from code, not from old documents. | H | I | Q |
| SCOPE-03 | Release scope decided | IN, IN-BUT-OFF and OUT lists exist and match owner decisions; open scope questions are listed. | H | I | Q |
| SCOPE-04 | No dev-only surface reachable in release | Design galleries, debug menus, test hooks are unreachable in a release build. | H | I, R | E |
| SCOPE-05 | Audience and platform support stated | Countries, languages, OS versions, device classes are written down; unresolved assumptions listed. | M | I | Q |
| SCOPE-06 | Documents do not contradict source | Authoritative documents that disagree with the candidate are corrected or marked stale. | M | I | Q |

## 2. Architecture and dependencies

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| ARCH-01 | System map current | Components, data flows, trust boundaries and external services are mapped at the candidate. | H | I | E |
| ARCH-02 | External dependency failure modes known | For each external service: what the user sees when it is down, slow, or returns garbage. | H | I, A | E |
| ARCH-03 | Architecture guards green | `tools/check_arch_guard.sh` passes. | M | A | Q |
| ARCH-04 | Feature flags inventoried | Each remote and compile-time flag: default, production value, what turning it off does, whether that was tested. | H | I, P | E |

## 3. Core functionality

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| CORE-01 | Capture → transaction → report | A synthetic bank message is captured, sanitized, parsed, categorized, stored, and appears correctly in lists and reports, per supported ingestion path. | C | A, R, D | Q |
| CORE-02 | Onboarding and sign-in | First run, language choice, each sign-in provider, returning user, all complete without dead ends. | C | R, D | Q |
| CORE-03 | Manual transaction lifecycle | Add, edit, delete, recategorize; totals follow. | C | A, R | Q |
| CORE-04 | Planning features in scope | Budgets, goals, subscriptions/bills behave as specified where enabled. | M | A, R | Q |
| CORE-05 | Sign-out, session expiry, re-sign-in | No data loss, no cross-account leakage, clear state. | C | A, R, D | Q |
| CORE-06 | Account deletion | Reachable in-app, completes, and the result matches the policy. | C | A, R, P | M |
| CORE-07 | Messages and labels are true | Success messages and status labels match the actual state. | H | I, R | Q |
| CORE-08 | Offline use | Core local features work offline; reconnect resumes without duplicates or loss. | H | A, R, D | Q |

## 4. Data integrity

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| DATA-01 | Amount precision | Amounts are integer minor units end to end; no floating-point money arithmetic; rounding rules explicit. | C | A, I | Q |
| DATA-02 | Totals and balances consistent | Dashboard, lists, reports and account balances agree under the defined semantics for income, expense, refund, reversal, failed, transfer. | C | A | Q |
| DATA-03 | No fabricated values | Missing or invalid amount/currency never becomes a stored transaction without user review. | C | A | Q |
| DATA-04 | Number, currency and date parsing | Arabic and Western digits, separators, currency before/after, timestamps and date boundaries parse correctly. | C | A | Q |
| DATA-05 | Duplicates | Same message through any paths → one transaction. Distinct similar messages stay distinct. | C | A, D | Q |
| DATA-06 | Manual categories preserved | User category choices survive re-parse, import, restore and sync. | H | A | Q |
| DATA-07 | Local schema migration | Upgrade from each supported prior schema keeps data; interrupted migration recovers or fails safely. | C | A, D | E |
| DATA-08 | Backup, restore, export, import | Round trip is lossless; old, malformed and corrupted inputs are rejected safely; ownership respected. | C | A, R | Q |
| DATA-09 | Sync conflict handling | No silent loss of a user edit; conflicts visible and resolvable; timezone-independent. | H | A | Q |
| DATA-10 | Queue durability | Capture queues survive process death; overflow, corrupted entries and age limits behave as specified. | C | A, D | Q |

## 5. Security

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| SEC-01 | Authentication and session | Tokens stored in platform secure storage; expiry and refresh handled; no auth bypass. | C | A, I | E |
| SEC-02 | Server authorization | Every user-data table has row-level security scoped to the owner; privileged functions pin `search_path` and restrict grants; functions using the service role authenticate and scope the caller. | C | A, I, P | E |
| SEC-03 | Account isolation on device | A second account on the same device cannot read the first account's local or queued data. | C | A, D | Q |
| SEC-04 | Local data protection | Sensitive local data and backups are protected as designed (encryption, key storage, backup exclusion). | H | I, A | E |
| SEC-05 | No secrets in source or artifact | No service-role keys, private keys, keystores or passwords in the tree or the built artifact. | C | I, A | E |
| SEC-06 | Logs and diagnostics | No message text, amounts, tokens or personal data in logs, crash reports or diagnostics beyond what the policy states. | H | I, A | Q |
| SEC-07 | Untrusted input | Messages, share payloads, deep links, AI output and admin-authored content are validated and treated as data. | H | A, I | E |
| SEC-08 | Network | TLS only; no cleartext exceptions; endpoints are production endpoints in release. | H | I, A | E |
| SEC-09 | Admin authorization | Every admin route and action checks authentication and role server-side. | C | A, I | E |
| SEC-10 | Storage access | Storage buckets enforce per-owner access. | C | A, I, P | E |

## 6. Privacy and consent

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| PRIV-01 | Consent model documented from code | Each consent flag, its default, and what it permits. | C | I | Q |
| PRIV-02 | Egress inventory matches consent | Every outbound transmission is listed with its data and gate; nothing leaves without the required consent in any combination. | C | A, I | Q |
| PRIV-03 | Revocation | After revocation no new prohibited transmission starts, including from queues and retries; handling of in-flight requests is documented. | C | A, D | Q |
| PRIV-04 | Server enforces consent | The server refuses work the user's consent state does not allow, independent of the client. | H | A, I | E |
| PRIV-05 | Policy matches behavior | Privacy policy and terms describe what the build actually does. | C | I | M |
| PRIV-06 | Store privacy declarations | App Store privacy details and Play Data safety match SDK and app behavior. | C | I, S | M |
| PRIV-07 | Deletion and retention | Deletion removes what the policy says, within the stated time; retention limits are enforced. | C | A, P | M |
| PRIV-08 | Notifications are privacy-preserving | Lock-screen content follows the policy. | H | I, D | Q |
| PRIV-09 | Advertising consent | Consent platform flow and non-personalized configuration match decisions. | H | I, R | M |
| PRIV-10 | AI path controls | Message content reaches an AI provider only with consent; provider settings match the declared data practices; model/prompt/config versions recorded. | C | I, A, P | Q |

## 7. Failure handling and recovery

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| FAIL-01 | Network failure, timeout | User sees a truthful state; nothing is lost; retry is bounded. | H | A, R | E |
| FAIL-02 | AI failure modes | Malformed output, missing fields, invalid amount/currency, timeout, rate limit, model unavailable → no invalid persistence; recovery or review path exists. | C | A | Q |
| FAIL-03 | Interrupted operations | Kill during write, sync, backup, restore, migration → consistent state. | C | A, D | E |
| FAIL-04 | Concurrent operations | Overlapping capture, sync and user edits do not corrupt or duplicate. | H | A | E |
| FAIL-05 | Retry and idempotency | Server and client retries cannot double-apply. | H | A, I | E |
| FAIL-06 | Corrupted local state | Corrupted queue entries or settings are quarantined, not fatal. | H | A | E |

## 8. Performance, capacity and cost

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| PERF-01 | Start-up | Meets the cold-start threshold with a populated database. | M | D | E |
| PERF-02 | Populated database | Lists and reports meet thresholds with the target data volume. | M | A, R, D | E |
| PERF-03 | Backend hot paths | Indexed; no unbounded queries reachable by clients. | M | I, P | E |
| PERF-04 | Rate limits and quotas | Abuse of an endpoint is bounded per user/device. | H | I, A | E |
| PERF-05 | Cost exposure | AI and other metered spend has a ceiling or an alert. | H | I, P | E |
| PERF-06 | App size and battery | No regression that would surprise users; background work bounded. | M | D | E |

## 9. UI/UX and accessibility

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| UX-01 | Primary screens, both languages | No clipping, overflow or overlap in Arabic (RTL) and English on the smallest and a large supported screen. | H | R, D | Q |
| UX-02 | Mixed-direction content | Amounts, currencies and dates render correctly inside RTL text. | H | R | Q |
| UX-03 | Appearances | Light and dark both legible, where supported. | M | R | Q |
| UX-04 | States | Loading, empty, error, offline, success, disabled and permission-denied states exist and are truthful. | H | R, I | Q |
| UX-05 | Large text | Primary screens usable at the largest supported text size. | M | R | E |
| UX-06 | Targets and contrast | Meet thresholds. | M | R, I | E |
| UX-07 | Screen reader | Interactive controls have accessible names; order is sensible. | M | R, I | E |
| UX-08 | Feedback and repeated taps | Actions give feedback; double taps do not double-submit; input is preserved on error. | H | R, A | Q |
| UX-09 | Reduced motion | Animations respect the system setting. | M | I, R | E |
| UX-10 | Keyboard and safe areas | Fields are not hidden by the keyboard; content respects safe areas. | M | R | Q |

## 10. Device and platform compatibility

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| COMP-01 | Minimum and latest OS | App runs on the minimum supported and the latest OS version per platform. | H | R, D | E |
| COMP-02 | Device classes | Small phone, large phone; tablets if supported. | M | R, D | E |
| COMP-03 | Platform lifecycle | Background, termination, locked device, low power, permission changes behave as designed for capture. | C | D | Q |
| COMP-04 | Fresh install and upgrade | Both work from each supported prior build. | C | D | E |
| COMP-05 | Locale and timezone | Behavior correct outside UTC and across date boundaries. | H | A, R | Q |

## 11. Build and supply-chain integrity

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| BUILD-01 | Canonical gates | `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` exits 0 on the candidate. | C | A | Q |
| BUILD-02 | Tests are meaningful | Critical journeys have behavioral tests; skips have reasons; no weakened assertions since last release. | H | I | E |
| BUILD-03 | Reproducible dependencies | Lockfiles committed; no git or unreviewed path dependencies; vendored code explained. | H | A, I | E |
| BUILD-04 | Known vulnerabilities | Dependency advisories reviewed; none exploitable left open without a record. | H | A | E |
| BUILD-05 | Licenses | Obligations met (notices shown where required; no incompatible license). | M | I | M |
| BUILD-06 | Artifact identity | Identifiers, version and build number, signing team, entitlements/permissions as intended. | C | A | M |
| BUILD-07 | Release configuration | Production endpoints, release flags, no debug capability, no test credentials. | C | A, I | E |
| BUILD-08 | Provenance | The artifact is traceable to the frozen commit and CI run. | H | A | E |
| BUILD-09 | Version reporting | Everything the app shows or sends as its version is the real version. | M | I, R | Q |

## 12. Store submission

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| STORE-01 | Apple review requirements | Each applicable App Review guideline in SOURCES is met or has a written answer. | C | I, S | M |
| STORE-02 | Apple submission assets | Metadata, screenshots, privacy details, age rating, export compliance, review notes and reviewer access. | C | S | M |
| STORE-03 | Google Play policy | Restricted permission declarations, Data safety, target API level, account deletion link, ads declaration. | C | I, S | M |
| STORE-04 | Reviewer can exercise the core feature | Notes or a demo path let a reviewer see capture work. | C | S | M |
| STORE-05 | Public legal pages | Live URLs match the text in the repository and the build. | H | S | M |
| STORE-06 | Beta distribution rules | TestFlight / testing-track requirements for the intended testers are met. | M | S | M |

## 13. Deployment and backward compatibility

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| DEPLOY-01 | Production state known | Migration ledger, deployed functions, flags, cron and secret presence compared with the repository. | C | P | E |
| DEPLOY-02 | Migration safety | Each unapplied migration reviewed for locks, destructiveness and idempotency; rehearsed on a copy or a local stack. | C | A, I | E |
| DEPLOY-03 | Old-client compatibility | Every backend change works with installed clients, or a verified forced update exists. | C | A, I | E |
| DEPLOY-04 | Deploy order written | Database → functions → admin → mobile order, with checks between steps. | H | I | E |
| DEPLOY-05 | Staged rollout plan | Beta, limited audience, wider; stop conditions defined. | H | I | E |
| DEPLOY-06 | Recovery feasibility | For each step: can it be undone, how, and was that rehearsed. | C | I | E |

## 14. Monitoring, support and incident response

| ID | Item | Acceptance criteria | Risk | Method | Kind |
|---|---|---|---|---|---|
| OPS-01 | Signals exist | Crash reporting, function errors, queue health, push and AI error rates are observable. | H | I, P | E |
| OPS-02 | Thresholds and stop conditions | Written before rollout. | H | I | E |
| OPS-03 | Ownership | Named person and contact path for incidents during the observation window. | H | I | E |
| OPS-04 | User support path | Users can report a problem; diagnostics are privacy-safe. | M | I, R | E |
| OPS-05 | Safe disablement | Which features can be turned off remotely, verified to work. | H | I, A, P | E |
| OPS-06 | Backups | Production database backup/restore capability is known and stated honestly. | C | P | E |
