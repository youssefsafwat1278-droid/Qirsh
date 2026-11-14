// MALI-032 / MALI-039 / MALI-075n — shared privacy-classification contract.
//
// One source of truth for "what may leave the device, and in what form", used
// by BOTH the outbound telemetry boundary (Sentry) and local diagnostic
// logging. The posture is an ALLOWLIST, not a blacklist:
//
//   * Structured fields (tags, extra, contexts) are dropped unless their KEY is
//     explicitly allowlisted here — see [TelemetrySanitizer].
//   * Free-form text that is nonetheless retained (a log line, an allowlisted
//     tag value) is passed through [redactText], which strips the known classes
//     of sensitive data below.
//
// Sensitive classes this file recognises (the canary set the privacy tests
// exercise): raw SMS bodies, monetary amounts, account/card/phone digit runs,
// auth tokens / secrets, e-mail addresses, filesystem paths, and any long
// opaque identifier (install IDs, keys). Merchant names and bank sender IDs are
// free-form words that no regex can enumerate — text carrying them is never
// *retained*; the telemetry boundary drops such free text entirely rather than
// attempting to redact it in place.
library;

/// Stateless redaction + classification helpers. Pure functions only, so they
/// are trivially unit-testable and safe to call from any isolate.
class PrivacyRedactor {
  const PrivacyRedactor._();

  /// Replacement token emitted for any value that has been removed.
  static const String redacted = '[redacted]';

  // ── Structured-field allowlists (used by the telemetry boundary) ──────────

  /// `tags` keys permitted to leave the device. Values are still redacted.
  static const Set<String> allowedTagKeys = <String>{
    'level',
    'environment',
    'release',
    'dist',
    'error.code',
    'error.module',
    'error.retryable',
  };

  /// `extra` keys permitted to leave the device. Values are still redacted.
  static const Set<String> allowedExtraKeys = <String>{
    'error.code',
    'error.module',
    'error.operation',
    'error.retryable',
  };

  /// Standard, non-user context blocks kept as ordinary telemetry. Any custom
  /// context (where app data would ride) is dropped.
  static const Set<String> allowedContextKeys = <String>{
    'device',
    'os',
    'app',
    'runtime',
    'culture',
    'gpu',
  };

  // ── Redaction patterns (ordered: specific → generic) ──────────────────────

  static final RegExp _path = RegExp(
    r'(?:file://)?(?:/(?:Users|var|private|data|storage|tmp)/)[^\s"'
    "'"
    r']*',
  );
  static final RegExp _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
  static final RegExp _jwt =
      RegExp(r'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*');
  static final RegExp _bearer =
      RegExp(r'(?:[Bb]earer|[Tt]oken|[Aa]pikey|[Aa]uthorization)\s*[:=]?\s*\S+');
  static final RegExp _amount = RegExp(r'\d[\d,]*\.\d{1,3}');
  // A database error's bound parameters (`parameters: <merchant>, <amount>`)
  // are user data of any shape: dropped to the end of the line.
  static final RegExp _sqlParams = RegExp(r'parameters:[^\n]*');
  // A comma-grouped integer (`1,250`) is an amount.
  static final RegExp _groupedInt = RegExp(r'\d{1,3}(?:,\d{3})+');
  static final RegExp _digitRun = RegExp(r'\d[\d\s-]{4,}\d');
  // A bare integer of 4+ digits (minor-unit amounts such as `12550`).
  static final RegExp _longInt = RegExp(r'(?<![\w.])\d{4,}(?![\w.])');
  static final RegExp _opaqueId = RegExp(r'[A-Za-z0-9_-]{24,}');

  /// Strips every recognised sensitive class from an arbitrary string. Used for
  /// text we deliberately KEEP (log lines, allowlisted tag values). It cannot
  /// catch open-vocabulary tokens (merchant names, sender IDs); callers that
  /// might handle those must drop the text rather than rely on this.
  static String redactText(String input) {
    if (input.isEmpty) return input;
    var out = input;
    out = out.replaceAll(_path, '[path]');
    out = out.replaceAll(_email, '[email]');
    out = out.replaceAll(_jwt, '[token]');
    out = out.replaceAll(_bearer, '[token]');
    out = out.replaceAll(_sqlParams, 'parameters: [redacted]');
    out = out.replaceAll(_amount, '[amount]');
    out = out.replaceAll(_groupedInt, '[amount]');
    out = out.replaceAll(_digitRun, '[num]');
    out = out.replaceAll(_longInt, '[num]');
    out = out.replaceAll(_opaqueId, '[id]');
    return out;
  }

  /// Redacts a dynamic value destined for an allowlisted structured field.
  /// Strings are passed through [redactText]; bools/nums are safe as-is;
  /// anything else collapses to the [redacted] token so no nested map/list can
  /// smuggle text past the boundary.
  static Object? redactValue(Object? value) {
    if (value == null) return null;
    if (value is String) return redactText(value);
    if (value is bool || value is num) return value;
    return redacted;
  }
}
