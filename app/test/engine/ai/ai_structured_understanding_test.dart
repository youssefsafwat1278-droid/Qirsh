// Owner brief 4.2-4.4 on the device: structured answers, the request context
// and currency from a matched account. Server answers are SYNTHETIC JSON; no
// model is called.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

final _ref = DateTime.utc(2026, 6, 16, 12);
const _validator = AiCandidateValidator();

AiParseResponse _answer({
  double amount = 45,
  String amountText = '45.00',
  String currency = 'SAR',
  String? messageType,
  String? status,
}) =>
    AiParseResponse(
      amount: amount,
      amountText: amountText,
      currency: currency,
      type: 'payment',
      direction: 'debit',
      messageType: messageType,
      status: status,
    );

AiCandidateValidation _check(AiParseResponse r, String text,
        {String? accountCurrency}) =>
    _validator.validate(
      response: r,
      sanitizedText: text,
      localParsed: null,
      referenceTime: _ref,
      messageText: text,
      normalizedType: TransactionType.payment,
      accountCurrency: accountCurrency,
    );

void main() {
  const purchase = 'Purchase of SAR 45.00 at Test Diner with card *4521.';

  group('structured status (4.2)', () {
    test('a completed transaction answer is accepted', () {
      expect(
          _check(_answer(messageType: 'transaction', status: 'completed'),
                  purchase)
              .accepted,
          isTrue);
    });

    for (final status in ['pending', 'declined', 'failed', 'scheduled', 'unknown']) {
      test('status $status is never a transaction', () {
        final v = _check(_answer(status: status), purchase);
        expect(v.rejectionReason, 'status_not_completed');
      });
    }

    for (final type in ['bill_or_reminder', 'balance_or_limit_notice', 'ambiguous']) {
      test('message type $type is never a transaction', () {
        final v = _check(_answer(messageType: type), purchase);
        expect(v.rejectionReason, 'message_type_not_transaction');
      });
    }

    test('an older server without the fields is judged as before', () {
      expect(_check(_answer(), purchase).accepted, isTrue);
    });
  });

  group('V1-086 (RR-03): a notice footer next to a completed movement', () {
    test('authorised purchase + credit-limit line is accepted', () {
      expect(
          _check(
                  _answer(),
                  'Card *4521 authorised SAR 45.00 at Test Diner. '
                  'Credit limit: SAR 20,000')
              .accepted,
          isTrue);
    });

    test('the notice that carries the amount is still rejected', () {
      expect(
          _check(_answer(amount: 20000, amountText: '20000'),
                  'Your credit limit is now SAR 20000. Card *4521 authorised')
              .rejectionReason,
          'not_a_transaction');
    });

    test('an OTP line keeps the message out', () {
      expect(
          _check(
                  _answer(),
                  'Card *4521 authorised SAR 45.00. '
                  'OTP 482913 is your activation code')
              .accepted,
          isFalse);
    });
  });

  group('currency from a matched account (4.4)', () {
    const noCurrency = 'Purchase of 45.00 at Test Diner from account 1234';

    test('accepted only with the matched account currency, and flagged', () {
      final v = _check(_answer(), noCurrency, accountCurrency: 'SAR');
      expect(v.accepted, isTrue);
      expect(v.currencyFromAccount, isTrue);
    });

    test('an AI guess with no account context is rejected', () {
      expect(_check(_answer(), noCurrency).rejectionReason,
          'currency_not_grounded');
    });

    test('a different currency than the account is rejected', () {
      expect(
          _check(_answer(currency: 'EGP'), noCurrency, accountCurrency: 'SAR')
              .rejectionReason,
          'currency_not_grounded');
    });

    test('a currency named in the text contradicts the account context', () {
      expect(
          _check(_answer(), '$noCurrency. Fee USD 1.00',
                  accountCurrency: 'SAR')
              .rejectionReason,
          'currency_not_grounded');
    });

    test('a grounded currency is not flagged as inferred', () {
      final v = _check(_answer(), purchase, accountCurrency: 'SAR');
      expect(v.accepted, isTrue);
      expect(v.currencyFromAccount, isFalse);
    });
  });

  group('client request context and response fields', () {
    SupabaseAiParserClient client(http.Client c) => SupabaseAiParserClient(
          edgeFunctionUrl: 'https://x.test/functions/v1/parse-sms',
          getAnonJwt: () async => 'anon-jwt',
          httpClient: c,
        );

    test('sends local evidence and account currency as optional fields',
        () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({
              'is_transaction': true,
              'amount': 45,
              'amount_text': '45.00',
              'currency': 'SAR',
              'message_type': 'transaction',
              'status': 'completed',
              'currency_source': 'account_context',
              'model_used': 'gemini-3.8-flash',
              'prompt_version': 'sms-understanding-v2',
            }),
            200);
      });
      final r = await client(mock).parseWithContext(
        sanitizedSms: 'Purchase of 45.00 at Test Diner',
        senderId: 'BANK',
        installId: 'install-1',
        context: const AiParseContext(
            localAmountText: '45.00',
            localDirection: 'debit',
            accountCurrency: 'SAR'),
      );
      expect(sent['local_evidence'],
          {'amount_text': '45.00', 'direction': 'debit'});
      expect(sent['account_currency'], 'SAR');
      expect(sent['analysis_mode'], 'ai_primary_v1');
      expect(sent.containsKey('sender_id'), isFalse);
      expect(r!.messageType, 'transaction');
      expect(r.status, 'completed');
      expect(r.currencySource, 'account_context');
      expect(r.promptVersion, 'sms-understanding-v2');
    });

    test('plain parse sends no context fields (unchanged request)', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'is_transaction': false}), 200);
      });
      await client(mock).parse(
          sanitizedSms: 'x', senderId: 'BANK', installId: 'install-1');
      expect(sent.containsKey('local_evidence'), isFalse);
      expect(sent.containsKey('account_currency'), isFalse);
    });

    test('a not-completed verdict from the new server is "no transaction"',
        () async {
      final mock = MockClient((req) async => http.Response(
          jsonEncode({
            'is_transaction': false,
            'message_type': 'pending_or_scheduled',
            'status': 'pending',
            'model_used': 'gemini-3.8-flash',
            'prompt_version': 'sms-understanding-v2',
          }),
          200));
      expect(
          await client(mock).parse(
              sanitizedSms: 'x', senderId: 'BANK', installId: 'install-1'),
          isNull);
    });
  });
}
