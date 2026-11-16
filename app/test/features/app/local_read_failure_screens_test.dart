import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

/// The local read screen after automatic recovery stopped: offline (retry and
/// logout, never sign-in), rejected (sign in again), or the generic screen.
class _IdleRecovery extends Fake implements AutomaticSessionRecovery {
  int retries = 0;
  int yields = 0;

  @override
  Future<void> quiesced() async {}

  @override
  Duration get presentationDeadline => const Duration(seconds: 30);

  @override
  void trigger() => retries++;

  @override
  void yieldToExplicitAttempt() => yields++;
}

void main() {
  late _IdleRecovery recovery;
  late int signIns;
  AutomaticSessionRecovery? previous;

  setUp(() {
    previous = AutomaticSessionRecovery.active;
    recovery = _IdleRecovery();
    AutomaticSessionRecovery.active = recovery;
    signIns = 0;
  });

  tearDown(() {
    AutomaticSessionRecovery.active = previous;
    AutomaticSessionRecovery.lastFailure.value = null;
    AutomaticSessionRecovery.restoringSession.value = false;
  });

  Future<void> pumpShell(WidgetTester tester, AsrFailure? failure,
      {Locale locale = const Locale('en')}) async {
    AutomaticSessionRecovery.lastFailure.value = failure;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      locale: locale,
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: LocalReadShell(onReconnect: () => signIns++),
    ));
    await tester.pumpAndSettle();
  }

  final retry = find.byKey(const Key('session_recovery_retry'));
  final signIn = find.byKey(const Key('local_read_reconnect'));
  final logout = find.byKey(const Key('local_read_logout'));

  testWidgets('offline: Try again and Log out, never a sign-in button',
      (tester) async {
    final en = AppL10nEn();
    await pumpShell(tester, AsrFailure.offline);
    expect(find.text(en.sessionRecoveryOfflineTitle), findsOneWidget);
    expect(find.text(en.sessionRecoveryOfflineBody), findsOneWidget);
    expect(retry, findsOneWidget);
    expect(logout, findsOneWidget);
    expect(signIn, findsNothing);
    expect(find.text(en.sessionRecoverySignIn), findsNothing);
    await tester.tap(retry);
    expect(recovery.retries, 1);
  });

  testWidgets('offline in Arabic', (tester) async {
    final ar = AppL10nAr();
    await pumpShell(tester, AsrFailure.offline, locale: const Locale('ar'));
    expect(find.text(ar.sessionRecoveryOfflineTitle), findsOneWidget);
    expect(find.text(ar.startRetry), findsOneWidget);
    expect(find.text(ar.localReadLogout), findsOneWidget);
    expect(find.text(ar.sessionRecoverySignIn), findsNothing);
  });

  testWidgets('rejected: sign in again as the primary action, plus Log out',
      (tester) async {
    final en = AppL10nEn();
    await pumpShell(tester, AsrFailure.rejected);
    expect(find.text(en.sessionRecoveryRejectedTitle), findsOneWidget);
    expect(find.text(en.sessionRecoveryRejectedBody), findsOneWidget);
    expect(retry, findsNothing);
    expect(find.descendant(of: signIn, matching: find.text(en.sessionRecoverySignIn)),
        findsOneWidget);
    expect(tester.widget(signIn), isA<FilledButton>());
    expect(logout, findsOneWidget);
    await tester.tap(signIn);
    expect(signIns, 1);
  });

  for (final failure in [null, AsrFailure.other]) {
    testWidgets('other ($failure): the generic screen is unchanged',
        (tester) async {
      final en = AppL10nEn();
      await pumpShell(tester, failure);
      expect(find.text(en.sessionRecoveryTitle), findsOneWidget);
      expect(find.text(en.sessionRecoveryBody), findsOneWidget);
      expect(retry, findsOneWidget);
      expect(tester.widget(signIn), isA<TextButton>());
      expect(logout, findsOneWidget);
    });
  }

  testWidgets('the screen follows the failure class as it changes',
      (tester) async {
    final en = AppL10nEn();
    await pumpShell(tester, AsrFailure.offline);
    expect(signIn, findsNothing);
    AutomaticSessionRecovery.lastFailure.value = AsrFailure.rejected;
    await tester.pump();
    expect(find.text(en.sessionRecoveryRejectedTitle), findsOneWidget);
    expect(signIn, findsOneWidget);
  });
}
