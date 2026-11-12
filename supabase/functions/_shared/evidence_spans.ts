/// PHASE 6 — server-side validation of evidence spans.
///
/// A span is a claim about WHICH CHARACTERS of the transmitted text some piece
/// of evidence occupies. The client computes spans against its own sanitized
/// copy; the server re-sanitizes independently. If those two texts differ for
/// any reason — a bypassed client, a version skew, a tampered payload, a bug —
/// the spans silently describe different characters, and every proof built on
/// them is about the wrong part of the message.
///
/// So spans are not trusted, they are CHECKED against the exact string this
/// server is about to send upstream. A span that cannot quote its own text is
/// rejected rather than repaired: there is no safe way to guess what was meant.
///
/// Spans that land on a redaction placeholder are refused too. `[CARD]` is not
/// evidence, and evidence that claims to be it is either confused or hostile.
export const REDACTION_TOKENS = [
  '[CARD]',
  '[PHONE]',
  '[ACCOUNT]',
  '[IBAN]',
  '[OTP]',
  '[REDACTED]',
  '[NAME]',
  '[REF]',
  '[EMAIL]',
];

export function validateEvidenceSpans(
  evidence: unknown,
  sanitized: string,
): { ok: true; count: number } | { ok: false; reason: string } {
  if (evidence === undefined || evidence === null) return { ok: true, count: 0 };
  if (!Array.isArray(evidence)) return { ok: false, reason: 'evidence_not_array' };
  if (evidence.length > 64) return { ok: false, reason: 'evidence_too_many' };

  for (const node of evidence) {
    if (typeof node !== 'object' || node === null) {
      return { ok: false, reason: 'evidence_node_not_object' };
    }
    const n = node as Record<string, unknown>;
    const s = n.s ?? n.start;
    const e = n.e ?? n.end;
    const t = n.t ?? n.text;
    if (typeof s !== 'number' || typeof e !== 'number' || typeof t !== 'string') {
      return { ok: false, reason: 'evidence_span_malformed' };
    }
    if (!Number.isInteger(s) || !Number.isInteger(e)) {
      return { ok: false, reason: 'evidence_span_not_integer' };
    }
    if (s < 0 || e > sanitized.length || s >= e) {
      return { ok: false, reason: 'evidence_span_out_of_range' };
    }
    // THE check: the span must quote its own text in the text we will send.
    if (sanitized.slice(s, e) !== t) {
      return { ok: false, reason: 'evidence_span_stale' };
    }
    for (const token of REDACTION_TOKENS) {
      const at = sanitized.indexOf(token);
      let from = at;
      while (from >= 0) {
        if (s < from + token.length && from < e) {
          return { ok: false, reason: 'evidence_span_overlaps_redaction' };
        }
        from = sanitized.indexOf(token, from + 1);
      }
    }
  }
  return { ok: true, count: evidence.length };
}
