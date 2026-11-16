import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/data/catalog/shared_category_learning_client.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/shared_category_learning.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/merchant_category_map.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

UserSettingsEntity _settings({required bool cloud, required bool ai}) =>
    UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
      aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
    );

final _at = DateTime.utc(2026, 11, 1, 12);

TransactionEntity _tx({
  String? merchant = 'HALA BOUTIQUE 123',
  TransactionTypeEntity type = TransactionTypeEntity.payment,
  TransactionSourceEntity source = TransactionSourceEntity.bank,
  TransactionDirectionEntity? direction = TransactionDirectionEntity.debit,
  String message = 'Purchase SAR 45.00 at HALA BOUTIQUE 123 card **1234',
}) =>
    TransactionEntity(
      id: 'tx-1',
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
      currency: 'SAR',
      type: type,
      source: source,
      direction: direction,
      occurredAt: _at,
      rawMessage: message,
      parseConfidence: 0.9,
      status: TransactionStatus.confirmed,
      createdAt: _at,
      updatedAt: _at,
      rawMerchant: merchant,
      cardLast4: '1234',
      note: 'my private note',
    );

/// Consent driven by the real policy (ConsentAuthority.decide), switchable
/// between the offer-time and send-time checks.
class _Harness {
  _Harness({bool cloud = true, bool ai = true})
      : settings = _settings(cloud: cloud, ai: ai);

  UserSettingsEntity settings;
  final sent = <Map<String, String>>[];
  int checks = 0;

  /// Applied right after the N-th consent check (1-based), to model a
  /// revocation between enqueue and send.
  final onCheck = <int, UserSettingsEntity>{};

  late final client = SharedCategoryLearningClient(
    mayEgress: () async {
      final allowed =
          ConsentAuthority.decide(EgressClass.aiProcessing, settings);
      checks++;
      final next = onCheck[checks];
      if (next != null) settings = next;
      return allowed;
    },
    send: (body) async => sent.add(body),
  );
}

void main() {
  group('consent', () {
    test('Cloud OFF: nothing is sent', () async {
      final h = _Harness(cloud: false, ai: true);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    test('AI OFF: nothing is sent', () async {
      final h = _Harness(cloud: true, ai: false);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    for (final revoked in ['cloud', 'ai']) {
      test(
          '$revoked revoked between enqueue and send: nothing sent, queue '
          'dropped, and a later re-grant does not release it', () async {
        final h = _Harness()
          ..onCheck[1] =
              _settings(cloud: revoked != 'cloud', ai: revoked != 'ai');
        await h.client.offer(_tx(), 'shopping');
        expect(h.checks, 2, reason: 'checked at offer AND again at send');
        expect(h.sent, isEmpty);
        expect(h.client.queuedCount, 0);

        h.settings = _settings(cloud: true, ai: true);
        await h.client.flush();
        expect(h.sent, isEmpty);

        await h.client.offer(_tx(merchant: 'NEW CAFE'), 'cafes');
        expect(h.sent, [
          {'merchant_key': 'NEW CAFE', 'category_key': 'cafes'}
        ]);
      });
    }
  });

  group('payload', () {
    test('only the normalised merchant key and the category key', () async {
      final h = _Harness();
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, hasLength(1));
      expect(h.sent.single.keys.toList(), ['merchant_key', 'category_key']);
      expect(h.sent.single,
          {'merchant_key': 'HALA BOUTIQUE', 'category_key': 'shopping'});
      final wire = h.sent.single.values.join(' ');
      for (final leaked in ['45', '1234', 'SAR', 'private', 'Purchase']) {
        expect(wire, isNot(contains(leaked)));
      }
    });

    test('a refund from a business is eligible', () {
      expect(
          sharedContributionFor(
                  _tx(
                      type: TransactionTypeEntity.refund,
                      direction: TransactionDirectionEntity.credit,
                      message: 'Refund SAR 45.00 from HALA BOUTIQUE'),
                  'shopping')
              ?.toJson(),
          {'merchant_key': 'HALA BOUTIQUE', 'category_key': 'shopping'});
    });
  });

  group('people and transfers are never contributed', () {
    final cases = <String, TransactionEntity>{
      'transfer type': _tx(type: TransactionTypeEntity.transfer),
      'income type': _tx(type: TransactionTypeEntity.income),
      'withdrawal type': _tx(type: TransactionTypeEntity.withdrawal),
      'unknown type': _tx(type: TransactionTypeEntity.unknown),
      'incoming payment (a payer)':
          _tx(direction: TransactionDirectionEntity.credit),
      'wallet (may be wallet-to-person)':
          _tx(source: TransactionSourceEntity.wallet),
      'InstaPay wording':
          _tx(message: 'IPN transfer sent to SARRAA ALASMARI EGP 500'),
      'Arabic transfer wording':
          _tx(message: 'تحويل إلى محمد الغامدي 500 ريال'),
      'beneficiary context':
          _tx(message: 'Payment to beneficiary MOHAMMED ALI SAR 200'),
      'own-account move':
          _tx(message: 'Internal transfer between your accounts'),
      'no merchant': _tx(merchant: null),
      'identifier as merchant': _tx(merchant: 'name@example.com'),
      'Arabic-Indic digits survive normalisation':
          _tx(merchant: 'متجر ٠٥٥١٢٣٤٥٦٧'),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final h = _Harness();
        await h.client.offer(entry.value, 'shopping');
        expect(h.sent, isEmpty);
        expect(h.checks, 0, reason: 'dropped before consent is even asked');
      });
    }

    test('people-shaped, catch-all and custom categories are not shared', () {
      for (final key in [
        'transfers',
        'income',
        'cash',
        'other',
        'user-cat-9'
      ]) {
        expect(sharedContributionFor(_tx(), key), isNull, reason: key);
      }
    });
  });

  test('an approved shared mapping ranks below the user\'s confirmed rule', () {
    // Shared mappings reach the device as catalog keywords (merchant_keywords);
    // they never enter the user's rule map.
    const shared = RemoteMerchantKeyword(
      id: 'k1',
      keyword: 'HALA BOUTIQUE',
      categoryKey: 'restaurants',
      language: 'any',
      countryCode: 'ALL',
      priority: 0,
      isActive: true,
      isDeleted: false,
      updatedAt: '2026-11-16T00:00:00Z',
    );
    final txn = ParsedTransaction(
      amountText: '45',
      amount: 45,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'HALA BOUTIQUE',
      occurredAt: _at,
      parseConfidence: 0.9,
    );
    final withRule = Categorizer(
      map: MerchantCategoryMap({'HALA BOUTIQUE': 'shopping'}),
      remoteKeywords: const [shared],
    ).categorize(txn);
    expect(withRule.categoryKey, 'shopping');
    expect(withRule.source, CategorySource.userMap);

    final withoutRule =
        Categorizer(remoteKeywords: const [shared]).categorize(txn);
    expect(withoutRule.categoryKey, 'restaurants');
    expect(withoutRule.source, CategorySource.keyword);
  });
}
