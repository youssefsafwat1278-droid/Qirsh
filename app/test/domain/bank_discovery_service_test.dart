import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bank_discovery_models.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/services/bank_discovery_service.dart';
import 'package:money_companion/engine/ai/bank_discovery_client.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parse_result.dart';

class _FakeBankDiscoveryClient implements BankDiscoveryClient {
  _FakeBankDiscoveryClient(this.response);

  final BankDiscoverySuggestion? response;
  int callCount = 0;
  BankDiscoveryRequest? lastRequest;

  @override
  Future<BankDiscoverySuggestion?> detectBank(
    BankDiscoveryRequest request,
  ) async {
    callCount++;
    lastRequest = request;
    return response;
  }
}

class _FakeSenderBankMappingRepository implements SenderBankMappingRepository {
  SenderBankMappingEntity? mapping;
  SenderBankMappingDraft? savedDraft;

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    if (mapping == null) return null;
    return mapping!.senderId.toLowerCase() == senderId.toLowerCase()
        ? mapping
        : null;
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId) async {
    final value = await getBySender(senderId);
    return value?.status == SenderBankMappingStatus.confirmed ? value : null;
  }

  @override
  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  }) async =>
      getBySender(senderId);

  @override
  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  }) async {
    final value = await getBySender(senderId);
    return value?.suppressesDiscovery(now ?? DateTime.now().toUtc()) ?? false;
  }

  @override
  Future<SenderBankMappingEntity> saveSuggestion(
    SenderBankMappingDraft draft,
  ) async {
    savedDraft = draft;
    final now = (draft.now ?? DateTime.now()).toUtc();
    mapping = SenderBankMappingEntity(
      id: 'pending-${draft.senderId}',
      senderId: draft.senderId,
      normalizedSenderId: draft.senderId.toUpperCase(),
      bankKey: draft.bankKey,
      suggestedBankName: draft.suggestedBankName,
      suggestedCountry: draft.suggestedCountry,
      confidence: draft.confidence,
      status: SenderBankMappingStatus.pending,
      source: draft.source,
      firstSeenAt: now,
      lastSeenAt: now,
      confirmedAt: null,
      rejectedAt: null,
      rejectionExpiresAt: null,
      createdAt: now,
      updatedAt: now,
      syncedAt: null,
      syncStatus: SenderBankMappingSyncStatus.pending,
    );
    return mapping!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Unknown sender used across tests — must NOT be in BankProfiles.all.
const _unknownSender = 'GULFCORP-UNKNOWN';

void main() {
  const highConfidenceSuggestion = BankDiscoverySuggestion(
    suggestedBankName: 'Mashreq Bank UAE',
    bankKeySuggestion: 'mashreq_ae',
    country: 'AE',
    confidence: 0.97,
    reason: 'Sender and wording match UAE bank alerts.',
  );

  test('unknown sender returns a matched suggestion and persists nothing',
      () async {
    final repo = _FakeSenderBankMappingRepository();
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: repo,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, card alerts are now active for your AED account.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
      localeHint: 'ar-AE',
      now: DateTime.utc(2026, 6, 16),
    );

    expect(client.callCount, 1);
    expect(result.status, BankDiscoveryResultStatus.pendingSuggestion);
    // The invented AI key is resolved onto the existing catalog profile and
    // returned in the result only: nothing is written to the repository.
    expect(result.suggestion?.suggestedBankName, 'بنك المشرق');
    expect(result.suggestion?.bankKeySuggestion, 'mashreq');
    expect(repo.savedDraft, isNull);
  });

  test('suggestion with no catalog match saves nothing', () async {
    final repo = _FakeSenderBankMappingRepository();
    final client = _FakeBankDiscoveryClient(const BankDiscoverySuggestion(
      suggestedBankName: 'Totally Invented Bank',
      bankKeySuggestion: 'invented_ae',
      country: 'AE',
      confidence: 0.98,
      reason: 'Looks like a bank.',
    ));
    final service = BankDiscoveryService(
      mappingRepository: repo,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, card alerts are now active for your AED account.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
      now: DateTime.utc(2026, 6, 16),
    );

    expect(result.status, BankDiscoveryResultStatus.noSuggestion);
    expect(result.reason, 'no_catalog_match');
    expect(repo.savedDraft, isNull);
  });

  test('low confidence result is ignored without pending prompt', () async {
    final repo = _FakeSenderBankMappingRepository();
    final client = _FakeBankDiscoveryClient(const BankDiscoverySuggestion(
      suggestedBankName: 'Maybe Bank',
      country: 'AE',
      confidence: 0.94,
      reason: 'Weak match.',
    ));
    final service = BankDiscoveryService(
      mappingRepository: repo,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, card alerts are active.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
    );

    expect(client.callCount, 1);
    expect(result.status, BankDiscoveryResultStatus.noSuggestion);
    expect(repo.savedDraft, isNull);
  });

  test('ignored admin SMS never calls Gemini', () async {
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: _FakeSenderBankMappingRepository(),
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear Customer, thank you for requesting a new chequebook for '
          'your A/C NO: ****0535. Your request will be fulfilled at the '
          'earliest. Sincerely, $_unknownSender',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
    );

    expect(client.callCount, 0);
    expect(result.status, BankDiscoveryResultStatus.ineligible);
    expect(result.reason, 'ignored_message');
  });

  test('confirmed mapping skips Gemini', () async {
    final now = DateTime.utc(2026, 6, 16);
    final repo = _FakeSenderBankMappingRepository()
      ..mapping = _mapping(
        senderId: _unknownSender,
        status: SenderBankMappingStatus.confirmed,
        confirmedAt: now,
      );
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: repo,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, card alerts are active.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
      now: now,
    );

    expect(client.callCount, 0);
    expect(result.status, BankDiscoveryResultStatus.skipped);
    expect(result.reason, 'confirmed_mapping');
  });

  test('rejected cooldown skips Gemini', () async {
    final now = DateTime.utc(2026, 6, 16);
    final repo = _FakeSenderBankMappingRepository()
      ..mapping = _mapping(
        senderId: _unknownSender,
        status: SenderBankMappingStatus.rejected,
        rejectedAt: now.subtract(const Duration(days: 1)),
        rejectionExpiresAt: now.add(const Duration(days: 29)),
      );
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: repo,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, card alerts are active.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
      now: now,
    );

    expect(client.callCount, 0);
    expect(result.status, BankDiscoveryResultStatus.skipped);
    expect(result.reason, 'rejected_cooldown');
  });

  test('request payload is sanitized', () async {
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: _FakeSenderBankMappingRepository(),
      client: client,
      loadAiConsent: () async => true,
    );

    await service.discoverIfEligible(
      rawSms: 'Card 4111111111111111 account 123456789012 '
          'Trx. of AED 50.00 at SHOP.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
      localeHint: 'ar-AE',
    );

    expect(client.callCount, 1);
    expect(client.lastRequest?.senderId, _unknownSender);
    expect(client.lastRequest?.detectedCurrency, 'AED');
    expect(client.lastRequest?.localeHint, 'ar-AE');
    expect(client.lastRequest?.sanitizedSms, isNot(contains('411111')));
    expect(client.lastRequest?.sanitizedSms, isNot(contains('1234567890')));
    expect(client.lastRequest?.sanitizedSms, contains('[CARD]'));
    expect(client.lastRequest?.sanitizedSms, contains('[ACCOUNT]'));
  });

  test('usable generic pending result skips Gemini discovery', () async {
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: _FakeSenderBankMappingRepository(),
      client: client,
      loadAiConsent: () async => true,
    );
    final parseResult = ParseResult.success(
      ParsedTransaction(
        amountText: '50',
        amount: 50,
        currency: 'AED',
        type: TransactionType.payment,
        source: TransactionSource.bank,
        rawMerchant: 'MERCHANT STORE',
        parseConfidence: 0.79,
      ),
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Trx. of AED 50.00 at MERCHANT STORE.',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: parseResult,
    );

    expect(client.callCount, 0);
    expect(result.status, BankDiscoveryResultStatus.skipped);
    expect(result.reason, 'generic_pending_is_usable');
  });

  test('egress: a person named in a transfer never reaches discovery',
      () async {
    final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
    final service = BankDiscoveryService(
      mappingRepository: _FakeSenderBankMappingRepository(),
      client: client,
      loadAiConsent: () async => true,
    );

    await service.discoverIfEligible(
      rawSms: 'Transfer received from MOHAMED ALI HASSAN AED 750.00 '
          'Ref 7788991 call 0551234567',
      senderId: _unknownSender,
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
    );

    final sent = client.lastRequest!.sanitizedSms;
    expect(sent, 'Transfer received from [NAME] AED 750.00 Ref [REF] '
        'call [PHONE]');
  });

  test('egress: phone-number and numeric short-code senders are never sent',
      () async {
    // Discovery is only for alphanumeric (brand) sender IDs: a phone number
    // is personal data and identifies no bank, so the request never leaves.
    for (final sender in ['+966551234567', '0551234567', '19623', '3636']) {
      final client = _FakeBankDiscoveryClient(highConfidenceSuggestion);
      final service = BankDiscoveryService(
        mappingRepository: _FakeSenderBankMappingRepository(),
        client: client,
        loadAiConsent: () async => true,
      );
      final result = await service.discoverIfEligible(
        rawSms: 'Trx. of AED 50.00 at SHOP.',
        senderId: sender,
        availableProfiles: const [],
        parseResult: ParseResult.notTransaction(),
      );
      expect(client.callCount, 0, reason: sender);
      expect(result.reason, 'sender_not_bank_like', reason: sender);
    }
  });
}

SenderBankMappingEntity _mapping({
  required String senderId,
  required SenderBankMappingStatus status,
  DateTime? confirmedAt,
  DateTime? rejectedAt,
  DateTime? rejectionExpiresAt,
}) {
  final now = DateTime.utc(2026, 6, 16);
  return SenderBankMappingEntity(
    id: 'mapping-$senderId',
    senderId: senderId,
    normalizedSenderId: senderId.toUpperCase(),
    bankKey: 'gulfcorp_ae',
    suggestedBankName: 'Unknown Gulf Bank',
    suggestedCountry: 'AE',
    confidence: 0.98,
    status: status,
    source: SenderBankMappingSource.gemini,
    firstSeenAt: now,
    lastSeenAt: now,
    confirmedAt: confirmedAt,
    rejectedAt: rejectedAt,
    rejectionExpiresAt: rejectionExpiresAt,
    createdAt: now,
    updatedAt: now,
    syncedAt: null,
    syncStatus: SenderBankMappingSyncStatus.pending,
  );
}
