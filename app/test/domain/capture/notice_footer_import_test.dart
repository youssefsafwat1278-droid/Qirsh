// V1-086 (RR-03) on the iOS import gate: a server row validated by the AI
// candidate validator is not sent to review again only because an unrelated
// account-notice line sits next to the completed movement. The notice that
// carries the amount is still a contradiction. Synthetic messages.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';

void main() {
  test('an authorised purchase with a credit-limit footer is not contradicted',
      () {
    expect(
        localParseContradictsServer(
            text: 'Card *4521 authorised SAR 45.00 at Test Diner. '
                'Credit limit: SAR 20,000',
            direction: 'debit',
            type: 'payment',
            amount: 45),
        isFalse);
  });

  test('an approved purchase with an e-statement line is not contradicted', () {
    expect(
        localParseContradictsServer(
            text: 'Test Diner: SAR 45.00 approved on card *4521\n'
                'Your e-statement is available',
            direction: 'debit',
            type: 'payment',
            amount: 45),
        isFalse);
  });

  test('a credit-limit notice that carries the amount is still contradicted',
      () {
    expect(
        localParseContradictsServer(
            text: 'Your credit limit is now SAR 20,000. Card *4521 authorised',
            direction: 'debit',
            type: 'payment',
            amount: 20000),
        isTrue);
  });

  test('without a server amount the whole text is judged, as before', () {
    expect(
        localParseContradictsServer(
            text: 'Card *4521 authorised SAR 45.00 at Test Diner. '
                'Credit limit: SAR 20,000',
            direction: 'debit',
            type: 'payment'),
        isTrue);
  });
}
