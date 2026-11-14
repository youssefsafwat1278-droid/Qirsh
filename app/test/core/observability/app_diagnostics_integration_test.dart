import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/observability/app_diagnostics.dart';
import 'package:money_companion/core/observability/flutter_diagnostics.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/sync/sync_diagnostics_report.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

import '../../harness/egress_test_support.dart';

class _KeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test';
  @override
  Future<String?> readStoredKey() async => 'test';
}

void main() {
  setUp(AppDiagnostics.resetForTest);
  tearDown(AppDiagnostics.resetForTest);

  test(
      'actual SQL reads, writes and rollback are observed without SQL or values',
      () async {
    final db = AppDatabase.createForTesting(
        executor: NativeDatabase.memory(), keyStore: _KeyStore());
    addTearDown(db.close);
    await db.customStatement(
        'CREATE TABLE transactions(id TEXT PRIMARY KEY, secret TEXT)');
    await db.customStatement(
        "INSERT INTO transactions VALUES ('private-id', 'private SMS 123.45')");
    expect(
        (await db.customSelect('SELECT * FROM transactions').get()).length, 1);
    await expectLater(db.transaction(() async {
      await db.customStatement(
          "INSERT INTO transactions VALUES ('rollback-id', 'secret')");
      throw StateError('private failure');
    }), throwsStateError);
    expect(
        (await db.customSelect('SELECT * FROM transactions').get()).length, 1);
    expect(AppDiagnostics.counts[AppOperation.transactionWrite], 2);
    expect(AppDiagnostics.counts[AppOperation.databaseRead], greaterThan(0));
    expect(AppDiagnostics.counts[AppOperation.databaseRollback], 1);
    final report = const SyncDiagnosticsReport([]).toRedactedText();
    for (final secret in [
      'private-id',
      'rollback-id',
      'private SMS',
      '123.45',
      'INSERT INTO'
    ]) {
      expect(report, isNot(contains(secret)));
    }
    expect(report, contains('transactionWrite'));
  });

  test(
      'network denial is distinct from dispatch and retains no URL or credential',
      () async {
    TestEgress().install();
    var sent = 0;
    final client = GatedHttpClient(MockClient((_) async {
      sent++;
      return http.Response('{}', 200);
    }));
    addTearDown(client.close);
    await expectLater(
        client.post(
            Uri.parse(
                'https://example.supabase.co/rest/v1/user_settings?email=secret@example.com'),
            headers: {'Authorization': 'Bearer PRIVATE-TOKEN'},
            body: 'PRIVATE SMS'),
        throwsA(isA<EgressDeniedException>()));
    expect(sent, 0);
    expect(AppDiagnostics.events.last.state, AppEventState.blocked);
    expect(AppDiagnostics.events.any((e) => e.state == AppEventState.sent),
        isFalse);
    final report = AppDiagnostics.exportText();
    for (final secret in [
      'PRIVATE-TOKEN',
      'PRIVATE SMS',
      'secret@example.com',
      'https://'
    ]) {
      expect(report, isNot(contains(secret)));
    }
  });

  test(
      'actual network dispatch records response status without response payloads',
      () async {
    TestEgress(seedOn: true).install();
    final client = GatedHttpClient(
        MockClient((_) async => http.Response('PRIVATE RESPONSE', 503)));
    addTearDown(client.close);
    final response = await client
        .get(Uri.parse('https://example.supabase.co/rest/v1/user_settings'));
    expect(response.statusCode, 503);
    expect(response.body, 'PRIVATE RESPONSE');
    expect(AppDiagnostics.events.any((e) => e.state == AppEventState.sent),
        isTrue);
    expect(
        AppDiagnostics.events
            .where((e) => e.state == AppEventState.response)
            .single
            .statusCode,
        503);
    expect(AppDiagnostics.events.last.state, AppEventState.completed);
    expect(AppDiagnostics.exportText(), isNot(contains('PRIVATE RESPONSE')));
  });

  test('a response-body failure is recorded after successful response headers',
      () async {
    TestEgress(seedOn: true).install();
    final failure = TimeoutException('PRIVATE BODY CONTENT');
    final client = GatedHttpClient(MockClient.streaming((request, body) async =>
        http.StreamedResponse(Stream<List<int>>.error(failure), 200)));
    addTearDown(client.close);
    final response = await client.send(http.Request(
        'GET', Uri.parse('https://example.supabase.co/rest/v1/user_settings')));
    await expectLater(response.stream.toBytes(), throwsA(same(failure)));
    expect(AppDiagnostics.events.last.state, AppEventState.failed);
    expect(AppDiagnostics.events.last.reason, AppEventReason.timeout);
    expect(
        AppDiagnostics.exportText(), isNot(contains('PRIVATE BODY CONTENT')));
  });

  test(
      'provider failure and navigation do not expose family values or route IDs',
      () {
    final provider =
        Provider.family<String, String>((ref, arg) => throw StateError(arg));
    final container =
        ProviderContainer(observers: [const DiagnosticProviderObserver()]);
    addTearDown(container.dispose);
    expect(() => container.read(provider('PRIVATE ACCOUNT')), throwsStateError);
    final route = MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/account/PRIVATE ACCOUNT'),
        builder: (_) => const SizedBox());
    DiagnosticNavigationObserver().didPush(route, null);
    expect(
        AppDiagnostics.events.any((e) => e.operation == AppOperation.provider),
        isTrue);
    expect(
        AppDiagnostics.events
            .any((e) => e.operation == AppOperation.navigation),
        isTrue);
    expect(AppDiagnostics.exportText(), isNot(contains('PRIVATE ACCOUNT')));
  });
}
