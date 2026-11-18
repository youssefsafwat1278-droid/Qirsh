// Referral & Ads Phase R2 — referral / entitlement detail (spec §6).
//
// Read-only. Assembles, for one user, from the zero-policy tables via a
// service-role read: referral code + status; current cycle (progress + pinned
// rule version); the referrals list (short ids only — "deleted user" for
// de-identified qualified rows); the immutable grant-history ledger; and the
// current entitlement state. NEVER any financial data. Provenance comes from
// the ledger, not from a mutable field on the state row.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { isUuid } from "@/lib/referral-validation.mjs";

function dbFail(context: string, error: unknown) {
  console.error(`[referral-users/detail] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const userId = (await params).id;
  if (!isUuid(userId)) {
    return NextResponse.json(safeErrorBody("invalid_user_id"), { status: 400 });
  }

  const supabase = await createAdminClient();
  try {
    const [code, progress, referralsMade, grants, entitlement] = await Promise.all([
      supabase
        .from("referral_codes")
        .select("code, status, created_at, rotated_at")
        .eq("user_id", userId)
        .maybeSingle(),
      supabase
        .from("referral_reward_progress")
        .select(
          "reward_type, pinned_rule_id, pinned_rule_version, cycle_index, qualified_in_cycle, cycle_state, updated_at",
        )
        .eq("referrer_user_id", userId),
      supabase
        .from("referrals")
        .select(
          "id, referred_user_id, attribution_method, status, rejection_reason, created_at, qualified_at, referred_user_deleted_at",
        )
        .eq("referrer_user_id", userId)
        .order("created_at", { ascending: false }),
      supabase
        .from("referral_reward_grants")
        .select(
          "id, rule_version, cycle_index, reward_type, reward_days_granted, resulting_ends_at, created_at",
        )
        .eq("referrer_user_id", userId)
        .order("created_at", { ascending: false }),
      supabase
        .from("user_entitlement_state")
        .select("entitlement_type, status, starts_at, ends_at, updated_at")
        .eq("user_id", userId),
    ]);

    for (const [ctx, res] of [
      ["code", code],
      ["progress", progress],
      ["referrals", referralsMade],
      ["grants", grants],
      ["entitlement", entitlement],
    ] as const) {
      if (res.error) return dbFail(ctx, res.error);
    }

    // De-identify qualified rows whose referee was deleted (spec §14): expose
    // only the non-identifying qualification fact, never a dangling reference.
    const referrals = (referralsMade.data ?? []).map((r) => ({
      id: r.id,
      referred_user: r.referred_user_id ?? (r.referred_user_deleted_at ? "deleted user" : null),
      attribution_method: r.attribution_method,
      status: r.status,
      rejection_reason: r.rejection_reason,
      created_at: r.created_at,
      qualified_at: r.qualified_at,
    }));

    return NextResponse.json({
      user_id: userId,
      code: code.data ?? null,
      progress: progress.data ?? [],
      referrals,
      grants: grants.data ?? [],
      entitlement: entitlement.data ?? [],
    });
  } catch (e) {
    return dbFail("detail", e);
  }
}
