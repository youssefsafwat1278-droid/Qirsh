import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

// The consent actions capture their scope once. If it is revoked while the
// action awaits (logout, removal, another uid, the same uid readmitted at a new
// epoch -> the captured authority is no longer current) nothing further happens:
// no save, no retry/sync, no prompt-seen mark, no success callback, no toast.

class _PausedRepository extends FakeSettingsRepository {
  // The controlled future is created INSIDE the test body (pauseNextRead is
  // called there), i.e. in the widget test's fake-async zone, so completing it
  // schedules its continuation on the queue `tester.pump` flushes. One created
  // in setUp lives in the outer zone: its completion never reaches that queue.
  Completer<void>? _release;
  bool _pauseNextRead = false;

  /// True while a read is held; observed synchronously after a `pump`, never
  /// awaited.
  bool readPaused = false;
  void Function()? afterSave;

  void pauseNextRead() => _pauseNextRead = true;

  void releaseRead() {
    readPaused = false;
    _release!.complete();
  }

  @override
  Future<UserSettingsEntity> getSettings() async {
    final value = await super.getSettings();
    if (_pauseNextRead) {
      _pauseNextRead = false;
      final hold = _release = Completer<void>();
      readPaused = true;
      await hold.future;
    }
    return value;
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity value) async {
    final saved = await super.saveSettings(value);
    afterSave?.call();
    return saved;
  }

  /// The typed write: the lifecycle may end right after the write lands, exactly
  /// like a logout between the write and the caller's next step.
  @override
  Future<UserSettingsEntity> saveConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    capability.requireCurrent();
    final saved = await super.saveConsentChoice(capability, choices);
    afterSave?.call();
    return saved;
  }
}

class _Service extends FakeRegistrationService {
  void Function()? afterRetry;

  @override
  Future<void> retry() async {
    await super.retry();
    afterRetry?.call();
  }
}

class _Opener extends ConsumerWidget {
  const _Opener(this.onResult);
  final ValueChanged<bool> onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async =>
                onResult(await showSmartAnalysisConsentSheet(context, ref)),
            child: const Text('open'),
          ),
        ),
      );
}

class _ReaskHost extends ConsumerStatefulWidget {
  const _ReaskHost({required this.seen, required this.markSeen});
  final Future<bool> Function() seen;
  final Future<void> Function() markSeen;

  @override
  ConsumerState<_ReaskHost> createState() => _ReaskHostState();
}

class _ReaskHostState extends ConsumerState<_ReaskHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeReaskConsent(
        context, ref,
        seen: widget.seen, markSeen: widget.markSeen));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

/// A fixed, bounded number of frames: enough for the bottom-sheet animation and
/// every pending microtask, and unable to wait forever like `pumpAndSettle`.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _bounded = Timeout(Duration(seconds: 30));

class _RefProbe extends ConsumerWidget {
  const _RefProbe(this.onRef);
  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox();
  }
}

void main() {
  const failedText = 'Your settings could not be saved. Please try again.';
  late _PausedRepository repo;
  late _Service service;
  late bool live;
  late ConsentLocalWork work;
  bool? result;

  setUp(() {
    DiagnosticsConsentGate.resetForTest();
    repo = _PausedRepository();
    service = _Service();
    live = true;
    result = null;
    work = fakeConsentWork(isCurrent: () => live, uid: 'uid-x');
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service, work: work),
      home: _Opener((v) => result = v),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);
  }

  void expectNothingHappened() {
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.enableCalls, 0);
    expect(service.retryCalls, 0);
    expect(service.syncCalls, 0);
    expect(result, isNull, reason: 'a stale choice never reports success');
    expect(find.text(failedText), findsNothing,
        reason: 'a stale choice never reports into the new scope');
    expect(DiagnosticsConsentGate.allowed, isFalse);
  }

  testWidgets('scope revoked during the initial settings read: nothing saved',
      timeout: _bounded, (tester) async {
    await open(tester);
    repo.pauseNextRead();
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    expect(repo.readPaused, isTrue, reason: 'the read is held, not finished');
    live = false;
    repo.releaseRead();
    await _settle(tester);
    expect(repo.readPaused, isFalse);
    expectNothingHappened();
    // The sheet is still the one shown for the revoked scope and is usable
    // again (no stuck "granting" state), yet still cannot grant anything.
    expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('initialConsentAccept')))
            .onPressed,
        isNotNull);
  });

  testWidgets('saveConsentChoice itself ends in StaleAdmissionException when '
      'the scope is revoked during the initial read', timeout: _bounded,
      (tester) async {
    WidgetRef? ref;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service, work: work),
      home: _RefProbe((r) => ref = r),
    ));
    repo.pauseNextRead();
    Object? outcome;
    var finished = false;
    unawaited(saveConsentChoice(ref!, cloud: true, ai: true).then<void>(
        (_) => finished = true, onError: (Object e) {
      outcome = e;
      finished = true;
    }));
    await tester.pump();
    expect(repo.readPaused, isTrue);
    expect(finished, isFalse);
    live = false;
    repo.releaseRead();
    await tester.pump();
    expect(finished, isTrue, reason: 'the operation ended, it did not hang');
    expect(outcome, isA<StaleAdmissionException>());
    expect(repo.saveCalls, 0);
    expect(service.enableCalls, 0);
    expect(service.retryCalls, 0);
    expect(service.syncCalls, 0);
    expect(DiagnosticsConsentGate.allowed, isFalse);
  });

  testWidgets('scope revoked while the local commit is writing: no success, '
      'no retry, no diagnostics widening', timeout: _bounded, (tester) async {
    await open(tester);
    repo.afterSave = () => live = false;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await _settle(tester);
    expect(service.enableCalls, 1, reason: 'the gate transition was reached');
    expect(service.retryCalls, 0);
    expect(service.syncCalls, 0);
    expect(result, isNull);
    expect(find.text(failedText), findsNothing);
    expect(DiagnosticsConsentGate.allowed, isFalse);
  });

  testWidgets('scope revoked during the registration retry: the success '
      'callback is not reported', timeout: _bounded, (tester) async {
    await open(tester);
    service.afterRetry = () => live = false;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await _settle(tester);
    expect(service.retryCalls, 1);
    expect(result, isNull);
    expect(find.text(failedText), findsNothing);
  });

  testWidgets('scope revoked during a decline: no completion callback',
      timeout: _bounded, (tester) async {
    await open(tester);
    repo.afterSave = () => live = false;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentDecline')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await _settle(tester);
    expect(result, isNull);
    expect(find.text(failedText), findsNothing);
  });

  testWidgets('current scope: one explicit accept saves, enables and retries '
      'exactly once', timeout: _bounded, (tester) async {
    await open(tester);
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await _settle(tester);
    expect(repo.saveCalls, 1);
    expect(service.enableCalls, 1);
    expect(service.retryCalls, 1);
    expect(result, isTrue);
  });

  testWidgets('a panel shown for scope X cannot grant for the scope Y that is '
      'live when the button is pressed', timeout: _bounded, (tester) async {
    var source = work;
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service, workSource: () => source),
      home: _Opener((v) => result = v),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);
    live = false; // X revoked...
    source = fakeConsentWork(isCurrent: () => true, uid: 'uid-y');
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await _settle(tester);
    expectNothingHappened(); // ...Y is live but was never asked
  });

  group('re-ask', () {
    var seenCalls = 0;
    var markCalls = 0;

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      seenCalls = 0;
      markCalls = 0;
      await tester.pumpWidget(consentApp(
        overrides: consentOverrides(repo, service, work: work),
        home: _ReaskHost(
          seen: () async {
            seenCalls++;
            return false;
          },
          markSeen: () async => markCalls++,
        ),
      ));
    }

    testWidgets('scope revoked during the initial read: no sheet, no marker',
        timeout: _bounded, (tester) async {
      repo.pauseNextRead();
      await pump(tester);
      await tester.pump();
      expect(repo.readPaused, isTrue, reason: 'the read is held, not finished');
      live = false;
      repo.releaseRead();
      await _settle(tester);
      expect(repo.readPaused, isFalse);
      expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
      expect(seenCalls, 0);
      expect(markCalls, 0);
      expect(repo.saveCalls, 0);
    });

    testWidgets('scope revoked before the answer: the prompt is not marked '
        'seen for the new scope', timeout: _bounded, (tester) async {
      await pump(tester);
      await _settle(tester);
      expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
      live = false;
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentDecline')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentDecline')));
      await _settle(tester);
      expect(markCalls, 0);
      expect(repo.saveCalls, 0);
    });
  });
}
