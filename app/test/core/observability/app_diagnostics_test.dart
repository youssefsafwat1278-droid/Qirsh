import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/app_diagnostics.dart';

void main() {
  setUp(AppDiagnostics.resetForTest);
  tearDown(AppDiagnostics.resetForTest);

  test('async nested operations share a parent and preserve their result',
      () async {
    final result = await AppDiagnostics.run(AppOperation.backup, () async {
      await Future<void>.delayed(Duration.zero);
      return AppDiagnostics.run(AppOperation.databaseRead, () async => 42);
    });
    expect(result, 42);
    final start = AppDiagnostics.events
        .where((e) => e.state == AppEventState.started)
        .toList();
    expect(start, hasLength(2));
    expect(start.last.parent, start.first.trace);
    expect(AppDiagnostics.events.last.state, AppEventState.completed);
  });

  test('parallel operations do not inherit each other as parents', () async {
    final wait = Completer<void>();
    final first = AppDiagnostics.run(AppOperation.backup, () => wait.future);
    await AppDiagnostics.run(AppOperation.reportExport, () async {});
    wait.complete();
    await first;
    expect(
        AppDiagnostics.events
            .where((e) => e.state == AppEventState.started)
            .every((e) => e.parent == null),
        isTrue);
  });

  test('exceptions retain identity, but their content never enters diagnostics',
      () async {
    final error =
        StateError('SMS SECRET 125.50 SAR card 4417883322110099 token abc');
    await expectLater(
        AppDiagnostics.run(AppOperation.capture, () async => throw error),
        throwsA(same(error)));
    expect(AppDiagnostics.events.last.reason, AppEventReason.exception);
    final text = AppDiagnostics.exportText();
    for (final secret in [
      'SMS SECRET',
      '125.50',
      '4417883322110099',
      'token abc'
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('a completed trace cannot emit a second terminal outcome', () {
    final trace = AppDiagnostics.begin(AppOperation.restore);
    trace.finish(state: AppEventState.blocked, reason: AppEventReason.stale);
    trace.finish();
    expect(AppDiagnostics.events, hasLength(2));
    expect(AppDiagnostics.events.last.state, AppEventState.blocked);
  });

  test('areas use only known modules and tolerate malformed route encoding',
      () {
    expect(AppDiagnostics.areaForRoute('/accounts/private-id?token=secret'),
        AppArea.accounts);
    expect(AppDiagnostics.areaForRoute('/unknown/private-id'), AppArea.app);
    expect(AppDiagnostics.areaForRoute('/%FF'), AppArea.app);
    expect(
        AppDiagnostics.areaForStack(StackTrace.fromString(
            '#0 action (package:money_companion/features/goals/private.dart:20:3)')),
        AppArea.goals);
  });

  test('hot paths are counted without flooding the bounded event journal',
      () async {
    for (var i = 0; i < 600; i++) {
      await AppDiagnostics.measure(AppOperation.databaseRead, () async => i);
    }
    expect(AppDiagnostics.counts[AppOperation.databaseRead], 600);
    expect(AppDiagnostics.events, isEmpty);
    for (var i = 0; i < 620; i++) {
      AppDiagnostics.record(AppOperation.consent, AppEventState.pending,
          revision: i);
    }
    expect(AppDiagnostics.events, hasLength(AppDiagnostics.capacity));
    expect(AppDiagnostics.events.first.revision, 120);
  });

  test('bounded journal survives restart and keeps events during attachment',
      () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-diag-');
    addTearDown(() => dir.delete(recursive: true));
    await AppDiagnostics.attach(dir);
    for (var i = 0; i < 620; i++) {
      AppDiagnostics.record(AppOperation.consent, AppEventState.pending,
          revision: i);
    }
    await AppDiagnostics.flush();
    expect(await File('${dir.path}/${AppDiagnostics.fileName}').length(),
        lessThanOrEqualTo(AppDiagnostics.maxFileBytes));
    await AppDiagnostics.resetForTest();
    final attaching = AppDiagnostics.attach(dir);
    AppDiagnostics.record(AppOperation.lifecycle, AppEventState.resumed);
    await attaching;
    expect(AppDiagnostics.events, hasLength(AppDiagnostics.capacity));
    expect(AppDiagnostics.events.last.state, AppEventState.resumed);
    expect(AppDiagnostics.events.where((e) => e.state == AppEventState.resumed),
        hasLength(1));
  });

  test('restoration ignores unknown content, expired and malformed events',
      () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-diag-');
    addTearDown(() => dir.delete(recursive: true));
    AppDiagnostics.record(AppOperation.session, AppEventState.started);
    final good = AppDiagnostics.events.single.toJson();
    await AppDiagnostics.resetForTest();
    await File('${dir.path}/${AppDiagnostics.fileName}')
        .writeAsString(jsonEncode({
      'schema': 1,
      'events': [
        {...good, 'body': 'PRIVATE SMS', 'email': 'secret@example.com'},
        {...good, 'operation': 'PRIVATE SMS'},
        {...good, 'trace': 'secret@example.com'},
        {
          ...good,
          'at':
              DateTime.now().subtract(const Duration(days: 3)).toIso8601String()
        },
        {
          ...good,
          'at': DateTime.now().add(const Duration(days: 1)).toIso8601String()
        },
      ],
    }));
    await AppDiagnostics.attach(dir);
    expect(AppDiagnostics.events, hasLength(1));
    final disk =
        await File('${dir.path}/${AppDiagnostics.fileName}').readAsString();
    expect(disk, isNot(contains('PRIVATE SMS')));
    expect(disk, isNot(contains('secret@example.com')));
  });

  test('oversized or broken files never prevent subsequent logging', () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-diag-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/${AppDiagnostics.fileName}');
    await file.writeAsString('x' * (AppDiagnostics.maxFileBytes + 1));
    await AppDiagnostics.attach(dir);
    AppDiagnostics.record(AppOperation.startup, AppEventState.started);
    await AppDiagnostics.flush();
    expect(AppDiagnostics.events, hasLength(1));
    await AppDiagnostics.resetForTest();
    await file.writeAsString('{not valid json');
    await AppDiagnostics.attach(dir);
    expect(await AppDiagnostics.run(AppOperation.backup, () async => true),
        isTrue);
    await AppDiagnostics.flush();
  });

  test(
      'foreground export includes the separate background journal without overwriting it',
      () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-diag-engines-');
    addTearDown(() => dir.delete(recursive: true));
    await AppDiagnostics.attach(dir, background: true);
    AppDiagnostics.record(AppOperation.capture, AppEventState.completed);
    await AppDiagnostics.flush();
    final backgroundFile =
        File('${dir.path}/${AppDiagnostics.backgroundFileName}');
    final before = await backgroundFile.readAsString();
    await AppDiagnostics.resetForTest();
    await AppDiagnostics.attach(dir);
    AppDiagnostics.record(AppOperation.lifecycle, AppEventState.resumed);
    await AppDiagnostics.flush();
    await AppDiagnostics.refreshBackground();
    expect(AppDiagnostics.events.single.operation, AppOperation.lifecycle);
    expect(AppDiagnostics.exportText(), contains('Background app diagnostics'));
    expect(AppDiagnostics.exportText(), contains('capture completed'));
    expect(await backgroundFile.readAsString(), before);
  });

  test('unwritable diagnostic storage cannot break an application operation',
      () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-diag-');
    addTearDown(() => dir.delete(recursive: true));
    final blocker = File('${dir.path}/not-a-directory');
    await blocker.writeAsString('x');
    await AppDiagnostics.attach(Directory(blocker.path));
    expect(await AppDiagnostics.run(AppOperation.backup, () async => 7), 7);
    await AppDiagnostics.flush();
  });
}
