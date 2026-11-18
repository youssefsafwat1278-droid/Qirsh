import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/config/legal_urls.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/shared_learning_preference.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../harness/egress_test_support.dart';
import 'consent_test_harness.dart';

class _Launcher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final launched = <String>[];
  @override
  Widget Function(LinkInfo)? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// Decisions 3.5, 3.8, 3.10: the first-run screen discloses everything,
/// offers two equally prominent choices, opens the legal documents with Cloud
/// OFF, and only "Agree and enable" turns anything on — shared learning
/// included.
void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  late Map<String, String> prefs;
  late _Launcher launcher;
  bool? done;

  Future<void> pump(WidgetTester tester, {String locale = 'en'}) async {
    await tester.binding.setSurfaceSize(const Size(800, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    prefs = {};
    done = null;
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    TestEgress().install(); // never consented: the gate denies
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        sharedLearningPreferenceProvider
            .overrideWithValue(SharedLearningPreference.memory(prefs)),
      ],
      home: Scaffold(
          body: SingleChildScrollView(
              child: SmartAnalysisConsentPanel(onDone: (v) => done = v))),
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  for (final locale in ['en', 'ar']) {
    testWidgets('$locale: full disclosure, two equal choices, nothing on yet',
        (tester) async {
      await pump(tester, locale: locale);
      final l = AppL10n.of(
          tester.element(find.byType(SmartAnalysisConsentPanel)));
      for (final text in [
        l.smartConsentIntro,
        l.smartConsentHeadSent,
        l.smartConsentBullet2,
        l.smartConsentBullet1,
        l.smartConsentHeadWho,
        l.smartConsentWho,
        l.smartConsentHeadWhy,
        l.smartConsentWhy,
        l.smartConsentBullet3,
        l.smartConsentShared,
        l.smartConsentOff,
        l.smartConsentLocal,
        l.initialConsentAccept,
        l.initialConsentDecline,
        l.privPolicy,
        l.privTerms,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      final accept = tester.getSize(find.byKey(const Key('initialConsentAccept')));
      final local = tester.getSize(find.byKey(const Key('initialConsentDecline')));
      expect(local, accept, reason: 'honest, equal prominence');
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(repo.saveCalls, 0);
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(prefs, isEmpty);
      expect(Directionality.of(tester.element(find.text(l.smartConsentIntro))),
          locale == 'ar' ? TextDirection.rtl : TextDirection.ltr);
    });
  }

  testWidgets('legal documents open before consent and enable nothing',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('legal-privacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('legal-terms')));
    await tester.pumpAndSettle();
    expect(launcher.launched, [kPrivacyPolicyUrl.toString(), kTermsUrl.toString()]);
    expect(repo.saveCalls, 0);
    expect(service.retryCalls, 0);
    expect(done, isNull);
    for (final c in EgressClass.values) {
      expect(ConsentAuthority.decide(c, repo.settings), isFalse);
    }
  });

  testWidgets('Agree and enable turns on Cloud, AI and shared learning',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(prefs, {SharedLearningPreference.keyFor('uid-fake'): 'on'});
    expect(done, isTrue);
  });

  testWidgets('Continue locally turns nothing on, shared learning included',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.declined);
    expect(repo.settings.aiConsentState, ConsentState.declined);
    expect(prefs, isEmpty);
    expect(await SharedLearningPreference.memory(prefs).isOn('uid-fake'),
        isFalse);
    expect(done, isFalse);
    for (final c in EgressClass.values) {
      expect(ConsentAuthority.decide(c, repo.settings), isFalse);
    }
  });

  testWidgets('a failed save writes no shared-learning choice', (tester) async {
    await pump(tester);
    repo.failSave = true;
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle();
    expect(prefs, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });
}
