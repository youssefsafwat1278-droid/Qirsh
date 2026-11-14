import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/install_presentation_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  late InstallPresentationStore presentation;
  late SupabaseClient sdk;
  late Future<http.Response> Function(http.Request) respond;
  late List<http.Request> profileRequests;
  late List<http.Request> cloudRequests;
  late List<Map<String, Object?>> cloudRows;
  late TestEgress egress;

  setUp(() async {
    egress = TestEgress()..owner = 'returning-owner';
    egress.install();
    f = await F2Fixture.create();
    profileRequests = [];
    cloudRequests = [];
    cloudRows = [];
    respond = (request) async => http.Response(
          jsonEncode([
            {'onboarding_completed_at': '2026-10-01T00:00:00Z'}
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
    sdk = SupabaseClient(
      'https://example.supabase.co',
      'synthetic-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: GatedHttpClient(MockClient((request) async {
        if (request.url.path.endsWith('/profiles')) {
          profileRequests.add(request);
          final reply = await respond(request);
          return http.Response(reply.body, reply.statusCode,
              headers: reply.headers, request: request);
        }
        if (request.url.path.endsWith('/user_settings')) {
          cloudRequests.add(request);
          return http.Response(jsonEncode(cloudRows), 200,
              headers: {'content-type': 'application/json'}, request: request);
        }
        return http.Response('{}', 200);
      })),
    );
    await F2Fixture.recoverSession_(sdk, 'returning-owner');
    presentation = InstallPresentationStore(
      File('${f.support.path}/install-presentation.json'),
    );
    await presentation.prepare(
        hasExistingData: () async => false,
        resetPresentation: f.session.resetInstallPresentation);
    f.session.configureInstallPresentation(presentation);
    await f.session.markOnboardingLanguageChosen();
    await f.session.markWelcomeManifestoSeen();
    await f.session.setIdentity(
      method: 'apple',
      userId: 'returning-owner',
      email: 'returning-owner@example.com',
      sessionCurrent: () => sdk.auth.currentSession?.isExpired == false,
    );
  });

  tearDown(() async {
    f.session.configureInstallPresentation(null);
    await sdk.dispose();
    await f.dispose();
  });

  Future<bool> verify() =>
      f.session.reconcileAccountOnboarding(sdk, requireRemoteResult: true);

  test('verified returning account skips setup after reinstall and reopening',
      () async {
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
    expect(await f.session.reconcileAccountOnboarding(sdk), isFalse,
        reason: 'automatic reconciliation does not bypass first-run UI');
    expect(profileRequests, isEmpty);

    expect(await verify(), isTrue);
    expect(profileRequests, hasLength(1));
    expect(
        profileRequests.single.url.queryParameters['id'], 'eq.returning-owner');
    expect(profileRequests.single.url.queryParameters['select'],
        'onboarding_completed_at');
    expect(presentation.requiresSetup, isFalse);
    expect(presentation.languageChosen, isTrue);
    expect(await egress.gate.permits(), isFalse,
        reason: 'the account lookup never enables Cloud');
    expect(f.session.hasSeenWelcomeManifesto, isTrue);
    await f.session.load();
    expect(f.session.status, SessionStatus.authenticated);
    expect(await verify(), isTrue);
    expect(profileRequests, hasLength(1),
        reason: 'verified completion is cached for ordinary reopening');
  });

  test('same UID reuses completion after reinstall while Cloud remains Off',
      () async {
    f.storage.data['onboarding_completed_accounts_v1'] =
        '["uid:returning-owner"]';
    await f.session.load();
    expect(f.session.hasCompletedOnboarding, isFalse);

    expect(await verify(), isTrue);
    expect(profileRequests, isEmpty);
    expect(presentation.requiresSetup, isFalse);
    expect(await egress.gate.permits(), isFalse);
  });

  test('fresh installation must ask again when only the old prompt marker survives',
      () async {
    f.storage.data['qirsh.consent_asked.v1.returning-owner'] = '1';
    await f.session.resetInstallPresentation();
    expect(await verify(), isTrue);
    expect(await egress.gate.permits(), isFalse);
    expect(await f.session.consentPromptSeen(), isFalse,
        reason: 'the previous installation answered, the new one has not');
  });

  test('Cloud preference can be read while off for this account only', () async {
    expect(await verify(), isTrue);
    final authority = AdmissionAuthority('returning-owner', () => true);
    cloudRows = [{'cloud_processing_enabled': true, 'consent_version': 7}];
    expect(await f.session.readAccountCloudPreference(sdk, authority), isTrue);
    expect(cloudRequests.single.url.queryParameters['user_id'],
        'eq.returning-owner');
    expect(await egress.gate.permits(), isFalse);

    cloudRows = [{'cloud_processing_enabled': false, 'consent_version': 8}];
    expect(await f.session.readAccountCloudPreference(sdk, authority), isFalse);
    cloudRows = [{'cloud_processing_enabled': true, 'consent_version': 0}];
    expect(await f.session.readAccountCloudPreference(sdk, authority), isNull);
    expect(await f.session.readAccountCloudPreference(
        sdk, AdmissionAuthority('different-owner', () => true)), isNull);
    expect(cloudRequests, hasLength(3));
  });

  test('another UID completion cannot skip the current account setup',
      () async {
    f.storage.data['onboarding_completed_accounts_v1'] = '["uid:other-owner"]';
    await f.session.load();
    respond = (_) async => http.Response(
          '[{"onboarding_completed_at":null}]',
          200,
          headers: {'content-type': 'application/json'},
        );

    expect(await verify(), isFalse);
    expect(profileRequests, hasLength(1));
    expect(presentation.requiresSetup, isTrue);
  });

  test('a late incomplete lookup preserves concurrent verified completion',
      () async {
    final arrived = Completer<void>();
    final firstReply = Completer<http.Response>();
    var calls = 0;
    respond = (_) async {
      if (++calls == 1) {
        arrived.complete();
        return firstReply.future;
      }
      return http.Response(
        '[{"onboarding_completed_at":"2026-10-01T00:00:00Z"}]',
        200,
        headers: {'content-type': 'application/json'},
      );
    };
    final older = verify();
    await arrived.future;
    expect(await verify(), isTrue);
    firstReply.complete(http.Response(
      '[{"onboarding_completed_at":null}]',
      200,
      headers: {'content-type': 'application/json'},
    ));

    expect(await older, isTrue);
    expect(presentation.requiresSetup, isFalse);
    expect(f.session.hasCompletedOnboarding, isTrue);
  });

  test('confirmed incomplete account still receives setup', () async {
    respond = (_) async => http.Response(
          '[{"onboarding_completed_at":null}]',
          200,
          headers: {'content-type': 'application/json'},
        );

    expect(await verify(), isFalse);
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
  });

  test('unavailable lookup retries without converting failure to incomplete',
      () async {
    respond =
        (_) async => http.Response('{"message":"private-server-detail"}', 503);

    await expectLater(verify(), throwsA(isA<OnboardingStatusUnavailable>()));
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
    expect(sdk.auth.currentSession!.user.id, 'returning-owner');

    respond = (_) async => http.Response(
          '[{"onboarding_completed_at":"2026-10-01T00:00:00Z"}]',
          200,
          headers: {'content-type': 'application/json'},
        );
    expect(await verify(), isTrue);
  });

  test('sign-out during lookup cannot complete the old installation state',
      () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    respond = (_) async {
      arrived.complete();
      await release.future;
      return http.Response(
        '[{"onboarding_completed_at":"2026-10-01T00:00:00Z"}]',
        200,
        headers: {'content-type': 'application/json'},
      );
    };
    final result =
        expectLater(verify(), throwsA(isA<StaleAdmissionException>()));
    await arrived.future;
    await f.session.signOut();
    release.complete();
    await result;
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
  });

  test('a server that never answers has a bounded verification wait', () async {
    final stalled = Completer<http.Response>();
    respond = (_) => stalled.future;
    try {
      await expectLater(verify(), throwsA(isA<OnboardingStatusUnavailable>()));
      expect(presentation.requiresSetup, isTrue);
    } finally {
      stalled.complete(http.Response('[]', 200,
          headers: {'content-type': 'application/json'}));
    }
  });
}
