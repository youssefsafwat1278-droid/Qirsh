import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/planning_canonical_invariants.dart';
import '../../data/db/planning_cutover.dart';
import '../di/app_providers.dart';
import '../session/account_scope.dart';

/// The provider overrides that bind a provider graph to ONE published
/// writable account scope: its database, its host, its startup facts and the
/// planning cutover state resolved from that database. The root `ProviderScope`
/// (foreground) and the headless cold-start drain's container use the same
/// list, so both build the same services over the same replica.
List<Override> accountScopeProviderOverrides(
    AccountScope scope, AccountScopeHost host) {
  final database = scope.database;
  return [
    appDatabaseProvider.overrideWithValue(database),
    accountScopeHostProvider.overrideWithValue(host),
    startupHasLocalDataProvider.overrideWithValue(scope.hasLocalData),
    // MALI-026 (B8-3 §1/§12) — seed the coordinator with the REAL state
    // resolved from the DB at bootstrap (canonical for fresh v30, unresolved
    // for upgraded-with-data), so P1/P3 behavior is correct from launch.
    planningCutoverCoordinatorProvider.overrideWith(
      (ref) => DbBackedPlanningCutoverCoordinator(
        initialState: scope.planningCutoverState,
        readUserVersion: () async =>
            (await database.customSelect('PRAGMA user_version;').getSingle())
                .read<int>('user_version'),
        readMarker: () async => (await database
                .customSelect(
                    'SELECT planning_cutover_state AS s FROM user_settings;')
                .getSingle())
            .read<int>('s'),
        countCanonicalViolations: () async =>
            (await planningCanonicalViolations(database)).length,
      ),
    ),
  ];
}
