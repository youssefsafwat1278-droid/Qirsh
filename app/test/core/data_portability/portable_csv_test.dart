import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';

void main() {
  test('round-trips Arabic, quotes and multiline text with BOM', () {
    final bytes = encodePortableCsv(
      const ['date', 'merchant', 'note'],
      const [
        ['2026-07-18T10:00:00Z', 'مطعم "قرش"', 'سطر أول\nسطر ثان'],
      ],
    );

    expect(bytes.take(3), utf8.encode('\ufeff'));
    final decoded = decodePortableCsv(bytes);
    expect(decoded.rows.single['merchant'], 'مطعم "قرش"');
    expect(decoded.rows.single['note'], 'سطر أول\nسطر ثان');
  });

  test('neutralizes spreadsheet formulas in text cells', () {
    final bytes = encodePortableCsv(
      const ['merchant'],
      const [
        ['=HYPERLINK("bad")'],
      ],
    );
    final decoded = decodePortableCsv(bytes);
    expect(decoded.rows.single['merchant'], startsWith("'="));
  });

  test('a Qirsh package gets back the exact value the escaping changed', () {
    const values = ['-LtBgvXKsE5Fk4k05cnSFA', '=x', '+20', '@a', "'plain", 'ok'];
    final bytes = encodePortableCsv(
      const ['record_id'],
      [for (final v in values) [v]],
    );
    final decoded = unescapePackageCsv(decodePortableCsv(bytes));
    expect([for (final r in decoded.rows) r['record_id']], values);
  });

  test('auto detects semicolon separated files', () {
    final bytes = Uint8List.fromList(
      utf8.encode('Date;Amount;Currency\r\n2026-01-01;12.50;EGP'),
    );
    final decoded = decodePortableCsv(bytes);
    expect(decoded.headers, ['Date', 'Amount', 'Currency']);
    expect(decoded.rows.single['Amount'], '12.50');
  });

  test('guesses Arabic and English transaction columns', () {
    final mapping = guessCsvMapping(
      const ['التاريخ', 'Amount', 'العملة', 'الوصف'],
    );
    expect(mapping, isNotNull);
    expect(mapping!.dateColumn, 'التاريخ');
    expect(mapping.amountColumn, 'Amount');
    expect(mapping.currencyColumn, 'العملة');
    expect(mapping.merchantColumn, 'الوصف');
  });

  test('rejects duplicate headers', () {
    final bytes = Uint8List.fromList(utf8.encode('date,date\n1,2'));
    expect(() => decodePortableCsv(bytes), throwsA(isA<Exception>()));
  });

  test('row errors do not block importing otherwise valid CSV rows', () {
    const preview = ImportPreview(
      sourcePath: '/tmp/sample.csv',
      format: ImportFormat.genericCsv,
      packageId: 'sample',
      totalRows: 2,
      tableCounts: {'transactions': 2},
      issues: [
        ImportIssue(
          severity: ImportIssueSeverity.error,
          message: 'invalid row',
          rowNumber: 2,
        ),
      ],
      canReplace: false,
    );

    expect(preview.hasErrors, isFalse);
  });
}
