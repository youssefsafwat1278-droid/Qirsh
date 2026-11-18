import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/core/auth/immediate_deletion_flow.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/replica_store.dart';
import '../../core/session/fake_account_scope.dart';
import '../../core/session/fake_remove_barrier.dart';
import 'dart:io';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _FakeAccountDeletionService implements AccountDeletionService {
  _FakeAccountDeletionService({this.scheduledAt, this.throwOnRequest = false, this.requestError, this.cancelError});

  DateTime? scheduledAt;
  bool throwOnRequest;
  final Object? requestError;
  final Object? cancelError;
  var requestCalls = 0;
  var cancelCalls = 0;

  @override
  Future<AccountDeletionStatus> getStatus() async {
    return AccountDeletionStatus(scheduledAt: scheduledAt);
  }

  @override
  Future<DateTime?> requestDeletion() async {
    requestCalls += 1;
    if (requestError != null) throw requestError!;
    if (throwOnRequest) throw Exception('boom');
    scheduledAt = DateTime.now().toUtc().add(const Duration(days: 30));
    return scheduledAt;
  }

  @override
  Future<void> cancelDeletion() async {
    cancelCalls += 1;
    if (cancelError != null) throw cancelError!;
    scheduledAt = null;
  }
}

class _NoopDataWipeService implements DataWipeService {
  var wipeCalls = 0;

  @override
  Future<void> wipeAll() async {
    wipeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Publishes an admitted uid and wires the removal flow to a recording queue.
List<String> _wireRemoval() {
  FlutterSecureStorage.setMockInitialValues({'local_data_owner_uid': 'uid-x'});
  final calls = <String>[];
  final scope = FakeAccountScope(calls)..activeUid = 'uid-x';
  final support = Directory.systemTemp.createTempSync('pd_');
  addTearDown(() => support.deleteSync(recursive: true));
  AppSession.instance.configureAccountScope(scope);
  AppSession.instance.configureRemoveData(RemoveDataFlow(
    store: ReplicaStore(appSupportDirectory: support.path),
    scope: scope,
    barrier: FakeRemoveBarrier(calls),
    clearOwnerMarker: AppSession.instance.clearLocalDataOwnerMarker,
    invalidateAdmissionGeneration:
        AppSession.instance.invalidateRemovalGeneration,
    quiesce: AppSession.instance.drainAdmissions,
  ));
  return calls;
}

Widget _app(_FakeAccountDeletionService service, _NoopDataWipeService wipe,
    {bool realDeletionRoute = false}) {
  return ProviderScope(
    overrides: [
      accountDeletionServiceProvider.overrideWithValue(service),
      accountDeletionStatusProvider.overrideWith((_) => service.getStatus()),
      dataWipeServiceProvider.overrideWithValue(wipe),
      // No admitted operation can be captured: the screen must fail honestly.
      immediateDeletionFlowProvider
          .overrideWithValue(const UnavailableDeletionFlow()),
    ],
    // PrivacyScreen reads `context.l10n` (the merchant-personalization choice
    // added in COUPONS Phase 1), so the harness has to supply delegates. Arabic
    // because that is the app's default locale and the screen is RTL there.
    child: MaterialApp.router(
      theme: AppTheme.light,
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const PrivacyScreen()),
        GoRoute(path: '/welcome', builder: (_, __) => const SizedBox()),
        GoRoute(
            path: '/delete-account',
            builder: (_, __) => realDeletionRoute
                ? const DeleteAccountScreen()
                : const Text('delete-account-screen')),
      ]),
    ),
  );
}

Future<void> _tapEnsuringVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  // The reset fence invalidates the admission generation in secure storage first.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('failed cancellation keeps pending deletion visible and shows error without wiping', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final scheduled = DateTime.utc(2026, 8, 14);
    final service = _FakeAccountDeletionService(scheduledAt: scheduled,
        cancelError: StateError('synthetic_cancel_failure'));
    final wipe = _NoopDataWipeService();
    await tester.pumpWidget(_app(service, wipe));
    await tester.pumpAndSettle();
    await _tapEnsuringVisible(tester, find.text(lookupAppL10n(const Locale('ar')).privCancelDeletion).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(lookupAppL10n(const Locale('ar')).privCancelDeletion).last);
    await tester.pumpAndSettle();
    expect(service.cancelCalls, 1);
    expect(service.scheduledAt, scheduled);
    expect(service.requestCalls, 0);
    expect(wipe.wipeCalls, 0);
    expect(find.textContaining('2026-08-14'), findsOneWidget);
    expect(find.text(lookupAppL10n(const Locale('ar')).privCancelFailed), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('pending deletion card shows scheduled date and cancel action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final scheduled = DateTime.utc(2026, 8, 14);
    final service = _FakeAccountDeletionService(scheduledAt: scheduled);
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    expect(find.textContaining('2026-08-14'), findsOneWidget);
    expect(find.text(lookupAppL10n(const Locale('ar')).privCancelDeletion), findsWidgets);
  });

  testWidgets(
      'cancelling a pending deletion calls the service and hides the card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final scheduled = DateTime.utc(2026, 8, 14);
    final service = _FakeAccountDeletionService(scheduledAt: scheduled);
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text(lookupAppL10n(const Locale('ar')).privCancelDeletion).first);
    await tester.pumpAndSettle();
    // Confirmation dialog.
    await tester.tap(find.text(lookupAppL10n(const Locale('ar')).privCancelDeletion).last);
    await tester.pumpAndSettle();

    expect(service.cancelCalls, 1);
    expect(find.textContaining('2026-08-14'), findsNothing);
  });

  testWidgets('no pending-deletion card when nothing is scheduled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService();
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    expect(find.textContaining('لن يُنفَّذ طلب حذف'), findsNothing);
  });

  testWidgets(
      'the delete-account entry opens the dedicated screen and does not '
      'request deletion or touch local data itself', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService();
    final wipe = _NoopDataWipeService();
    final removal = _wireRemoval();
    await tester.pumpWidget(_app(service, wipe));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text('حذف الحساب وكل بياناتي'));
    await tester.pumpAndSettle();

    expect(find.text('delete-account-screen'), findsOneWidget);
    expect(service.requestCalls, 0);
    expect(removal, isEmpty);
    expect(wipe.wipeCalls, 0);
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
  });

  testWidgets(
      'an immediate deletion that cannot start shows an error, wipes nothing and never calls the legacy scheduled route',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService(throwOnRequest: true);
    final wipe = _NoopDataWipeService();
    final removal = _wireRemoval();
    await tester.pumpWidget(_app(service, wipe, realDeletionRoute: true));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text('حذف الحساب وكل بياناتي'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deleteAccountAction')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // No operation could be captured, so there is nothing to confirm.
    expect(find.byKey(const Key('deleteAccountConfirm')), findsNothing);

    expect(service.requestCalls, 0,
        reason: 'the legacy 30-day scheduled route is no longer reachable here');
    expect(removal, isEmpty, reason: 'no local removal after a failed request');
    expect(wipe.wipeCalls, 0);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
    expect(find.text(lookupAppL10n(const Locale('ar')).deleteAccountFailedFinal), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('a legacy-unavailable backend is irrelevant: the screen fails honestly without reset or welcome navigation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800,1400));
    final service=_FakeAccountDeletionService(requestError:const LegacyDeletionUnavailable());
    final wipe=_NoopDataWipeService();final removal=_wireRemoval();
    try{
      final statusBefore=AppSession.instance.status;
      await tester.pumpWidget(_app(service,wipe, realDeletionRoute: true));await tester.pumpAndSettle();
      await _tapEnsuringVisible(tester,find.text('حذف الحساب وكل بياناتي'));
      await tester.pumpAndSettle();await tester.tap(find.byKey(const Key('deleteAccountAction')));
      await tester.pump();await tester.pump(const Duration(milliseconds:300));
      expect(find.byKey(const Key('deleteAccountConfirm')),findsNothing);
      expect(service.requestCalls,0);expect(service.scheduledAt,isNull);
      expect(removal,isEmpty);expect(wipe.wipeCalls,0);
      expect(await tester.runAsync(()=>AppSession.instance.readLocalDataOwnerUid()),'uid-x');
      expect(AppSession.instance.status,statusBefore);
      expect(find.byType(DeleteAccountScreen),findsOneWidget);
      expect(GoRouterState.of(tester.element(find.byType(DeleteAccountScreen))).uri.path,'/delete-account');
      expect(find.text(lookupAppL10n(const Locale('ar')).deleteAccountFailedFinal),findsOneWidget);
      expect(find.textContaining('لن يُنفَّذ طلب حذف'),findsNothing);
    }finally{
      await tester.pump(const Duration(seconds:3));
      await tester.pumpWidget(const SizedBox());await tester.pump();
      AppSession.instance.configureRemoveData(null);AppSession.instance.configureAccountScope(null);
      await tester.binding.setSurfaceSize(null);
    }
  });

}
