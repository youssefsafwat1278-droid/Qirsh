type Account = { id: string; local_id: string; currency: string };
type Budget = { currency: string; category_id: string; user_category_id?: string | null;
  server_account_id?: string | null; local_account_id?: string | null };
type Capture = { payload_id: string; parsed: Record<string, unknown> | null };

// Captures are not ledger entries until the app imports them. Count their
// verified results for background alerts without writing financial records.
export function pendingCaptureSpend(captures: Capture[], accounts: Account[],
  ledgerIds: Set<string>, budget: Budget, from: number, to: number): number {
  let total = 0;
  for (const capture of captures) {
    if (ledgerIds.has(capture.payload_id)) continue;
    const p = capture.parsed;
    if (!p || p.currency !== budget.currency || budget.user_category_id) continue;
    const account = accounts.find((a) => a.currency === p.currency);
    if (budget.server_account_id && account?.id !== budget.server_account_id) continue;
    if (!budget.server_account_id && budget.local_account_id &&
        account?.local_id !== budget.local_account_id) continue;
    if (budget.category_id !== 'all_expenses' && p.category !== budget.category_id) continue;
    const when = Date.parse(String(p.occurredAt ?? p.comparisonTimestamp ?? ''));
    if (!(when >= from && when < to)) continue;
    const amount = Number(p.amount_text ?? p.amount);
    if (!Number.isFinite(amount) || amount <= 0) continue;
    if (p.type === 'refund') { total -= amount; continue; }
    if (p.direction !== 'debit' || p.type === 'income') continue;
    if (p.type === 'transfer' && /internal transfer|own account|self transfer|between your accounts|تحويل داخلي|بين حساباتك|لحسابك الآخر|من حسابك إلى حسابك/i.test(String(p.rawMessage ?? ''))) continue;
    total += amount;
  }
  return total;
}

export function budgetWindow(period: string, now: number, offsetMinutes: number): [number, number] {
  const shift = offsetMinutes * 60000;
  const d = new Date(now + shift);
  const y = d.getUTCFullYear(), m = d.getUTCMonth(), day = d.getUTCDate();
  if (period === 'yearly') return [Date.UTC(y, 0, 1) - shift, Date.UTC(y + 1, 0, 1) - shift];
  if (period === 'monthly') return [Date.UTC(y, m, 1) - shift, Date.UTC(y, m + 1, 1) - shift];
  const start = Date.UTC(y, m, day - (period === 'weekly' ? (d.getUTCDay() + 1) % 7 : 0)) - shift;
  return [start, start + (period === 'weekly' ? 7 : 1) * 86400000];
}
