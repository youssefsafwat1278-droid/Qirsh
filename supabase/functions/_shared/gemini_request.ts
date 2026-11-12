/// The ONE builder for every Gemini `models/*:generateContent` request body
/// sent from these functions. Every such request carries SMS-derived text.
///
/// `store: false` opts the request out of the Gemini API "Logs and Datasets"
/// feature. Since 2026-10-26 new paid-tier projects store generateContent
/// requests by default (55-day default retention). The v1beta API reference
/// documents `store` as a top-level optional boolean on the generateContent
/// request body, a sibling of `generationConfig`: "Optional. Configures the
/// logging behavior for a given request. If set, it takes precedence over the
/// project-level logging config."
///
/// It is set AFTER the caller's fields so no caller can turn storage back on.
export function geminiRequestBody(body: {
  contents: unknown;
  generationConfig?: Record<string, unknown>;
}): string {
  return JSON.stringify({ ...body, store: false });
}
