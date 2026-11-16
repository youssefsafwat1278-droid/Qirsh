// Admin push: send the current draft to ONE account only, as a test.
//
// Same content validation and the same sender as a real broadcast, but
// admin_create_push_broadcast_test (migration 20261116230000) targets only the
// devices of the account named by email or user id, creates no in-app
// announcement, and needs no typed recipient count.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { isRpcNotDeployed, rpcErrorStatus, UUID_RE } from "@/lib/feature-flags-server";
import { parseTestTarget, validateBroadcastDraft } from "@/lib/push-broadcast.mjs";
import { invokeBroadcastSend } from "@/lib/push-broadcast-server";

type TestBody = {
  operation_id?: string;
  target?: string;
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
  const body = (await req.json().catch(() => ({}))) as TestBody;
  if (typeof body.operation_id !== "string" || !UUID_RE.test(body.operation_id)) {
    return NextResponse.json({ error: "operation_id_invalid" }, { status: 400 });
  }
  const target = parseTestTarget(body.target);
  if (target === null) return NextResponse.json({ error: "test_target_invalid" }, { status: 400 });
  const draft = validateBroadcastDraft(body);
  if (!draft.ok) {
    return NextResponse.json({ error: "validation_failed", errors: draft.errors }, { status: 422 });
  }

  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_create_push_broadcast_test", {
    p_actor: user.id,
    p_operation_id: body.operation_id,
    p_title_ar: draft.value.title_ar,
    p_title_en: draft.value.title_en,
    p_body_ar: draft.value.body_ar,
    p_body_en: draft.value.body_en,
    p_deep_link: draft.value.deep_link,
    p_target: target,
  });
  if (error) {
    if (isRpcNotDeployed(error.code)) return NextResponse.json({ error: "not_deployed" }, { status: 503 });
    const status = error.code === "42501" ? 403 : rpcErrorStatus(error.code);
    if (status === 500) console.error("[push-broadcasts/test]", error);
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
