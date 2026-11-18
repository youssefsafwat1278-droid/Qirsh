import 'package:url_launcher/url_launcher.dart';

import '../config/legal_urls.dart';
import 'cloud_egress_gate.dart';

/// Astra H2.5: the ONE way the app opens an external URL. Every `url_launcher`
/// call site goes through it (a source-scan test pins that no other file imports
/// `url_launcher`). While the egress gate does not permit (Cloud OFF, unset,
/// unresolved, DISABLING, uncertain) the launch is DENIED and this returns
/// `false`, which every call site already treats as "could not open". The only
/// exception is an allowlisted host inside an active account-control grant
/// ([CloudEgressGate.mayLaunchExternal]); no call site needs it today.
Future<bool> launchExternalUrl(Uri uri) async {
  if (!await CloudEgressGate.instance.mayLaunchExternal(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The one ungated exception (user-approved 2026-11-10): Apple Shortcuts links
/// for bank-SMS setup, which must work with Cloud OFF.
///
/// None of these carry user data or reach a Qirsh/third-party server:
/// `shortcuts://` opens the on-device Shortcuts app, and an iCloud shortcut
/// link names only a public shortcut id. It does not change the Cloud OFF
/// policy for anything else: every other URL is refused here and must use
/// [launchExternalUrl]. Allowed, exactly:
/// - `shortcuts://open-shortcut?name=<QIRSH | Qirsh …>`
/// - `shortcuts://run-shortcut?name=<QIRSH | Qirsh …>&input=text&text=QIRSH_SETUP_CHECK_V1`
/// - `https://www.icloud.com/shortcuts/<32 hex id>`
bool isShortcutSetupUrl(Uri uri) {
  if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) return false;
  if (uri.scheme == 'https') {
    return uri.host == 'www.icloud.com' &&
        !uri.hasQuery &&
        RegExp(r'^/shortcuts/[0-9a-f]{32}$').hasMatch(uri.path);
  }
  if (uri.scheme != 'shortcuts' || uri.path.isNotEmpty) return false;
  final q = uri.queryParameters;
  final name = q['name'] ?? '';
  final qirsh = name == 'QIRSH' || name.startsWith('Qirsh ');
  return switch (uri.host) {
    'open-shortcut' => qirsh && q.length == 1,
    'run-shortcut' => qirsh &&
        q.length == 3 &&
        q['input'] == 'text' &&
        q['text'] == 'QIRSH_SETUP_CHECK_V1',
    _ => false,
  };
}

/// Opens an [isShortcutSetupUrl] link without the Cloud gate; refuses the rest.
Future<bool> launchShortcutSetupUrl(Uri uri) async {
  if (!isShortcutSetupUrl(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The second ungated exception (owner decision 3.5): the Privacy Policy and
/// Terms must open with Cloud OFF, including before consent.
///
/// Exactly the two configured documents ([kPrivacyPolicyUrl], [kTermsUrl]),
/// compared as whole URLs: no other path, query, fragment, port, user info or
/// host. The URLs are constants, so opening one carries no message, account or
/// consent data; the legal site receives an ordinary page request from the
/// browser. It does not enable Cloud or AI and changes no other egress rule:
/// every other URL is refused here and must use [launchExternalUrl].
bool isLegalDocumentUrl(Uri uri) {
  final text = uri.toString();
  return uri.scheme == 'https' &&
      (text == kPrivacyPolicyUrl.toString() || text == kTermsUrl.toString());
}

/// Opens an [isLegalDocumentUrl] document in an in-app Safari view (the
/// system browser on platforms without one) without the Cloud gate; refuses
/// the rest.
Future<bool> launchLegalDocument(Uri uri) async {
  if (!isLegalDocumentUrl(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}
