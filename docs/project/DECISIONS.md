# Qirsh — decision record

Decisions that shaped the product, with the reasoning that produced them. A
decision belongs here when reversing it would cost real work or real trust.

Reversed decisions stay, marked REVOKED, because the fact that a position was
held and abandoned is what stops it being re-proposed.

---

## D-1 · Android automatic SMS capture is a required core feature · 2026-08-31

**Owner decision.** Revokes the earlier "Play-safe, share-only" position.
Recorded in `Qirsh Production/18_Android_SMS_Capture/README.md`.

Consequences that are now load-bearing: `RECEIVE_SMS` is declared (and only
that — no `READ_SMS`, so the receiver reads broadcast intents and never touches
`content://sms`); privacy policy §8 describing capture is **live**; publication
is gated on Play approval.

> **REVOKED:** "Android SMS capture is intentionally disabled for MVP"
> (`docs/ANDROID_SMS_CAPTURE_DECISION.md`, pre-2026-08-31). That document
> asserted the manifest declared no SMS permission and no receiver. Both became
> false and it was never revised; it has now been rewritten. A reviewer
> re-proposed the revoked position on 2026-09-02 and withdrew it on seeing D-1.

## D-2 · A granted permission is not consent — the two-key lock

`RECEIVE_SMS` granted **and** `CaptureSettings.autoCaptureEnabled == true`.
The opt-in defaults false, is set only by explicit user action after the
prominent disclosure, and is reset on identity change so one user's consent is
never inherited by the next. `SmsCaptureReceiver.onReceive` returns before
touching the intent unless the opt-in is true.

The UI renders from the platform snapshot, never a cached boolean: a permission
revoked outside the app must not leave a switch reading ON.

## D-3 · Disclosure ordering is structural, not conventional

`AndroidSmsCaptureService.requestAndEnable` takes the disclosure as a callback
and has no code path reaching the system dialog without it returning true. Play
treats a permission dialog shown before disclosure as a violation even when the
user then grants it, so the ordering cannot be left to whoever calls the method.

## D-4 · Forward-only database recovery

Drift is additive and forward-only. A v34 binary cannot open a v35 database.
Recovery is a feature flag, the kill switch, a hotfix or a forward migration —
**never shipping an older build**. Every bump forces a repository-wide sweep of
version pins.

## D-5 · UMP is the sole advertising-consent authority

No Qirsh-owned advertising-consent boolean exists, and an architecture test
asserts no `adConsentState` symbol appears anywhere in `lib/`. Separate from
`cloudProcessingEnabled`, which governs product analytics only.

## D-6 · No ATT prompt; every ad request is non-personalized

`AdRequest(nonPersonalizedAds: true)` plus the legacy `npa` extra, on both
formats. No `NSUserTrackingUsageDescription`. If personalized advertising is
ever wanted it is a separately approved configuration covering the ATT prompt,
the plist key and UMP IDFA messaging together.

## D-7 · Ad-free entitlement is three-state, and uncertainty means no ad

`verifiedActive` → no ad. `verifiedInactive` → eligible. `unknownOrStale` — any
timeout, unreachable server, malformed response, signed-out session or stale
cache → **no ad**. Never "not entitled".

A reviewer argued this loses revenue from signed-out users. The router disproved
it: unauthenticated users never reach the screens where ads appear.

## D-8 · One banner placement, chosen over density

Transactions list only. Coupons excluded outright rather than labelled — it is
an owned affiliate marketplace and a third-party banner competes with the offers
it exists to sell. Both reviewers independently.

## D-9 · No ad telemetry that implies an impression opportunity

There is no `*_suppressed_*` event and there must never be one. An event meaning
"this user was eligible for an ad but we withheld it" is exactly the signal the
ad-free design promises never to emit.

## D-10 · Nothing publishes itself

`ingestOffers` has no code path producing `published`. Making affiliate offer
publication automatic would take a schema change, not a config flag.

## D-11 · Savings abstain rather than invent

No structured value, no currency, a different currency, a basket below the
minimum, a pending conversion, an approved conversion of unknown size — all
produce *nothing*, not zero. Zero reads as "you saved nothing", which is a
different and false statement.

## D-12 · Exact reviewed merchant aliases, never fuzzy matching

A false category chip is user-correctable; "you shop at X constantly", derived
from someone's bank messages when they do not, is a trust breach in a finance
app. Recall is an alias-coverage problem solved by adding data.

## D-13 · Proof-Carrying engine ships dormant

Implemented, tested, **zero production callers**. Both reviewers: do not
activate pre-release, do not delete. Activation is an integration change (wire a
call site, ship it disabled, then use the activation pack) — **not a flag flip**,
which the activation pack incorrectly implied.

## D-14 · The affiliate click gateway stays unwired until a network exists

Coupons work today: the CTA opens the validated HTTPS merchant URL untracked.
Wiring a remotely-gated egress path before a contract exists adds
accidental-activation risk for zero benefit.

## D-15 · Phase 6 Safari extension — DEFER

Three conditions must hold together to reopen: a signed affiliate agreement
explicitly permitting a browser extension, Apple portal access restored with a
device for QA, and instrumented evidence that merchant-URL sharing is actually
used. "When we have more time" is not a condition.

## D-16 · A gate that is always red is not a gate

Applied twice on 2026-09-02. The arch guard pinned the schema at 31 and failed
on four separately approved bumps; the signing guard was named "no key material
is committed" but scanned the filesystem, so it failed on every machine capable
of building a signed release. Both were corrected to assert their real
invariant — the signing guard is now *stronger*, asking git what is tracked
anywhere in the repo rather than what sits in one directory.

The inverse also holds: a skip with no stated reason is indistinguishable from a
silently disabled test, so 19 of them were made to state why rather than being
whitelisted.

## D-17 · Documentation that contradicts source is a defect, not a nit

Four documents claimed things the code disproved: the SMS decision doc said the
manifest had no permission; the activation pack described activating code with
no call site; the release-readiness doc recorded Drift v31; and a **Play Data
Safety draft** claimed zero open egress findings when there are three. The last
one would have gone into a regulatory submission.

## D-18 · The ad-surface allowlist is closed, and it is two surfaces

**Owner decision, 2026-09-03. Closes RB-9.**

`docs/plans/MONETIZATION_PLAN.md` (2026-06-14) prohibited banners and
interstitials outright. That prohibition is superseded **only** by the two
surfaces below, and explicitly is **not** a general permission to place ads
across Qirsh.

| Surface | Status |
|---|---|
| `AdPlacement.transactionsList` — anchored adaptive banner | **APPROVED** |
| Report-export interstitial | **APPROVED — preserved** |

The interstitial was preserved under the owner's condition *"only if its later
owner approval is already evidenced in project history/current decisions."* It
is. The evidence is `Qirsh Production/13_AdMob/`, a numbered owner-facing
production workstream whose README tracks owner-assigned activation tasks
("AdMob account created — Youssef", "Four production identifiers obtained —
Youssef", "Set in Codemagic — Youssef") for this specific feature, described
there as "the report-export interstitial (R4/R7)". Its four `ADMOB_*`
identifiers are wired through `codemagic.yaml` into the release pipeline. That
is the same evidence class as `18_Android_SMS_Capture/`, which was accepted as
authoritative for the SMS supersession. Design-only spec status in
`docs/REPORT_ADS_SYSTEM.md` r3 is stale prose about a feature that shipped.

**Excluded, and this list is illustrative rather than exhaustive:** Dashboard /
Home, Budgets, Goals, Smart Inbox, capture / review / confirmation flows,
transaction detail and edit, Coupons / Savings / Merchant offers, onboarding and
auth, privacy, backup and restore, deletion and destructive flows, forms and
modal financial actions. What defines the boundary is the allowlist, not the
exclusions: a surface absent from both is prohibited.

**The guard stays structural.** `report_ads_guards_test.dart` holds a *positive*
call-site allowlist — `QirshAdBanner` may be mounted only at an approved site,
and any new mount fails CI. This decision does not relax it. Widening it
requires a new entry in this file, not a test edit.

**No ad is enabled by this.** `enable_report_ads`, `enable_banner_ads` and
`enable_banner_transactions_list` remain seeded OFF, no production ad units
exist, and a release build without injected identifiers resolves null and serves
nothing. Activation is a separate owner action.

## D-19 · The ad-surface allowlist widens to six banner surfaces

**Owner decision, 2026-09-19. Supersedes D-18's allowlist.**

D-18 (2026-09-03) closed the allowlist at two surfaces and named Dashboard/Home
and Goals among the exclusions. The owner has since directed that banners be
placed on five further screens. That is the owner's call — the exclusions in
D-18 were a product judgement recorded on the owner's behalf, not a safety
invariant — so D-18's **allowlist** is superseded here. Its **structure** is not:
closed allowlist, no raw unit ids in feature code, flags seeded OFF and
fail-closed, and no ad beside a financial confirmation or a destructive action
all remain in force and are still enforced by
`app/test/architecture/report_ads_guards_test.dart`.

### Approved ad surfaces — the complete list

| Surface | Format | Status |
|---|---|---|
| `AdPlacement.transactionsList` | Anchored adaptive banner | **APPROVED** — D-18, unchanged |
| `AdPlacement.dashboard` | Banner | **APPROVED** — D-19 |
| `AdPlacement.goals` | Banner | **APPROVED** — D-19 |
| `AdPlacement.subscriptions` | Banner | **APPROVED** — D-19 |
| `AdPlacement.reports` | Banner **and** the report-export interstitial | **APPROVED** — D-19 (banner); D-18 preserved (interstitial) |
| `AdPlacement.achievements` | Banner | **APPROVED** — D-19 |

Reports is the only surface carrying two formats. Both firing around one export
is a sequencing problem that the surface plan must solve; approving the banner
here is not approval of a banner→export→interstitial run.

**Still excluded, illustratively rather than exhaustively:** Budgets, Smart
Inbox, capture / review / confirmation flows, transaction detail and edit,
Coupons / Savings / Merchant offers, onboarding and auth, privacy screens,
backup and restore, deletion and other destructive flows, any form or modal
financial action. As under D-18, the allowlist is what permits: a surface in
neither list is prohibited.

### Approved is not mounted, and mounted is not enabled

Three separate gates, deliberately:

1. **Approved** — a value in `AdPlacement`. This decision.
2. **Mounted** — a `QirshAdBanner` call site, held in a positive allowlist in
   the guard test. Five of the six are approved and not yet mounted; each entry
   goes in with the widget, not ahead of it.
3. **Enabled** — `enable_banner_ads` plus one `enable_banner_<key>` per
   placement, every one of them seeded `false` in `_defaults` and activated
   remotely. A guard asserts `false`, not merely presence: the rollout bucket
   returns null outside the percentage and falls through to the default, so a
   placement seeded `true` would serve ads to exactly the users a partial
   rollout exists to hold back.

Operationally, the rollout hash is `SHA-256("$installId:$flagKey")`, so the
master and per-placement flags bucket **independently**. A master at 10% and a
placement at 10% is the intersection of two unrelated samples, not 10% of users.
Roll out on one flag and leave the other at 100%.

### AdMob configuration is out of scope

The owner has production AdMob identifiers and Codemagic environment
configuration already in place and has placed them out of scope (2026-09-19):
Codemagic environment variables, AdMob App IDs and Ad Unit IDs, release secrets
and defines, the iOS `Info.plist` AdMob injection, and the Android AdMob
configuration are not to be modified, moved or reorganised.

The visible consequence is in `bannerUnitFor`: all six placements resolve to the
**single** configured banner unit. D-18's note that a second placement "should
get its own unit" for AdMob reporting still holds as advice, and is deliberately
not acted on — a per-placement unit means a new `ADMOB_*` build input, a new
Codemagic variable and a new ad unit, all inside the frozen area. The guard
pinning exactly six `ADMOB_*` build inputs is therefore unchanged by this
decision. Per-placement measurement runs meanwhile on the placement-keyed
analytics events, which cost no build inputs.

**No ad is enabled by this.** Every flag remains seeded OFF; activation stays a
separate owner action.

## D-20 · Version 1 product decisions (owner, round 3)

**Owner decisions, 2026-11-17. Approved; not to be re-asked.** Source, kept
verbatim: `docs/releases/version-1/OWNER-BRIEF-ROUND3.md` §3. Where they differ,
these supersede **D-19's advertising position** (and, through it, D-18's) and
the earlier **30-day deletion brief** (scheduled deletion with an undo window).

| # | Decision | Supersedes |
|---|---|---|
| 3.1 | V1 targets iPhone. Dedicated iPad support and Android release readiness are outside V1. Android code is kept. | — |
| 3.2 | **V1 has no advertising.** Ad display and ad SDK initialisation/requests are disabled in the V1 build; a remote flag must not reactivate them. Production ad-flag changes are prepared, not executed without approval. Privacy declarations stay truthful about any SDK that remains linked. | D-19 / D-18 ad surfaces for V1 |
| 3.3 | Backup restore merges: restores missing records, keeps newer data, keeps server identities, respects tombstones and manual edits. | — |
| 3.4 | **Account deletion is final, with no 30-day undo period.** Copy must not promise immediate completion of asynchronous server work. No historical production clean-up is authorised by this decision. | 30-day deletion brief |
| 3.5 | Privacy Policy and Terms open with Cloud off, before consent, without enabling Cloud/AI or sending messages. | — |
| 3.6 | First launch asks for a language with none preselected; existing choices are kept. | — |
| 3.7 | All countries are selectable. Country availability is separate from verified bank-parser coverage; no claim that every bank, language or format is tested. | Egypt/Saudi-only onboarding |
| 3.8 | One first-run consent screen: "Agree and enable" / "Continue locally". Cloud and AI start only on the affirmative action. Sanitised text is not called anonymous. Existing users are not opted in by an update. | — |
| 3.9 | The user-facing disabling action turns Cloud and AI off together, and does not imply that sent requests can be recalled. | — |
| 3.10 | Shared learning is part of the Cloud/AI consent; the contribution is explained and minimised; existing aggregation/publication safeguards stay. | — |
| 3.11 | Existing sign-in methods are kept; no reviewer backdoor. | — |
| 3.12 | Notifications show the available transaction details within platform limits and never OTPs, full numbers, secrets or raw SMS. | — |
| 3.13 | Signed-out capture never reports success silently and never attaches a message to whoever signs in next. | — |
| 3.14 | Balances are labelled by source with their update time. | — |
| 3.15 | Parser corrections apply to newly processed messages only; no bulk re-analysis of history. | — |

**What this means for D-19 in the code.** The ad structure D-18/D-19 put in place
(closed allowlist, flags seeded OFF, guard tests) is kept, so a later version can
reopen advertising by a new owner decision. For V1 an additional build-time gate
sits above it: ads are compiled out unless the build passes
`--dart-define=QIRSH_ADS_ENABLED=true` (`AdMobBuildConfig.adsCompiledIn`), which
the V1 release build does not. The Google Mobile Ads and UMP SDKs remain linked
but are never initialised. The eight production ad flags are currently `true`;
turning them off is a prepared owner action (RELEASE-PLAN.md).

**Not decided here:** risk tolerances for AI accuracy, any historical data
clean-up, and the advertising position for versions after V1.
