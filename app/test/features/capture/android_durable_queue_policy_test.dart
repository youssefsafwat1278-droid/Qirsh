import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android durable capture queue must never discard, evict or refuse a
/// legitimate capture silently, and an unreadable store is an error.
///
/// The project has no JVM or instrumentation test source set for Android (see
/// android_sms_permission_test.dart), so these are STRUCTURAL assertions over
/// the Kotlin source — a guard against the invariants being edited away, not
/// the proof that they hold. The proof is the scratchpad JVM harness that
/// executes the real `DurableCaptureQueue.kt` against fakes (overflow of 2500
/// items, disk failure, corrupt blobs/files, SMS identity); its output is in
/// the fix report. The harness is deliberately not part of the repo.
void main() {
  const dir = 'android/app/src/main/kotlin/com/example/money_companion';
  final queue = File('$dir/DurableCaptureQueue.kt').readAsStringSync();
  final receiver = File('$dir/SmsCaptureReceiver.kt').readAsStringSync();
  final activity = File('$dir/MainActivity.kt').readAsStringSync();

  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
    }
    fail('unbalanced braces after $signature');
  }

  group('capacity never loses a capture', () {
    test('enqueue never evicts and has no capacity refusal', () {
      final enqueue = body(queue, 'fun enqueue(item: Item)');
      expect(enqueue.contains('removeAt('), isFalse,
          reason: 'evicting the oldest capture is silent message loss');
      expect(queue.contains('REFUSED_FULL'), isFalse,
          reason: 'a legitimate capture is never refused for capacity');
      expect(enqueue, contains('CaptureQueuePolicy.Admission.OVERFLOW'));
    });

    test('duplicates are detected by id only, never by text', () {
      final enqueue = body(queue, 'fun enqueue(item: Item)');
      expect(enqueue.contains('it.text == item.text'), isFalse,
          reason: 'two real purchases with identical wording are two captures');
      expect(queue, contains('mainIds.contains(newId)'));
    });

    test('an overflow capture is written atomically: temp, fsync, rename', () {
      final write = body(queue, 'private fun writeOverflow(item: Item)');
      final temp = write.indexOf('TEMP_SUFFIX');
      final sync = write.indexOf('stream.fd.sync()');
      final rename = write.indexOf('temp.renameTo(target)');
      expect(temp, greaterThan(-1));
      expect(sync, greaterThan(temp));
      expect(rename, greaterThan(sync));
      expect(write, contains('if (target.exists()) return false'),
          reason: 'an existing capture file is never overwritten');
    });

    test('a write that is not durable is NOT_PERSISTED, never STORED', () {
      final enqueue = body(queue, 'fun enqueue(item: Item)');
      final failed = enqueue.indexOf('if (!stored) return notPersisted()');
      final stored = enqueue.indexOf('return EnqueueResult.STORED');
      expect(failed, greaterThan(-1));
      expect(stored, greaterThan(failed));
      expect(queue, contains('KEY_NOT_PERSISTED'));
      expect(activity, contains('"captureQueueHealth"'));
    });
  });

  group('unreadable storage is preserved and reported as an error', () {
    test('a corrupt main blob is quarantined, never deleted', () {
      final read = body(queue, 'private fun readAll()');
      expect(read.contains('remove(KEY_ITEMS)'), isFalse,
          reason: 'resetting the queue on corrupt JSON deletes every capture');
      expect(read, contains('QUARANTINE_PREFIX'));
      expect(read, contains('return null'),
          reason: 'if the quarantine cannot be written the blob is left as is');
    });

    test('a corrupt overflow file is renamed, never deleted', () {
      final read = body(queue, 'private fun readOverflow(file: File)');
      expect(read, contains('QUARANTINE_SUFFIX'));
      expect(read.contains('.delete()'), isFalse);
    });

    test('an unreadable queue is an ERROR on the channel, not an empty list',
        () {
      expect(body(queue, 'fun peekJson()'), contains('peekItems()'));
      expect(body(queue, 'private fun peekItems()'),
          contains('readAll() ?: throw QueueUnreadableException()'));
      final at = activity.indexOf('"peekPendingSharedMessages" ->');
      final handler = activity.substring(at, at + 400);
      expect(handler, contains('catch (_: QueueUnreadableException)'));
      expect(handler, contains('result.error("queue_unreadable"'));
    });

    test('an identity purge removes overflow files, quarantine and counters',
        () {
      final purge = body(queue, 'fun purge()');
      expect(purge, contains('.clear().commit()'));
      expect(purge, contains('overflowDir.listFiles()'));
      expect(purge, contains('prefsCleared && filesCleared'));
    });
  });

  group('identity and callers', () {
    test('a received SMS gets a stable id from sender, timestamp and body', () {
      expect(body(queue, 'fun smsId('), isNotNull);
      expect(queue, contains(r'sha256Hex("sms\u0000${sender.orEmpty()}\u0000$smsEpochMs\u0000$body")'));
      expect(receiver, contains('DurableCaptureQueue.smsId(cleanSender, platformEpochMs, text)'));
    });

    test('the SMS receiver and the share path inspect the enqueue result', () {
      expect(receiver, contains('DurableCaptureQueue.EnqueueResult.NOT_PERSISTED'));
      expect(body(activity, 'private fun captureSharedText('),
          contains('DurableCaptureQueue.EnqueueResult.STORED'));
    });
  });
}
