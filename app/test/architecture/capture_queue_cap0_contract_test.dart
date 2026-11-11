import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CAP-0 — the capture queue must never lose data to a Keychain or lock error.
///
/// Proven defects at b28bb001: (1) a Keychain read that failed for ANY reason
/// (e.g. `errSecInteractionNotAllowed` before first unlock) generated a new
/// queue key, deleted the old one and made the existing encrypted queue
/// permanently undecryptable; (2) an unreadable queue was reported as EMPTY, so
/// the next enqueue overwrote it; (3) `withQueueLock` ran its body UNLOCKED when
/// the container, the lock file or the flock failed; (4) the App Intent
/// returned a quiet result when persistence failed.
///
/// Swift cannot run here. The behavioural proof is `ios/RunnerTests/
/// RunnerTests.swift` (T-Q1..T-Q4, needs Xcode); these static checks pin the
/// source properties that make it true so a regression fails in CI.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final intent =
      File('ios/BankMessageShortcuts/BankMessageShortcuts.swift')
          .readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final share =
      File('ios/ShareBankMessage/ShareViewController.swift').readAsStringSync();
  final xctest = File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();

  /// The text from the `{` after [signature] to its matching `}`.
  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('queue key', () {
    test('a key is generated ONLY under errSecItemNotFound', () {
      expect('SymmetricKey(size:'.allMatches(store).length, 1,
          reason: 'exactly one place may mint a queue key');
      final fn = body(store, 'private static func encryptionKey()');
      final notFound = fn.indexOf('case errSecItemNotFound:');
      final generate = fn.indexOf('SymmetricKey(size:');
      final fallthrough = fn.indexOf('default:');
      expect(notFound, greaterThan(-1));
      expect(generate, greaterThan(notFound),
          reason: 'key generation must sit inside the errSecItemNotFound case');
      expect(generate, lessThan(fallthrough),
          reason: 'and must not be reachable from the default (error) case');
      expect(fn.substring(fallthrough), contains('throw QueueError.keyUnavailable'),
          reason: 'any other Keychain status must fail the operation');
    });

    test('the read path never creates a key and never reports "empty"', () {
      final decode = body(store, 'private static func decodeQueueBlob(');
      expect(decode, isNot(contains('encryptionKey()')),
          reason: 'loading must only READ the key');
      expect(decode, isNot(contains('SymmetricKey(size:')));
      expect(decode, contains('throw QueueError.keyUnavailable'));
      expect(decode, contains('throw QueueError.unreadable'),
          reason: 'an undecryptable blob must fail, not become []');
      final load = body(store, 'private static func loadQueue()');
      expect(load, isNot(contains('?? []')));
      expect(load, contains('try decodeQueueBlob'));
    });

    test('the key is written with SecItemUpdate, never delete-then-add', () {
      final write = body(store, 'static func writeData(');
      expect(write, contains('SecItemUpdate('));
      expect(write, contains('SecItemAdd('));
      expect(write.indexOf('SecItemUpdate('),
          lessThan(write.indexOf('SecItemAdd(')));
      expect(write, contains('errSecItemNotFound'),
          reason: 'add only when the item does not exist');
      expect(write, isNot(contains('SecItemDelete')));
      final setData = body(store, 'static func setData(');
      expect(setData, isNot(contains('SecItemDelete')));
      // The only delete left is the explicit purge/remove.
      final remove = body(store, 'static func remove(forKey key: String)');
      expect('SecItemDelete('.allMatches(store).length, 1);
      expect(remove, contains('SecItemDelete('));
    });

    // CAP-6 (§4.2) deliberately moved the queue from the v2 UserDefaults blob
    // to a v3 file; the encryption and the key are unchanged. P0's "queue
    // format is unchanged (v2)" no longer holds once CAP-6 ships.
    test('the queue blob is still AES-GCM under the same key (v3 file, v2 read only to migrate)', () {
      expect(store, contains('"pending_bank_messages_v3.bin"'));
      expect(store, contains('"pending_bank_messages_v2"'),
          reason: 'the v2 blob is still read once, to migrate it');
      expect(store, contains('AES.GCM.seal'));
      expect(store, contains('capture_queue_key_v1'));
    });
  });

  group('queue lock', () {
    test('withQueueLock has no unlocked branch', () {
      final fn = body(store, 'private static func withQueueLock<T>(');
      expect(store, contains('func withQueueLock<T>(_ body: () throws -> T) throws -> T'));
      expect('body()'.allMatches(fn).length, 1,
          reason: 'the body may be invoked exactly once');
      expect(fn, contains('return try body()'));
      expect(fn.indexOf('return try body()'),
          greaterThan(fn.indexOf('LOCK_EX')),
          reason: 'the body runs only after the lock is taken');
      expect(fn.indexOf('return try body()'),
          greaterThan(fn.lastIndexOf('throw QueueError.lockUnavailable')),
          reason: 'every failure path throws before the body');
      expect('throw QueueError.lockUnavailable'.allMatches(fn).length,
          greaterThanOrEqualTo(3),
          reason: 'no container, open() failure and flock() failure all throw');
    });

    test('every queue write is a throwing call, none swallowed into success', () {
      expect(store, contains('private static func saveQueue('));
      expect(RegExp(r'saveQueue\([^)]*\)\s*throws').hasMatch(store), isTrue);
      expect(store, isNot(contains('_ = saveQueue(')));
      expect(store, isNot(contains('guard saveQueue(')));
    });
  });

  group('visible errors', () {
    test('the App Intent throws instead of returning a quiet result', () {
      expect(intent, contains('func perform() async throws -> some IntentResult'));
      expect(intent, isNot(contains('try? service.capture')));
      expect(intent, isNot(contains('guard persisted != nil')));
      expect(intent, contains('let persisted = try service.capture('));
      expect(intent, contains('let outcome = try service.capture('));
    });

    // R9 copy rule: users see only approved copy, chosen by failure kind and
    // device language. Technical reasons (OSStatus, errSec*, QueueError text,
    // raw localization keys) are logged internally and never shown.
    test('the Shortcuts error shows only the approved copy', () {
      final errors = body(intent, 'var errorDescription: String?');
      expect(errors, contains('FailureKind.emptyText.userMessage'));
      expect(errors, contains('kind.userMessage'));
      for (final leak in const [
        'String(format',
        'NSLocalizedString',
        'reason',
        '%@',
      ]) {
        expect(errors, isNot(contains(leak)), reason: 'leaks $leak');
      }
      expect(intent, contains('case captureFailed(SharedCaptureStore.FailureKind)'));
    });

    test('the copy is exactly the approved text, Arabic or English by app language', () {
      final copy = body(store, 'var userMessage: String');
      // Since 2d2b2df1 the copy follows the language chosen in Qirsh (the same
      // one capture notifications use), not the device language: Flutter
      // mirrors it to the App Group and the native side reads it back.
      expect(copy, contains('let arabic = notificationLanguage == "ar"'));
      expect(copy, isNot(contains('Locale.preferredLanguages')));
      // The stored in-app choice wins; only while nothing was mirrored yet (a
      // Shortcut run before Qirsh was ever opened) does the device decide.
      final language = body(store, 'static var notificationLanguage: String');
      expect(language, contains(
          'if let stored = defaults?.string(forKey: notificationLanguageKey) {'));
      expect(language, contains('return stored == "ar" ? "ar" : "en"'));
      expect(language, contains(
          'return Locale.preferredLanguages.first?.lowercased().hasPrefix("ar") == true ? "ar" : "en"'));
      expect(
          File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync(),
          store,
          reason: 'the Share extension copy must stay identical');
      expect(File('lib/core/i18n/locale_provider.dart').readAsStringSync(),
          contains('NativeCaptureBridge.setNotificationLanguage(code)'));
      for (final text in const [
        'لم يصل نص رسالة البنك إلى قِرش. تأكد أن الاختصار يمرّر نص الرسالة، ثم حاول مرة أخرى.',
        "Qirsh didn't receive the bank message text. Make sure the Shortcut passes the message text, then try again.",
        'تعذر الوصول إلى بيانات قِرش الآمنة. افتح قِرش ثم حاول مرة أخرى.',
        "Qirsh couldn't access its secure storage. Open Qirsh, then try again.",
        'تعذر حفظ الرسالة بأمان. افتح قفل الآيفون، ثم افتح قِرش وحاول مرة أخرى.',
        "Couldn't save the message securely. Unlock your iPhone, then open Qirsh and try again.",
      ]) {
        expect(copy, contains(text));
      }
      expect(copy, isNot(contains('\\(')), reason: 'no interpolation');
    });

    test('a locked device (errSecInteractionNotAllowed) selects the locked copy', () {
      final enqueue = body(store, 'static func enqueue(');
      expect(enqueue,
          contains('case let QueueError.keyUnavailable(status) = error'));
      expect(enqueue, contains('status == errSecInteractionNotAllowed'));
      expect(enqueue, contains('kind = .deviceLocked'));
    });

    test('the share extension shows the approved copy, never the reason', () {
      expect(share, contains('NSLocalizedDescriptionKey: kind.userMessage'));
      expect(share, isNot(contains('NSLocalizedDescriptionKey: reason')));
    });

    test('method-channel queue calls surface a FlutterError', () {
      expect(appDelegate, contains('"queue_unavailable"'));
      for (final call in const [
        'consumePendingText()',
        'consumePendingPayloadsJSON()',
        'peekPendingPayloadsJSON()',
      ]) {
        expect(appDelegate, contains('try SharedCaptureStore.$call'));
      }
      expect(appDelegate, isNot(contains('result(SharedCaptureStore.peekPending')));
    });

    test('the share extension does not report a lost share as success', () {
      expect(share, contains('case let .failed(reason, kind) = SharedCaptureStore.enqueue'));
      expect(share, contains('cancelRequest(withError:'));
    });

    test('the XCTest cases for T-Q1..T-Q4 exist', () {
      for (final name in const [
        'testKeyReadErrorFailsWithoutNewKeyAndKeepsBlob',
        'testLockUnavailableThrowsAndWritesNothing',
        'testUnreadableBlobIsNeverOverwritten',
        'testIntentThrowsVisibleErrorWhenQueueUnavailable',
      ]) {
        expect(xctest, contains('func $name('));
      }
      expect(xctest, contains('errSecInteractionNotAllowed'));
    });
  });

  group('R9 marker', () {
    test('the optional payload field and the intent wiring exist', () {
      expect(store, contains('let receivedAtInferred: Bool?'),
          reason: 'optional, so older builds still decode the queue');
      expect(intent, contains('receivedAtInferred: dateReceived == nil'));
      expect(intent, contains('receivedAtInferred: request.receivedAtInferred'));
    });
  });
}
