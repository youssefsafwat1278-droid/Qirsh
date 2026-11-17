import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// DATA-04 — a year-less SMS date must never land in the future relative to
/// the processing time. Synthetic data.
void main() {
  const engine = ParserEngine();

  DateTime? occurredAt(String dayMonth, DateTime now) => engine
      .parse(
        'Purchase EGP 20.00 at SHELL on $dayMonth at 11:50 PM card 1234',
        senderId: 'IPN',
        defaultCurrency: 'EGP',
        now: now,
      )
      .transaction
      ?.occurredAt;

  test('31/12 processed on 17 Nov resolves to the previous year', () {
    expect(occurredAt('31/12', DateTime(2026, 11, 17, 10)),
        DateTime(2025, 12, 31, 23, 50));
  });

  test('31/12 processed just after New Year resolves to the previous year', () {
    expect(occurredAt('31/12', DateTime(2027, 1, 1, 0, 5)),
        DateTime(2026, 12, 31, 23, 50));
  });

  test('01/01 processed on 1 Jan stays in the current year', () {
    expect(occurredAt('01/01', DateTime(2027, 1, 1, 9)),
        DateTime(2027, 1, 1, 23, 50));
  });

  test('a date earlier this year keeps the current year', () {
    expect(occurredAt('15/03', DateTime(2026, 11, 17)),
        DateTime(2026, 3, 15, 23, 50));
  });

  test('a date within one day ahead (skew) keeps the current year', () {
    expect(occurredAt('18/11', DateTime(2026, 11, 18, 1)),
        DateTime(2026, 11, 18, 23, 50));
  });
}
