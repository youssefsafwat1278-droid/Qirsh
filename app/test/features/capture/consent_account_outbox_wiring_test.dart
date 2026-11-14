import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/consent_session_support.dart';
import '../../harness/egress_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('production registration provider queues each explicit Cloud enable',
      () async {
    SharedPreferences.setMockInitialValues({});
    final egress = TestEgress()..owner = 'uid-x';
    egress.install();
    final f = await F2Fixture.create();
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-anon',
      httpClient: MockClient((request) async => http.Response('{}', 200)),
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
    final sdk = Supabase.instance.client;
    await F2Fixture.recoverSession_(sdk, 'uid-x');
    final cap = (await freshSignIn(f, 'uid-x', client: sdk))!;
    final db = f.host.current!.database;
    final queue = HookedOutbox(db, 'uid-x');
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      planningOutboxQueueProvider.overrideWithValue(queue),
      captureBackendClientProvider.overrideWithValue(null),
    ]);
    try {
      final service = container.read(captureDeviceRegistrationServiceProvider);
      await service.enableCloud(
        write: ConsentWrite(
            cap, const ConsentChoices(cloud: ConsentState.accepted)),
      );
      expect(queue.enqueues, 1);
      expect(await settingsOutboxRows(db), 1);
      final row = await db
          .customSelect(
              "SELECT payload_json FROM planning_sync_outbox WHERE entity_type = 'settings';")
          .getSingle();
      final payload = jsonDecode(row.read<String>('payload_json')) as Map;
      expect(payload['cloud_processing_enabled'], isTrue);
      expect(payload['consent_version'], greaterThan(0));
      final firstVersion = payload['consent_version'];
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      // A previous attempt may have reached only capture_devices. Repeating
      // the explicit choice must still send the consent, without inventing a
      // new local version or an unrelated full settings update.
      await container.read(consentSettingsWriterProvider).saveConsentChoice(
          cap, const ConsentChoices(cloud: ConsentState.accepted));
      final retryRow = await db.customSelect(
          "SELECT payload_json FROM planning_sync_outbox WHERE entity_type = 'settings';")
          .getSingle();
      final retry = jsonDecode(retryRow.read<String>('payload_json')) as Map;
      expect(retry['cloud_processing_enabled'], isTrue);
      expect(retry['consent_version'], firstVersion);
      expect(retry['consent_only'], isTrue);
    } finally {
      container.dispose();
      await Supabase.instance.dispose();
      await f.dispose();
      ConsentAuthority.egressFrozen = false;
    }
  });

  for (final remote in <AccountConsentStatus?>[
    (cloud: false, ai: false, version: 1),
    (cloud: true, ai: false, version: 0),
    (cloud: true, ai: false, version: 2),
    (cloud: true, ai: true, version: 1),
    (cloud: true, ai: false, version: 1),
    null,
  ]) {
    test('device receipt requires exact account confirmation: $remote',
        () async {
      final egress = TestEgress()..owner = 'uid-x';
      egress.install();
      final f = await F2Fixture.create();
      try {
        final cap = (await freshSignIn(f, 'uid-x'))!;
        final repository =
            DriftUserSettingsRepository(f.host.current!.database);
        final settings = await repository.saveConsentChoice(
            cap, const ConsentChoices(cloud: ConsentState.accepted));
        expect(settings.consentVersion, 1);
        f.storage.data['qirsh_capture_consent_ack'] = 'uid-x|1|0|1';
        f.storage.data['qirsh_capture_consent_verified_ack'] = 'uid-x|1|0|1';
        var scopeCurrent = true;
        var retireOnRead = false;
        var reads = 0;
        final service = CaptureDeviceRegistrationService(
          settingsRepository: repository,
          isIos: () => true,
          isBackendConfigured: () => true,
          isCurrentScope: () => scopeCurrent,
          readSession: () => (uid: 'uid-x', jwt: 'synthetic'),
          readAccountConsent: (authority) async {
            expect(authority.uid, 'uid-x');
            reads++;
            if (retireOnRead) scopeCurrent = false;
            return remote;
          },
        );
        try {
          expect(await service.deviceConsentMatches(settings), isTrue);
          expect(await service.serverConsentMatches(settings),
              remote == (cloud: true, ai: false, version: 1));
          expect(reads, 1);
          retireOnRead = true;
          expect(await service.serverConsentMatches(settings), isFalse,
              reason: 'a late account response cannot confirm a retired scope');
          expect(reads, 2);
          expect(await service.serverConsentMatches(settings), isFalse);
          expect(reads, 2,
              reason: 'a retired scope must not read account data');
        } finally {
          service.dispose();
        }
      } finally {
        await f.dispose();
        ConsentAuthority.egressFrozen = false;
      }
    });
  }
}
