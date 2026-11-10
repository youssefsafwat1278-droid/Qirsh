import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/capture_identity_metrics.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// R9 — the iOS Shortcut recipe must always pass Date Received. When it does
/// not, the native layer stamps `receivedAtInferred: true` on the queue payload;
/// Dart parses it and counts it (counts only — no SMS content).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => NativeCaptureBridge.debugTreatHostAsNative = true);
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('bridge parsing', () {
    Future<List<SharedCapturedMessage>> peek(List<Map<String, Object?>> items) {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => jsonEncode(items),
      );
      return NativeCaptureBridge.peekPendingSharedMessages();
    }

    test('receivedAtInferred is parsed as true / false / absent', () async {
      final messages = await peek([
        {'id': 'a', 'text': 'x 1', 'receivedAtInferred': true},
        {'id': 'b', 'text': 'x 2', 'receivedAtInferred': false},
        // A payload written by a build before R9 has no such key.
        {'id': 'c', 'text': 'x 3'},
      ]);
      expect(messages.map((m) => m.receivedAtInferred), [true, false, null]);
    });

    test('a non-bool value is treated as unknown, not as inferred', () async {
      final messages = await peek([
        {'id': 'a', 'text': 'x 1', 'receivedAtInferred': 'true'},
      ]);
      expect(messages.single.receivedAtInferred, isNull);
    });

    test('a native queue failure surfaces as an empty, retryable peek',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'queue_unavailable');
      });
      expect(await NativeCaptureBridge.peekPendingSharedMessages(), isEmpty);
    });
  });

  test('onboarding keeps automatic time capture without a manual date demand', () {
    for (final locale in const ['en', 'ar']) {
      final arb = jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;
      for (final key in const ['setupShortcutStep5Body', 'iosStep6Body']) {
        expect(arb[key], isNot(contains('Date Received')),
            reason: '$locale/$key must not demand manual date setup');
      }
    }
  });

  group('CaptureIdentityMetrics', () {
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
    });
    tearDown(() => db.close());

    test('counts inferred against all marker-bearing captures', () async {
      await CaptureIdentityMetrics.record(db, true);
      await CaptureIdentityMetrics.record(db, false);
      await CaptureIdentityMetrics.record(db, true);
      final c = await CaptureIdentityMetrics.read(db);
      expect(c.total, 3);
      expect(c.receivedAtInferred, 2);
    });

    test('an unknown marker (null) is not counted', () async {
      await CaptureIdentityMetrics.record(db, null);
      final c = await CaptureIdentityMetrics.read(db);
      expect(c.total, 0);
      expect(c.receivedAtInferred, 0);
    });

    test('stores counts only — no SMS content, sender or payload id', () async {
      await CaptureIdentityMetrics.record(db, true);
      final rows = await db
          .customSelect(
            'SELECT entity, last_updated_at, last_id FROM sync_cursors '
            "WHERE entity = '${CaptureIdentityMetrics.entity}';",
          )
          .get();
      expect(rows, hasLength(1));
      final stored = jsonDecode(rows.single.read<String>('last_id')) as Map;
      expect(stored.keys.toSet(), {'total', 'received_at_inferred'});
      expect(stored.values.every((v) => v is int), isTrue);
    });
  });
}
