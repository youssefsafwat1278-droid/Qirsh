import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two rules that keep the threshold honest.
void main() {
  test('no runtime code decides a budget warning from a constant', () {
    // The number lived in two places before this feature: 0.75 in the alert
    // planner and 0.8 in the progress use case. They disagreed, so a budget
    // could show a warning bar with no alert sent, or the reverse. Both now
    // read `budget.alertThresholdPercent`.
    //
    // Scoped to the two files that own the decision; a threshold comparison
    // reappearing in either is the regression this catches.
    const owners = <String>[
      'lib/domain/services/budget_alert_planner.dart',
      'lib/domain/usecases/budget_progress_usecase.dart',
    ];
    final offenders = <String>[];
    for (final path in owners) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        // `ratio >= 0.75` / `>= .8` — a literal fraction compared against a
        // spend ratio. 1.0 is exempt: "exceeded" is not a preference.
        if (RegExp(r'ratio\s*>=\s*0?\.\d').hasMatch(line)) {
          offenders.add('$path:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these warn at a hardcoded fraction instead of the budget\'s '
            'own alertThresholdPercent:\n  ${offenders.join("\n  ")}');
  });

  test('budget threshold is included in all sync builders after migration', () {
    for (final path in [
      'lib/features/planning_sync/services/planning_outbox_queue.dart',
      'lib/features/planning_sync/services/planning_push_service.dart',
      'lib/features/planning_sync/services/planning_primary_backfill_service.dart',
    ]) {
      expect(File(path).readAsStringSync(), contains("'alert_threshold_percent':"));
    }
    expect(File('../supabase/migrations/20261110044549_budget_alert_threshold_sync.sql')
      .readAsStringSync(), contains('ADD COLUMN IF NOT EXISTS alert_threshold_percent'));
  });
}
