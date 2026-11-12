import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_conflict_store.dart';
import 'package:money_companion/core/sync/sync_diagnostics_report.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/features/settings/sync_diagnostics_screen.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

// WP-8 / CAP-8: each diagnostic reflects the real state its source package
// produced, and nothing sensitive can reach any diagnostic surface.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _uid = '9f1c2b7e-4d3a-4e55-8a0b-5c6d7e8f9a01';
const _otherUid = '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';
final _now = DateTime.utc(2026, 10, 6, 12);

UserSettingsEntity _settings({
  ConsentState cloud = ConsentState.accepted,
  ConsentState ai = ConsentState.declined,
  int cloudVersion = 3,
  int aiVersion = 2,
}) =>
    UserSettingsEntity(
      id: 'settings',
      displayName: 'Synthetic Person',
      phoneNumber: '+966500000000',
      country: 'SA',
      currency: 'SAR',
      language: 'en',
      theme: 'light',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud,
      aiConsentState: ai,
      cloudConsentVersion: cloudVersion,
      cloudConsentAt: DateTime.utc(2026, 9, 1),
      aiConsentVersion: aiVersion,
    );

class _Fixture {
  _Fixture(this.db, this.health);
  final AppDatabase db;
  final SyncHealth health;
  String? authUid = _uid;
  String? ownerUid = _uid;
  UserSettingsEntity settings = _settings();
  Map<String, ServerCapabilityState> caps = {};
  ReplicaEntry? entry;
  CaptureOwnerRecord? owner =
      const CaptureOwnerRecord(uid: _uid, uidHash: 'h', generation: 4);
  List<SharedCapturedMessage> peek = const [];
  CaptureQueueStats? stats;
  int unbound = 0;
  CaptureRemovalBarrier? barrier;
  ({bool cloud, bool ai, int version})? ack;
  int? mirror;
  CaptureRegistrationStatus? registration;
  CaptureImportReport? lastImport;
  bool v3 = true;

  Future<SyncDiagnosticsReport> collect() => collectSyncDiagnostics(
        SyncDiagnosticsSources(
          db: db,
          health: health,
          settings: settings,
          authUid: authUid,
          ownerUid: ownerUid,
          cachedCapability: (k) => caps[k] ?? ServerCapabilityState.unknown,
          otherCapabilities: const {'awaiting FX': 'unknown'},
          replicaEntry: () async => entry,
          captureOwner: () async => owner,
          peekQueue: () async => peek,
          queueStats: () async => stats,
          unboundHinted: (_) async => unbound,
          removalBarrier: () async => barrier,
          consentAck: () async => ack,
          mirroredConsentVersion: mirror,
          registration: registration,
          lastImport: lastImport,
          captureV3Enabled: v3,
          now: () => _now,
        ),
      );
}

String _row(SyncDiagnosticsReport r, String section, String label) {
  final s = r.sections.firstWhere((s) => s.title == section);
  return s.rows[label] ?? '<missing $label>';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SyncHealth health;
  late _Fixture f;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    health = SyncHealth(clock: () => _now);
    f = _Fixture(db, health);
  });
  tearDown(() async => db.close());

  group('each diagnostic reflects its source package', () {
    test('WP-4: pull stop, head, cursors vs head, quarantine count', () async {
      await writeSeqCursor(db, _uid, 'transactions', 10);
      await writeSeqCursor(db, _uid, 'accounts', 7);
      health.recordPullPlan(stop: SyncPullStop.epochMismatch, headSeq: 10);
      await db.customStatement(
          'INSERT INTO parked_child_rows(table_name, server_id, row_json, '
          "reason, attempt_count, first_seen_at, updated_at) VALUES "
          "('transactions', 'x', '{}', 'integrity', 0, '2026-10-01T00:00:00Z', "
          "'2026-10-01T00:00:00Z');");
      final r = await f.collect();
      expect(_row(r, 'Pull', 'last pull stop'), 'epochMismatch');
      expect(_row(r, 'Pull', 'server head seq (last read)'), '10');
      expect(_row(r, 'Pull', 'seq cursors'), '2');
      expect(_row(r, 'Pull', 'seq cursor min'), '7');
      expect(_row(r, 'Pull', 'seq cursor max'), '10');
      expect(_row(r, 'Pull', 'cursors behind head'), '1');
      expect(_row(r, 'Pull', 'quarantined (integrity)'), '1');
      expect(_row(r, 'Pull', 'parked rows: integrity'), '1');
    });

    test('WP-4: capabilityUnknown stop is its own code', () async {
      health.recordPullPlan(stop: SyncPullStop.capabilityUnknown);
      expect(_row(await f.collect(), 'Pull', 'last pull stop'),
          'capabilityUnknown');
    });

    test('WP-5: open conflicts by kind; resolved ones are not counted',
        () async {
      await db.customStatement(
          "INSERT INTO accounts(id, name, type, currency, created_at, updated_at) "
          "VALUES ('a1', 'n', 'checking', 'SAR', '2026-10-01T00:00:00Z', "
          "'2026-10-01T00:00:00Z');");
      final store = SyncConflictStore(db);
      await store.flag(
          entityType: 'account',
          localId: 'a1',
          kind: SyncConflictKind.tombstone,
          mine: {'name': 'n'});
      final r = await f.collect();
      expect(_row(r, 'Queue', 'open conflicts: tombstone'), '1');
      expect(_row(r, 'Queue', 'open conflicts: update'), '0');
      expect(_row(r, 'Queue', 'conflicts (flagged rows)'), '1');
    });

    test('WP-5: revision_cas gate state is the cached capability', () async {
      f.caps[kCapRevisionCas] = ServerCapabilityState.verified;
      final r = await f.collect();
      expect(_row(r, 'Capabilities', 'revision_cas'), 'verified');
      expect(_row(r, 'Capabilities', 'sync_seq'), 'unknown');
    });

    test('WP-7: rebootstrap phase marker and the 14-day retained replica',
        () async {
      final entry = ReplicaEntry(
        uidHash: 'hash',
        createdAt: DateTime.utc(2026, 9, 1),
        lastOpenedAt: DateTime.utc(2026, 10, 5),
        schemaVersion: 41,
        epoch: 2,
        state: ReplicaState.active,
        rebootstrap: RebootstrapMarker(
          phase: RebootstrapPhase.receiptsRecovered,
          reason: 'reset',
          startedAt: DateTime.utc(2026, 10, 6, 11),
        ),
        retiredAt: DateTime.utc(2026, 10, 1, 12),
      );
      f.entry = entry;
      final r = await f.collect();
      expect(_row(r, 'Identity and replica', 'rebootstrap in progress'), 'yes');
      expect(_row(r, 'Identity and replica', 'rebootstrap phase'),
          'receipts_recovered');
      expect(_row(r, 'Identity and replica', 'rebootstrap reason'), 'reset');
      expect(_row(r, 'Identity and replica', 'retired replica retained'), 'yes');
      // retired 5 days ago -> 9 of 14 days left.
      expect(_row(r, 'Identity and replica', 'retired replica days left'), '9');
      expect(_row(r, 'Identity and replica', 'replica schema version'), '41');
    });

    test('WP-7: the real registry marker is what the report shows', () async {
      final support = Directory.systemTemp.createTempSync('diag_replica_');
      FlutterSecureStorage.setMockInitialValues({});
      final store = ReplicaStore(requireCreationAuthority: false, 
        appSupportDirectory: support.path,
        now: () => _now,
        readOwnerMarker: () async => _uid,
      );
      addTearDown(() async {
        await store.closeAll();
        support.deleteSync(recursive: true);
      });
      await store.openReplica(_uid);
      await store.beginRebootstrap(_uid, 'purge');
      await store.advanceRebootstrap(_uid, RebootstrapPhase.extracted);
      final hash = await store.uidHash(_uid);
      f.entry = (await store.list()).firstWhere((e) => e.uidHash == hash);
      final r = await f.collect();
      expect(_row(r, 'Identity and replica', 'rebootstrap phase'), 'extracted');
      expect(_row(r, 'Identity and replica', 'rebootstrap reason'), 'purge');
    });

    test('WP-7: no marker, no retained replica', () async {
      f.entry = ReplicaEntry(
        uidHash: 'hash',
        createdAt: _now,
        lastOpenedAt: _now,
        schemaVersion: 41,
        epoch: 1,
        state: ReplicaState.active,
      );
      final r = await f.collect();
      expect(_row(r, 'Identity and replica', 'rebootstrap in progress'), 'no');
      expect(_row(r, 'Identity and replica', 'retired replica retained'), 'no');
    });

    test('WP-4/7: recorded epoch reason is a code, the epoch itself is absent',
        () async {
      await writeRecordedSyncEpoch(db, _uid, 'epoch-opaque-123', 'reset');
      final r = await f.collect();
      expect(_row(r, 'Identity and replica', 'server epoch recorded'), 'yes');
      expect(_row(r, 'Identity and replica', 'recorded epoch reason'), 'reset');
      expect(r.toRedactedText(), isNot(contains('epoch-opaque-123')));
    });

    test('CAP-5: queue states, unbound hint, quota ceiling', () async {
      f.unbound = 2;
      f.peek = [
        const SharedCapturedMessage(
            text: 't', source: CapturedMessageSource.iosShortcut, ownerUid: _uid),
        const SharedCapturedMessage(
            text: 't',
            source: CapturedMessageSource.iosShortcut,
            ownerUid: _uid,
            localOnly: true),
        const SharedCapturedMessage(
            text: 't',
            source: CapturedMessageSource.iosShortcut,
            ownerUid: _uid,
            status: 'pendingSend',
            failureReason: 'network'),
        const SharedCapturedMessage(
            text: 't',
            source: CapturedMessageSource.iosShortcut,
            ownerUid: _otherUid),
      ];
      final r = await f.collect();
      expect(_row(r, 'Capture', 'queue items (this owner)'), '3');
      expect(_row(r, 'Capture', 'queue items bound local-only'), '1');
      expect(_row(r, 'Capture', 'queue items awaiting upload'), '1');
      expect(_row(r, 'Capture', 'queue items with failure marker'), '1');
      expect(_row(r, 'Capture', 'queue items of other owners/unbound (peek)'),
          '1');
      expect(_row(r, 'Capture', 'unbound items hinted to this user'), '2');
      // The count-only quota rows were replaced by the native stats rows.
      // 2026-11-12: no per-owner/unbound quota rows; segment sizes instead.
      expect(_row(r, 'Capture', 'queue segment size items'), '500');
      expect(_row(r, 'Capture', 'queue segment size bytes'), '2097152');
      expect(_row(r, 'Capture', 'queue stats available'), 'no');
      expect(_row(r, 'Capture', 'queue quota (this owner)'), '—');
    });

    test('D3: native captureQueueStats rows (counts, bytes, quota state)',
        () async {
      f.stats = const CaptureQueueStats(
        stamped: 4,
        localOnly: 3,
        waiting: 2,
        unbound: 1,
        activeOwnerBytes: 700,
        unboundBytes: 90,
        deviceBytes: 1200,
        ownerQuota: CaptureQuotaState.near,
        unboundQuota: CaptureQuotaState.ok,
        deviceQuota: CaptureQuotaState.full,
        quarantinedSegments: 2,
      );
      final r = await f.collect();
      expect(_row(r, 'Capture', 'queue stats available'), 'yes');
      expect(_row(r, 'Capture', 'queue stats: quarantined segments'), '2');
      expect(_row(r, 'Capture', 'queue stats: stamped, may upload'), '4');
      expect(_row(r, 'Capture', 'queue stats: local-only'), '3');
      expect(_row(r, 'Capture', 'queue stats: waiting (other owners)'), '2');
      expect(_row(r, 'Capture', 'queue stats: unbound'), '1');
      expect(_row(r, 'Capture', 'queue bytes (this owner)'), '700');
      expect(_row(r, 'Capture', 'queue bytes (unbound)'), '90');
      expect(_row(r, 'Capture', 'queue bytes (device)'), '1200');
      expect(_row(r, 'Capture', 'queue quota (this owner)'), 'near');
      expect(_row(r, 'Capture', 'queue quota (unbound)'), 'ok');
      expect(_row(r, 'Capture', 'queue quota (device)'), 'full');
      expect(_row(r, 'Capture', 'queue limit bytes (single capture)'),
          '2097152');
    });

    test('CAP-6a: the removal barrier', () async {
      expect(_row(await f.collect(), 'Capture', 'removal barrier active'), 'no');
      f.barrier = const CaptureRemovalBarrier(
          nonce: 'n', uidHash: 'h', startedAt: '2026-10-06T11:00:00.000Z');
      final r = await f.collect();
      expect(_row(r, 'Capture', 'removal barrier active'), 'yes');
      expect(_row(r, 'Capture', 'removal barrier started'),
          '2026-10-06T11:00:00.000Z');
    });

    test('CAP-6a: the segment constants equal the native shipping values', () {
      final swift =
          File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
      expect(
          RegExp(r'static let segmentMaxItems = (\d+)').firstMatch(swift)![1],
          '$kCaptureSegmentMaxItems');
      expect(swift, contains('static let maxItemBytes = segmentMaxBytes'));
      expect(kCaptureMaxItemBytes, kCaptureSegmentMaxBytes);
      // The old refusing quotas are gone on both sides (2026-11-12).
      for (final gone in const [
        'ownerMaxItems',
        'unboundMaxItems',
        'ownerMaxBytes',
        'unboundMaxBytes',
        'deviceMaxBytes',
      ]) {
        expect(swift, isNot(contains('static let $gone')));
      }
      for (final entry in {
        'segmentMaxBytes': kCaptureSegmentMaxBytes,
      }.entries) {
        final m = RegExp('static let ${entry.key} = (.+)').firstMatch(swift)!;
        // `2 * 1024 * 1024` style: evaluate the product.
        final value = m[1]!
            .split('*')
            .map((p) => int.parse(p.trim()))
            .reduce((a, b) => a * b);
        expect(value, entry.value, reason: entry.key);
      }
    });

    test('CAP-5: latest import outcome and receipts', () async {
      await db.customStatement(
          'INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
          "VALUES ('capture_payload:${'a' * 64}', 'tx', '1970-01-01T00:00:00Z', "
          "'2026-10-01T00:00:00Z');");
      f.lastImport = const CaptureImportReport(
        imported: [
          CaptureImportItem(id: 'x', path: CaptureImportPath.server),
          CaptureImportItem(id: 'y', path: CaptureImportPath.local),
          CaptureImportItem(id: 'z', path: CaptureImportPath.local),
        ],
        skippedAwaiting: 2,
        skippedForeignOwner: 1,
        barrierHeld: true,
      );
      final r = await f.collect();
      expect(_row(r, 'Capture import (latest run)', 'imported (total)'), '3');
      expect(_row(r, 'Capture import (latest run)', 'imported: server'), '1');
      expect(_row(r, 'Capture import (latest run)', 'imported: local'), '2');
      expect(_row(r, 'Capture import (latest run)', 'left for retry'), '2');
      expect(_row(r, 'Capture import (latest run)', 'skipped other owner'), '1');
      expect(
          _row(r, 'Capture import (latest run)', 'rebootstrap barrier held'),
          'yes');
      expect(_row(r, 'Capture', 'receipts in replica'), '1');
    });

    test('CAP-5: no run recorded when the import flag never ran', () async {
      f.lastImport = null;
      f.v3 = false;
      final r = await f.collect();
      expect(_row(r, 'Capture import (latest run)', 'run recorded'), 'no');
      expect(_row(r, 'Capture', 'capture import v3 enabled'), 'no');
    });

    test('CAP-7: alert state words are counted', () async {
      Future<void> mark(String id, String state) => db.customStatement(
          'INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
          "VALUES ('capture_notified:$id', '$state', '2026-10-01T00:00:00Z', "
          "'2026-10-01T00:00:00Z');");
      await mark('1', CaptureAlertStateWords.app);
      await mark('2', CaptureAlertStateWords.app);
      await mark('3', CaptureAlertStateWords.summary);
      final r = await f.collect();
      expect(_row(r, 'Capture alerts', 'alert state: app'), '2');
      expect(_row(r, 'Capture alerts', 'alert state: summary'), '1');
      expect(_row(r, 'Capture alerts', 'alerts recorded'), '3');
    });

    test('WP-6: consent projection, server ack and mirror', () async {
      f.ack = (cloud: true, ai: false, version: 3);
      f.mirror = 3;
      f.registration = const CaptureRegistrationStatus(
          CaptureRegistrationPhase.failed, 'consent_sync_failed');
      final r = await f.collect();
      expect(_row(r, 'Consent', 'cloud consent state'), 'accepted');
      expect(_row(r, 'Consent', 'cloud consent'), 'yes');
      expect(_row(r, 'Consent', 'cloud consent version'), '3');
      expect(_row(r, 'Consent', 'AI consent state'), 'declined');
      expect(_row(r, 'Consent', 'AI consent version'), '2');
      expect(_row(r, 'Consent', 'server ack present'), 'yes');
      expect(_row(r, 'Consent', 'server ack version'), '3');
      expect(_row(r, 'Consent', 'native mirror version (this run)'), '3');
      expect(_row(r, 'Consent', 'device registration'), 'failed');
      expect(_row(r, 'Consent', 'device registration failure'),
          'consent_sync_failed');
    });

    test('queue: parked and dead-letter reasons from the outbox', () async {
      Future<void> row(String id, String status, String cls) => db.customStatement(
          'INSERT INTO ledger_sync_outbox(id, transaction_id, operation, '
          'payload_json, attempt_count, created_at, updated_at, status, '
          "failure_class, op_seq) VALUES ('$id', 'tx-$id', 'update', '{}', 0, "
          "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', '$status', '$cls', 1);");
      await row('1', 'parked', kParkAuthRequired);
      await row('2', 'dead_letter', 'permissionDenied');
      final r = await f.collect();
      expect(_row(r, 'Queue', 'parked'), '1');
      expect(_row(r, 'Queue', 'dead letter'), '1');
      expect(_row(r, 'Parked by reason', kParkAuthRequired), '1');
      expect(_row(r, 'Dead letter by reason', 'permissionDenied'), '1');
    });
  });

  group('flags/capabilities-false view still makes sense', () {
    test('every capability reads unknown/unsupported; sections still render',
        () async {
      f.v3 = false;
      f.owner = null;
      f.caps = {
        for (final k in [kCapSyncSeq, kCapRevisionCas, kCapReplicaEpoch])
          k: ServerCapabilityState.unsupported,
      };
      final r = await f.collect();
      expect(_row(r, 'Capabilities', 'sync_seq'), 'unsupported');
      expect(_row(r, 'Capabilities', 'replica_epoch'), 'unsupported');
      expect(_row(r, 'Capabilities', 'capture_contract_v2'), 'unknown');
      expect(_row(r, 'Pull', 'last pull stop'), '—');
      expect(_row(r, 'Pull', 'seq cursors'), '0');
      expect(_row(r, 'Capture', 'native owner published'), 'no');
      expect(_row(r, 'Capture', 'queue items (this owner)'), '0');
      expect(_row(r, 'Capture import (latest run)', 'run recorded'), 'no');
      expect(r.toRedactedText(), contains('[Capabilities]'));
    });

    test('signed out: nothing is probed or read for a uid', () async {
      f.authUid = null;
      f.ownerUid = null;
      f.owner = null;
      final r = await f.collect();
      expect(_row(r, 'Identity and replica', 'session present'), 'no');
      expect(_row(r, 'Capabilities', 'sync_seq'), 'unknown');
      expect(_row(r, 'Pull', 'seq cursors'), '0');
    });

    test('a failing source reads as a dash and never throws', () async {
      final r = await collectSyncDiagnostics(SyncDiagnosticsSources(
        db: db,
        health: health,
        settings: _settings(),
        authUid: _uid,
        ownerUid: _uid,
        cachedCapability: (_) => ServerCapabilityState.unknown,
        otherCapabilities: const {},
        replicaEntry: () async => throw StateError('boom'),
        captureOwner: () async => throw StateError('boom'),
        peekQueue: () async => throw StateError('boom'),
        unboundHinted: (_) async => throw StateError('boom'),
        removalBarrier: () async => throw StateError('boom'),
        consentAck: () async => throw StateError('boom'),
      ));
      expect(_row(r, 'Identity and replica', 'replica state'), '—');
      expect(_row(r, 'Capture', 'native owner published'), 'no');
    });
  });

  group('CONTENT-FREE: no diagnostic surface carries SMS content', () {
    // Synthetic sensitive fixtures. None of these may appear in any output.
    const smsText =
        'Your card ending 4111111111111234 was charged SAR 1,234.56 at ACME COFFEE ROASTERS';
    const sender = 'AL-RAJHI-BNK';
    const merchant = 'ACME COFFEE ROASTERS';
    final payloadId = 'ab12' * 16;
    const epoch = 'epoch-7c1d9e30-aaaa-bbbb-cccc-0123456789ab';
    const secretFragments = [
      '4111111111111234',
      '1234.56',
      '1,234',
      'ACME',
      'COFFEE',
      'ROASTERS',
      'AL-RAJHI',
      'Synthetic Person',
      '+966500000000',
      '9f1c2b7e',
      '4d3a',
      '1a2b3c4d',
      'ab12ab12',
      '7c1d9e30',
      'Your card',
      'charged',
    ];

    Future<void> seedSensitive() async {
      // Replica content that must never surface.
      await db.customStatement(
          'INSERT INTO transactions(id, amount, amount_minor, currency, type, '
          'source, occurred_at, raw_message, parse_confidence, status, '
          'created_at, updated_at, raw_merchant, sync_status, direction) VALUES '
          "('$payloadId', 1234.56, 123456, 'SAR', 'payment', 'iosShortcut', "
          "'2026-10-01T00:00:00Z', '$smsText', 1.0, 'confirmed', "
          "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', '$merchant', "
          "'conflict', 'debit');");
      await db.customStatement(
          'INSERT INTO ledger_sync_outbox(id, transaction_id, operation, '
          'payload_json, attempt_count, last_error, created_at, updated_at, '
          "status, failure_class, op_seq) VALUES ('o1', '$payloadId', 'create', "
          "'{\"merchant\":\"$merchant\",\"raw\":\"$smsText\"}', 3, '$smsText', "
          "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 'dead_letter', "
          "'$merchant', 1);");
      await db.customStatement(
          'INSERT INTO parked_child_rows(table_name, server_id, row_json, '
          "reason, attempt_count, first_seen_at, updated_at) VALUES "
          "('transactions', '$payloadId', '{\"raw\":\"$smsText\"}', "
          "'integrity', 0, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');");
      await db.customStatement(
          'INSERT INTO sync_conflicts(id, entity_type, local_id, kind, '
          'mine_json, theirs_json, created_at, updated_at) VALUES ('
          "'c1', 'transaction', '$payloadId', 'update', "
          "'{\"merchant\":\"$merchant\"}', '{\"raw\":\"$smsText\"}', "
          "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');");
      await db.customStatement(
          'INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
          "VALUES ('capture_payload:$payloadId', '$payloadId', "
          "'1970-01-01T00:00:00Z', '2026-10-01T00:00:00Z');");
      await db.customStatement(
          'INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
          "VALUES ('capture_notified:$payloadId', 'app', "
          "'2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');");
      await writeRecordedSyncEpoch(db, _uid, epoch, 'reset');
      await writeSeqCursor(db, _uid, 'transactions', 5);
      // Health: an error whose MESSAGE carries content is classified, never kept.
      health.recordFailure(
        SyncDomain.ledger,
        const PostgrestException(message: smsText, details: merchant, code: '42501'),
      );
      f.peek = [
        SharedCapturedMessage(
          id: payloadId,
          text: smsText,
          sender: sender,
          senderName: sender,
          senderId: sender,
          source: CapturedMessageSource.iosShortcut,
          ownerUid: _uid,
          failureReason: smsText,
        ),
      ];
      f.lastImport = CaptureImportReport(imported: [
        CaptureImportItem(id: payloadId, path: CaptureImportPath.local),
      ]);
      // The native stats carry integers and a quota word: nothing else exists.
      f.stats = const CaptureQueueStats(
        stamped: 1,
        localOnly: 2,
        waiting: 3,
        unbound: 4,
        activeOwnerBytes: 5551,
        unboundBytes: 6662,
        deviceBytes: 7773,
        ownerQuota: CaptureQuotaState.near,
        unboundQuota: CaptureQuotaState.ok,
        deviceQuota: CaptureQuotaState.full,
      );
      f.registration = const CaptureRegistrationStatus(
          CaptureRegistrationPhase.failed, 'register_failed');
      f.entry = ReplicaEntry(
        uidHash: 'x',
        createdAt: _now,
        lastOpenedAt: _now,
        schemaVersion: 41,
        epoch: 1,
        state: ReplicaState.active,
        rebootstrap: RebootstrapMarker(
            phase: RebootstrapPhase.frozen,
            reason: 'reset',
            startedAt: _now),
      );
    }

    void expectClean(String text, {String where = 'output'}) {
      for (final frag in secretFragments) {
        expect(text.contains(frag), isFalse,
            reason: '"$frag" leaked into $where');
      }
      expect(RegExp(r'[0-9a-fA-F]{32,}').hasMatch(text), isFalse,
          reason: 'an opaque id leaked into $where');
      expect(
          RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}').hasMatch(text),
          isFalse,
          reason: 'a uuid leaked into $where');
    }

    test('the redacted text bundle and every section row are clean', () async {
      await seedSensitive();
      final r = await f.collect();
      // The seeded rows are really reflected as counts, so the scan is not
      // passing on an empty report.
      expect(_row(r, 'Pull', 'quarantined (integrity)'), '1');
      expect(_row(r, 'Queue', 'dead letter'), '1');
      expect(_row(r, 'Queue', 'open conflicts: update'), '1');
      expect(_row(r, 'Capture', 'queue items (this owner)'), '1');
      expect(_row(r, 'Capture', 'receipts in replica'), '1');
      // The native stats rows are really present (so the scan is not vacuous).
      expect(_row(r, 'Capture', 'queue stats: local-only'), '2');
      expect(_row(r, 'Capture', 'queue bytes (device)'), '7773');
      expect(_row(r, 'Capture', 'queue quota (device)'), 'full');
      expectClean(r.toRedactedText(), where: 'toRedactedText');
      for (final s in r.sections) {
        expectClean(s.title, where: 'section title ${s.title}');
        for (final e in s.rows.entries) {
          expectClean('${e.key}=${e.value}', where: '${s.title}/${e.key}');
        }
      }
    });

    test('a hostile failure_class is redacted, not echoed', () async {
      await seedSensitive();
      final r = await f.collect();
      expect(_row(r, 'Dead letter by reason', '[redacted]'), '1');
    });

    test('free text can never be a row value', () {
      final rows = DiagnosticRows()
        ..add('a', smsText)
        ..add('b', payloadId)
        ..add('c', _uid)
        ..add('d', {'k': 'v'})
        ..add('e', 'reset')
        ..add('f', 42)
        ..add('g', true);
      expect(rows.rows['a'], '[redacted]');
      expect(rows.rows['b'], '[redacted]');
      expect(rows.rows['c'], '[redacted]');
      expect(rows.rows['d'], '[redacted]');
      expect(rows.rows['e'], 'reset');
      expect(rows.rows['f'], '42');
      expect(rows.rows['g'], 'yes');
    });

    test('the health snapshot keeps the error CLASS only', () async {
      await seedSensitive();
      final r = await f.collect();
      expect(_row(r, 'Domain: ledger', 'last error class'), 'auth');
      expectClean(r.toRedactedText());
      expectClean(health.of(SyncDomain.ledger).toJson().toString(),
          where: 'SyncDomainHealth.toJson');
    });

    testWidgets('the rendered screen (every Text) is clean', (tester) async {
      await tester.runAsync(seedSensitive);
      final report = (await tester.runAsync(f.collect))!;
      tester.view.physicalSize = const Size(800, 12000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [syncDiagnosticsProvider.overrideWith((ref) async => report)],
        child: MaterialApp(
            theme: AppTheme.light, home: const SyncDiagnosticsScreen()),
      ));
      await tester.pumpAndSettle();
      final texts = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          t.data ?? t.textSpan?.toPlainText() ?? '',
      ];
      expect(texts.length, greaterThan(40));
      expect(texts, contains('Capture'));
      expectClean(texts.join('\n'), where: 'rendered screen');
    });

    test('the report source reads no content accessor of a queue item', () {
      // Defence in depth for the one function that sees raw queue items: it may
      // read ownership and state flags only.
      final src =
          File('lib/core/sync/sync_diagnostics_report.dart').readAsStringSync();
      final body = src.substring(src.indexOf('CaptureQueueCounts summarize'),
          src.indexOf('/// Everything the collector reads'));
      expect(
          RegExp(r'\bm\.(text|sender|senderName|senderId|id|receivedAt|locale)\b')
              .hasMatch(body),
          isFalse);
      expect(src.contains('print('), isFalse);
      expect(src.contains('debugPrint'), isFalse);
    });
  });
}

/// The `capture_notified` state words (CAP-7 `CaptureAlertState`), spelled out
/// so a rename there fails here.
class CaptureAlertStateWords {
  static const app = 'app';
  static const summary = 'summary';
}
