#!/usr/bin/env bash
# MALI-034 architecture guard — a NARROW, code-only invariant check that the
# retired Supabase-primary financial authority cannot silently return.
#
# It is deliberately scoped to CODE signals (imports, quoted flag keys,
# constructor/class usage, the schema constant) so the intentional HISTORY
# comments that name the retired classes ("replaces the retired
# FinancialCacheRepairService cycle", "extracted from SupabaseTransactionRepository")
# do NOT trip it. Each check prints its result; any violation exits non-zero and
# lists the offending lines.
#
# Guards (all against app/lib — production code only):
#   1. DB schema stays at the AUTHORIZED version (_targetSchemaVersion) — no
#      unapproved bump. The authorized value and its history live in section 1.
#   2. No *_supabase_primary authority-switch flag keys are read (quoted selectors).
#   3. No FinancialCacheRepairService is imported or constructed.
#   4. No legacy Supabase financial repository is imported or constructed.
#   5. No vestigial Routed* repository wrapper is (re)introduced.
#   6. No Drift multiple-database warning suppression (MALI-040) exists in lib OR
#      test — ownership is correct, so the warning must never be masked.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/app/lib"
viol=0

fail() { echo "  ✗ $1"; viol=1; }
okc()  { echo "  ✓ $1"; }

# Grep helper: prints matches, returns 0 if ANY match (i.e. a violation exists).
hits() { grep -rnE "$1" "$LIB" 2>/dev/null; }

echo "══ MALI-034 architecture guard ══"

# 1. Schema pinned at the CURRENT AUTHORIZED version ----------------------------
#
# The pin is not "never change"; it is "changing this number is a deliberate act
# that edits this file too". Each bump below was separately approved and shipped:
#
#   v30 — Phase-8 B8-3 fixed-precision cutover (the money authority)
#   v31 — Coupons C4: the refetchable remote_coupons catalog cache
#   v32 — Phase 8/9A capture work items
#   v33 — Proof-Carrying capture review labels
#   v34 — Coupons Phase 1: merchant catalog + alias cache, coupon economics
#   v35 — Coupons Phase 3/4: affiliate click receipts + local savings ledger
#   v36 — PHASE 11: proof_shadow_evaluations, the durable local store for
#         Proof shadow observations that the Tier 2 activation gate counts
#   v37 — PHASE 11 Tier 2: proof_shadow_evaluations.transaction_id, the
#         attribution key joining an observation to the transaction it influenced
#   v38 — PHASE 11 Tier 2: proof_correction_events, the append-only correctness
#         provenance log (updated_at cannot distinguish confirm from correct)
#   v39 — WP-3a: replica_meta, the single-row owner record of a per-uid
#         replica file (the per-UID encrypted replica layer)
#   v40 — WP-6: user_settings cloud/ai consent version + time columns
#         (versioned, per-replica consent that survives sign-out)
#   v41 — WP-5: sync_conflicts (durable conflict snapshots) + operation_id /
#         base_revision on both outboxes (revision CAS, lost-ACK receipts)
#   v42 — Beta 1: consent_version_watermark, the per-replica consent version
#         frontier that survives sign-out (Cloud enable never reuses a version)
#   v43 — Category learning fix (user-approved 2026-11-16): transactions.
#         category_source (auto|rule|user|unknown), transactions.
#         imported_from_file (sticky file-import marker, separate from source),
#         merchant_aliases (verified, reversible) + deterministic link repair
#
# The guard sat at 31 for four bumps and failed CI on correct, approved work,
# which is the failure mode that teaches people to ignore a gate. Raising the
# number is the whole point of the check — an UNAPPROVED bump still fails here,
# loudly, because whoever makes it has to come and edit this list.
AUTHORIZED_SCHEMA=43
schema_line="$(grep -E 'const int _targetSchemaVersion = [0-9]+;' "$LIB/data/db/app_database.dart" 2>/dev/null)"
if echo "$schema_line" | grep -qE "= ${AUTHORIZED_SCHEMA};"; then
  okc "schema pinned at ${AUTHORIZED_SCHEMA}"
else
  fail "schema is not ${AUTHORIZED_SCHEMA} (found: ${schema_line:-<missing>}) — a bump must be an approved change, recorded in the list above in tools/check_arch_guard.sh"
fi

# 1b. …and the developer documentation says the SAME number ---------------------
# app/CLAUDE.md rule 6 states the authoritative schema version. It silently went
# stale across the v30 cutover; this ties it to the source of truth so a bump
# cannot land without updating the doc in the same commit.
schema_version="$(echo "$schema_line" | grep -oE '[0-9]+')"
doc_line="$(grep -nE '_targetSchemaVersion.*\(currently [0-9]+\)' "$ROOT/app/CLAUDE.md" 2>/dev/null)"
if [ -n "$schema_version" ] && echo "$doc_line" | grep -qE "\(currently ${schema_version}\)"; then
  okc "app/CLAUDE.md documents schema $schema_version"
else
  fail "app/CLAUDE.md schema statement is stale (want 'currently ${schema_version:-?}', found: ${doc_line:-<missing>})"
fi

# 2. No *_supabase_primary flag SELECTORS (quoted keys are code; comments aren't) --
m="$(hits "['\"][a-z_]*_supabase_primary['\"]")"
if [ -z "$m" ]; then okc "no *_supabase_primary flag selectors"; else
  fail "*_supabase_primary flag selector present:"; echo "$m"; fi

# 3. No FinancialCacheRepairService import or construction ----------------------
m="$(hits "import .*financial_cache_repair_service\.dart|\bFinancialCacheRepairService\s*\(")"
if [ -z "$m" ]; then okc "no FinancialCacheRepairService wiring"; else
  fail "FinancialCacheRepairService is imported/constructed:"; echo "$m"; fi

# 4. No legacy Supabase financial repository import or construction -------------
m="$(hits "import .*repositories/supabase_[a-z_]+_repository\.dart|\bSupabase(Account|Transaction|Budget|Goal|Bill|Plan|SmartInbox|Category)Repository\s*\(")"
if [ -z "$m" ]; then okc "no legacy Supabase financial repo wiring"; else
  fail "legacy Supabase financial repository imported/constructed:"; echo "$m"; fi

# 5. No vestigial Routed* repository wrapper -----------------------------------
m="$(hits "import .*repositories/routed_[a-z_]+_repository\.dart|\bclass Routed[A-Z][A-Za-z]*Repository\b|\bRouted(Account|Transaction|Budget|Goal|Bill|Plan|SmartInbox|Category)Repository\s*\(")"
if [ -z "$m" ]; then okc "no vestigial Routed* repository wrappers"; else
  fail "Routed* repository wrapper present:"; echo "$m"; fi

# 6. MALI-040 — no Drift multiple-database warning SUPPRESSION anywhere ---------
#    (production OR tests). AppDatabase.close() completes Drift's teardown
#    (super.close() disposes streamQueries + decrements the open-db counter), so
#    the "multiple databases" warning now means a genuine CONCURRENT instance,
#    not ambient noise. Suppressing it globally would re-hide an ownership
#    regression; the correct response to a real warning is to fix ownership.
m="$(grep -rnE 'dontWarnAboutMultipleDatabases' "$ROOT/app/lib" "$ROOT/app/test" 2>/dev/null)"
if [ -z "$m" ]; then okc "no Drift multi-db warning suppression (MALI-040)"; else
  fail "dontWarnAboutMultipleDatabases suppression present (MALI-040):"; echo "$m"; fi

# 7. MALI-026 (B8-3 §16) — no canonical money SUM is cast to REAL. Financial
#    totals SUM the exact `amount_minor` int column so an int64 overflow FAILS
#    EXACT (SQLite raises), never a silent float; casting a SUM to REAL would
#    reintroduce a lossy floating total. (The recurring-detection heuristic uses
#    CAST(AVG/MIN/MAX(...)) — a ratio, NOT a SUM — and is intentionally untouched.)
m="$(grep -rnE 'CAST\((COALESCE\()?SUM\(.*AS REAL' "$LIB" 2>/dev/null)"
if [ -z "$m" ]; then okc "no money SUM cast to REAL (exact integer minor totals)"; else
  fail "a SUM(...) is cast to REAL — money totals must SUM amount_minor as integer:"; echo "$m"; fi

echo
if [ "$viol" -eq 0 ]; then
  echo "ARCH GUARD PASS — Supabase-primary authority stays retired; DB warning suppression stays out."
  exit 0
else
  echo "ARCH GUARD FAIL — a retired-architecture or suppression signal reappeared (see ✗ above)."
  exit 1
fi
