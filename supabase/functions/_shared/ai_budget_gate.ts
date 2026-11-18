import { type AiBudgetBucket, type AiBudgetRpcClient, consumeGlobalAiBudget } from './ai_spend_guard.ts';

// Call-site wrapper around the project-wide AI ceiling (V1-022,
// ai_spend_guard.ts). One reservation per paid provider request.
//
// Deploy-order rule: a function deployed BEFORE migration 20261117120000 finds
// no consume_ai_global_budget function. That one case (PostgREST PGRST202 /
// Postgres 42883 "function does not exist") behaves exactly as before the
// guard existed: the provider call goes ahead. Every other failure — a
// refusal, an RPC error, a thrown or malformed reply — fails closed and the
// caller must not call the provider.

const GUARD_ABSENT_CODES: ReadonlySet<string> = new Set(['PGRST202', '42883']);

export type AiBudgetGate =
  | { allowed: true; reason: 'ok' | 'guard_absent' }
  | { allowed: false; reason: string };

export async function reserveAiBudget(client: AiBudgetRpcClient, bucket: AiBudgetBucket): Promise<AiBudgetGate> {
  let guardAbsent = false;
  const watched: AiBudgetRpcClient = {
    rpc: (fn, args) =>
      Promise.resolve(client.rpc(fn, args)).then((reply) => {
        const code = (reply?.error as { code?: unknown } | null | undefined)?.code;
        if (typeof code === 'string' && GUARD_ABSENT_CODES.has(code)) guardAbsent = true;
        return reply;
      }),
  };
  const decision = await consumeGlobalAiBudget(watched, bucket);
  if (decision.allowed) return { allowed: true, reason: 'ok' };
  // Content-free log lines: a bucket and a reason, never an identity.
  if (guardAbsent) {
    console.log(JSON.stringify({ event: 'ai_budget_guard_absent', bucket }));
    return { allowed: true, reason: 'guard_absent' };
  }
  console.log(JSON.stringify({ event: 'ai_budget_refused', bucket, reason: decision.reason }));
  return { allowed: false, reason: decision.reason };
}
