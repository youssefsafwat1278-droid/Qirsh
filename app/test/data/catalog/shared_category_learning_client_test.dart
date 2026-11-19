import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/shared_learning_preference.dart';
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
  /// [optedIn]: the "Help improve categories for everyone" switch for the
  /// signed-in account, as an explicit choice. Null leaves it unset, which is
  /// OFF (decision 3.10 transition: an update opts nobody in).
  _Harness({bool cloud = true, bool ai = true, bool? optedIn = false})
      : settings = _settings(cloud: cloud, ai: ai) {
    if (optedIn != null) {
      prefs[SharedLearningPreference.keyFor(uid!)] = optedIn ? 'on' : 'off';
    }
  }

  UserSettingsEntity settings;
  String? uid = 'uid-a';
  final prefs = <String, String>{};
  late final preference = SharedLearningPreference.memory(prefs);
  final sent = <Map<String, String>>[];
  int checks = 0;

  /// Applied right after the N-th consent check (1-based), to model a
  /// revocation between enqueue and send.
  final onCheck = <int, UserSettingsEntity>{};

  late final client = SharedCategoryLearningClient(
    accountUid: () => uid,
    optedIn: preference.isOn,
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
  group('opt-in (Help improve categories for everyone)', () {
    // Decided behaviour change (owner decision 3.10, round 3): an unset
    // switch used to mean ON. The consent existing users accepted did not
    // mention shared learning, so unset is now OFF and unanswered; ON is
    // recorded only by "Agree and enable", the one-time question, or the
    // Privacy switch.
    test('unset is OFF: with Cloud and AI on, nothing is sent', () async {
      final h = _Harness(optedIn: null);
      expect(await h.preference.isOn('uid-a'), isFalse);
      expect(await h.preference.isAnswered('uid-a'), isFalse);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    test('a recorded ON still needs Cloud and AI consent', () async {
      for (final h in [
        _Harness(optedIn: true, cloud: false),
        _Harness(optedIn: true, ai: false),
      ]) {
        await h.client.offer(_tx(), 'shopping');
        expect(h.sent, isEmpty);
      }
    });

    test('turned OFF explicitly: nothing is sent, and it stays OFF', () async {
      final h = _Harness(optedIn: null);
      await h.preference.set('uid-a', false);
      expect(await h.preference.isOn('uid-a'), isFalse);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    test('an unreadable store is OFF; signed out is OFF', () async {
      final broken = SharedLearningPreference(
        read: (_) async => throw StateError('keychain locked'),
        write: (_, __) async {},
      );
      expect(await broken.isOn('uid-a'), isFalse);
      expect(await SharedLearningPreference.memory().isOn(null), isFalse);
      expect(await SharedLearningPreference.memory().isOn(''), isFalse);
    });

    test('ON with Cloud and AI: sent', () async {
      final h = _Harness();
      await h.preference.set('uid-a', true);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, [
        {'merchant_key': 'HALA BOUTIQUE', 'category_key': 'shopping'}
      ]);
    });

    test('turned OFF between offer and send: nothing sent, queue dropped',
        () async {
      final h = _Harness(optedIn: true);
      // The switch goes off right after the offer-time check passes.
      final client = SharedCategoryLearningClient(
        accountUid: () => h.uid,
        optedIn: (uid) async {
          final on = await h.preference.isOn(uid);
          if (on) await h.preference.set('uid-a', false);
          return on;
        },
        mayEgress: () async => true,
        send: (body) async => h.sent.add(body),
      );
      await client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(client.queuedCount, 0);
      await h.preference.set('uid-a', true);
      await client.flush();
      expect(h.sent, isEmpty, reason: 'the dropped item never comes back');
    });

    test('turning the switch OFF (dropQueued) drops what is waiting', () async {
      final h = _Harness(optedIn: true);
      final gate = Completer<void>();
      final client = SharedCategoryLearningClient(
        accountUid: () => h.uid,
        optedIn: h.preference.isOn,
        mayEgress: () async => true,
        send: (body) async {
          await gate.future;
          h.sent.add(body);
        },
      );
      final first = client.offer(_tx(), 'shopping');
      await Future<void>.delayed(Duration.zero);
      await client.offer(_tx(merchant: 'NEW CAFE'), 'cafes');
      expect(client.queuedCount, 1, reason: 'waiting behind the first send');
      client.dropQueued();
      gate.complete();
      await first;
      expect(h.sent.map((b) => b['merchant_key']), ['HALA BOUTIQUE']);
      expect(client.queuedCount, 0);
    });

    test('each account keeps its own choice on a shared device', () async {
      final h = _Harness(optedIn: false);
      await h.preference.set('uid-b', true);
      h.uid = 'uid-b';
      expect(await h.preference.isOn('uid-b'), isTrue,
          reason: 'uid-a turning it off does not turn it off for uid-b');
      await h.preference.set('uid-b', false);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      h.uid = null; // signed out
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
    });

    test('an account switch between offer and send drops the item', () async {
      final h = _Harness(optedIn: true);
      await h.preference.set('uid-b', true);
      final client = SharedCategoryLearningClient(
        accountUid: () => h.uid,
        optedIn: (uid) async {
          final on = await h.preference.isOn(uid);
          h.uid = 'uid-b'; // switched after the offer-time check
          return on;
        },
        mayEgress: () async => true,
        send: (body) async => h.sent.add(body),
      );
      await client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty,
          reason: "uid-a's contribution is never sent as uid-b");
      expect(client.queuedCount, 0);
    });

    test('turning it ON sends nothing retroactively', () async {
      final h = _Harness();
      // Rules confirmed while OFF.
      await h.client.offer(_tx(), 'shopping');
      await h.client.offer(_tx(merchant: 'OLD CAFE'), 'cafes');
      await h.preference.set('uid-a', true);
      await h.client.flush();
      expect(h.sent, isEmpty);
      // Only a later choice contributes.
      await h.client.offer(_tx(merchant: 'NEW CAFE'), 'cafes');
      expect(h.sent, [
        {'merchant_key': 'NEW CAFE', 'category_key': 'cafes'}
      ]);
    });
  });

  group('consent', () {
    test('Cloud OFF: nothing is sent', () async {
      final h = _Harness(cloud: false, ai: true, optedIn: true);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    test('AI OFF: nothing is sent', () async {
      final h = _Harness(cloud: true, ai: false, optedIn: true);
      await h.client.offer(_tx(), 'shopping');
      expect(h.sent, isEmpty);
      expect(h.client.queuedCount, 0);
    });

    for (final revoked in ['cloud', 'ai']) {
      test(
          '$revoked revoked between enqueue and send: nothing sent, queue '
          'dropped, and a later re-grant does not release it', () async {
        final h = _Harness(optedIn: true)
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
      final h = _Harness(optedIn: true);
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
        final h = _Harness(optedIn: true);
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

  group('withdraw (a learned rule was deleted)', () {
    test('sends only the merchant key and the withdraw action', () async {
      final h = _Harness(optedIn: true);
      // Offered by this account first (review fix R4P-08): a key that was
      // never offered and has no business word is not sent on deletion.
      await h.client.offer(_tx(), 'shopping');
      h.sent.clear();
      await h.client.withdraw('HALA BOUTIQUE 123');
      expect(h.sent, [
        {'merchant_key': 'HALA BOUTIQUE', 'action': 'withdraw'}
      ]);
    });

    test('R4P-08: a rule saved for a person is never sent on deletion',
        () async {
      final h = _Harness(optedIn: true);
      for (final person in [
        'Nadir',
        'Nadir Zaki',
        'NADIR ZAKI',
        'nadir zaki',
        'NADIR ZAKI VIA MADA',
        'نادر زكي',
        'عبد العزيز القحطاني',
        'ACCOUNT OF NADIR ZAKI',
      ]) {
        await h.client.withdraw(person);
      }
      expect(h.sent, isEmpty);
      // The merchant twin: a business by its own words is still withdrawn
      // without having been offered in this session.
      await h.client.withdraw('Example Bookstore');
      await h.client.withdraw('مكتبة المثال');
      expect(h.sent, [
        {'merchant_key': 'EXAMPLE BOOKSTORE', 'action': 'withdraw'},
        {'merchant_key': 'مكتبة المثال', 'action': 'withdraw'},
      ]);
    });

    test('R4P-08: a key offered by another account is not withdrawn',
        () async {
      final h = _Harness(optedIn: true);
      await h.client.offer(_tx(), 'shopping');
      h.sent.clear();
      h.uid = 'uid-b';
      h.prefs[SharedLearningPreference.keyFor('uid-b')] = 'on';
      await h.client.withdraw('HALA BOUTIQUE');
      expect(h.sent, isEmpty);
    });

    test('drops a still-queued offer for the same merchant', () async {
      final gate = Completer<void>();
      final h = _Harness(optedIn: true);
      final sent = <Map<String, String>>[];
      final client = SharedCategoryLearningClient(
        accountUid: () => h.uid,
        optedIn: h.preference.isOn,
        mayEgress: () async => true,
        send: (body) async {
          sent.add(body);
          if (sent.length == 1) await gate.future;
        },
      );
      final first = client.offer(_tx(), 'shopping');
      await Future<void>.delayed(Duration.zero);
      await client.offer(_tx(merchant: 'OTHER SHOP'), 'shopping');
      await client.offer(_tx(merchant: 'NEW CAFE'), 'cafes');
      await client.withdraw('NEW CAFE');
      gate.complete();
      await first;
      expect(sent.map((b) => b['merchant_key']),
          ['HALA BOUTIQUE', 'NEW CAFE', 'OTHER SHOP']);
      expect(sent[1], {'merchant_key': 'NEW CAFE', 'action': 'withdraw'});
    });

    test('nothing leaves the device when sharing would not', () async {
      for (final h in [
        _Harness(optedIn: false),
        _Harness(cloud: false, optedIn: true),
        _Harness(ai: false, optedIn: true),
        _Harness(optedIn: true)..uid = null,
      ]) {
        await h.client.withdraw('HALA BOUTIQUE');
        expect(h.sent, isEmpty);
      }
    });

    test('merchant text that could identify someone is never sent', () async {
      final h = _Harness(optedIn: true);
      for (final raw in ['AB', 'name@mail.com', '0551234567', '12345']) {
        await h.client.withdraw(raw);
      }
      expect(h.sent, isEmpty);
    });

    test('a send failure is swallowed', () async {
      final client = SharedCategoryLearningClient(
        accountUid: () => 'uid-a',
        optedIn: (_) async => true,
        mayEgress: () async => true,
        send: (_) async => throw Exception('offline'),
      );
      await client.withdraw('HALA BOUTIQUE STORE');
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
