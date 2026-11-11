import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every platform capture entry point must have a DURABLE path.
///
/// Capture has one live topology: a native durable queue that both platforms
/// write into, drained by `AppShell._consumeSharedInput` under a per-item
/// lease. A second entry point — a background Dart isolate, a native path that
/// parses and commits on its own, a `vm:entry-point` nobody dispatches — is the
/// failure this pins. `sms_background_handler.dart` was exactly that: a
/// `@pragma('vm:entry-point')` no-op with no dispatcher on either platform,
/// which two separate audits had to stop and explain before ruling it out.
///
/// "Durable" here means: a captured message ends as a transaction (confirmed or
/// pending review), a persisted suspected duplicate, a Smart Inbox row the user
/// can act on, or it stays in the native queue for the next drain. Never a
/// silent drop.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final nativeSources = [
    ...Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt')),
    ...Directory('ios').listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.swift') && !f.path.contains('/ephemeral/')),
  ];

  group('capture entry points', () {
    test('the ONLY capture channel is money_companion/native_capture', () {
      final bridge =
          read('lib/features/capture/services/native_capture_bridge.dart');
      expect(
          bridge, contains("MethodChannel('money_companion/native_capture')"));

      final dartChannels = RegExp(r"MethodChannel\('([^']+)'\)")
          .allMatches(
              read('lib/features/capture/services/native_capture_bridge.dart'))
          .map((m) => m.group(1))
          .toSet();
      expect(dartChannels, {'money_companion/native_capture'},
          reason: 'a second capture channel is a second entry point');
    });

    test('no native code dispatches a background Dart entry point', () {
      // A background isolate would be a capture authority this guard, the
      // drain, and the Proof/consent gates know nothing about.
      const forbidden = [
        'FlutterCallbackInformation',
        'DartCallback',
        'FlutterEngineGroup',
      ];
      for (final file in nativeSources) {
        final body = file.readAsStringSync();
        for (final token in forbidden) {
          expect(body.contains(token), isFalse,
              reason: '${file.path} dispatches Dart out of band ($token) — '
                  'capture would bypass the drain');
        }
      }
    });

    test('every Dart vm:entry-point is registered by something', () {
      // An unregistered entry point is dead weight that reads as a live path.
      // The notification background tap handler is registered with the plugin;
      // anything else must justify itself here deliberately.
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final body = file.readAsStringSync();
        if (!body.contains("@pragma('vm:entry-point')")) continue;
        for (final m in RegExp(
                r"@pragma\('vm:entry-point'\)\s*\n\s*(?:static\s+)?(?:void|Future<[^>]*>)\s+(\w+)")
            .allMatches(body)) {
          final name = m.group(1)!;
          final referenced = Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .any((f) =>
                  f.readAsStringSync().split(RegExp(r'@pragma')).length > 1
                      ? f.readAsStringSync().contains('$name,') ||
                          f.readAsStringSync().contains('$name)')
                      : f.readAsStringSync().contains(name));
          if (!referenced) offenders.add('${file.path}:$name');
        }
      }
      expect(offenders, isEmpty,
          reason: 'unreachable background entry point(s): $offenders');
    });

    test('Android SMS capture enqueues durably and never calls Dart', () {
      final receiver = read(
          'android/app/src/main/kotlin/com/example/money_companion/SmsCaptureReceiver.kt');
      expect(receiver, contains('DurableCaptureQueue.get(context).enqueue('),
          reason: 'a received SMS must land in the durable queue');
      expect(receiver, contains('UUID.randomUUID().toString()'),
          reason: 'every payload needs a stable id or it can never be acked');
      expect(receiver.contains('MethodChannel'), isFalse,
          reason: 'the receiver must not reach into Dart directly');
      expect(receiver, contains('isAutoCaptureEnabled'),
          reason: 'permission alone is not consent to read');
    });

    test('Android share capture enqueues into the same durable queue', () {
      final main = read(
          'android/app/src/main/kotlin/com/example/money_companion/MainActivity.kt');
      expect(main, contains('DurableCaptureQueue.get(this).enqueue('));
      expect(main, contains('DurableCaptureQueue.get(this).peekJson()'),
          reason: 'the drain must PEEK, not destructively read');
      expect(main, contains('DurableCaptureQueue.get(this).acknowledge('),
          reason: 'per-item ack is the lease boundary');
    });

    test('iOS capture mints a stable payload id', () {
      final store = read('ios/Runner/SharedCaptureStore.swift');
      expect(store, contains('func makePayloadID('),
          reason: 'without an id the message can never be acknowledged');
    });
  });

  group('the drain is the single durable owner', () {
    test('every disposition is handled by the drain notification switch', () {
      final shell = read('lib/features/app/app_shell.dart');
      final switchBody = shell.substring(
          shell.indexOf('Future<void> _showCapturedMessageNotification'));
      for (final d in [
        'CapturedMessageDisposition.ignored',
        'CapturedMessageDisposition.notifyOnly',
        'CapturedMessageDisposition.requestConfirmation',
        'CapturedMessageDisposition.suspiciousDuplicate',
        'CapturedMessageDisposition.unprocessable',
      ]) {
        expect(switchBody, contains(d),
            reason: '$d has no notification branch on the live path');
      }
    });

    test('an unprocessable capture is persisted BEFORE it is acknowledged', () {
      final handoff = read(
          'lib/features/capture/services/shared_capture_handoff_service.dart');
      final unprocessableAt =
          handoff.indexOf('case CapturedMessageDisposition.unprocessable:');
      final persistAt = handoff.indexOf('persistUnprocessableCapture');
      final ackAt = handoff.indexOf('await _acknowledge(payloadId)');
      expect(unprocessableAt, isNot(-1));
      expect(persistAt, greaterThan(unprocessableAt),
          reason: 'the Smart Inbox row must be written in this branch');
      expect(ackAt, greaterThan(persistAt),
          reason: 'acknowledging before persisting is a silent drop');
      expect(handoff, contains('SharedCaptureHandoffOutcome.retained'),
          reason: 'a message that could not be made durable must be retried');
    });

    test('a committed outcome without a transaction is retained, not acked',
        () {
      final handoff = read(
          'lib/features/capture/services/shared_capture_handoff_service.dart');
      expect(handoff, contains('if (transactionId == null) {'),
          reason: 'notifyOnly/requestConfirmation/duplicate promise a row');
    });

    test(
        'the drain re-ingests on device only unless the AI fallback rule holds',
        () {
      final shell = read('lib/features/app/app_shell.dart');
      expect(shell, contains('onDeviceOnly: !nativeCaptureMayUseAiFallback('),
          reason: 'a later drain must never re-send an SMS to AI/enrichment '
              'except a backend-failed `sent` capture, behind consent + flag');
      expect(shell, contains('EgressClass.aiProcessing'),
          reason:
              'consent is read fresh per message so revocation never re-sends');
      expect(shell, contains("'capture_ai_fallback_enabled'"));
    });
  });

  group('manual recovery always exists', () {
    test('the capture sheet offers paste AND manual entry', () {
      final sheet = read('lib/features/capture/capture_entry_sheet.dart');
      expect(sheet, contains('ManualPasteScreen.showSheet'));
      expect(sheet, contains('ManualTransactionSheet.show'));
    });

    test('capture copy does not promise automatic AI classification', () {
      // AI consent is `unset` by default, so a build that promises automatic AI
      // handling is lying to most installs.
      final sheet = read('lib/features/capture/capture_entry_sheet.dart');
      expect(sheet.contains('بتصنيفها وإضافتها تلقائياً'), isFalse);
    });

    test('no raw AI reason token reaches the user', () {
      final paste = read('lib/features/capture/manual_paste_screen.dart');
      expect(paste.contains(r'فشل الذكاء الاصطناعي: $reason'), isFalse,
          reason: 'consent_off is an internal identifier, not user copy');
      expect(paste, contains("'consent_off'"),
          reason:
              'the skip reasons must still be classified, just not printed');
    });
  });

  test('the shared-input drain stops when the shell is disposed', () {
    // MALI — regression: opening a top-level route (/accounts, /goals, …)
    // disposes AppShell, and `peekPendingSharedMessages` can outlive it. The
    // `ref` uses that follow then throw, and unlike the sync calls above them
    // this stretch sits outside any try/catch, so the StateError escaped as an
    // unhandled async error rather than the drain simply stopping. Observed on
    // a physical iPhone during post-auth QA.
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    final start = shell.indexOf('Future<void> _consumeSharedInput');
    expect(start, isNonNegative, reason: '_consumeSharedInput missing');
    final peek = shell.indexOf(
        'await NativeCaptureBridge.peekPendingSharedMessages()', start);
    expect(peek, isNonNegative, reason: 'the peek await moved');
    final nextRef = shell.indexOf('ref.read(', peek);
    final guard = shell.indexOf('if (!mounted) return;', peek);
    expect(guard, isNonNegative, reason: 'no mounted guard after the peek');
    expect(guard < nextRef, isTrue,
        reason: 'the mounted guard must precede the first ref use after the '
            'peek, or a disposed shell throws instead of stopping');
  });

  test('a disposed shell stops the drain instead of raising unhandled', () {
    // The outer block was try/finally with NO catch, so a StateError from a
    // post-dispose `ref` use escaped as an unhandled async error. Deciding on
    // `mounted` is exact: disposed means stop; still-mounted means real bug.
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    final start = shell.indexOf('Future<void> _consumeSharedInput');
    final tail = shell.indexOf('_isConsumingSharedInput = false;', start);
    expect(tail, isNonNegative, reason: 'the drain\'s finally block moved');
    final region = shell.substring(start, tail);
    expect(region.contains('on StateError catch'), isTrue,
        reason: 'the drain must catch a post-dispose StateError');
    expect(region.contains('if (mounted) rethrow;'), isTrue,
        reason: 'a StateError raised while mounted is a real bug and must '
            'keep propagating — never swallow it unconditionally');
  });

  test('shell async work that outlives disposal cannot raise unhandled', () {
    // AppShell is a route: opening a top-level page disposes it while resume
    // and engagement work is still awaiting. Any `ref` use after an await then
    // throws, and without a mounted guard or an enclosing catch that is an
    // unhandled async error. Observed on a physical iPhone.
    //
    // Two reviewers found the first version of this test presence-only: a
    // single `!mounted` anywhere in the body satisfied it, which is exactly how
    // four unguarded sites slipped past. It now walks each method and requires
    // that EVERY `ref` use following an `await` has a disposal check between
    // that await and the use — unless the whole body sits under an
    // `on StateError` catch, which is the drain's chosen discipline.
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    String body(String method) {
      final start = shell.indexOf('Future<void> $method() async {');
      expect(start, isNonNegative, reason: '$method missing');
      final asyncAt = shell.indexOf(') async {', start);
      final open = asyncAt >= 0
          ? asyncAt + ') async '.length
          : shell.indexOf('{', start);
      var depth = 0;
      for (var i = open; i < shell.length; i++) {
        if (shell[i] == '{') depth++;
        if (shell[i] == '}') depth--;
        if (depth == 0) return shell.substring(start, i);
      }
      fail('$method: unbalanced braces');
    }

    final offenders = <String>[];
    // syncCatalog lives in app_providers.dart but is awaited from _onResume and
    // takes the shell's WidgetRef, so it is the same hazard one call deeper.
    final providers = File('lib/core/di/app_providers.dart').readAsStringSync();
    String bodyIn(String src, String signature) {
      final signaturePattern = RegExp(signature
          .trim()
          .split(RegExp(r'\s+'))
          .map(RegExp.escape)
          .join(r'\s+'));
      final start = signaturePattern.firstMatch(src)?.start ?? -1;
      expect(start, isNonNegative, reason: '$signature missing');
      // Anchor on `async {`, not the first `{`: a method declaring NAMED
      // parameters opens a brace in its parameter list, and starting there
      // captured only that list — which is how the caller-level discipline
      // looked absent while it was plainly there.
      final asyncAt = src.indexOf(') async {', start);
      final firstBrace = src.indexOf('{', start);
      // A method declaring NAMED parameters opens a brace in its parameter
      // list, so the first `{` is not the body. Prefer `) async {` when it
      // belongs to THIS signature — judged by proximity, since for a sync
      // method (initState) the next `) async {` is some other method entirely.
      final open = asyncAt >= 0 && asyncAt - start < 300
          ? asyncAt + ') async '.length
          : firstBrace;
      var depth = 0;
      for (var i = open; i < src.length; i++) {
        if (src[i] == '{') depth++;
        if (src[i] == '}') depth--;
        if (depth == 0) return src.substring(start, i);
      }
      fail('$signature: unbalanced braces');
    }

    final drainWrapper = bodyIn(shell, 'Future<void> _consumeSharedInput() {');
    expect(drainWrapper, contains('_consumeSharedInputOnce()'),
        reason: 'the drain wrapper must delegate to the guarded body');
    expect(RegExp(r'\bref\b').hasMatch(drainWrapper), isFalse,
        reason: 'the single-flight wrapper must not touch ref; all ref use '
            'belongs in _consumeSharedInputOnce, which is scanned below');

    final engagementBody = bodyIn(shell,
        'Future<bool> _syncEngagementBody(AdmittedLocalWork work, bool Function() current, SyncPhaseBinding phase) async {');
    final engagementWrapper = bodyIn(shell,
        'Future<bool> _syncEngagement({AdmittedLocalWork? originalWork}) async {');
    String compact(String source) => source.replaceAll(RegExp(r'\s+'), ' ');
    final wrapper = compact(engagementWrapper);
    // Only these paired regions may use current() as a disposal guard. Pin
    // its original work/generation, mounted state, bound phase and exact DB
    // before allowing that spelling in the per-await scan below.
    expect(
        wrapper,
        contains('if (_syncEngagementInFlight || !mounted) return false; '
            'final work = originalWork ?? AdmittedLocalWork.capture(ref); '
            'if (work == null || !work.current) return false; '
            'final generation = _syncGate.generation; '
            'final phase = SyncPhaseBinding(); '
            'bool rawCurrent() => mounted && _syncGate.admits(generation) && work.current; '
            'phase.bind(_NotificationCallerLifecycle(work, rawCurrent)); '
            'bool current() => rawCurrent() && phase.isCurrent && identical(phase.database, work.database);'));
    expect(
        wrapper,
        contains(
            'return await _syncEngagementBody(work, current, phase) && current();'));
    expect(
        wrapper,
        contains(
            '} on StateError { if (current()) rethrow; return false; } catch (_) { '
            'if (!current()) return false; rethrow; } finally {'));
    final targets = <String, String>{
      // initState's cold-start closure is the same hazard: a long await chain
      // that can outlive the shell. It threw from `initState.<anonymous
      // closure>` on device while every named method was already guarded.
      'initState': bodyIn(shell, 'void initState() {'),
      '_onResume': body('_onResume'),
      '_syncEngagementBody': engagementBody + engagementWrapper,
      // The drain is a single-flight wrapper around `_consumeSharedInputOnce`;
      // the async body (every `ref` use) lives in the latter. The wrapper is
      // pinned to stay ref-free below, so the hazard cannot move into it.
      '_consumeSharedInput': body('_consumeSharedInputOnce'),
      // Paired with its caller: the discipline may live in either, and for
      // these two it lives in the caller's try, covering the whole body.
      '_runLedgerSyncBody': bodyIn(shell, 'Future<void> _runLedgerSyncBody(') +
          bodyIn(shell, 'Future<void> _runLedgerSync('),
      'syncCatalog': bodyIn(providers, 'Future<void> syncCatalog('),
    };
    for (final entry in targets.entries) {
      final method = entry.key;
      final src = entry.value;
      if (src.contains('on StateError catch') &&
          src.contains('if (mounted) rethrow;')) {
        continue; // whole-body discipline: any post-dispose ref use is caught
      }
      // Method ENTRY counts as a suspension point: every one of these is
      // awaited from a chain that can outlive the shell, so a `ref` use before
      // the first guard throws exactly as one after an await does. That is how
      // _syncEngagementBody kept failing with a guard already in the body.
      var awaited = method != 'initState';
      // `ref` at end of line with `.read(` on the next is one use, not none.
      final lines =
          src.replaceAll(RegExp(r'\bref\s*\n\s*\.'), 'ref.').split('\n');
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trim();
        if (l.startsWith('//')) continue;
        if (l.contains('if (!mounted) return;') ||
            l.contains('if (!ref.context.mounted) return;') ||
            (method == '_syncEngagementBody' &&
                l == 'if (!current()) return false;')) {
          awaited = false;
        }
        // A try block with a broad catch already handles the disposal
        // StateError, so uses inside it are not unguarded. Narrow this if a
        // `try` ever appears here with only typed `on X catch` clauses.
        if (l == 'try {') awaited = false;
        final usesRef = RegExp(
                r'\bref\.(read|watch|invalidate|listen)\(|\bsyncCatalog\(ref\)')
            .hasMatch(l);
        if (awaited && usesRef) offenders.add('$method: line ${i + 1}: $l');
        if (l.contains('await ')) awaited = true;
      }
    }
    expect(offenders, isEmpty,
        reason: 'ref used after an await with no mounted guard in between:\n'
            '${offenders.join('\n')}');
  });
}
