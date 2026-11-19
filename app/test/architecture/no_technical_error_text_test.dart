import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner report (iPhone, sign-in cancelled): the banner read
/// «تعذّر تسجيل الدخول. جرب تاني. (E: PlatformException)». Exception names and
/// `(E: …)` reason codes are diagnostics; they belong in the debug log, never
/// in copy a user reads.
///
/// What this can detect (line-based source scan, deliberately simple):
/// - an `(E:` reason-code suffix anywhere in `lib/` Dart code or the ARB copy;
/// - on a single line under `lib/features/`, a `Text(` / toast / SnackBar call
///   that interpolates an error variable (`$e`, `${error}`, `$err`, …) or
///   calls `.toString()` / `.runtimeType` on one.
/// What it cannot: a call split across lines, an error passed through a local
/// variable or a helper, or a raw server message forwarded as a String. Those
/// still need review.
final _uiCall = RegExp(
    r'\b(Text\(|showError\(|showErrorInOverlay\(|AppToast\.show\(|SnackBar\()');
const _names = r'(e|err|error|exception|cause|failure|st|stackTrace)';
final _leak = RegExp(r'\$\{?' + _names + r'\b(?!\w)|\b' + _names +
    r'\.(toString\(\)|runtimeType)');

void main() {
  Iterable<File> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.contains('/l10n/app_localizations'));

  bool isComment(String line) {
    final t = line.trimLeft();
    return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
  }

  test('no (E: …) reason code in user-facing code or copy', () {
    final offenders = <String>[];
    for (final file in dartFiles('lib')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!isComment(lines[i]) && lines[i].contains('(E:')) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    for (final arb in ['lib/l10n/app_en.arb', 'lib/l10n/app_ar.arb']) {
      final map = jsonDecode(File(arb).readAsStringSync()) as Map;
      map.forEach((key, value) {
        if (value is String && value.contains('(E:')) {
          offenders.add('$arb: $key');
        }
      });
    }
    expect(offenders, isEmpty);
  });

  test('no UI call interpolates an error or its type on the same line', () {
    final offenders = <String>[];
    for (final file in dartFiles('lib/features')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (isComment(line)) continue;
        if (_uiCall.hasMatch(line) && _leak.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('the scan sees the pattern it guards against', () {
    for (final sample in [
      r"AppToast.showError(context, '$message $error');",
      r"Text('failed: ${e.toString()}')",
      r"Text(error.toString())",
      r"AppToast.showError(context, '${error.runtimeType}');",
    ]) {
      expect(_uiCall.hasMatch(sample) && _leak.hasMatch(sample), isTrue,
          reason: sample);
    }
    expect(_leak.hasMatch(r"Text('$email')"), isFalse);
  });
}
