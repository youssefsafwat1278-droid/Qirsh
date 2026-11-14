import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Closed vocabulary: no request bodies, SQL, paths, identifiers or exception
/// messages can enter the journal. This journal is LOCAL ONLY, including while
/// Cloud is off. A support export is an explicit user action.
enum AppOperation {
  startup,
  session,
  authentication,
  consent,
  cloudConsent,
  aiConsent,
  deviceConsent,
  accountConsent,
  settingsQueue,
  settingsSync,
  sync,
  syncLedger,
  syncPlanning,
  syncAccounts,
  syncChildren,
  syncInbox,
  syncEngagement,
  syncMappings,
  networkAuth,
  networkSettings,
  networkData,
  networkCapture,
  networkAi,
  networkBackup,
  networkOther,
  databaseOpen,
  databaseRead,
  databaseWrite,
  databaseCommit,
  databaseRollback,
  capture,
  parsing,
  backup,
  restore,
  reportExport,
  notification,
  navigation,
  lifecycle,
  provider,
  framework,
  accountWrite,
  transactionWrite,
  budgetWrite,
  goalWrite,
  billWrite,
  cardWrite,
  couponWrite,
  engagementWrite,
  settingsWrite,
  catalogWrite,
}

enum AppEventState {
  started,
  succeeded,
  completed,
  failed,
  blocked,
  queued,
  sent,
  response,
  cancelled,
  pending,
  resumed,
  paused,
  inactive,
  detached,
  enabled,
  disabled,
  confirmed,
}

enum AppEventReason {
  none,
  timeout,
  offline,
  exception,
  denied,
  stale,
  unavailable,
  noPendingWork,
  consentOff,
  capability,
  ownerMissing,
  authMissing,
  conflict,
  dependency,
  server,
  parseNoMatch,
}

enum AppArea {
  app,
  auth,
  onboarding,
  transactions,
  accounts,
  budgets,
  goals,
  subscriptions,
  cards,
  capture,
  backup,
  reports,
  settings,
  catalog,
  notifications,
  coupons,
  achievements,
  referrals,
  help,
  security,
  storage,
  sync,
  parser,
}

class AppDiagnosticEvent {
  const AppDiagnosticEvent._(this.at, this.operation, this.state, this.trace,
      this.parent, this.reason, this.elapsedMs, this.statusCode, this.revision,
      {this.area = AppArea.app});

  final DateTime at;
  final AppOperation operation;
  final AppEventState state;
  final String trace;
  final String? parent;
  final AppEventReason reason;
  final int? elapsedMs;
  final int? statusCode;
  final int? revision;
  final AppArea area;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'operation': operation.name,
        'state': state.name,
        'trace': trace,
        if (parent != null) 'parent': parent,
        'reason': reason.name,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        if (statusCode != null) 'statusCode': statusCode,
        if (revision != null) 'revision': revision,
        'area': area.name,
      };

  String get line => '${at.toUtc().toIso8601String()} ${operation.name} '
      '${state.name} trace=$trace${parent == null ? '' : ' parent=$parent'}'
      '${reason == AppEventReason.none ? '' : ' reason=${reason.name}'}'
      '${elapsedMs == null ? '' : ' ms=$elapsedMs'}'
      '${statusCode == null ? '' : ' http=$statusCode'}'
      '${revision == null ? '' : ' revision=$revision'} area=${area.name}';

  static AppDiagnosticEvent? decode(Object? raw) {
    if (raw is! Map) return null;
    T? member<T extends Enum>(List<T> values, Object? name) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    final at =
        raw['at'] is String ? DateTime.tryParse(raw['at'] as String) : null;
    final op = member(AppOperation.values, raw['operation']);
    final state = member(AppEventState.values, raw['state']);
    final reason = member(AppEventReason.values, raw['reason']);
    final trace = raw['trace'];
    final parent = raw['parent'];
    if (at == null ||
        op == null ||
        state == null ||
        reason == null ||
        trace is! String ||
        !_tracePattern.hasMatch(trace) ||
        (parent != null &&
            (parent is! String || !_tracePattern.hasMatch(parent)))) {
      return null;
    }
    int? bounded(Object? value, int max) =>
        value is int && value >= 0 && value <= max ? value : null;
    return AppDiagnosticEvent._(
        at,
        op,
        state,
        trace,
        parent as String?,
        reason,
        bounded(raw['elapsedMs'], 86400000),
        bounded(raw['statusCode'], 599),
        bounded(raw['revision'], 2147483647),
        area: member(AppArea.values, raw['area']) ?? AppArea.app);
  }
}

final _tracePattern = RegExp(r'^r[0-9a-f]{12}\.[0-9]{1,12}$');

class AppTrace {
  AppTrace._(this.operation, this.id, this.parent)
      : _watch = Stopwatch()..start();
  final AppOperation operation;
  final String id;
  final String? parent;
  final Stopwatch _watch;
  bool _finished = false;

  void event(AppEventState state,
      {AppEventReason reason = AppEventReason.none, int? statusCode}) {
    if (_finished) return;
    AppDiagnostics._append(operation, state, id, parent, reason,
        _watch.elapsedMilliseconds, statusCode, null);
  }

  void finish(
      {AppEventState state = AppEventState.succeeded,
      AppEventReason reason = AppEventReason.none,
      int? statusCode}) {
    if (_finished) return;
    event(state, reason: reason, statusCode: statusCode);
    _finished = true;
    _watch.stop();
  }
}

class AppDiagnostics {
  AppDiagnostics._();
  static const capacity = 500;
  static const maxFileBytes = 192 * 1024;
  static const retention = Duration(days: 2);
  static const fileName = 'app_diagnostics_v1.json';
  static const backgroundFileName = 'app_background_diagnostics_v1.json';
  static final _events = Queue<AppDiagnosticEvent>();
  static final _traceKey = Object();
  static final String _run =
      'r${List.generate(6, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  static int _sequence = 0;
  static File? _file;
  static File? _backgroundFile;
  static List<AppDiagnosticEvent> _backgroundEvents = const [];
  static Timer? _saveTimer;
  static Future<void> _writes = Future<void>.value();
  static final Map<AppOperation, int> _counts = {};

  static List<AppDiagnosticEvent> get events => List.unmodifiable(_events);
  static Map<AppOperation, int> get counts => Map.unmodifiable(_counts);

  static AppTrace begin(AppOperation operation) {
    final span = AppTrace._(
        operation, '$_run.${++_sequence}', Zone.current[_traceKey] as String?);
    span.event(AppEventState.started);
    return span;
  }

  static void record(AppOperation operation, AppEventState state,
      {AppEventReason reason = AppEventReason.none,
      int? revision,
      AppArea area = AppArea.app}) {
    final trace = Zone.current[_traceKey] as String? ?? '$_run.${++_sequence}';
    _append(operation, state, trace, null, reason, null, null, revision,
        area: area);
  }

  /// Only known feature names survive. Route parameters, query strings and
  /// source locations are discarded, even when supplied by an exception.
  static AppArea areaForRoute(String? route) {
    try {
      final first = Uri.tryParse(route ?? '')?.pathSegments.firstOrNull;
      return _area(first);
    } catch (_) {
      return AppArea.app;
    }
  }

  static AppArea areaForStack(StackTrace? stack) {
    if (stack == null) return AppArea.app;
    final match = RegExp(
            r'package:money_companion/(?:features|core|data|engine)/([a-z_]+)/')
        .firstMatch(stack.toString());
    return _area(match?.group(1));
  }

  static AppArea _area(String? value) => switch (value) {
        'auth' || 'session' => AppArea.auth,
        'onboarding' || 'welcome' => AppArea.onboarding,
        'transactions' => AppArea.transactions,
        'accounts' => AppArea.accounts,
        'budgets' => AppArea.budgets,
        'goals' => AppArea.goals,
        'subscriptions' || 'bills' => AppArea.subscriptions,
        'cards' => AppArea.cards,
        'capture' => AppArea.capture,
        'backup' || 'data-transfer' => AppArea.backup,
        'reports' || 'report_ads' => AppArea.reports,
        'settings' || 'privacy' || 'consent' => AppArea.settings,
        'catalog' => AppArea.catalog,
        'notifications' => AppArea.notifications,
        'coupons' || 'savings' => AppArea.coupons,
        'achievements' => AppArea.achievements,
        'referrals' => AppArea.referrals,
        'help' => AppArea.help,
        'security' => AppArea.security,
        'db' || 'repositories' => AppArea.storage,
        'sync' || 'planning_sync' => AppArea.sync,
        'parser' => AppArea.parser,
        _ => AppArea.app,
      };

  /// Counts hot paths without flooding the journal with every SQL read/write.
  static Future<T> measure<T>(
      AppOperation operation, Future<T> Function() action) async {
    _counts.update(operation, (n) => n + 1, ifAbsent: () => 1);
    final watch = Stopwatch()..start();
    try {
      final value = await action();
      if (watch.elapsedMilliseconds >= 500) {
        _append(
            operation,
            AppEventState.succeeded,
            Zone.current[_traceKey] as String? ?? '$_run.${++_sequence}',
            null,
            AppEventReason.none,
            watch.elapsedMilliseconds,
            null,
            null);
      }
      return value;
    } catch (error) {
      record(operation, AppEventState.failed, reason: classify(error));
      rethrow;
    }
  }

  static Future<T> run<T>(AppOperation operation, Future<T> Function() action) {
    final trace = begin(operation);
    return runZoned(() async {
      try {
        final value = await action();
        // A returned Future is not proof of business acceptance (a restore can
        // return a blocked result, for example). Domain confirmations are
        // explicit events at the authoritative acknowledgement boundary.
        trace.finish(state: AppEventState.completed);
        return value;
      } catch (error) {
        trace.finish(state: AppEventState.failed, reason: classify(error));
        rethrow;
      }
    }, zoneValues: {_traceKey: trace.id});
  }

  static AppEventReason classify(Object error) => switch (error) {
        TimeoutException() => AppEventReason.timeout,
        SocketException() || HttpException() => AppEventReason.offline,
        _ => AppEventReason.exception,
      };

  static void _append(
      AppOperation operation,
      AppEventState state,
      String trace,
      String? parent,
      AppEventReason reason,
      int? elapsed,
      int? status,
      int? revision,
      {AppArea area = AppArea.app}) {
    final now = DateTime.now().toUtc();
    _events.add(AppDiagnosticEvent._(
        now,
        operation,
        state,
        trace,
        parent,
        reason,
        elapsed,
        status != null && status >= 100 && status <= 599 ? status : null,
        revision != null && revision >= 0 && revision <= 2147483647
            ? revision
            : null,
        area: area));
    while (_events.length > capacity ||
        (_events.isNotEmpty && now.difference(_events.first.at) > retention)) {
      _events.removeFirst();
    }
    if (_file != null && _saveTimer == null) {
      _saveTimer = Timer(const Duration(seconds: 2), () {
        _saveTimer = null;
        unawaited(flush());
      });
    }
  }

  /// Foreground and the single headless drain host write SEPARATE journals.
  /// Reading background evidence must never overwrite its writer's file.
  static Future<void> attach(Directory directory,
      {bool background = false}) async {
    if (_file != null) return;
    final file =
        File('${directory.path}/${background ? backgroundFileName : fileName}');
    if (!background) {
      _backgroundFile = File('${directory.path}/$backgroundFileName');
    }
    try {
      final restored = await _readEvents(file);
      // Events recorded while the file was being read are kept too.
      final pending = _events.toList();
      _events.clear();
      _events.addAll([...restored, ...pending]);
      while (_events.length > capacity) {
        _events.removeFirst();
      }
      _file = file;
      await flush();
      if (!background) await refreshBackground();
    } catch (_) {
      // Storage/diagnostic failures never fail startup or user operations.
      _file = file;
    }
  }

  static Future<List<AppDiagnosticEvent>> _readEvents(File file) async {
    final restored = <AppDiagnosticEvent>[];
    try {
      if (!await file.exists() || await file.length() > maxFileBytes) {
        return restored;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['schema'] != 1 || raw['events'] is! List) {
        return restored;
      }
      final now = DateTime.now().toUtc();
      for (final item in (raw['events'] as List).take(capacity)) {
        final event = AppDiagnosticEvent.decode(item);
        if (event != null &&
            !event.at.isAfter(now) &&
            now.difference(event.at) <= retention) {
          restored.add(event);
        }
      }
    } catch (_) {}
    return restored;
  }

  static Future<void> refreshBackground() async {
    final file = _backgroundFile;
    if (file != null) _backgroundEvents = await _readEvents(file);
  }

  static Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final file = _file;
    if (file == null) return Future<void>.value();
    final contents = jsonEncode(
        {'schema': 1, 'events': _events.map((e) => e.toJson()).toList()});
    _writes = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(contents, flush: true);
        await temp.rename(file.path);
      } catch (_) {}
    });
    return _writes;
  }

  static String exportText() {
    final out = StringBuffer('\n[App diagnostics: local, content-free]\n');
    for (final entry in _counts.entries) {
      out.writeln('count.${entry.key.name}=${entry.value}');
    }
    for (final event in _events) {
      out.writeln(event.line);
    }
    if (_backgroundEvents.isNotEmpty) {
      out.writeln('\n[Background app diagnostics: local, content-free]');
      for (final event in _backgroundEvents) {
        out.writeln(event.line);
      }
    }
    return out.toString();
  }

  /// Test seam; production never clears operation history implicitly.
  static Future<void> resetForTest() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _writes;
    _file = null;
    _backgroundFile = null;
    _backgroundEvents = const [];
    _events.clear();
    _counts.clear();
  }
}
