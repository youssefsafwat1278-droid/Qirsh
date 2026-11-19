// Server leg of the parser differential harness.
// deno run -A --no-lock server.ts <version root> <cases.json> <out.jsonl>
// Runs the version's own parseSms on the text index.ts parses
// (redactThirdPartyNames(redactPii(raw)).trim()) with AI off; a second call
// with AI allowed and a beforeAi hook that refuses tells whether the capture
// would reach the AI (review) or is rejected before it (silent).
const root = Deno.args[0];
const P = await import(`file://${root}/supabase/functions/process-ios-sms/parse.ts`);
const R = await import(`file://${root}/supabase/functions/_shared/sms_redaction.ts`);
const rows = JSON.parse(await Deno.readTextFile(Deno.args[1]));
const out: string[] = [];
for (const r of rows) {
  const raw: string = r.text;
  try {
    const text = R.redactThirdPartyNames(R.redactPii(raw)).trim();
    const inp = { text, rawText: raw, sender: r.sender ?? 'AlRajhi', receivedAt: '2026-11-17T10:00:00Z', tzOffsetMinutes: 180, locale: 'en' };
    const off = await P.parseSms({ ...inp, allowAi: false });
    let ai = false;
    await P.parseSms({ ...inp, allowAi: true, beforeAi: () => { ai = true; return Promise.resolve(false); } });
    const p = off.parsed;
    let processed = !!(off.accepted && p.amount && p.currency);
    // index.ts: a processed capture whose meaning is not "record" is rejected
    // with the meaning's reason (versions that have messageMeaning).
    const meaning = P.messageMeaning ? (off.meaning ?? P.messageMeaning(text)) : null;
    let reason = p.reviewReason ?? null;
    if (processed && meaning && meaning.disposition !== 'record') {
      processed = false;
      reason = `${meaning.kind}:${meaning.reason}`;
    } else if (!processed && meaning && (!reason || meaning.disposition === 'review')) {
      // (Round 5: a review meaning is what the device shows, also when the
      // server held the capture on its own reading — a transfer.)
      reason = `${meaning.kind}:${meaning.reason}`;
    }
    out.push(JSON.stringify({ id: r.id, processed, ai, reason, type: p.type ?? null, dir: p.direction ?? null,
      a: p.amount ?? null, cur: p.currency ?? null, at: p.amount_text ?? null, m: p.merchant ?? null,
      l4: p.last4 ?? null, occ: p.occurredAt ?? null }));
  } catch (e) {
    out.push(JSON.stringify({ id: r.id, throw: String(e).slice(0, 120) }));
  }
}
await Deno.writeTextFile(Deno.args[2], out.join('\n') + '\n');
