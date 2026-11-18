import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/config/legal_urls.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/gated_url_launcher.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../harness/egress_test_support.dart';

class _Launcher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final launched = <String>[];
  final modes = <PreferredLaunchMode>[];
  @override
  Widget Function(LinkInfo)? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    modes.add(options.mode);
    return true;
  }
}

const _unset = UserSettingsEntity(
  id: 's',
  country: 'EG',
  currency: 'EGP',
  language: 'en',
  theme: 'system',
  inputMethod: 'manual',
  notificationsJson: '{}',
  privacyModeEnabled: false,
);

void main() {
  late _Launcher launcher;
  setUp(() {
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
  });

  test('exactly the two configured documents are legal destinations', () {
    expect(isLegalDocumentUrl(kPrivacyPolicyUrl), isTrue);
    expect(isLegalDocumentUrl(kTermsUrl), isTrue);
    final base = kPrivacyPolicyUrl;
    for (final other in [
      base.replace(scheme: 'http'),
      base.replace(query: 'uid=1'),
      base.replace(fragment: 'x'),
      base.replace(path: '/privacy/'),
      base.replace(path: '/privacy2'),
      base.replace(path: '/'),
      base.replace(host: 'evil.example'),
      base.replace(host: 'sub.${base.host}'),
      base.replace(port: 8443),
      base.replace(userInfo: 'a:b'),
      Uri.parse('https://example.com/privacy'),
      Uri.parse('shortcuts://open-shortcut?name=QIRSH'),
    ]) {
      expect(isLegalDocumentUrl(other), isFalse, reason: '$other');
    }
  });

  test(
      'Cloud OFF / before consent: the documents open, nothing else does, and '
      'no gate changes', () async {
    final egress = TestEgress().install(); // absent record: never consented
    expect(await egress.gate.permits(), isFalse);

    expect(await launchLegalDocument(kPrivacyPolicyUrl), isTrue);
    expect(await launchLegalDocument(kTermsUrl), isTrue);
    expect(launcher.launched,
        [kPrivacyPolicyUrl.toString(), kTermsUrl.toString()]);
    expect(launcher.modes, everyElement(PreferredLaunchMode.inAppBrowserView));

    // The exception is not a general opening: the gated launcher still refuses
    // the same URLs, and the legal launcher refuses any other URL.
    expect(await launchExternalUrl(kPrivacyPolicyUrl), isFalse);
    expect(await launchLegalDocument(Uri.parse('https://example.com/p')),
        isFalse);
    expect(await launchLegalDocument(kTermsUrl.replace(query: 'x=1')),
        isFalse);
    expect(launcher.launched.length, 2);

    // Opening them enabled nothing.
    expect(await egress.gate.permits(), isFalse);
    expect(CloudEgressGate.instance, same(egress.gate));
    for (final c in EgressClass.values) {
      expect(ConsentAuthority.decide(c, _unset), isFalse, reason: '$c');
    }
  });

  test('unresolved gate: the documents still open', () async {
    TestEgress(resolved: false).install();
    expect(await launchLegalDocument(kPrivacyPolicyUrl), isTrue);
    expect(await launchExternalUrl(Uri.parse('https://example.com/')), isFalse);
  });
}
