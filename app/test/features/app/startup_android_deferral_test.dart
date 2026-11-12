import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/main.dart';

/// A session store that keeps deferring (the pre-fix Android state: no
/// keychain handler, so every load deferred forever).
class _AlwaysDeferredRunner extends BootstrapRunner {
  var calls = 0;

  @override
  Future<AppDatabase> run() async {
    calls += 1;
    throw const BootstrapAuthDeferred('item_unavailable');
  }
}

void main() {
  testWidgets(
      'Android: a deferral that persists ends on the retryable error screen',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final runner = _AlwaysDeferredRunner();
      await tester.pumpWidget(StartupApp(runner: runner));
      await tester.pump();
      for (var i = 0; i < 6 && runner.calls < 5; i++) {
        expect(find.text('Qirsh could not start'), findsNothing);
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
      }
      expect(runner.calls, StartupApp.maxAndroidDeferrals);
      expect(find.text('Qirsh could not start'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // No more automatic retries behind the error screen.
      await tester.pump(const Duration(seconds: 30));
      expect(runner.calls, StartupApp.maxAndroidDeferrals);

      // Retry is the user's: it runs bootstrap again from the loading state.
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(runner.calls, StartupApp.maxAndroidDeferrals + 1);
      expect(find.text('Qirsh could not start'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS: a deferral keeps waiting (before first unlock)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final runner = _AlwaysDeferredRunner();
      await tester.pumpWidget(StartupApp(runner: runner));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
      }
      expect(runner.calls, greaterThan(StartupApp.maxAndroidDeferrals));
      expect(find.text('Qirsh could not start'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
