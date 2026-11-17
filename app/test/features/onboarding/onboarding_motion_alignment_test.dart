import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _RecordingBackupService implements BackupService {
  int prepareCalls = 0;
  int commitCalls = 0;

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async {
    prepareCalls++;
    return RestorePlan(
      operationId: 'op',
      envelopeVersion: 3,
      snapshotSchemaVersion: 3,
      sourceFingerprint: 'fp',
      tables: const {},
      warnings: const [],
    );
  }

  @override
  Future<RestoreResult> commitRestore(
      {required RestoreConfirmation confirmation}) async {
    commitCalls++;
    return const RestoreResult(RestoreOutcome.success, operationId: 'op');
  }

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => true;
  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}
  @override
  Future<BackupStatus> status() async => const BackupStatus(enabled: false);
  @override
  Future<bool> hasRemoteBackup() async => false;
  @override
  Future<String> enable({required String passphrase}) async => 'X';
  @override
  Future<void> backupNow() async {}
  @override
  Future<void> disable() async {}
  @override
  Future<void> deleteRemoteBackups() async {}
}

// UX-17: the restore prompt's illustration does not animate under Reduce
// Motion. UX-18: the brand tagline is centred like the title when it wraps.
void main() {
  testWidgets('restore illustration is static under Reduce Motion',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => const RestorePromptScreen(onboardingFlow: false)),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        backupServiceProvider.overrideWithValue(_RecordingBackupService())
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        routerConfig: router,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final art = find.byWidgetPredicate(
        (w) => w is QirshIllustration && w.name == 'dataTransfer');
    expect(art, findsOneWidget);
    expect(find.ancestor(of: art, matching: find.byType(Animate)), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final language in ['en', 'ar']) {
    testWidgets('brand tagline is centred ($language)', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: const TextScaler.linear(1.25)),
            child: child!),
        home: const OnboardingBrandScreen(),
      ));
      await tester.pumpAndSettle();
      final l10n =
          AppL10n.of(tester.element(find.byType(OnboardingBrandScreen)));
      expect(tester.widget<Text>(find.text(l10n.brandTagline)).textAlign,
          TextAlign.center);
      expect(tester.takeException(), isNull);
    });
  }
}
