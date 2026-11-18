// Phase-7 Batch-2-B closure §Blocker-1/2 — the production backup path streams the
// snapshot to canonical v3 plaintext bytes WITHOUT building the full object graph or
// a whole JSON String. This proves the streamed bytes are BYTE-IDENTICAL to
// utf8.encode(jsonEncode(build())) (same schema/wire), and that the plaintext cap
// aborts DURING accumulation (before a large buffer is built) with a typed error.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BackupSnapshotBuilder builder;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    builder = BackupSnapshotBuilder(db);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'حسابي ☕', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await db.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order) "
      "VALUES ('c0', 'k0', 'طعام', 'x', '#111', 0, 0);",
    );
    final base = DateTime.utc(2026, 3, 1);
    await db.transaction(() async {
      // > one page so the streaming path actually iterates multiple reads.
      for (var i = 0; i < 4500; i++) {
        final occ = dateTimeToSql(base.add(Duration(minutes: i)));
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, category_id, "
          "type, source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at, note) VALUES "
          "('txn-${i.toString().padLeft(5, '0')}', ${10 + i}, 'SAR', 'a0', 'c0', "
          "'payment', 'bank', '$occ', 'r$i', 0.9, 'confirmed', '$occ', '$occ', "
          "'ملاحظة \"$i\"');", // embedded quotes/Arabic → exercises JSON escaping
        );
      }
    });
    await backfillNonPlanningMoneyV30(db);
  });
  tearDown(() => db.close());

  test('streamed plaintext == utf8(jsonEncode(build())) — byte-identical wire',
      () async {
    final now = DateTime.utc(2026, 6, 1, 12, 30, 15);
    final streamed = await builder.buildEncryptedPlaintext(
      maxBytes: 64 * 1024 * 1024,
      createdAt: now,
    );
    final viaObject = utf8.encode(jsonEncode(await builder.build(createdAt: now)));
    expect(streamed.length, viaObject.length);
    expect(streamed, viaObject,
        reason: 'the streaming serializer must be wire-identical to jsonEncode');
    // And it is valid JSON decoding back to the same structure.
    final decoded = jsonDecode(utf8.decode(streamed)) as Map<String, dynamic>;
    expect(decoded['schemaVersion'], 5);
    expect((decoded['tables'] as Map)['transactions'], hasLength(4500));
  });

  test('the plaintext cap aborts DURING streaming with payloadTooLarge', () async {
    BackupEnvelopeException? thrown;
    try {
      // Far smaller than the 4500-row snapshot → must trip mid-stream.
      await builder.buildEncryptedPlaintext(maxBytes: 4096);
    } on BackupEnvelopeException catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    expect(thrown!.kind, BackupEnvelopeErrorKind.payloadTooLarge);
  });
}
