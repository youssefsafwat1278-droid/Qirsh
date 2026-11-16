// Admin push broadcasts. GET = history with per-status counts; POST = create
// (typed confirmation of the dry-run device count) and start sending.
//
// requireAdmin() -> service-role RPC with the admin's id, as in
// /api/feature-flags/apply. The RPCs re-check admin_users, the content, the
// deep-link allowlist and the confirmed count, and are idempotent on
// operation_id; a replayed create never adds rows.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { isRpcNotDeployed, rpcErrorStatus, UUID_RE } from "@/lib/feature-flags-server";
import { parseTypedConfirmation, validateBroadcastDraft } from "@/lib/push-broadcast.mjs";
import { invokeBroadcastSend } from "@/lib/push-broadcast-server";

export async function GET() {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_push_broadcast_history", { p_actor: user.id, p_limit: 50 });
  if (error) {
    if (isRpcNotDeployed(error.code)) return NextResponse.json({ error: "not_deployed" }, { status: 503 });
    return NextResponse.json({ error: "history_unavailable" }, { status: 500 });
  }
  return NextResponse.json({ broadcasts: data ?? [] });
}

type CreateBody = {
  operation_id?: string;
  typed_confirmation?: string;
  title_ar?: string;
  title_en?: string;
  body_ar?: string;
  body_en?: string;
  deep_link?: string | null;
};

export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as CreateBody;
  if (typeof body.operation_id !== "string" || !UUID_RE.test(body.operation_id)) {
    return NextResponse.json({ error: "operation_id_invalid" }, { status: 400 });
  }
  const confirmed = parseTypedConfirmation(body.typed_confirmation);
  if (confirmed === null) {
    return NextResponse.json({ error: "confirmation_invalid" }, { status: 400 });
  }
  const draft = validateBroadcastDraft(body);
  if (!draft.ok) {
    return NextResponse.json({ error: "validation_failed", errors: draft.errors }, { status: 422 });
  }

  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_create_push_broadcast", {
    p_actor: user.id,
    p_operation_id: body.operation_id,
    p_title_ar: draft.value.title_ar,
    p_title_en: draft.value.title_en,
    p_body_ar: draft.value.body_ar,
    p_body_en: draft.value.body_en,
    p_deep_link: draft.value.deep_link,
    p_confirm_devices: confirmed,
  });
  if (error) {
    if (isRpcNotDeployed(error.code)) return NextResponse.json({ error: "not_deployed" }, { status: 503 });
    const status = error.code === "42501" ? 403 : rpcErrorStatus(error.code);
    if (status === 500) console.error("[push-broadcasts]", error);
    return NextResponse.json({ error: status === 500 ? "unexpected" : error.message }, { status });
  }

  const created = data as { broadcast_id: string };
  const send = await invokeBroadcastSend(created.broadcast_id);
  return NextResponse.json({
    created: data,
    send: send.ok ? send.result : null,
    error: send.ok ? undefined : "send_unavailable",
  });
}
