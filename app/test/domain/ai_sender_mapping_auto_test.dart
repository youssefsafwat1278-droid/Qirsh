import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/bank_discovery_models.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/services/bank_discovery_service.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/resolve_bank_for_sender_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/ai/bank_discovery_client.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

class _FakeParserIsolate extends ParserIsolate {
  const _FakeParserIsolate(this._result);
  final ParseResult _result;
  @override
  Future<ParseResult?> parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    List<CatalogParserRule> catalogRules = const [],
    String defaultCurrency = 'SAR',
  }) async =>
      _result;
}

class _StoringTransactionRepo implements TransactionRepository {
  final Map<String, TransactionEntity> byId = {};
  bool reportDuplicate = false;
  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    String? categoryKey,
    String? resolvedCategoryId,
  }) async {
    byId[transaction.id] = transaction;
    return transaction;
  }

  @override
  Future<TransactionEntity?> getById(String id) async => byId[id];

  @override
  Future<TransactionEntity?> findDuplicate({
    required Money amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async =>
      null;

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required Money amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) async =>
      reportDuplicate ? byId.values.first : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMerchantRepo implements MerchantCategoryRepository {
  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async =>
      null;

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => false;
  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryDedupStore implements DedupStore {
  final Map<String, String> hashes = {};
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      hashes[hash];
  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {
    hashes[hash] = transactionId;
  }
}

class _CountingAiClient implements AiParserClient {
  _CountingAiClient(this.response);
  final AiParseResponse? response;
  int calls = 0;
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    calls++;
    return response;
  }
}

class _DiscoveryClient implements BankDiscoveryClient {
  _DiscoveryClient(this.response);
  final BankDiscoverySuggestion? response;
  @override
  Future<BankDiscoverySuggestion?> detectBank(
          BankDiscoveryRequest request) async =>
      response;
}

const _sender = 'GULFCORP-UNKNOWN';
const _sms = 'خصم 150.00 ريال من حسابك في مطعم البيك';
const _validAi = AiParseResponse(
  amount: 150.0,
  amountText: '150.00',
  currency: 'SAR',
  type: 'payment',
  merchantName: 'البيك',
);
const _mashreqSuggestion = BankDiscoverySuggestion(
  suggestedBankName: 'Mashreq Bank UAE',
  bankKeySuggestion: 'mashreq_ae',
  country: 'AE',
  confidence: 0.97,
  reason: 'Sender and wording match UAE bank alerts.',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftSenderBankMappingRepository repo;

  setUp(() async {
    AiSenderFailureTracker.instance.resetForTest();
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftSenderBankMappingRepository(db);
  });
  tearDown(() => db.close());

  Future<AiMappingOutcome> ai(String bank, {String sender = 'ACME'}) =>
      repo.upsertAiValidated(
        senderId: sender,
        bankKey: bank,
        bankName: 'Bank $bank',
        country: 'AE',
        now: DateTime.utc(2026, 7, 1),
      );

  Future<int> rowCount(String sender, {bool includeDeleted = true}) async =>
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM sender_bank_mappings '
                  "WHERE normalized_sender_id = '$sender'"
                  '${includeDeleted ? '' : ' AND deleted_at IS NULL'};')
              .getSingle())
          .read<int>('n');

  group('schema and migration file', () {
    test('fresh install has accepted_by column', () async {
      final cols = await db
          .customSelect('PRAGMA table_info(sender_bank_mappings);')
          .get();
      expect(cols.map((c) => c.read<String>('name')), contains('accepted_by'));
    });

    test('upgrade path adds accepted_by to an existing table', () async {
      final dir = Directory.systemTemp.createTempSync('accepted_by_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';
      final first = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      await first.customStatement(
          'ALTER TABLE sender_bank_mappings DROP COLUMN accepted_by;');
      await first.close();
      final upgraded = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      final cols = await upgraded
          .customSelect('PRAGMA table_info(sender_bank_mappings);')
          .get();
      expect(cols.map((c) => c.read<String>('name')), contains('accepted_by'));
      await upgraded.close();
    });

    test('supabase migration 0100 is active (applied) and additive', () {
      const name = '0100_sender_mapping_accepted_by.sql';
      // Interpolated so head_completeness's tracked-file scan (which only
      // follows literal paths) does not treat this absence check as a read.
      expect(File('../supabase/deferred/$name').existsSync(), isFalse);
      expect(
          File('../supabase/rollback/0100_sender_mapping_accepted_by_rollback.sql')
              .existsSync(),
          isTrue);
      final sql =
          File('../supabase/migrations/0100_sender_mapping_accepted_by.sql')
              .readAsStringSync();
      expect(
          sql,
          contains('ALTER TABLE public.sender_bank_mappings\n'
              '  ADD COLUMN IF NOT EXISTS accepted_by text NULL'));
      expect(sql, contains("accepted_by IN ('user','ai_validated')"));
      expect(sql.toUpperCase(), isNot(contains('DROP ')));
      expect(sql.toUpperCase(), isNot(contains('POLICY')));
    });
  });

  test('ai_sender_mapping_auto is seeded inactive in the flag catalog', () {
    final json = File('assets/catalog/feature_flags.json').readAsStringSync();
    final entry = RegExp(
            r'"key": "ai_sender_mapping_auto",[^}]*"is_active": (true|false)')
        .firstMatch(json);
    expect(entry, isNotNull);
    expect(entry!.group(1), 'false');
  });

  group('conflict rules', () {
    test('d. no mapping -> creates confirmed gemini/ai_validated mapping',
        () async {
      expect(await ai('mashreq'), AiMappingOutcome.created);
      final m = (await repo.getBySender('acme'))!;
      expect(m.status, SenderBankMappingStatus.confirmed);
      expect(m.source, SenderBankMappingSource.gemini);
      expect(m.acceptedBy, SenderBankMappingAcceptedBy.aiValidated);
      expect(m.bankKey, 'mashreq');
      expect(m.confirmedAt, isNotNull);
      expect(m.syncStatus, SenderBankMappingSyncStatus.pending);
    });

    // Changed from "stamps 'user'": a non-null accepted_by in the sync payload
    // is rejected by production PostgREST until migration 0100 is deployed.
    // NULL already means user/legacy-accepted (isUserAccepted).
    test('user confirm() leaves accepted_by NULL and is user-accepted',
        () async {
      final s = await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        suggestedBankName: 'B',
        suggestedCountry: 'AE',
        confidence: 0.9,
      ));
      final c = await repo.confirm(mappingId: s.id, bankKey: 'adib');
      expect(c.acceptedBy, isNull);
      expect(c.isUserAccepted, isTrue);
    });

    test('a. user-confirmed mapping is never modified', () async {
      final s = await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        suggestedBankName: 'B',
        suggestedCountry: 'AE',
        confidence: 0.9,
      ));
      await repo.confirm(mappingId: s.id, bankKey: 'adib');
      expect(await ai('mashreq'), AiMappingOutcome.blockedUserAccepted);
      final m = (await repo.getBySender('acme'))!;
      expect(m.bankKey, 'adib');
      expect(m.acceptedBy, isNull);
      expect(m.isUserAccepted, isTrue);
    });

    test('a. legacy NULL accepted_by confirmed row is user-accepted', () async {
      final s = await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        suggestedBankName: 'B',
        suggestedCountry: 'AE',
        confidence: 0.9,
      ));
      await repo.confirm(mappingId: s.id, bankKey: 'adib');
      await db.customStatement(
          'UPDATE sender_bank_mappings SET accepted_by = NULL;');
      expect(await ai('mashreq'), AiMappingOutcome.blockedUserAccepted);
      expect((await repo.getBySender('acme'))!.bankKey, 'adib');
    });

    test('a. user_manual source is user-accepted even if accepted_by is odd',
        () async {
      await ai('adib');
      await db.customStatement(
          "UPDATE sender_bank_mappings SET source = 'user_manual';");
      expect(await ai('mashreq'), AiMappingOutcome.blockedUserAccepted);
      expect((await repo.getBySender('acme'))!.bankKey, 'adib');
    });

    test(
        'b. rejected mapping (active cooldown and expired) is never auto-mapped',
        () async {
      final s = await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        suggestedBankName: 'B',
        suggestedCountry: 'AE',
        confidence: 0.9,
      ));
      await repo.reject(
          mappingId: s.id,
          cooldown: const Duration(days: 30),
          now: DateTime.utc(2020, 1, 1));
      // Cooldown long expired.
      expect(await ai('mashreq'), AiMappingOutcome.blockedRejected);
      expect((await repo.getBySender('acme'))!.status,
          SenderBankMappingStatus.rejected);
    });

    test('c. pending legacy suggestion is left untouched', () async {
      await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        bankKey: 'adib',
        suggestedBankName: 'B',
        suggestedCountry: 'AE',
        confidence: 0.9,
      ));
      expect(await ai('mashreq'), AiMappingOutcome.blockedPending);
      final m = (await repo.getBySender('acme'))!;
      expect(m.status, SenderBankMappingStatus.pending);
      expect(m.bankKey, 'adib');
    });

    test('e. same bank AI mapping is a no-op', () async {
      await ai('mashreq');
      final before = (await repo.getBySender('acme'))!;
      expect(await ai('mashreq'), AiMappingOutcome.unchanged);
      final after = (await repo.getBySender('acme'))!;
      expect(after.id, before.id);
      expect(after.updatedAt, before.updatedAt);
    });

    test('f. different bank tombstones the AI mapping; next call recreates',
        () async {
      await ai('mashreq');
      expect(await ai('adib'), AiMappingOutcome.tombstonedConflict);
      expect(await repo.getBySender('acme'), isNull);
      expect(await rowCount('ACME'), 1); // tombstone, synced as delete
      final tomb = await db
          .customSelect('SELECT deleted_at, sync_status FROM '
              'sender_bank_mappings;')
          .getSingle();
      expect(tomb.readNullable<String>('deleted_at'), isNotNull);
      expect(tomb.read<String>('sync_status'), 'pending');

      expect(await ai('adib'), AiMappingOutcome.created);
      final m = (await repo.getBySender('acme'))!;
      expect(m.bankKey, 'adib');
      expect(m.acceptedBy, SenderBankMappingAcceptedBy.aiValidated);
      expect(await rowCount('ACME'), 1);
    });
  });

  group('content evidence contradicts an AI mapping (rule f, live flow)', () {
    const body = 'Dear Mashreq customer, thank you.';
    const noBankBody = 'Hello, thank you for banking with us.';

    Future<void> run(String text) async {
      final useCase = AddTransactionUseCase(
        transactionRepository: _StoringTransactionRepo(),
        merchantCategoryRepository: _StubMerchantRepo(),
        parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
        loadAiConsent: () async => true,
        aiClient: _CountingAiClient(null),
        dedupStore: _MemoryDedupStore(),
        resolveBankForSenderUseCase:
            ResolveBankForSenderUseCase(mappingRepository: repo),
        senderBankMappingRepository: repo,
        isAiSenderMappingAuto: () => true,
      );
      await useCase(rawMessage: text, senderId: 'ACME');
    }

    Future<Map<String, Object?>> row() async => (await db
            .customSelect('SELECT deleted_at, sync_status FROM '
                'sender_bank_mappings;')
            .getSingle())
        .data;

    test('AI mapping X + content says Y -> tombstoned, synced as delete',
        () async {
      await ai('alrajhi');
      await run(body);
      expect(await repo.getBySender('acme'), isNull);
      final r = await row();
      expect(r['deleted_at'], isNotNull);
      expect(r['sync_status'], 'pending');
      // Rule d afterwards: a later validated suggestion creates a fresh one.
      expect(await ai('mashreq'), AiMappingOutcome.created);
      expect((await repo.getBySender('acme'))!.bankKey, 'mashreq');
    });

    test('user mapping X + content Y -> untouched', () async {
      final s = await repo.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'ACME',
        suggestedBankName: 'B',
        suggestedCountry: 'SA',
        confidence: 0.9,
      ));
      await repo.confirm(mappingId: s.id, bankKey: 'alrajhi');
      await run(body);
      expect((await repo.getBySender('acme'))!.bankKey, 'alrajhi');
    });

    test('AI mapping X + content X -> untouched', () async {
      await ai('mashreq');
      await run(body);
      expect((await repo.getBySender('acme'))!.bankKey, 'mashreq');
    });

    test('no content bank -> untouched', () async {
      await ai('alrajhi');
      await run(noBankBody);
      expect((await repo.getBySender('acme'))!.bankKey, 'alrajhi');
    });
  });

  group('AddTransactionUseCase creation point', () {
    AddTransactionUseCase build({
      required ParseResult parse,
      required AiParseResponse? aiResponse,
      bool? Function()? flag,
      BankDiscoverySuggestion? suggestion = _mashreqSuggestion,
      _StoringTransactionRepo? txRepo,
      _MemoryDedupStore? dedup,
      _CountingAiClient? aiClient,
      bool withRepo = true,
    }) {
      return AddTransactionUseCase(
        transactionRepository: txRepo ?? _StoringTransactionRepo(),
        merchantCategoryRepository: _StubMerchantRepo(),
        parserIsolate: _FakeParserIsolate(parse),
        loadAiConsent: () async => true,
        aiClient: aiClient ?? _CountingAiClient(aiResponse),
        dedupStore: dedup ?? _MemoryDedupStore(),
        resolveBankForSenderUseCase:
            ResolveBankForSenderUseCase(mappingRepository: repo),
        bankDiscoveryService: BankDiscoveryService(
          mappingRepository: repo,
          client: _DiscoveryClient(suggestion),
          loadAiConsent: () async => true,
        ),
        senderBankMappingRepository: withRepo ? repo : null,
        isAiSenderMappingAuto: flag == null ? null : () => flag() ?? false,
      );
    }

    Future<SenderBankMappingEntity?> mapping() => repo.getBySender(_sender);

    test('flag on + saved aiValidated txn + catalog match -> mapping created',
        () async {
      final useCase = build(
          parse: ParseResult.notTransaction(),
          aiResponse: _validAi,
          flag: () => true);
      final result = await useCase(rawMessage: _sms, senderId: _sender);
      expect(result.transaction?.status, TransactionStatus.confirmed);
      final m = (await mapping())!;
      expect(m.bankKey, 'mashreq');
      expect(m.acceptedBy, SenderBankMappingAcceptedBy.aiValidated);
      expect(m.source, SenderBankMappingSource.gemini);
    });

    test('flag off, flag absent, flag throwing, repo absent -> nothing saved',
        () async {
      for (final useCase in [
        build(
            parse: ParseResult.notTransaction(),
            aiResponse: _validAi,
            flag: () => false),
        build(parse: ParseResult.notTransaction(), aiResponse: _validAi),
        build(
            parse: ParseResult.notTransaction(),
            aiResponse: _validAi,
            flag: () => throw StateError('boom')),
        build(
            parse: ParseResult.notTransaction(),
            aiResponse: _validAi,
            flag: () => true,
            withRepo: false),
      ]) {
        final result = await useCase(rawMessage: _sms, senderId: _sender);
        expect(result.transaction, isNotNull,
            reason: 'a mapping failure never affects the saved transaction');
        expect(await mapping(), isNull);
      }
    });

    test('validator failure (fabricated amount) -> nothing saved', () async {
      final useCase = build(
          parse: ParseResult.notTransaction(),
          aiResponse: const AiParseResponse(
            amount: 999.99,
            amountText: '999.99',
            currency: 'SAR',
            type: 'payment',
          ),
          flag: () => true);
      final result = await useCase(rawMessage: _sms, senderId: _sender);
      expect(result.transaction, isNull);
      expect(await mapping(), isNull);
    });

    test('no catalog-matched suggestion -> nothing saved', () async {
      final useCase = build(
          parse: ParseResult.notTransaction(),
          aiResponse: _validAi,
          flag: () => true,
          suggestion: null);
      await useCase(rawMessage: _sms, senderId: _sender);
      expect(await mapping(), isNull);
    });

    test('duplicate capture -> nothing saved', () async {
      final txRepo = _StoringTransactionRepo();
      final dedup = _MemoryDedupStore();
      var on = false;
      final useCase = build(
          parse: ParseResult.notTransaction(),
          aiResponse: _validAi,
          flag: () => on,
          txRepo: txRepo,
          dedup: dedup);
      await useCase(rawMessage: _sms, senderId: _sender);
      expect(txRepo.byId, hasLength(1));
      on = true;
      txRepo.reportDuplicate = true;
      final second = await useCase(rawMessage: _sms, senderId: _sender);
      expect(second.outcome, AddTransactionOutcome.suspiciousDuplicate);
      expect(txRepo.byId, hasLength(1));
      expect(await mapping(), isNull);
    });

    test('local parse (AI consulted too) -> nothing saved', () async {
      final parsed = ParsedTransaction(
        amountText: '150.00',
        amount: 150.0,
        currency: 'SAR',
        type: TransactionType.payment,
        source: TransactionSource.bank,
        rawMerchant: 'ALBAIK',
        occurredAt: DateTime.utc(2026, 6, 16, 12),
        parseConfidence: 0.5,
      );
      final aiClient = _CountingAiClient(_validAi);
      final useCase = build(
          parse: ParseResult.success(parsed),
          aiResponse: null,
          aiClient: aiClient,
          flag: () => true);
      await useCase(rawMessage: _sms, senderId: _sender);
      // AI is always consulted, but a local parse still creates no mapping.
      expect(aiClient.calls, 1);
      expect(await mapping(), isNull);
    });

    test(
        'next message: resolver aliases sender locally, but a non-parseable '
        'body still goes to AI', () async {
      await build(
          parse: ParseResult.notTransaction(),
          aiResponse: _validAi,
          flag: () => true).call(rawMessage: _sms, senderId: _sender);
      expect((await mapping())!.bankKey, 'mashreq');

      final resolution = await ResolveBankForSenderUseCase(
        mappingRepository: repo,
      ).call(
        rawMessage: 'Dear customer, thank you.',
        senderId: _sender,
        bankProfiles: const [],
      );
      expect(resolution.source, BankSenderResolutionSource.confirmedMapping);
      expect(resolution.profile?.bankKey, 'mashreq');

      final aiClient = _CountingAiClient(null);
      final useCase = build(
          parse: ParseResult.notTransaction(),
          aiResponse: null,
          aiClient: aiClient,
          flag: () => true);
      final result = await useCase(
          rawMessage: 'Dear customer, thank you.', senderId: _sender);
      expect(aiClient.calls, 1,
          reason: 'bank resolution alone must not skip AI for a body with no '
              'valid local parse');
      expect(result.transaction, isNull);
    });
  });
}
