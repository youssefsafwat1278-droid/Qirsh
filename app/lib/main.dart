import 'dart:io' show File;
import 'package:path_provider/path_provider.dart';
import 'core/startup/install_presentation_store.dart';
import 'core/security/lock_prompt_language.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/backend/sentry_config.dart';
import 'core/di/app_providers.dart';
import 'core/di/local_read_providers.dart';
import 'core/observability/diagnostics.dart';
import 'core/observability/sentry_lifecycle.dart';
import 'core/session/account_scope.dart';
import 'core/session/app_session.dart';
import 'core/startup/bootstrap_runner.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/font_licenses.dart';
import 'data/db/planning_canonical_invariants.dart';
import 'data/db/planning_cutover.dart';
import 'features/app/startup_loading_screen.dart';
import 'core/startup/automatic_session_recovery.dart';
import 'core/utils/app_lucide_icons.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';
import 'core/utils/l10n_ext.dart';
import 'core/theme/widgets/native_glass.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The bundled fonts' OFL notices. Registered here rather than lazily so the
  // obligation is discharged on every launch path, including the one that skips
  // Sentry. The generator is lazy internally, so this costs nothing until the
  // licence page is actually opened.
  registerBundledFontLicenses();
  // MALI-039 — redact + bound every diagnostic line (all call sites, plugins,
  // future code) before it reaches the platform log, in debug and release.
  Diag.installRedactingSink();
  // Astra H2.5: Sentry is NOT initialised here. It is started (and closed again)
  // by SentryLifecycle only while the egress gate permits and diagnostics
  // consent is open — never before bootstrap resolved the gate, never while
  // Cloud is OFF. `attach` only wires the listeners.
  if (SentryConfig.isConfigured) SentryLifecycle.attach();
  // One cached channel call: lets explicit native hosts (sheets, dialogs,
  // toasts, nav) use Apple's real Liquid Glass on iOS 26+.
  unawaited(NativeGlassSupport.probe());
  runApp(const StartupApp());
}

/// Root widget for the first frame. Renders [StartupLoadingScreen] while
/// [BootstrapRunner] performs real async initialization (Supabase, session
/// restore, local DB, seed data, feature flags, capture registration), then
/// swaps itself out for the real [MoneyApp] in the same widget tree. Bootstrap
/// starts after the loading screen's first frame so fast/synchronously
/// completing startup work cannot replace it before the spinner is painted.
/// Nothing here is a fixed/minimum-duration splash; the loading screen is
/// removed the instant bootstrap actually finishes.
class StartupApp extends StatefulWidget {
  const StartupApp(
      {super.key,
      this.runner,
      this.externalOverrides = const [],
      this.externalObservers = const []});

  /// Injectable for lifecycle tests. Production always uses a fresh runner.
  final BootstrapRunner? runner;

  /// External service overrides for real startup lifecycle tests.
  @visibleForTesting
  final List<Override> externalOverrides;

  /// Test-only observers (e.g. to record which providers a scope ever builds).
  @visibleForTesting
  final List<ProviderObserver> externalObservers;

  @override
  State<StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<StartupApp> {
  late final BootstrapRunner _runner;
  AccountScopeHost? _accountScope;
  Object? _error;
  bool _bootstrapping = false;
  InstallPresentationStore? _installPresentation;

  /// ASR §6.7: while auth is deferred (protected data locked) the loading
  /// screen stays up and bootstrap re-runs when protected data becomes
  /// available, on the next foreground, or after a short backoff.
  Timer? _deferredRetry;
  StreamSubscription<void>? _deferredAvailable;
  AppLifecycleListener? _deferredResume;

  @override
  void initState() {
    super.initState();
    _runner = widget.runner ?? BootstrapRunner();
    AutomaticSessionRecovery.recoveryTimedOut.addListener(_onAccountScopeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attempt();
    });
  }

  void _attempt() {
    if (_bootstrapping) return;
    setState(() => _error = null);
    unawaited(_runBootstrap());
  }

  Future<void> _resetDatabaseAndRetry() async {
    await _runner.resetDatabaseAndRetry();
    _attempt();
  }

  /// A switch of account (sign-in of another uid, sign-out, removal) withdraws
  /// the published scope and later publishes a new one: rebuild so every
  /// provider built on the old database is disposed with it.
  void _onAccountScopeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _accountScope?.removeListener(_onAccountScopeChanged);
    AutomaticSessionRecovery.recoveryTimedOut.removeListener(_onAccountScopeChanged);
    _clearDeferredRetry();
    super.dispose();
  }

  void _clearDeferredRetry() {
    _deferredRetry?.cancel();
    _deferredRetry = null;
    _deferredAvailable?.cancel();
    _deferredAvailable = null;
    _deferredResume?.dispose();
    _deferredResume = null;
  }

  void _scheduleDeferredRetry() {
    _clearDeferredRetry();
    void retry() {
      _clearDeferredRetry();
      if (mounted) _attempt();
    }

    _deferredRetry = Timer(const Duration(seconds: 3), retry);
    _deferredAvailable =
        _runner.protectedDataAvailableEvents?.listen((_) => retry());
    _deferredResume = AppLifecycleListener(onResume: retry);
  }

  Future<void> _runBootstrap() async {
    _bootstrapping = true;
    try {
      if (widget.runner == null && _installPresentation == null) {
        final support = await getApplicationSupportDirectory();
        final presentation = InstallPresentationStore(
            File('${support.path}/qirsh_install_presentation_v1.json'));
        await presentation.prepare(
          hasExistingData: () => BootstrapRunner.localInstallDataPresent(support.path),
          resetPresentation: () async {
            await AppSession.instance.resetInstallPresentation();
            await LockPromptLanguage.set('en');
          },
        );
        AppSession.instance.configureInstallPresentation(presentation);
        _installPresentation = presentation;
      }
      await _runner.run();
      if (!mounted) return;
      final host = _runner.accountScope;
      if (!identical(host, _accountScope)) {
        _accountScope?.removeListener(_onAccountScopeChanged);
        host.addListener(_onAccountScopeChanged);
      }
      setState(() => _accountScope = host);
    } catch (error) {
      if (!mounted) return;
      if (error is BootstrapAuthDeferred) {
        // Not a failure: nothing was initialized or published. Keep loading.
        _scheduleDeferredRetry();
        return;
      }
      setState(() => _error = error);
    } finally {
      _bootstrapping = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // While an account switch is in flight the host has withdrawn the previous
    // scope and not yet published the next: the loading screen below shows.
    final host = _accountScope;
    final scope = host?.current;
    if (scope != null) {
      final database = scope.database;
      return ProviderScope(
        // A new generation is a new database and therefore a new provider
        // graph: nothing built for the previous account survives the switch.
        key: ValueKey(scope.generation),
        observers: widget.externalObservers,
        overrides: [
          ...widget.externalOverrides,
          if (scope.isLocalRead) ...localReadProviderOverrides(scope),
          appDatabaseProvider.overrideWithValue(database),
          accountScopeHostProvider.overrideWithValue(host),
          startupHasLocalDataProvider.overrideWithValue(scope.hasLocalData),
          // MALI-026 (B8-3 §1/§12) — seed the coordinator with the REAL state
          // resolved from the DB at bootstrap (canonical for fresh v30, unresolved
          // for upgraded-with-data), so P1/P3 behavior is correct from launch.
          planningCutoverCoordinatorProvider.overrideWith(
            (ref) => DbBackedPlanningCutoverCoordinator(
              initialState: scope.planningCutoverState,
              readUserVersion: () async => (await database
                      .customSelect('PRAGMA user_version;')
                      .getSingle())
                  .read<int>('user_version'),
              readMarker: () async => (await database
                      .customSelect(
                          'SELECT planning_cutover_state AS s FROM user_settings;')
                      .getSingle())
                  .read<int>('s'),
              countCanonicalViolations: () async =>
                  (await planningCanonicalViolations(database)).length,
            ),
          ),
        ],
        child: const MoneyApp(),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      locale: Locale(LockPromptLanguage.initialSettingsLanguage),
      // Loading uses the same language-independent branded view as MoneyApp.
      // Retry/error copy uses the saved language mirror once bootstrap reads it.
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // A timeout can land while `database_open` is the step in flight (it's
      // simply the slowest step, e.g. first-run key generation) without the
      // database itself being corrupt — only route to the destructive
      // reset flow for a real database_open failure, never for a timeout.
      home: AutomaticSessionRecovery.recoveryTimedOut.value
          ? StartupLoadingScreen(
              error: const BootstrapTimeoutException('session_recovery'),
              lastStep: 'session_recovery',
              onRetry: () => AutomaticSessionRecovery.active?.trigger(),
            )
          : _error is BootstrapCoordinatorUnavailable
          // C1: fail closed. No database is involved in this screen and nothing
          // behind it can open; Retry re-runs bootstrap from the start.
          ? _CoordinatorUnavailableView(onRetry: _attempt)
          : _error != null &&
              _error is! BootstrapTimeoutException &&
              _runner.lastStep == 'database_open'
          ? _DatabaseRecoveryView(onReset: _resetDatabaseAndRetry)
          : StartupLoadingScreen(
              updatingData: host?.swapInProgress ?? false,
              error: _error,
              lastStep: _runner.lastStep,
              onRetry: _attempt,
            ),
    );
  }
}

/// C1: the database-access coordinator could not be created or proven. Shown
/// before any persistent replica is opened; offers only Retry (never a reset,
/// never an offline fallback).
class _CoordinatorUnavailableView extends StatelessWidget {
  const _CoordinatorUnavailableView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('startup-coordinator-unavailable'),
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppLucideIcons.alertCircle,
                  color: Colors.white70, size: 64),
              const SizedBox(height: 16),
              Text(
                context.l10n.startupCoordinatorTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.startupCoordinatorBody,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('startup-coordinator-retry'),
                  onPressed: onRetry,
                  child: Text(context.l10n.startupCoordinatorRetry),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the local encrypted DB can't be opened (corrupt file, or a
/// key/file mismatch after the keychain was cleared) — lets the user
/// explicitly reset their data rather than being stuck on a generic retry
/// that would just fail identically.
class _DatabaseRecoveryView extends StatefulWidget {
  const _DatabaseRecoveryView({required this.onReset});

  final Future<void> Function() onReset;

  @override
  State<_DatabaseRecoveryView> createState() => _DatabaseRecoveryViewState();
}

class _DatabaseRecoveryViewState extends State<_DatabaseRecoveryView> {
  bool _resetting = false;

  Future<void> _reset() async {
    setState(() => _resetting = true);
    try {
      await widget.onReset();
    } catch (_) {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Direction follows the resolved locale — this view is now localized, and
    // a forced RTL would mirror an English layout.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppLucideIcons.alertCircle,
                  color: Colors.white70, size: 64),
              const SizedBox(height: 16),
              Text(
                context.l10n.dbRecoveryTitle,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.dbRecoveryBody,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _resetting ? null : _reset,
                  // الشاشة دي خلفيتها سودا صريحة تحت ثيم فاتح — زر ink
                  // الفاتح (أسود) هيختفي عليها، فنقلب الألوان يدويًا.
                  //
                  // DESTRUCTIVE, and styled as such. This button deletes the
                  // user's entire local financial history, and it rendered
                  // white-on-black: the neutral, default affordance, on the
                  // only control this screen has. The prototype's
                  // SHELL-DATABASE-RECOVERY frame draws it red, and the rest
                  // of the app already reserves red for deletion.
                  //
                  // The colour is a literal because this view runs BEFORE the
                  // database opens, which is before the theme extension that
                  // carries `danger` is available; it is the same
                  // 0xFFDC2626 that token holds.
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                  ),
                  child: _resetting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(context.l10n.dbRecoveryReset),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
