import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _HeldRecovery extends Fake implements AutomaticSessionRecovery {
  final done = Completer<void>();
  int retries = 0;

  @override
  Future<void> quiesced() => done.future;

  /// The production default: the shell's wait is bounded only by this, far
  /// beyond the slow case, so the loader is held until [done] completes.
  @override
  Duration get presentationDeadline => const Duration(seconds: 30);

  @override
  void trigger() {
    retries++;
    AutomaticSessionRecovery.restoringSession.value = true;
  }
}

void main() {
  for (final slow in [false, true]) {
    testWidgets('one recovery loader until completion, slow=$slow',
        (tester) async {
      final previous = AutomaticSessionRecovery.active;
      final recovery = _HeldRecovery();
      AutomaticSessionRecovery.active = recovery;
      addTearDown(() {
        AutomaticSessionRecovery.active = previous;
        AutomaticSessionRecovery.restoringSession.value = false;
      });
      var signIns = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: LocalReadShell(onReconnect: () => signIns++),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AppBootLoader), findsOneWidget);
      if (slow) {
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(AppBootLoader), findsOneWidget,
            reason: 'no 1.5s cutoff while recovery is still running');
        expect(find.byKey(const Key('local_read_reconnect')), findsNothing);
      }
      // Even after the scope starts its handoff, the root presentation remains
      // held through the recovery's final settlement.
      AutomaticSessionRecovery.restoringSession.value = true;
      recovery.done.complete();
      await tester.pump();
      expect(find.byType(AppBootLoader), findsOneWidget);
      AutomaticSessionRecovery.restoringSession.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(AppBootLoader), findsNothing);
      expect(find.text('Offline — read only'), findsNothing);
      expect(find.text('Reconnect'), findsNothing);
      final retry = find.byKey(const Key('session_recovery_retry'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(recovery.retries, 1);
      expect(find.byType(AppBootLoader), findsOneWidget);
      AutomaticSessionRecovery.restoringSession.value = false;
      await tester.pumpAndSettle();
      final signIn = find.byKey(const Key('local_read_reconnect'));
      await tester.ensureVisible(signIn);
      await tester.tap(signIn);
      expect(signIns, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
