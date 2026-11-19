// Round 5: the frozen privacy acceptance set (tools/acceptance/
// privacy_cases.jsonl). The device must give the server's text byte for byte
// (privacy_acceptance_expected.json, written by the Deno test), send no
// `must_not` substring and keep every `must_keep` substring; a merchant row's
// merchant must not be reported as masked, so an enabled saved category rule
// and shared learning still see it, while a person row's name is.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/privacy/sanitization_edit_map.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';

const _dir = '../tools/acceptance';

void main() {
  final cases = File('$_dir/privacy_cases.jsonl')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();
  final expected = (jsonDecode(
          File('$_dir/privacy_acceptance_expected.json').readAsStringSync())
      as Map<String, dynamic>);

  test('the device sends the server text, nothing forbidden, nothing lost',
      () {
    expect(cases.length, greaterThanOrEqualTo(400));
    final failures = <String>[];
    for (final c in cases) {
      final id = c['id'] as String;
      final text = c['text'] as String;
      final out = SmsSanitizer.sanitize(text);
      if (out != expected[id]) {
        failures.add('$id: ${jsonEncode(out)} != ${jsonEncode(expected[id])}');
      }
      if (sanitizeWithMap(text).text != out) failures.add('$id: edit map');
      for (final s in (c['must_not'] as List).cast<String>()) {
        if (out.contains(s)) failures.add('$id: sent "$s"');
      }
      for (final s in (c['must_keep'] as List).cast<String>()) {
        if (!out.contains(s)) failures.add('$id: lost "$s"');
      }
    }
    expect(failures, isEmpty);
  });

  test('paired cases: the merchant survives for its rule, the person does not',
      () {
    final failures = <String>[];
    var merchants = 0;
    var people = 0;
    for (final c in cases) {
      final text = c['text'] as String;
      final merchant = c['merchant'] as String?;
      if (merchant != null) {
        merchants++;
        if (SmsSanitizer.masksPartOf(text, merchant)) {
          failures.add('${c['id']}: merchant "$merchant" masked');
        }
      } else if (c['pair'] != null) {
        people++;
        final name = (c['must_not'] as List).cast<String>().join(' ');
        if (!SmsSanitizer.masksPartOf(text, name)) {
          failures.add('${c['id']}: person "$name" not masked');
        }
      }
    }
    expect(merchants, greaterThanOrEqualTo(40));
    expect(people, greaterThanOrEqualTo(6));
    expect(failures, isEmpty);
  });
}
