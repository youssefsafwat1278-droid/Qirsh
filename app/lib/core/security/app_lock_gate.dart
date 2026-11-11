import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../features/app/app_boot_loader.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/app_lucide_icons.dart';
import 'app_lock_service.dart';
import 'lock_prompt_language.dart';
import '../utils/l10n_ext.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  static const Duration _backgroundLockDelay = Duration(seconds: 30);
  static const Duration _recentAuthenticationGrace = Duration(seconds: 8);

  bool _checking = true;
  bool _locked = false;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _lockIfNeeded());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authenticating) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final backgroundedAt = _backgroundedAt;
      _backgroundedAt = null;
      final shouldLock = backgroundedAt != null &&
          DateTime.now().difference(backgroundedAt) >= _backgroundLockDelay;
      _lockIfNeeded(forceLock: shouldLock);
    }
  }

  Future<void> _lockIfNeeded({bool forceLock = true}) async {
    if (_authenticating || !mounted) return;
    final enabled = await AppLockService.instance.isEnabled();
    if (!mounted) return;
    if (!enabled) {
      setState(() {
        _checking = false;
        _locked = false;
      });
      return;
    }
    // Already locked (the prompt was cancelled or failed): only a successful
    // authentication may open it. A short trip to the background must not.
    if (_locked) {
      await _unlock();
      return;
    }
    if (!forceLock) {
      setState(() => _checking = false);
      return;
    }
    if (AppLockService.instance.wasRecentlyAuthenticated(
      _recentAuthenticationGrace,
    )) {
      setState(() {
        _checking = false;
        _locked = false;
      });
      return;
    }
    setState(() {
      _checking = false;
      _locked = true;
    });
    await _unlock();
  }

  /// The prompt string handed to iOS, which draws it itself.
  ///
  /// NOT `context.l10n.lockPrompt`. The gate raises the prompt from the first
  /// frame's post-frame callback — deliberately, so nothing protected is ever
  /// on screen unauthenticated — and at that moment `userSettingsProvider` has
  /// not opened the encrypted database, so `context.l10n` is still the app
  /// default rather than the reader's language. Measured on a cold start with
  /// English persisted: the prompt went out in Arabic.
  ///
  /// [LockPromptLanguage] is a keychain mirror of `user_settings.language`
  /// written by every path that changes it, so this is one local read with no
  /// database, provider, network or bootstrap behind it — and it runs while the
  /// lock screen is already up, so it opens no window.
  Future<String> _promptReason() async {
    final language = await LockPromptLanguage.read();
    return (await AppL10n.delegate.load(Locale(language))).lockPrompt;
  }

  Future<void> _unlock() async {
    if (_authenticating || !mounted) return;
    setState(() => _authenticating = true);
    HapticFeedback.selectionClick();
    final reason = await _promptReason();
    final ok = await AppLockService.instance.authenticate(reason: reason);
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _locked = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    // widget.child is built only once the gate is open; while it checks, and
    // while the system prompt is up, the loader's coin stays on screen.
    final open = !_checking && !_locked;
    final locked = _locked && !_authenticating;
    return AppBootLoaderReveal(
      loading: !open,
      // The loader's composition: the coin on navy, with its ring only while
      // the check runs. Only once authentication failed or was cancelled
      // does a short line and the unlock button appear under the coin.
      loader: BootCoinStage(
        ring: _checking,
        footer: locked ? _LockFooter(onUnlock: _unlock) : null,
      ),
      child: open ? widget.child : null,
    );
  }
}

class _LockFooter extends StatelessWidget {
  const _LockFooter({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.lockTitle,
            textAlign: TextAlign.center,
            style: AppTypography.footnote(
                Colors.white.withValues(alpha: 0.62)),
          ),
          const SizedBox(height: AppSpacing.s3),
          TextButton.icon(
            onPressed: onUnlock,
            icon: const Icon(AppLucideIcons.unlock, size: 16),
            label: Text(context.l10n.lockUnlock),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.10),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s5, vertical: AppSpacing.s3),
              shape: StadiumBorder(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
              ),
              textStyle: AppTypography.subhead(Colors.white)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
