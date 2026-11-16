// Retry: runs the sender again for one broadcast. Only rows that were never
// delivered (pending, or failed with attempts left) are claimed, so a device
// that already received the push is never sent it again.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { UUID_RE } from "@/lib/feature-flags-server";
import { invokeBroadcastSend } from "@/lib/push-broadcast-server";

export async function POST(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as { broadcast_id?: string };
  if (typeof body.broadcast_id !== "string" || !UUID_RE.test(body.broadcast_id)) {
    return NextResponse.json({ error: "broadcast_id_invalid" }, { status: 400 });
  }
  const send = await invokeBroadcastSend(body.broadcast_id);
  if (!send.ok) return NextResponse.json({ error: "send_unavailable" }, { status: 502 });
  return NextResponse.json({ send: send.result });
}
