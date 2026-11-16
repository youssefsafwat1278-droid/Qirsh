// Dry run: how many devices and users a broadcast would reach right now.
// Read-only; the RPC re-checks admin_users.
import { NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { isRpcNotDeployed } from "@/lib/feature-flags-server";

export async function POST() {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_push_broadcast_dry_run", { p_actor: user.id });
  if (error) {
    if (isRpcNotDeployed(error.code)) return NextResponse.json({ error: "not_deployed" }, { status: 503 });
    return NextResponse.json({ error: "dry_run_unavailable" }, { status: 500 });
  }
  return NextResponse.json(data);
}
