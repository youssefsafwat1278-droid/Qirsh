import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/currency_table.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/message_meaning.dart';
import 'package:money_companion/engine/parser/normalizer.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/shared_preview_parser.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';

/// REV-04 — the transaction-state cue lists exist in three places. This test
/// reads the two JSON copies as text and fails when they drift from the Dart
/// source (`TransactionStateCues`):
/// - `process-ios-sms/parser_rules.json` (the server parser): every list must
///   be EQUAL, so server and device apply the same rule to the same words;
/// - `assets/catalog/parser_rules.json` (the Swift + Dart notification
///   preview): `ignoreKeywords` must CONTAIN every declined cue (raw and
///   folded), so a declined message gets the generic notification, never
///   "purchase detected" with an amount.
void main() {
  Map<String, dynamic> read(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  List<String> strings(Object? v) => (v as List).cast<String>();

  group('server rules == Dart cues', () {
    final server = read('../supabase/functions/process-ios-sms/parser_rules.json');
    final pairs = {
      'declinedKeywords': TransactionStateCues.declined,
      // Follow-up 6 (CUE-1): awaited or only attempted operations.
      'stateCueAwaitedWords': TransactionStateCues.awaited,
      'declinedExemptKeywords': TransactionStateCues.creditAction,
      'stateCueMerchantIntroducers': TransactionStateCues.merchantIntroducers,
      'stateCueHypotheticalMarkers': TransactionStateCues.hypotheticalMarkers,
      'stateCueFutureMarkers': TransactionStateCues.futureMarkers,
      'stateCueNegationMarkers': TransactionStateCues.negationMarkers,
      'stateCueMerchantNameWords': TransactionStateCues.merchantNameWords,
      'stateCueTransactionNouns': TransactionStateCues.transactionNouns,
      'stateCueGenericNouns': TransactionStateCues.genericNouns,
      'stateCueReversalWords': TransactionStateCues.reversalWords,
      'stateCuePurchaseNouns': TransactionStateCues.purchaseNouns,
    };
    for (final e in pairs.entries) {
      test(e.key, () => expect(strings(server[e.key]), e.value));
    }

    // LR-04 / LR-05 / NR-01: the server rejects (no AI) on the device's
    // ignore words; its other words, like the device's notice words, count
    // only in a message that names no money movement (moneyKeywords). The
    // two runtimes and both AI candidate validators read the same words.
    test('ignoreKeywords', () {
      expect(strings(server['ignoreKeywords']).toSet(),
          containsAll(ParserEngine.securityIgnoreWords));
      expect(
          ParserEngine.promotionWords,
          containsAll(strings(server['ignoreKeywords'])
              .where((w) => !ParserEngine.securityIgnoreWords.contains(w))));
    });
    test('nonTransactionKeywords', () {
      expect(
          {
            ...strings(server['ignoreKeywords']),
            ...strings(server['nonTransactionKeywords']),
          },
          {
            ...ParserEngine.securityIgnoreWords,
            ...ParserEngine.promotionWords,
            ...ParserEngine.ignoreMarkers,
          });
    });
    // OR-01: account notices, which never silence a message that names an
    // amount with its currency, on either side.
    test('noticeKeywords', () {
      expect(strings(server['noticeKeywords']), ParserEngine.noticeWords);
    });
    test('moneyKeywords', () {
      expect(strings(server['moneyKeywords']), ParserEngine.moneyWords);
    });

    // Round 3 (4.1): meaning before amount reads the same clause words on
    // both sides (message_meaning.dart ↔ process-ios-sms/message_meaning.ts).
    final meaning = server['messageMeaning'] as Map<String, dynamic>;
    final meaningPairs = {
      'otherEventMarkers': MessageMeaning.otherEventMarkers,
      'dueMarkers': MessageMeaning.dueMarkers,
      'futureMarkers': MessageMeaning.futureMarkers,
      'offerMarkers': MessageMeaning.offerMarkers,
      'summaryMarkers': MessageMeaning.summaryMarkers,
      'doneVerbs': MessageMeaning.doneVerbs,
      'tenseMarkers': MessageMeaning.tenseMarkers,
      'ownAccountStrong': MessageMeaning.ownAccountStrong,
      'ownAccountMarkers': MessageMeaning.ownAccountMarkers,
      'explicitOwnTransfer': MessageMeaning.explicitOwnTransfer,
      'cashDepositMarkers': MessageMeaning.cashDepositMarkers,
      'pendingWords': MessageMeaning.pendingWords,
      'abbreviations': MessageMeaning.abbreviations,
      'sourceOfFunds': MessageMeaning.sourceOfFunds,
      'ownDestination': MessageMeaning.ownDestination,
      'futureTense': MessageMeaning.futureTense,
      'rewardMarkers': MessageMeaning.rewardMarkers,
      // Follow-up 3 (SM-01, SM-04).
      'otherEventNouns': MessageMeaning.otherEventNouns,
      'noticeOpeners': MessageMeaning.noticeOpeners,
      'movementLeads': MessageMeaning.movementLeads,
      'debitFlow': DirectionSignal.debitFlow,
      'creditFlow': DirectionSignal.creditFlow,
    };
    test('messageMeaning has exactly the Dart lists', () {
      expect(meaning.keys.toSet(), meaningPairs.keys.toSet());
    });
    for (final e in meaningPairs.entries) {
      test('messageMeaning.${e.key}',
          () => expect(strings(meaning[e.key]), e.value));
    }

    // Round 3 (4.4, V1-031): one currency table on both sides.
    test('currencyTable', () {
      final table = server['currencyTable'] as Map<String, dynamic>;
      expect(strings(table['core']).join('|'),
          Normalizer.isoCurrencyAlternation);
      expect(strings(table['iso']), CurrencyTable.iso);
      expect(
          [for (final f in table['localForms'] as List) strings(f)],
          CurrencyTable.localForms);
    });
  });

  test('preview asset ignores every declined cue', () {
    final asset = read('assets/catalog/parser_rules.json');
    final ignore = strings(asset['ignoreKeywords']).toSet();
    for (final cue in TransactionStateCues.declined) {
      expect(ignore, contains(cue));
      expect(ignore, contains(TransactionStateCues.foldForCues(cue)));
    }
  });

  test('a declined purchase gets the generic preview (REV-04 probe)', () {
    final parser = SharedPreviewParser.fromJsonString(
        File('assets/catalog/parser_rules.json').readAsStringSync());
    final r = parser
        .parse('تم رفض عملية شراء بمبلغ 250.00 ريال لدى CAFE ONE بطاقة **1234');
    expect(r.outcome, PreviewOutcome.ignored);
    expect(r.isHighConfidence, isFalse);
  });
}
