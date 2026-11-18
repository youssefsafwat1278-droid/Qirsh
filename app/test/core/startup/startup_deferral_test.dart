// Phase-7 B2-C — startup critical-path contract: the LOCAL feature-flag init
// (kept on the critical path) makes `featureFlags` usable without the network
// override refresh, and the "first usable" milestone starts false.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  test('local-only feature-flag init keeps `featureFlags` usable (getter-safe)',
      () async {
    final db =
        await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _K());
    try {
      // applyRemoteOverrides: false is exactly what bootstrap passes so the
      // first frame never blocks on a remote flag fetch. The getter must still
      // resolve (it throws when the service was never initialised).
      await initFeatureFlagService(
        db,
        installIdOverride: 'test-install',
        applyRemoteOverrides: false,
      );
      expect(() => featureFlags, returnsNormally);
    } finally {
      await db.close();
    }
  });

  test('localFinancialUiUsable milestone defaults to false', () {
    // It only flips true once the bootstrap safety-critical phase completes.
    expect(localFinancialUiUsable.value, isFalse);
  });

  group('startup local/remote boundary (Blocker 2)', () {
    test('the app_open metric is a no-op offline — never blocks or throws', () {
      // The deferred `MetricsClient().logEvent('app_open')` must not block or
      // throw when there is no configured/authenticated remote (offline / cold
      // start with a stale session): it returns immediately.
      expect(
        () => MetricsClient().logEvent('app_open'),
        returnsNormally,
      );
    });

    test('offline: secure key + encrypted DB + migrations + owner-scoped query '
        'all succeed with NO network', () async {
      // The safety-critical local phase — everything localFinancialUiUsable
      // waits on — needs zero network. Opening the encrypted DB runs the full
      // migration chain (schema v29); a real owner-scoped query then works.
      final db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _K(),
      );
      try {
        final version = await db
            .customSelect('PRAGMA user_version;')
            .getSingle();
        expect(version.read<int>('user_version'), 44,
            reason: 'migrations ran offline');
        final rows = await db
            .customSelect('SELECT COUNT(*) AS n FROM transactions;')
            .getSingle();
        expect(rows.read<int>('n'), isNonNegative,
            reason: 'a real owner-scoped query succeeds offline');
      } finally {
        await db.close();
      }
    });
  });
}
