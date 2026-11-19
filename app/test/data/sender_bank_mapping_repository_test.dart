import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {

  late AppDatabase db;
  late DriftSenderBankMappingRepository repository;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repository = DriftSenderBankMappingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('schema creates sender_bank_mappings table', () async {
    expect(await db.count('sender_bank_mappings'), 0);
    expect(db.schemaVersion, 45);
  });

  test('saveSuggestion stores pending mapping by normalized sender', () async {
    final now = DateTime.utc(2026, 6, 16, 10);
    final mapping = await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: ' A-D_I.B ',
      bankKey: 'adib_ae',
      suggestedBankName: 'Abu Dhabi Islamic Bank',
      suggestedCountry: 'AE',
      confidence: 0.97,
      reason: 'Sender ADIB matches UAE bank alerts.',
      now: now,
    ));

    expect(mapping.status, SenderBankMappingStatus.pending);
    expect(mapping.normalizedSenderId, 'ADIB');
    expect(mapping.bankKey, 'adib_ae');
    expect(mapping.reason, 'Sender ADIB matches UAE bank alerts.');
    expect(mapping.syncStatus, SenderBankMappingSyncStatus.pending);
    expect(mapping.confirmedAt, isNull);

    final bySender = await repository.getBySender('adib');
    expect(bySender?.id, mapping.id);
    expect(await repository.getConfirmedBySender('ADIB'), isNull);
    expect(
      await repository.suppressesDiscoveryPrompt('ADIB', now: now),
      isFalse,
    );
  });

  test('confirmed mapping resolves unknown sender locally', () async {
    final now = DateTime.utc(2026, 6, 16, 10);
    final pending = await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: 'ADIB',
      suggestedBankName: 'Abu Dhabi Islamic Bank',
      suggestedCountry: 'AE',
      confidence: 0.98,
      now: now,
    ));

    final confirmed = await repository.confirm(
      mappingId: pending.id,
      bankKey: 'adib_ae',
      now: now.add(const Duration(minutes: 1)),
    );

    expect(confirmed.status, SenderBankMappingStatus.confirmed);
    expect(confirmed.bankKey, 'adib_ae');
    expect(confirmed.confirmedAt, isNotNull);
    expect(confirmed.rejectedAt, isNull);
    expect(confirmed.syncStatus, SenderBankMappingSyncStatus.pending);

    final lowerCase = await repository.getConfirmedBySender('a.d-i_b');
    expect(lowerCase?.id, confirmed.id);
    expect(lowerCase?.isTrusted, isTrue);
    expect(
      await repository.suppressesDiscoveryPrompt('ADIB', now: now),
      isTrue,
    );
  });

  test('rejected mapping prevents repeated discovery prompts during cooldown',
      () async {
    final now = DateTime.utc(2026, 6, 16, 10);
    final pending = await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: 'ADIB',
      suggestedBankName: 'Abu Dhabi Islamic Bank',
      suggestedCountry: 'AE',
      confidence: 0.96,
      now: now,
    ));

    final rejected = await repository.reject(
      mappingId: pending.id,
      cooldown: const Duration(days: 30),
      now: now.add(const Duration(minutes: 2)),
    );

    expect(rejected.status, SenderBankMappingStatus.rejected);
    expect(rejected.rejectedAt, isNotNull);
    expect(rejected.rejectionExpiresAt,
        now.add(const Duration(days: 30, minutes: 2)));
    expect(await repository.getConfirmedBySender('ADIB'), isNull);
    expect(
      await repository.suppressesDiscoveryPrompt(
        'adib',
        now: now.add(const Duration(days: 10)),
      ),
      isTrue,
    );
    expect(
      await repository.suppressesDiscoveryPrompt(
        'adib',
        now: now.add(const Duration(days: 31)),
      ),
      isFalse,
    );
  });

  test('pending mapping is an active suggestion but not trusted', () async {
    final now = DateTime.utc(2026, 6, 16, 10);
    final pending = await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: 'ENBD',
      suggestedBankName: 'Emirates NBD',
      suggestedCountry: 'AE',
      confidence: 0.95,
      now: now,
    ));

    final active = await repository.getActiveSuggestionBySender('e-n_b.d');
    expect(active?.id, pending.id);
    expect(active?.isTrusted, isFalse);
    expect(await repository.getConfirmedBySender('ENBD'), isNull);
  });

  test('pendingSync returns confirmed and rejected mappings only', () async {
    final now = DateTime.utc(2026, 6, 16, 10);
    final pending = await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: 'ADIB',
      suggestedBankName: 'Abu Dhabi Islamic Bank',
      suggestedCountry: 'AE',
      confidence: 0.97,
      now: now,
    ));
    final rejectedDraft =
        await repository.saveSuggestion(SenderBankMappingDraft(
      senderId: 'ENBD',
      suggestedBankName: 'Emirates NBD',
      suggestedCountry: 'AE',
      confidence: 0.97,
      now: now,
    ));

    final confirmed = await repository.confirm(
      mappingId: pending.id,
      bankKey: 'adib_ae',
      now: now.add(const Duration(minutes: 1)),
    );
    final rejected = await repository.reject(
      mappingId: rejectedDraft.id,
      cooldown: const Duration(days: 30),
      now: now.add(const Duration(minutes: 2)),
    );

    final sync = await repository.pendingSync();
    expect(
        sync.map((item) => item.id), containsAll([confirmed.id, rejected.id]));
    expect(sync.length, 2);

    await repository.markSynced(confirmed.id,
        now: now.add(const Duration(minutes: 3)));
    final afterSynced = await repository.pendingSync();
    expect(afterSynced.map((item) => item.id), isNot(contains(confirmed.id)));
    expect(afterSynced.map((item) => item.id), contains(rejected.id));
  });
}
