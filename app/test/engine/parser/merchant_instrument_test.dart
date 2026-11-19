import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Round 5 (coordinator follow-up): the user's own card or wallet is not part
/// of the merchant. Shared table with the server
/// (process-ios-sms/merchant_instrument_cases.json).
void main() {
  final cases = ((jsonDecode(File(
                  '../supabase/functions/process-ios-sms/merchant_instrument_cases.json')
              .readAsStringSync()) as Map<String, dynamic>)['cases'] as List)
      .cast<Map<String, dynamic>>();
  const engine = ParserEngine();
  for (final c in cases) {
    test('merchant without the payment instrument: ${c['text']}', () {
      final want = c.containsKey('device') ? c['device'] : c['merchant'];
      final got = engine
          .parse(c['text'] as String, senderId: 'ExampleBank')
          .transaction
          ?.rawMerchant;
      expect(got, want);
    });
  }
}
