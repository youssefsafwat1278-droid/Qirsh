// Shared category learning — validation for the admin review API.
//
// Not the last line of defence: admin_review_merchant_category_candidate
// re-checks admin membership, the candidate threshold and the category. This
// only turns a bad request into a clear error before the round trip.

export const DECISIONS = ["approved", "rejected"];
const EXCLUDED = new Set(["transfers", "income", "cash", "other", "all_expenses"]);

const categoryOk = (v) =>
  typeof v === "string" && /^[a-z_]{2,32}$/.test(v) && !EXCLUDED.has(v);

/** Returns {ok, value?, fields}. Only the four known keys are passed on. */
export function validateReviewPayload(body) {
  const fields = [];
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, fields: [{ field: "body", code: "invalid" }] };
  }
  const merchantKey = body.merchant_key;
  if (typeof merchantKey !== "string" || merchantKey.length < 3 || merchantKey.length > 64) {
    fields.push({ field: "merchant_key", code: "invalid" });
  }
  if (!categoryOk(body.category_key)) fields.push({ field: "category_key", code: "invalid" });
  if (!DECISIONS.includes(body.decision)) fields.push({ field: "decision", code: "invalid" });
  const published = body.published_category_key;
  if (published != null && published !== "") {
    if (body.decision !== "approved") fields.push({ field: "published_category_key", code: "only_on_approve" });
    else if (!categoryOk(published)) fields.push({ field: "published_category_key", code: "invalid" });
  }
  if (fields.length) return { ok: false, fields };
  return {
    ok: true,
    fields,
    value: {
      merchant_key: merchantKey,
      category_key: body.category_key,
      decision: body.decision,
      published_category_key: body.decision === "approved" && published ? published : null,
    },
  };
}

/** Revoke of a published mapping (manual or auto): only the pair. */
export function validateRevokePayload(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, fields: [{ field: "body", code: "invalid" }] };
  }
  const fields = [];
  const m = body.merchant_key;
  if (typeof m !== "string" || m.length < 3 || m.length > 64) fields.push({ field: "merchant_key", code: "invalid" });
  if (!categoryOk(body.category_key)) fields.push({ field: "category_key", code: "invalid" });
  if (fields.length) return { ok: false, fields };
  return { ok: true, fields, value: { merchant_key: m, category_key: body.category_key } };
}

/** SQLSTATEs raised by the review / revoke RPCs → HTTP. */
export function mapReviewError(code) {
  if (code === "P0403") return { status: 403, error: "not_authorized" };
  if (code === "P0409") return { status: 409, error: "not_a_candidate_or_already_reviewed" }; // revoke: not published
  if (code === "P0422") return { status: 400, error: "validation_failed" };
  return { status: 500, error: "unexpected" };
}
