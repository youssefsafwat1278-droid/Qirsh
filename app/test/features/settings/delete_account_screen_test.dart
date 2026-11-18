import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/auth/immediate_deletion_flow.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../core/session/fake_account_scope.dart';
import '../../core/session/fake_remove_barrier.dart';

/// Drives the screen without the platform, network or a real gateway. The real
/// challenge/Apple/request/local-removal chain is covered against the real
/// gateway in core/auth/immediate_deletion_flow_test.dart.
class _Session implements DeletionFlowSession {
  _Session(this.flow);
  final _Flow flow;
  final confirms = <Completer<DeletionFlowResult>>[];
  final checks = <Completer<DeletionFlowResult>>[];
  final cleanups = <Completer<DeletionFlowResult>>[];
  int closed = 0;

  @override
  Future<DeletionFlowResult> confirm() {
    final c = Completer<DeletionFlowResult>();
    confirms.add(c);
    flow.events.add('confirm');
    return c.future;
  }

  @override
  Future<DeletionFlowResult> checkStatus() {
    final c = Completer<DeletionFlowResult>();
    checks.add(c);
    flow.events.add('check');
    return c.future;
  }

  @override
  Future<DeletionFlowResult> retryLocalCleanup() {
    final c = Completer<DeletionFlowResult>();
    cleanups.add(c);
    return c.future;
  }

  @override
  void close() {
    closed++;
    flow.events.add('close');
  }
}

class _Flow implements ImmediateDeletionFlow {
  _Flow({this.beginReturns = true});
  bool beginReturns;
  _Session? existing;
  final events = <String>[];
  final sessions = <_Session>[];
  int begins = 0;
  int resumes = 0;
  _Session? cleanupExisting;

  @override
  Future<DeletionFlowSession?> begin() async {
    begins++;
    events.add('begin');
    if (!beginReturns) return null;
    final s = _Session(this);
    sessions.add(s);
    return s;
  }

  @override
  Future<DeletionFlowSession?> resume() async {
    resumes++;
    events.add('resume');
    return existing;
  }

  // Not recorded in [events]: the pre-existing event assertions stay exact.
  @override
  Future<DeletionFlowSession?> resumeLocalCleanup() async => cleanupExisting;
}

final _en = lookupAppL10n(const Locale('en'));

/// Real removal flow wired to fakes: ANY global reset/sign-out the screen did
/// would be recorded here. The screen must never cause one itself.
List<String> _wireRemoval() {
  FlutterSecureStorage.setMockInitialValues({'local_data_owner_uid': 'uid-x'});
  final calls = <String>[];
  final scope = FakeAccountScope(calls)..activeUid = 'uid-x';
  final support = Directory.systemTemp.createTempSync('del_');
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
  addTearDown(() {
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
  });
  return calls;
}

Widget _app(_Flow flow,
        {String locale = 'en', void Function()? onCompleted}) =>
    ProviderScope(
      overrides: [
        immediateDeletionFlowProvider.overrideWithValue(flow),
        deleteAccountAfterCompletionProvider
            .overrideWithValue(onCompleted ?? () {}),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        locale: Locale(locale),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (_, __) => const DeleteAccountScreen()),
          GoRoute(path: '/welcome', builder: (_, __) => const SizedBox()),
        ]),
      ),
    );

Future<void> _open(WidgetTester tester, _Flow flow,
    {String locale = 'en',
    void Function()? onCompleted,
    bool settle = true}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(flow, locale: locale, onCompleted: onCompleted));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A resumed status check shows an endless spinner: pump, never settle.
    await tester.pump();
    await tester.pump();
  }
}

Future<void> _tapAction(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('deleteAccountAction')));
  await tester.pumpAndSettle();
}

Future<void> _startAndConfirm(WidgetTester tester) async {
  await _tapAction(tester);
  await tester.tap(find.byKey(const Key('deleteAccountConfirm')));
  await tester.pump();
}

Future<void> _settle(WidgetTester tester, Completer<DeletionFlowResult> c,
    DeletionFlowResult result) async {
  c.complete(result);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('one clear action; opening only looks for an existing operation',
      (tester) async {
    final flow = _Flow();
    await _open(tester, flow);
    expect(find.byKey(const Key('deleteAccountAction')), findsOneWidget);
    expect(flow.events, ['resume'], reason: 'no begin, no confirm, no network');
    expect(flow.begins, 0);
  });

  testWidgets(
      'the operation is captured BEFORE the confirmation dialog; the dialog '
      'says permanent, final and Apple and does not promise immediate '
      'completion (decision 3.4); cancelling releases it and sends nothing',
      (tester) async {
    final flow = _Flow();
    await _open(tester, flow);
    await _tapAction(tester);
    expect(flow.events, ['resume', 'begin'], reason: 'captured before dialog');
    expect(find.text(_en.deleteAccountConfirmBody), findsOneWidget);
    final body = _en.deleteAccountConfirmBody.toLowerCase();
    expect(body, contains('permanent'));
    expect(body, contains('cannot be undone'));
    expect(body, contains('apple'));
    final intro = _en.deleteAccountIntro.toLowerCase();
    expect(intro, contains('apple'));
    // Decision 3.4: the server work is asynchronous, so no copy may promise
    // that it is already complete or happens immediately; no undo period.
    for (final text in [body, intro]) {
      expect(text, isNot(contains('immediate')));
      expect(text, isNot(contains('30 days')));
    }
    final ar = lookupAppL10n(const Locale('ar'));
    expect(ar.deleteAccountConfirmBody, contains('Apple'));
    expect(ar.deleteAccountIntro, contains('Apple'));
    for (final text in [ar.deleteAccountConfirmBody, ar.deleteAccountIntro]) {
      expect(text, isNot(contains('على الفور')));
      expect(text, isNot(contains('30')));
    }
    // An accepted (still running) deletion is final: no offer to cancel it.
    expect(_en.deleteAccountAcceptedBody.toLowerCase(),
        contains('cannot be cancelled'));
    expect(_en.deleteAccountAcceptedBody.toLowerCase(),
        isNot(contains('you can check or cancel')));
    expect(ar.deleteAccountAcceptedBody, contains('لا يمكن إلغاؤه'));
    expect(ar.deleteAccountAcceptedBody, isNot(contains('أو إلغاؤه')));
    await tester.tap(find.text(_en.commonCancel));
    await tester.pumpAndSettle();
    expect(flow.events, ['resume', 'begin', 'close']);
    expect(flow.sessions.single.confirms, isEmpty);
    expect(find.byKey(const Key('deleteAccountProgress')), findsNothing);
  });

  testWidgets('confirming runs the captured session once and shows progress',
      (tester) async {
    final removal = _wireRemoval();
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    expect(flow.events, ['resume', 'begin', 'confirm']);
    expect(find.byKey(const Key('deleteAccountProgress')), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
    // The action cannot be fired again while it runs.
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('deleteAccountAction')));
    expect(button.onPressed, isNull);
  });

  testWidgets('Apple cancel returns the screen to idle with nothing shown or reset',
      (tester) async {
    final removal = _wireRemoval();
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    await _settle(
        tester, flow.sessions.single.confirms.single, const DeletionFlowCancelled());
    expect(find.byKey(const Key('deleteAccountProgress')), findsNothing);
    expect(find.text(_en.deleteAccountFailed), findsNothing);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
    // A later attempt is a fresh capture.
    await _startAndConfirm(tester);
    expect(flow.begins, 2);
  });

  group('refusals and non-final outcomes never succeed and never reset', () {
    final cases = <(String, DeletionFlowResult, Key, String)>[
      (
        'pending',
        const DeletionFlowPending(),
        const Key('deleteAccountPending'),
        _en.deleteAccountPendingBody
      ),
      (
        'unconfirmed',
        const DeletionFlowUnconfirmed(canCheckStatus: true),
        const Key('deleteAccountUnconfirmed'),
        _en.deleteAccountUnconfirmed
      ),
      (
        'unconfirmed (stale)',
        const DeletionFlowUnconfirmed(canCheckStatus: false),
        const Key('deleteAccountUnconfirmed'),
        _en.deleteAccountUnconfirmedStale
      ),
      (
        'admin blocked',
        const DeletionFlowAdminBlocked(),
        const Key('deleteAccountAdminBlocked'),
        _en.deleteAccountAdminBlocked
      ),
      (
        'rate limited',
        const DeletionFlowRateLimited(),
        const Key('deleteAccountRateLimited'),
        _en.deleteAccountRateLimited
      ),
      (
        'local cleanup pending',
        const DeletionFlowLocalCleanupPending(),
        const Key('deleteAccountLocalCleanupPending'),
        _en.deleteAccountLocalCleanupPending
      ),
    ];
    for (final c in cases) {
      testWidgets(c.$1, (tester) async {
        final removal = _wireRemoval();
        var navigated = 0;
        final flow = _Flow();
        await _open(tester, flow, onCompleted: () => navigated++);
        await _startAndConfirm(tester);
        await _settle(tester, flow.sessions.single.confirms.single, c.$2);
        expect(find.byKey(c.$3), findsOneWidget);
        expect(find.text(c.$4), findsOneWidget);
        expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
        expect(removal, isEmpty, reason: 'no global reset or sign-out');
        expect(navigated, 0);
      });
    }

    testWidgets('pending says "not deleted yet" and Check status re-checks '
        'the same operation without a new request', (tester) async {
      final flow = _Flow();
      await _open(tester, flow);
      await _startAndConfirm(tester);
      final session = flow.sessions.single;
      await _settle(tester, session.confirms.single, const DeletionFlowPending());
      expect(_en.deleteAccountPendingBody.toLowerCase(), contains('not deleted yet'));
      await tester.tap(find.byKey(const Key('deleteAccountCheckStatus')));
      await tester.pump();
      expect(session.checks, hasLength(1));
      expect(session.confirms, hasLength(1));
      expect(flow.begins, 1);
    });

    testWidgets('a stale (non-checkable) unknown offers no Check status',
        (tester) async {
      final flow = _Flow();
      await _open(tester, flow);
      await _startAndConfirm(tester);
      await _settle(tester, flow.sessions.single.confirms.single,
          const DeletionFlowUnconfirmed(canCheckStatus: false));
      expect(find.byKey(const Key('deleteAccountCheckStatus')), findsNothing);
    });

    testWidgets('local cleanup pending states the server deletion and offers no '
        'false success or retry', (tester) async {
      final flow = _Flow();
      await _open(tester, flow);
      await _startAndConfirm(tester);
      await _settle(tester, flow.sessions.single.confirms.single,
          const DeletionFlowLocalCleanupPending());
      expect(_en.deleteAccountLocalCleanupPending, contains('deleted from our servers'));
      expect(find.byKey(const Key('deleteAccountRetry')), findsNothing);
      expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    });
  });

  testWidgets('a retryable failure shows Retry that re-runs the SAME captured '
      'session; local data is untouched', (tester) async {
    final removal = _wireRemoval();
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    final session = flow.sessions.single;
    await _settle(
        tester, session.confirms.single, const DeletionFlowFailed(retryable: true));
    expect(find.text(_en.deleteAccountFailed), findsOneWidget);
    expect(removal, isEmpty);
    await tester.tap(find.byKey(const Key('deleteAccountRetry')));
    await tester.pump();
    expect(session.confirms, hasLength(2));
    expect(flow.begins, 1);
  });

  testWidgets('a non-retryable failure offers no Retry', (tester) async {
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    await _settle(tester, flow.sessions.single.confirms.single,
        const DeletionFlowFailed(retryable: false));
    expect(find.text(_en.deleteAccountFailedFinal), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountRetry')), findsNothing);
  });

  testWidgets('a thrown error is an unconfirmed outcome, never success',
      (tester) async {
    final removal = _wireRemoval();
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    flow.sessions.single.confirms.single.completeError(StateError('boom'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deleteAccountUnconfirmed')), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
  });

  testWidgets('no admitted account / begin fails: honest final failure, nothing runs',
      (tester) async {
    final removal = _wireRemoval();
    final flow = _Flow(beginReturns: false);
    await _open(tester, flow);
    await _tapAction(tester);
    expect(find.text(_en.deleteAccountConfirmTitle), findsNothing,
        reason: 'no dialog without a captured operation');
    expect(find.text(_en.deleteAccountFailedFinal), findsOneWidget);
    expect(removal, isEmpty);
  });

  testWidgets(
      'Completed shows success and navigates; the screen itself performs NO '
      'global reset or sign-out (the flow already removed the original replica)',
      (tester) async {
    final removal = _wireRemoval();
    var navigated = 0;
    final flow = _Flow();
    await _open(tester, flow, onCompleted: () => navigated++);
    await _startAndConfirm(tester);
    await tester.pump();
    expect(navigated, 0);
    await _settle(tester, flow.sessions.single.confirms.single,
        const DeletionFlowCompleted());
    expect(find.byKey(const Key('deleteAccountSuccess')), findsOneWidget);
    expect(navigated, 1);
    expect(removal, isEmpty,
        reason: 'resetAllLocalData/sign-out is not reachable from this screen');
  });

  group('restart recovery', () {
    testWidgets('an existing operation is resumed by status on open; no new '
        'operation, dialog or confirm', (tester) async {
      final removal = _wireRemoval();
      final flow = _Flow();
      flow.existing = _Session(flow);
      await _open(tester, flow, settle: false);
      expect(flow.events, ['resume', 'check']);
      expect(flow.begins, 0);
      expect(find.byKey(const Key('deleteAccountProgress')), findsOneWidget);
      await _settle(tester, flow.existing!.checks.single, const DeletionFlowPending());
      expect(find.byKey(const Key('deleteAccountPending')), findsOneWidget);
      expect(removal, isEmpty);
      // Delete is blocked while a deletion is pending (no duplicate operation).
      final button = tester
          .widget<FilledButton>(find.byKey(const Key('deleteAccountAction')));
      expect(button.onPressed, isNull);
    });

    testWidgets('a resumed operation that completes shows success and navigates',
        (tester) async {
      var navigated = 0;
      final flow = _Flow();
      flow.existing = _Session(flow);
      await _open(tester, flow, onCompleted: () => navigated++, settle: false);
      await _settle(tester, flow.existing!.checks.single, const DeletionFlowCompleted());
      expect(find.byKey(const Key('deleteAccountSuccess')), findsOneWidget);
      expect(navigated, 1);
    });

    testWidgets('begin refused because an operation exists falls back to resuming it',
        (tester) async {
      final flow = _Flow(beginReturns: false);
      await _open(tester, flow);
      flow.existing = _Session(flow);
      await tester.tap(find.byKey(const Key('deleteAccountAction')));
      await tester.pump();
      await tester.pump();
      expect(flow.events, ['resume', 'begin', 'resume', 'check']);
      expect(find.text(_en.deleteAccountFailedFinal), findsNothing);
    });
  });

  testWidgets(
      'a definitive reject says confirmation failed/expired and Try again '
      'starts a FRESH operation', (tester) async {
    final flow = _Flow();
    await _open(tester, flow);
    await _startAndConfirm(tester);
    await _settle(tester, flow.sessions.single.confirms.single,
        const DeletionFlowRejected());
    expect(find.byKey(const Key('deleteAccountRejected')), findsOneWidget);
    expect(find.text('Confirmation failed or expired. Try again.'),
        findsOneWidget);
    expect(lookupAppL10n(const Locale('ar')).deleteAccountRejected,
        isNot(_en.deleteAccountRejected));
    expect(flow.sessions.single.closed, 1, reason: 'failed operation released');
    await tester.tap(find.byKey(const Key('deleteAccountRetry')));
    await tester.pumpAndSettle();
    expect(flow.begins, 2, reason: 'a new capture, not the abandoned session');
    expect(find.text(_en.deleteAccountConfirmBody), findsOneWidget);
  });

  testWidgets('local cleanup pending offers Retry, which retries cleanup only',
      (tester) async {
    final flow = _Flow();
    var completed = 0;
    await _open(tester, flow, onCompleted: () => completed++);
    await _startAndConfirm(tester);
    final session = flow.sessions.single;
    await _settle(tester, session.confirms.single,
        const DeletionFlowLocalCleanupPending());
    expect(find.byKey(const Key('deleteAccountLocalCleanupPending')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('deleteAccountRetryCleanup')));
    await tester.pump();
    expect(session.cleanups, hasLength(1));
    expect(session.confirms, hasLength(1), reason: 'no new confirmation');
    await _settle(tester, session.cleanups.single,
        const DeletionFlowLocalCleanupPending());
    expect(find.byKey(const Key('deleteAccountLocalCleanupPending')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('deleteAccountRetryCleanup')));
    await tester.pump();
    await _settle(tester, session.cleanups.last, const DeletionFlowCompleted());
    expect(find.byKey(const Key('deleteAccountSuccess')), findsOneWidget);
    expect(completed, 1);
  });

  testWidgets('Arabic renders the same states', (tester) async {
    final ar = lookupAppL10n(const Locale('ar'));
    final flow = _Flow();
    await _open(tester, flow, locale: 'ar');
    expect(find.text(ar.deleteAccountAction), findsWidgets);
    await _tapAction(tester);
    expect(find.text(ar.deleteAccountConfirmBody), findsOneWidget);
    await tester.tap(find.byKey(const Key('deleteAccountConfirm')));
    await tester.pump();
    await _settle(tester, flow.sessions.single.confirms.single,
        const DeletionFlowAdminBlocked());
    expect(find.text(ar.deleteAccountAdminBlocked), findsOneWidget);
  });

  test('every new deletion string exists in both languages', () {
    final en = lookupAppL10n(const Locale('en'));
    final ar = lookupAppL10n(const Locale('ar'));
    for (final pair in [
      (en.deleteAccountPendingBody, ar.deleteAccountPendingBody),
      (en.deleteAccountCheckStatus, ar.deleteAccountCheckStatus),
      (en.deleteAccountUnconfirmedStale, ar.deleteAccountUnconfirmedStale),
      (en.deleteAccountAdminBlocked, ar.deleteAccountAdminBlocked),
      (en.deleteAccountRateLimited, ar.deleteAccountRateLimited),
      (en.deleteAccountRejected, ar.deleteAccountRejected),
      (en.deleteAccountLocalCleanupPending, ar.deleteAccountLocalCleanupPending),
    ]) {
      expect(pair.$1.trim(), isNotEmpty);
      expect(pair.$2.trim(), isNotEmpty);
      expect(pair.$1, isNot(pair.$2));
    }
  });

  test('the scheduled copy makes no immediate claim', () {
    final en = lookupAppL10n(const Locale('en')).deleteAccountConfirmBodyScheduled;
    final ar = lookupAppL10n(const Locale('ar')).deleteAccountConfirmBodyScheduled;
    expect(en.toLowerCase(), isNot(contains('immediate')));
    expect(en.toLowerCase(), isNot(contains('right away')));
    expect(ar, isNot(contains('على الفور')));
    expect(ar, isNot(contains('فورًا')));
    expect(ar, isNot(contains('فورا')));
  });
}
