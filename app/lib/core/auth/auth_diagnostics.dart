import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../observability/app_diagnostics.dart';

/// Diagnostic only (Beta 1): the last few refresh attempts and recovery stops,
/// kept on this device so a tester can report why a token refresh did not
/// complete. Every entry is built from allowlisted constants, durations and the
/// local time — never a token, digest, user id or email — and is never sent.
class AuthDiagnostics {
  AuthDiagnostics._();

  static const int capacity = 12;
  static const String fileName = 'auth_refresh_diag_v1.json';

  static final ValueNotifier<List<String>> entries =
      ValueNotifier<List<String>>(const []);
  static File? _file;

  /// Loads the persisted entries from [directory] and persists later ones
  /// there. Unreadable or malformed content starts empty.
  static Future<void> attach(Directory directory) async {
    final file = File('${directory.path}/$fileName');
    _file = file;
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          entries.value = [
            for (final e in decoded)
              if (e is String) e,
          ].take(capacity).toList();
        }
      }
    } catch (_) {}
  }

  /// Prepends the local time and the app lifecycle state to [summary]. Never
  /// throws: a diagnostic must not change what its caller does.
  static void add(String summary) {
    AppDiagnostics.record(AppOperation.authentication, AppEventState.pending);
    try {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final time = '${now.month}/${now.day} '
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
      String state;
      try {
        state = WidgetsBinding.instance.lifecycleState?.name ?? '-';
      } catch (_) {
        state = '-';
      }
      final next = ['$time $state $summary', ...entries.value];
      entries.value = next.take(capacity).toList();
      final file = _file;
      if (file != null) {
        unawaited(file
            .writeAsString(jsonEncode(entries.value), flush: true)
            .then((_) {}, onError: (Object _) {}));
      }
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    entries.value = const [];
    _file = null;
  }
}
