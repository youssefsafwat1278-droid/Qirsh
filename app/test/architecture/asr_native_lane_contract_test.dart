import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// ASR v7.2 §7.1/§7.4 (C2): the native mutation counter and the single Dart lane
/// for protected native writes.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final shareStore =
      File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync();
  final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final bridge =
      File('lib/features/capture/services/native_capture_bridge.dart')
          .readAsStringSync();

  String fn(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: signature);
    final end = source.indexOf('\n  }\n', at);
    return source.substring(at, end);
  }

  test('the counter wrappers are the queue flock plus a bump, nothing else',
      () {
    final plain = fn(store, 'private static func withProtectedWriteLock<T>(');
    expect(
        plain.replaceAll(RegExp(r'\s+'), ' '),
        contains('try withQueueLock { bumpEgressMutationCounter() '
            'return try body() }'));
    final counted =
        fn(store, 'private static func withProtectedWriteLockCounted<T>(');
    expect(
        counted.replaceAll(RegExp(r'\s+'), ' '),
        contains('try withQueueLock { let prior = egressMutationCounter() '
            'bumpEgressMutationCounter() return try body(prior) }'));
    // The bump is the only writer of the counter key and never merges.
    expect(
        store
            .split('defaults?.set(')
            .where(
                (s) => s.startsWith('next, forKey: egressMutationCounterKey)'))
            .length,
        1,
        reason: 'the bump is the only writer of the counter');
    expect('forKey: egressMutationCounterKey)'.allMatches(store).length, 3,
        reason: 'read helper, plus the read and the write in the bump');
    expect(fn(store, 'private static func bumpEgressMutationCounter()'),
        isNot(contains('max(')));
  });

  test('both physical store copies are identical', () {
    expect(shareStore, store);
  });

  test('every Dart protected write is a Runner channel handler', () {
    for (final method in NativeCaptureBridge.protectedNativeWrites.keys) {
      expect(RegExp('case [^\\n]*"$method"').hasMatch(delegate), isTrue,
          reason: '$method has no Runner handler');
    }
    expect(NativeCaptureBridge.protectedNativeWrites.keys.toSet(), {
      'publishCaptureOwner',
      'publishRestrictiveCaptureOwner',
      'repairActiveOwnerGeneration',
      'revokeCaptureAuthorizationLifetime',
      'setCaptureConsentMirror',
      'setCloudEgressState',
      'beginCloudEgressEnable',
      'writeCloudEgressEnableOn',
      'restrictCloudEgressEnable',
      'finishCloudEgressEnable',
      'resolveLegacyCaptureItems',
      'mintExpiryEvidenceForLiveOn',
      'invalidateExpiryEvidence',
      'retireSuccessor',
      'withdrawCloudEgress',
      'clearCaptureOwner',
      'beginCaptureRemoval',
      'finishCaptureRemoval',
      'purgeAllCaptureState',
    });
  });

  test('protected writes go through the noting lane only', () {
    // Direct channel calls never name a protected method, except the purge,
    // which notes its cause first.
    final direct = RegExp(r"_channel\.invokeMethod<[^>]*>\(\s*'(\w+)'");
    for (final m in direct.allMatches(bridge)) {
      final name = m.group(1)!;
      if (!NativeCaptureBridge.protectedNativeWrites.containsKey(name)) {
        continue;
      }
      expect(name, 'purgeAllCaptureState');
      final before = bridge.substring(0, m.start);
      expect(
          before.lastIndexOf(
              "_noteProtectedWrite('purgeAllCaptureState', null)"),
          greaterThan(before.lastIndexOf('static Future')),
          reason: 'the purge notes its cause before the channel call');
    }
    // No other library file talks to the capture channel.
    for (final f
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') ||
          f.path.endsWith('native_capture_bridge.dart')) {
        continue;
      }
      expect(f.readAsStringSync(),
          isNot(contains("MethodChannel('money_companion/native_capture')")),
          reason: f.path);
    }
    // Non-literal channel calls: the noting lane, and the shared-message read
    // whose callers name only unprotected methods.
    final dynamicCalls =
        RegExp(r'_channel\.invokeMethod<[^>]*>\(\s*([^\s\x27,)]+)')
            .allMatches(bridge)
            .toList();
    expect(dynamicCalls.map((m) => m.group(1)), ['method', 'method']);
    expect(bridge.substring(0, dynamicCalls[1].start).lastIndexOf('static '),
        bridge.indexOf('static Future<List<SharedCapturedMessage>> '
            '_fetchSharedMessages('));
    for (final m in RegExp(r"_fetchSharedMessages\('(\w+)'\)")
        .allMatches(bridge)) {
      expect(NativeCaptureBridge.protectedNativeWrites.containsKey(m.group(1)),
          isFalse);
    }
    expect(RegExp(r'_fetchSharedMessages\((?!\x27|\s*String method)').hasMatch(bridge), isFalse,
        reason: 'only literal method names');
    final lane = fn(bridge, 'static Future<T?> _queueCall<T>(');
    expect(lane.indexOf('_noteProtectedWrite(method, causeAuthority);'),
        lessThan(lane.indexOf('_channel.invokeMethod<T>(method, arguments)')));
  });

  // Phase 4 (non-blocking): the writer set is DERIVED from the store's
  // `#if CAPTURE_STATE_WRITER` regions, not listed by hand.
  group('derived writer audit', () {
    final writers = <String>{};
    final lockOutside = <int>[];
    final stack = <bool>[];
    final lines = store.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.startsWith('#if')) {
        stack.add(t.contains('CAPTURE_STATE_WRITER'));
        continue;
      }
      if (t.startsWith('#endif')) {
        stack.removeLast();
        continue;
      }
      final inWriter = stack.any((w) => w);
      final def = RegExp(r'static func (\w+)').firstMatch(lines[i]);
      if (def != null && inWriter) writers.add(def.group(1)!);
      if (lines[i].contains('withProtectedWriteLock') &&
          !lines[i].contains('func ') &&
          !inWriter) {
        lockOutside.add(i + 1);
      }
    }

    test('the regions are found and every counted-lock use is inside one', () {
      expect(writers, containsAll(['retireSuccessor', 'publishActiveOwner']));
      expect(lockOutside, isEmpty);
    });

    test('every Runner channel case that reaches a writer is a noted write',
        () {
      // Outer channel cases (six-space indent), each up to the next one.
      final cases = RegExp(r'\n      case ((?:"\w+"(?:, )?)+):')
          .allMatches(delegate)
          .toList();
      expect(cases, isNotEmpty);
      // Read-only names that share a block with a writer.
      const readOnlyShared = {'inspectSuccessor'};
      for (var i = 0; i < cases.length; i++) {
        final end = i + 1 < cases.length ? cases[i + 1].start : delegate.length;
        final block = delegate.substring(cases[i].end, end);
        final reaches = writers.any(
            (w) => block.contains('SharedCaptureStore.$w('));
        if (!reaches) continue;
        final names = RegExp(r'"(\w+)"')
            .allMatches(cases[i].group(1)!)
            .map((m) => m.group(1)!);
        for (final name in names) {
          expect(
              NativeCaptureBridge.protectedNativeWrites.containsKey(name) ||
                  readOnlyShared.contains(name),
              isTrue,
              reason: '$name reaches a protected writer without a cause');
        }
      }
    });

    test('no other Swift source reaches a writer', () {
      final ios = Directory('ios');
      for (final f in ios.listSync(recursive: true).whereType<File>()) {
        final path = f.path.replaceAll('\\', '/');
        if (!path.endsWith('.swift') ||
            path.contains('/Pods/') ||
            path.contains('/Flutter/') ||
            path.contains('/RunnerTests/') ||
            path.endsWith('/SharedCaptureStore.swift') ||
            path == 'ios/Runner/AppDelegate.swift') {
          continue;
        }
        final source = f.readAsStringSync();
        for (final w in writers) {
          expect(source.contains('SharedCaptureStore.$w('), isFalse,
              reason: '$path calls $w');
        }
      }
    });
  });
}
