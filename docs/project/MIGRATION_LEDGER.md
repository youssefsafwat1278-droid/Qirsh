# Qirsh — migration ledger truth

**This is the single source of truth for what is deployed.** Migration file
headers describe what a migration *does*; they do not record where it has run.

---

## Verified production state — current (2026-11-17)

**This section supersedes the 2026-09-02 table below, which is kept as history.**

| | |
|---|---|
| **Production project** | `rjwphwsefnuotpbtuycf` |
| **Applied** | **134 migrations**: `0001`–`0117` and the 17 timestamped files through `20261117010000_push_broadcast_auto_retry` — exactly the set in `supabase/migrations/` at `d1212986` |
| **Verified by** | Connector `list_migrations` (names), 2026-11-17; and a schema fingerprint (`tools/schema_fingerprint.sql`) of production against a fresh local apply of the same files: columns, constraints, indexes, policies, table grants/RLS and triggers identical; functions identical except one hand-made grant (`anon` EXECUTE on `public.set_default_account(uuid)`); cron differs only by `affiliate-sync-hourly` set inactive by hand. Details: `docs/releases/version-1/evidence/production-comparison.md` §7.2 |
| **Source-only, NOT applied — in the V1 package** | `20261117120000_ai_global_spend_guard.sql` (global AI spend ceiling, V1-022). Additive and idempotent; rollback `supabase/rollback/20261117120000_ai_global_spend_guard_rollback.sql`. Applied only with the owner's approval of the V1 release package |
| **Deferred, not applied** | `0118_record_metric_ad_keys` (`supabase/deferred/`) |

---

## Verified production state — 2026-09-02 (historical)

| | |
|---|---|
| **Production project** | `rjwphwsefnuotpbtuycf` |
| **Applied continuously through** | **0092** |
| **Verified** | 2026-09-02, owner read-only query against `supabase_migrations.schema_migrations` |
| **Explicitly confirmed present** | 0084, 0085, 0086, 0087, 0088, 0089, 0090, 0091, 0092 |
| **Source-only, NOT deployed — ACTIVE TARGET** | **0093 – 0097** |
| **DEFERRED — product activation decision required** | **0099** (`supabase/deferred/`, renumbered from 0098 on 2026-09-06) |

**0093–0099 must not be assumed deployed and must not be applied without an
explicit activation instruction.** Every feature that depends on them is behind
a flag seeded OFF, so nothing is broken by their absence.

| Migration | Feature | Flag |
|---|---|---|
| 0093 | `merchant_keywords` catalog versioning | — (correctness fix) |
| 0094 | `catalog_merchants` + reviewed aliases | `enable_offers_merchants` OFF |
| 0095 | coupon offer economics | `enable_coupons` OFF |
| 0096 | affiliate core | `enable_affiliate_links` OFF |
| 0097 | affiliate attribution | `enable_affiliate_links` OFF |
| 0099 | `record_metric` ad-key allowlist (deferred; was 0098) | telemetry silently dropped until applied |

---

## The contradiction that existed, and why it survived

Until 2026-09-02 this repository asserted two incompatible things.

Ten migrations (**0071–0080**) carried, verbatim:

> `DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified
> on production; this header was never revised after the deploy).`

Three migrations **inside that same range** (**0084, 0085, 0086**) said:

> `SOURCE-ONLY. NOT APPLIED TO ANY PROJECT.`

0084 ≤ 0092, so both could not be true. The Management API returned **403** for
the available credentials, so the ledger could not be read from this machine and
the contradiction stood unresolved through the 2026-09-02 finalization audit.

**The owner query resolved it: the 0071–0080 claim was correct, and the
0084–0086 headers were stale.**

**Why they were stale is the part worth keeping.** Those three headers named a
*different* production project — an earlier deployment target that is no longer
in use and is now explicitly off-limits. They were accurate statements about a
project these migrations were never going to run on, and said nothing at all
about the project they did run on. A reader checking "has 0084 been applied?"
got a confident answer to a question they had not asked.

That is why it survived repeated audits: the sentence was not wrong in the way
audits look for. It was wrong about its subject.

**Why it mattered.** `0084` is a *data-erasure repair* — it restores deletion
completeness in `purge_user_data()`. "Possibly not applied" meant "account
deletion may not fully erase, and we cannot tell". That is the single worst
shape an unknown can take in this product, and it is now closed.

---

## The rule this leaves behind

Deployment state lives **here, in one file**. Migration headers must not carry a
per-file deployment claim.

Ten copies of one fact is precisely how the contradiction arose: the copies were
batch-edited on 2026-09-01, three files inside the range were missed, and from
that moment the repository disagreed with itself. A single record cannot
disagree with itself.

The 0071–0080 headers still carry their (correct) claim. They were left alone
rather than swept, because rewriting ten accurate files is churn — but they
should not be treated as authoritative, and nothing new should imitate them.

---

## How to verify, next time

From the Supabase dashboard for `rjwphwsefnuotpbtuycf`, SQL editor:

```sql
select version
from supabase_migrations.schema_migrations
order by version desc
limit 20;
```

Then update the table at the top of this file with the result and the date. If
the highest applied version is below the highest file in `supabase/migrations/`,
list the gap explicitly — do not describe it as "probably applied".

---

# 0093–0098 pre-deploy safety review — 2026-09-04

> NOTE 2026-09-06: the deferred telemetry migration reviewed here as `0098` was
> renumbered to **0099** when `0098_engagement_worker_secret_auth.sql` took the
> active 0098 slot. Its SQL is unchanged; references below to `0098` in the
> telemetry context mean today's `supabase/deferred/0099_record_metric_ad_keys.sql`.

**Nothing was deployed.** Two independent adversarial reviews (Fable, Codex) plus
a source pass.

**Outcome — active production deployment target is `0093 – 0097`.**
`0098` is **DEFERRED** and has been moved out of `supabase/migrations/` to
`supabase/deferred/` (2026-09-04) so `supabase db push` cannot propose it. A
header comment does not stop the CLI; removing the file does.

**Production evidence supplied by the owner, 2026-09-04:**
- `coupons` row count = **0** → 0095's ten immediate `CHECK` validations are
  negligible. The concern raised in review is resolved by measurement, not by
  assumption; no `NOT VALID` split is needed.
- Vault holds **neither** `project_url` **nor** `affiliate_worker_secret` →
  0096's hourly `affiliate-sync` cron is **inert**. It fails closed and logs
  rather than calling anything.

## The blocker found and fixed before deploy — 0094 seed off-by-one

`0094` seeded `catalog_versions` at **1** for `catalog_merchants` and
`merchant_aliases` while both sequences start at 1. `0002` gets this right by
omitting the column and taking the `DEFAULT 0`.

The consequence, had it shipped:

1. Apply 0094 → category version 1, tables empty.
2. Any device syncs. `catalog_sync_service.dart:263` calls
   `upsertVersion(category, serverVersion, serverVersion)` **unconditionally,
   even for an empty item list** → device stores `since = 1`.
3. First merchant inserted → trigger takes `nextval() = 1`, so
   `updated_version = 1` and the category version stays **1**.
4. `catalog-delta:100` serves `.gt('updated_version', since)` → `1 > 1` false.

**The first row ever inserted into each table would be invisible to every device
that synced in between — permanently, with no version change to signal a delta.**
Row 2 onward arrives normally, making the symptom a single missing row on some
devices only. This is the same defect class `0093` exists to repair.

**Not mitigated by feature flags.** `CatalogCategories.syncable`
(`catalog_daos.dart:48-57`) lists both categories **unconditionally**;
`enable_offers_merchants` gates the coupons *UI*, not catalog sync. Every device
would have synced and pinned itself before any merchant existed.

**Fixed at source** (0094 unapplied, so nothing to migrate around), plus two
guards:
- a runtime invariant in 0094's own verification block — the migration aborts if
  either table is empty while its category version is non-zero;
- a CI check in `supabase/tools/check_migrations.sh` — any migration that creates
  a `catalog_*` table and seeds `catalog_versions` non-zero fails the lint.
  Proven non-vacuous: restoring `1` produces a FAIL.

**Proof standard, stated honestly.** No live Postgres was available (no server
binary, no Docker, so `dryrun_migrations.sh` could not run). The fix is proven by
arithmetic, the runtime assertion and the CI guard — **not** by observed
behaviour on a database.

## 0099 (was 0098) — blocked by the "telemetry OFF" constraint

**There is no telemetry feature flag.** `record_metric`'s allowlist *is* the
switch. 0072 ships `ARRAY['app_open']`; 0098 adds 11 keys.

Two of them are emitted by **already-shipped clients**:
`report_export_coordinator.dart:82` fires `report_export_requested` at the top of
`run()`, before any ad gate, and `:201` fires `report_export_completed` after
every successful export. Their only gate is cloud-processing consent
(`report_ads_analytics.dart:39`) — **not** `enable_report_ads`.

So applying 0098 immediately begins persisting report-export telemetry for every
cloud-consenting user, with no flag able to prevent it. Practical volume today is
near zero (the app is unpublished and consent seeds to `unset`), but the
requirement "keep telemetry OFF" cannot be satisfied while 0098 is applied.

**Resolution is a product decision, not an engineering one:** either defer 0098
until telemetry is intended to activate, or accept the collection explicitly.

## Non-blocking findings recorded

| # | Finding | Evidence |
|---|---|---|
| 1 | `record_metric.dimension` is **server-side free text**. The comment claims the client can only pass a placement key, but the function enforces only `length ≤ 128` (`0098:72`). Any authenticated user can persist arbitrary text under 11 keys at 1000 rows/day. Admin-read-only and rate-limited, so low severity — a `p_dimension ~ '^[a-z0-9_]{1,32}$'` guard would close it and the comment currently overstates the protection. | `0098:26-27`, `0098:72` |
| 2 | `0095`'s ten `CHECK` constraints use **immediate validation** (no `NOT VALID`), each taking `ACCESS EXCLUSIVE` on `coupons` plus a full scan. **Production cost is unmeasured** — it could not be measured from this workstation. Must be evidenced before deploy; see the pre-deploy checks. | `0095:46-129` |
| 3 | `0093` may cause **more catalog re-downloads than its comments project**, because `enrich-merchant` looks a keyword up by `keyword` alone, ignoring country (`enrich-merchant:352-370`). Two users in different countries hitting one merchant ping-pong `country_code`; each flip trips the trigger's WHEN clause and, because `merchant_keywords` is snapshot-versioned, forces a fleet-wide dictionary re-download. Bandwidth, not correctness — devices converge. The country-blind lookup is a pre-existing defect that 0093 amplifies. | `0093:103-116`, `catalog-delta:205-215` |

Also: every `merchant_keywords` write now serialises on one `catalog_versions`
row, and the one-time bump creates a single fleet-wide snapshot burst. Bounded in
practice by `enrich-merchant`'s per-identity rate limit.

## Reviewer disagreement, resolved against source

Fable said the 0094 defect was harmless with flags off. **That is wrong** — the
catalog sync is not flag-gated (`catalog_daos.dart:48-57`), which makes it strictly
worse than Fable assessed. Codex called 0093 "unbounded blocking DDL"; that
overstates it — `CREATE TRIGGER` is O(1) and needs its lock only briefly. The
real 0093 costs are the write serialisation and the snapshot burst above.
Codex's 0098 telemetry finding is correct and is the operative blocker.

## What could NOT be verified from this workstation

- `supabase db push --dry-run` — 403 on the login-role endpoint, and it requires
  `SUPABASE_DB_PASSWORD`. **The owner must re-run it**; 0094's *content* changed,
  though the proposed file set should still be exactly 0093–0098.
- Production `coupons` row count (0095 lock cost).
- Deployed Edge Function revisions (`supabase functions list` → 403).
- Vault contents (`project_url`, `affiliate_worker_secret`) for 0096's cron.
