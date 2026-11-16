import { createClient } from "@/lib/supabase-server";

/**
 * Runs the send-push-broadcast Edge Function for one broadcast as the signed-in
 * admin. The function authenticates that JWT and checks admin_users itself; the
 * service-role key never leaves this server and is never sent to the function.
 * Re-invoking it is safe: only rows that were never delivered are claimed.
 */
export async function invokeBroadcastSend(
  broadcastId: string,
): Promise<{ ok: true; result: unknown } | { ok: false; status: number }> {
  const supabase = await createClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session) return { ok: false, status: 401 };
  try {
    const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/send-push-broadcast`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ broadcast_id: broadcastId }),
    });
    const result = await res.json().catch(() => null);
    return res.ok ? { ok: true, result } : { ok: false, status: res.status };
  } catch {
    return { ok: false, status: 502 };
  }
}
