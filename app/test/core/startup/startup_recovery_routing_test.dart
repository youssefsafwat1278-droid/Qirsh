import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/main.dart';

// The startup error screens after a lock / background trip. Only a positively
// unreadable database may offer the destructive reset (and only behind a
// confirmation); every other failure is the retry screen, retried on resume and
// when protected data becomes available; a timed-out run's late success still
// proceeds, and Retry never starts a second run while one is in flight.

const _failed = 'Qirsh could not start';
const _tookLonger = 'Startup is taking longer than expected';
const _resetTitle = 'We could not open your data';
const _resetButton = 'Reset the data';
const _connection = 'Check your internet connection and try again.';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

/// Throws [outcomes] in order, then succeeds. `lastStep` is `database_open`, the
/// step the owner's failures were reported under.
class _Runner extends BootstrapRunner {
  _Runner(this.outcomes);

  final List<Object> outcomes;
  int runs = 0;
  int resets = 0;

  /// Read by the root only once bootstrap SUCCEEDED (it then publishes it).
  int scopeTaken = 0;
  final available = StreamController<void>.broadcast();
  late final AccountScopeHost _host = AccountScopeHost.uncoordinatedForTesting(
    store: ReplicaStore(appSupportDirectory: Directory.systemTemp.path),
    initialize: (db, uid) async => const AccountScopeInit(),
  );
  late final AppDatabase _db = AppDatabase.createForTesting(
      executor: NativeDatabase.memory(), keyStore: _K());

  @override
  String? get lastStep => 'database_open';

  @override
  Stream<void>? get protectedDataAvailableEvents => available.stream;

  @override
  AccountScopeHost get accountScope {
    scopeTaken++;
    return _host;
  }

  @override
  Future<void> resetDatabaseAndRetry() async => resets++;

  @override
  Future<AppDatabase> run() async {
    runs++;
    if (runs <= outcomes.length) throw outcomes[runs - 1];
    return _db;
  }
}

/// One slow run, joined by every call while it is in flight (the runner's
/// single-flight contract), each call with its own [BootstrapRunner.timeout].
class _SlowRunner extends _Runner {
  _SlowRunner() : super(const []);

  final done = Completer<AppDatabase>();
  Future<AppDatabase>? _inFlight;

  @override
  Future<AppDatabase> run() {
    runs++;
    return (_inFlight ??= done.future).timeout(BootstrapRunner.timeout,
        onTimeout: () =>
            throw const BootstrapTimeoutException('pending_sync_reconcile'));
  }
}

Future<void> _start(WidgetTester tester, BootstrapRunner runner) async {
  await tester.pumpWidget(StartupApp(runner: runner));
  await tester.pump();
  await tester.pump();
}

Future<void> _resume(WidgetTester tester) async {
  final binding = tester.binding;
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
  await tester.pump();
}

void main() {
  final transient = <String, Object Function()>{
    'SQLITE_BUSY (5)': () =>
        SqliteException(extendedResultCode: 5, message: 'database is locked'),
    'SQLITE_LOCKED (6)': () =>
        SqliteException(extendedResultCode: 6, message: 'table is locked'),
    'SQLITE_BUSY_RECOVERY (261)': () =>
        SqliteException(extendedResultCode: 261, message: 'busy'),
    'DatabaseBusyException': () => const DatabaseBusyException(),
    'key unavailable (keychain read error)': () =>
        const LocalDatabaseKeyUnavailableException(),
    'StaleAdmissionException': () => const StaleAdmissionException(),
    'account fence refusal': () => const AccountFenceDeniedException(),
    'coordinator / access refusal': () =>
        const DatabaseAccessUnavailable('coordinator_required'),
    'unknown error': () => StateError('unknown'),
  };

  for (final c in transient.entries) {
    testWidgets('${c.key} at database_open shows the retry screen, not reset',
        (tester) async {
      await _start(tester, _Runner([c.value()]));
      expect(find.text(_failed), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text(_resetTitle), findsNothing);
      expect(find.text(_resetButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a positively unreadable database offers the reset only behind a '
      'confirmation', (tester) async {
    final runner = _Runner([const BootstrapDatabaseUnreadable()]);
    await _start(tester, runner);
    expect(find.text(_resetTitle), findsOneWidget);

    // Permanent: never retried behind the user's back.
    await _resume(tester);
    expect(runner.runs, 1);

    await tester.tap(find.text(_resetButton));
    await tester.pumpAndSettle();
    expect(find.text('Delete the data on this device?'), findsOneWidget);
    expect(
        find.text('Data on this device that is not in the cloud will be '
            'deleted and cannot be recovered.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.resets, 0, reason: 'Cancel deletes nothing');
    expect(find.text(_resetTitle), findsOneWidget);

    await tester.tap(find.text(_resetButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete and reset'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(runner.resets, 1);
    expect(runner.runs, 2, reason: 'bootstrap re-runs after the reset');
    expect(runner.scopeTaken, 1);
    await tester.pumpWidget(const SizedBox());
  });

  test('only SQLite not-a-database (26) / corrupt (11) classify as unreadable',
      () async {
    bool m(int code) => BootstrapDatabaseUnreadable.matches(
        SqliteException(extendedResultCode: code, message: 'x'));
    expect(m(26), isTrue);
    expect(m(11), isTrue);
    expect(m(267), isTrue, reason: 'SQLITE_CORRUPT_VTAB, primary 11');
    for (final code in [5, 6, 261, 262, 10, 14, 1]) {
      expect(m(code), isFalse, reason: 'code $code');
    }
    expect(BootstrapDatabaseUnreadable.matches(StateError('x')), isFalse);
    expect(
        BootstrapDatabaseUnreadable.matches(
            const LocalDatabaseKeyUnavailableException()),
        isFalse);

    // The real error a background encrypted connection raises on a file that
    // is not a database arrives wrapped (DriftRemoteException).
    final dir = Directory.systemTemp.createTempSync('unreadable_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/garbage.sqlite')
      ..writeAsBytesSync(List<int>.generate(8192, (i) => (i * 37 + 11) & 0xFF));
    final db = AppDatabase.createForTesting(
        executor: NativeDatabase.createBackgroundConnection(file),
        keyStore: _K());
    Object? error;
    try {
      await db.customSelect('SELECT count(*) FROM sqlite_master').get();
    } catch (e) {
      error = e;
    }
    await db.close();
    expect(error, isNotNull);
    expect(BootstrapDatabaseUnreadable.matches(error!), isTrue,
        reason: '$error (${error.runtimeType})');
  });

  testWidgets('the retry screen does not blame the internet connection',
      (tester) async {
    await _start(tester, _Runner([const StaleAdmissionException()]));
    expect(find.text(_failed), findsOneWidget);
    expect(find.text(_connection), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stored transient error is retried on resume', (tester) async {
    final runner = _Runner([const StaleAdmissionException()]);
    await _start(tester, runner);
    expect(find.text(_failed), findsOneWidget);
    expect(runner.runs, 1);

    // No retry loop while the app stays in the foreground.
    await tester.pump(const Duration(seconds: 30));
    expect(runner.runs, 1);

    await _resume(tester);
    expect(runner.runs, 2);
    expect(find.text(_failed), findsNothing);
    expect(runner.scopeTaken, 1, reason: 'the successful retry proceeds');

    // Nothing re-runs a finished bootstrap on a later resume.
    await _resume(tester);
    expect(runner.runs, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stored transient error is retried when protected data '
      'becomes available', (tester) async {
    final runner =
        _Runner([const LocalDatabaseKeyUnavailableException()]);
    await _start(tester, runner);
    expect(find.text(_failed), findsOneWidget);

    runner.available.add(null);
    await tester.pump();
    await tester.pump();
    expect(runner.runs, 2);
    expect(find.text(_failed), findsNothing);
    expect(runner.scopeTaken, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after a timeout, the same run finishing later proceeds',
      (tester) async {
    final runner = _SlowRunner();
    await _start(tester, runner);
    await tester.pump(BootstrapRunner.timeout);
    await tester.pump();
    expect(find.text(_tookLonger), findsOneWidget);
    expect(runner.scopeTaken, 0);

    runner.done.complete(runner._db);
    await tester.pump();
    await tester.pump();
    expect(find.text(_tookLonger), findsNothing);
    expect(runner.scopeTaken, 1,
        reason: 'the late success replaced the error without any tap');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Retry while the timed-out run is in flight starts no new run',
      (tester) async {
    final runner = _SlowRunner();
    await _start(tester, runner);
    await tester.pump(BootstrapRunner.timeout);
    await tester.pump();
    expect(find.text(_tookLonger), findsOneWidget);
    final calls = runner.runs;

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(runner.runs, calls, reason: 'Retry joins, it does not call run()');

    runner.done.complete(runner._db);
    await tester.pump();
    await tester.pump();
    expect(find.text(_tookLonger), findsNothing);
    expect(runner.scopeTaken, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
