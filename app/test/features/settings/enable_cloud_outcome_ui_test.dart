import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../consent/consent_test_harness.dart';

// N-E: the Cloud toggle and the consent sheet report honest outcomes. A failed or
// incomplete enable says it could not turn on and invites a retry; nothing is
// presented as saved or connected, no spinner hangs, no backend sync follows.

class _Opener extends ConsumerWidget {
  const _Opener(this.onResult);
  final ValueChanged<bool> onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async =>
                onResult(await showSmartAnalysisConsentSheet(context, ref)),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    DiagnosticsConsentGate.resetForTest();
  });
  tearDown(DiagnosticsConsentGate.resetForTest);

  for (final locale in ['en', 'ar']) {
    String incomplete() =>
        lookupAppL10n(Locale(locale)).cloudEnableIncomplete;

    testWidgets('sheet: incomplete enable says so, stops the spinner and syncs '
        'nothing ($locale)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      service.enableError = const CloudEnableIncompleteException('native');
      bool? result;
      await tester.pumpWidget(consentApp(
        overrides: consentOverrides(repo, service),
        home: _Opener((v) => result = v),
        locale: locale,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('${incomplete()} (E: CloudEnableIncomplete:native)'),
          findsOneWidget,
          reason: 'the failure is reported, not hidden');
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'no spinner hang');
      expect(service.enableCalls, 1);
      expect(service.retryCalls, 0);
      expect(service.syncCalls, 0,
          reason: 'no backend registration after an incomplete enable');
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(result, isNull, reason: 'the sheet does not report a grant');
      // The user can try again.
      service.enableError = null;
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle(const Duration(seconds: 6));
      expect(result, isTrue);
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
    });
  }

  testWidgets('sheet must wait for confirmed server ON', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    service.outcome = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'consent_sync_failed');
    bool? result;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Opener((v) => result = v),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle();
    expect(service.retryCalls, 1);
    expect(result, isNot(true), reason: 'Supabase has not confirmed ON');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sheet: a revoked lifecycle reports nothing into the live scope',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    service.enableError = const StaleAdmissionException();
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Opener((_) {}),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(find.text(lookupAppL10n(const Locale('en')).cloudEnableIncomplete),
        findsNothing);
  });

  testWidgets('sheet: the toast carries the incomplete reason (owner_mismatch)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    service.enableError = const CloudEnableIncompleteException('owner_mismatch');
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Opener((v) {}),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        find.text('${lookupAppL10n(const Locale('en')).cloudEnableIncomplete} '
            '(E: CloudEnableIncomplete:owner_mismatch)'),
        findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  test('consentFailureCode: reason, the freeze tag only while frozen, and the '
      'type of any other failure', () {
    const e = CloudEnableIncompleteException('owner_mismatch');
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = 'startup_unresolved';
    expect(consentFailureCode(e), 'CloudEnableIncomplete:owner_mismatch');
    ConsentAuthority.freeze('startup_unresolved');
    addTearDown(() {
      ConsentAuthority.egressFrozen = false;
      ConsentAuthority.egressFreezeTag = '';
    });
    expect(consentFailureCode(e),
        'CloudEnableIncomplete:owner_mismatch/startup_unresolved');
    expect(consentFailureCode(StateError('x')), 'StateError');
  });

  testWidgets('privacy management: incomplete enable shows the retry message '
      'and nothing is granted or shown as on', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    service.enableError = const CloudEnableIncompleteException('native');
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
    await tester.tap(find.byKey(const Key('consentTurnOn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        find.text('${lookupAppL10n(const Locale('en')).cloudEnableIncomplete} '
            '(E: CloudEnableIncomplete:native)'),
        findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(service.enableCalls, 1);
    expect(service.syncCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(find.text(lookupAppL10n(const Locale('en')).consentStatusActive),
        findsNothing);
  });

  testWidgets('privacy management: success enables through the durable flow '
      'and syncs once', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('consentTurnOn')));
    await tester.tap(find.byKey(const Key('consentTurnOn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(service.enableCalls, 1);
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(find.text(lookupAppL10n(const Locale('en')).cloudEnableIncomplete),
        findsNothing);
  });
}
