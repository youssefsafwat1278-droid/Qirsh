// Project-wide daily AI ceiling (V1-022). Wraps the service-role RPC
// public.consume_ai_global_budget (migration 20261117120000).
//
// CONTRACT FOR CALLERS: call consumeGlobalAiBudget immediately before each
// paid provider request (after consent, ownership and the per-identity cap have
// passed, so refused requests do not use the global budget). When
// `allowed` is false, do NOT call the provider: treat the item exactly like an
// AI result that could not be obtained — send it to review (or, for the
// client-called endpoints, return the existing retryable error so the client
// keeps its local result in review). The guard FAILS CLOSED: any RPC error,
// thrown error or malformed reply is `allowed: false, reason: 'unavailable'`.

export type AiBudgetBucket = 'gemini' | 'places';

export type AiBudgetRefusal = 'ceiling' | 'disabled' | 'unknown_bucket' | 'unavailable';

export type AiBudgetDecision =
  | { allowed: true; reason: 'ok'; used: number; limit: number }
  | { allowed: false; reason: AiBudgetRefusal; used: number | null; limit: number | null };

export interface AiBudgetRpcClient {
  rpc(
    fn: string,
    args: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: unknown }>;
}

const REFUSALS: ReadonlySet<string> = new Set(['ceiling', 'disabled', 'unknown_bucket']);

function refused(reason: AiBudgetRefusal, used: number | null = null, limit: number | null = null): AiBudgetDecision {
  return { allowed: false, reason, used, limit };
}

export async function consumeGlobalAiBudget(
  client: AiBudgetRpcClient,
  bucket: AiBudgetBucket,
  units = 1,
): Promise<AiBudgetDecision> {
  if (!Number.isInteger(units) || units < 1 || units > 100) return refused('unavailable');
  let reply: { data: unknown; error: unknown };
  try {
    reply = await client.rpc('consume_ai_global_budget', { p_bucket: bucket, p_units: units });
  } catch {
    return refused('unavailable');
  }
  if (reply.error) return refused('unavailable');
  const data = reply.data as Record<string, unknown> | null;
  if (!data || typeof data !== 'object' || typeof data.allowed !== 'boolean') return refused('unavailable');
  const used = typeof data.used === 'number' ? data.used : null;
  const limit = typeof data.limit === 'number' ? data.limit : null;
  if (data.allowed === true) {
    if (data.reason !== 'ok' || used === null || limit === null) return refused('unavailable');
    return { allowed: true, reason: 'ok', used, limit };
  }
  const reason = typeof data.reason === 'string' && REFUSALS.has(data.reason)
    ? data.reason as AiBudgetRefusal
    : 'unavailable';
  return refused(reason, used, limit);
}
