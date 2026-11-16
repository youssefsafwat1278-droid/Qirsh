// Shared category learning — admin review API.
//
// GET  lists candidates: (merchant, category) pairs with at least the starting
//      threshold of DISTINCT users (5) that no admin has reviewed yet.
// POST approves (optionally with another category) or rejects one candidate.
//      Only an approval reaches devices (via merchant_keywords).
//
// The verified admin's id is passed to the RPC, which checks admin_users again;
// the service-role client never reads the raw contributions table.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapReviewError, validateReviewPayload } from "@/lib/shared-learning-validation.mjs";

export async function GET() {
  let admin: Awaited<ReturnType<typeof requireAdmin>>;
  try {
    admin = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_list_merchant_category_candidates", {
    p_actor: admin.id,
  });
  if (error) {
    const mapped = mapReviewError((error as { code?: string }).code);
    return NextResponse.json({ error: mapped.error }, { status: mapped.status });
  }
  return NextResponse.json({ items: data ?? [] });
}

export async function POST(request: NextRequest) {
  let admin: Awaited<ReturnType<typeof requireAdmin>>;
  try {
    admin = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid_json" }, { status: 400 });
  }
  const validated = validateReviewPayload(body);
  if (!validated.ok) {
    return NextResponse.json({ error: "validation_failed", fields: validated.fields }, { status: 400 });
  }
  const v = validated.value!;
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_review_merchant_category_candidate", {
    p_actor: admin.id,
    p_merchant_key: v.merchant_key,
    p_category_key: v.category_key,
    p_decision: v.decision,
    p_published_category_key: v.published_category_key,
  });
  if (error) {
    const mapped = mapReviewError((error as { code?: string }).code);
    return NextResponse.json({ error: mapped.error }, { status: mapped.status });
  }
  return NextResponse.json({ result: data });
}
