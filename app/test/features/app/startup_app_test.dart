import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/main.dart';

class _ImmediateFailureRunner extends BootstrapRunner {
  var calls = 0;

  @override
  Future<AppDatabase> run() async {
    calls += 1;
    throw StateError('test bootstrap failure');
  }
}

void main() {
  testWidgets('paints the startup spinner before bootstrap can replace it',
      (tester) async {
    final runner = _ImmediateFailureRunner();

    await tester.pumpWidget(StartupApp(runner: runner));

    // `StartupApp` builds its own MaterialApp and now carries the localization
    // delegates, so it resolves against the DEVICE locale — the saved language
    // lives in the database, which is exactly what has not opened yet. The
    // test binding's locale is en-US, so this is the English copy. The strings
    // came from hardcoded Arabic literals before, which is why this test could
    // not tell the two builds apart.
    expect(find.byKey(const Key('qirsh_stable_loader')), findsOneWidget);
    expect(find.text('Qirsh could not start'), findsNothing);
    expect(runner.calls, 1);

    await tester.pump();

    expect(find.byKey(const Key('qirsh_stable_loader')), findsNothing);
    expect(find.text('Qirsh could not start'), findsOneWidget);
  });

  swapStateTests();
}

// D2/WP-7 — while a rebootstrap swap is in flight no scope is published and the
// root shows "Updating your data…", never the signed-out routes.
class _SwapHost extends AccountScopeHost {
  _SwapHost()
      : super.uncoordinatedForTesting(
          store: ReplicaStore(
              appSupportDirectory: Directory.systemTemp.path),
          initialize: (db, uid) async => const AccountScopeInit(),
        );

  @override
  AccountScope? get current => null;

  @override
  bool get swapInProgress => true;
}

class _SwapRunner extends BootstrapRunner {
  final _host = _SwapHost();

  @override
  AccountScopeHost get accountScope => _host;

  @override
  Future<AppDatabase> run() async => AppDatabase.open(executor: NativeDatabase.memory());
}

void swapStateTests() {
  testWidgets('swap in flight shows the loading state, not the signed-out UI',
      (tester) async {
    await tester.pumpWidget(StartupApp(runner: _SwapRunner()));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('qirsh_stable_loader')), findsOneWidget);
    expect(find.text('Getting Qirsh ready…'), findsNothing);
  });

  testWidgets('loading state in Arabic', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('ar')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(StartupApp(runner: _SwapRunner()));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('qirsh_stable_loader')), findsOneWidget);
  });
}
