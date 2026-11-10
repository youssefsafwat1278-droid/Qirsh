import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_coordinator.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/session/app_session.dart';
import '../../core/startup/automatic_session_recovery.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../../l10n/app_localizations.dart';
import 'app_boot_loader.dart';
import 'local_read_cleanup_notice.dart';

/// Presentation for an existing, verified read-only scope. The scope and its
/// restrictions stay intact; automatic recovery shows only the branded loader.
/// If it stops, offer retry or explicit sign-in without mounting financial
/// providers, producers or the old Offline / Reconnect screen.
class LocalReadShell extends StatefulWidget {
  const LocalReadShell({
    super.key,
    this.onReconnect,
    this.onLogout,
    this.signOutAction,
    this.retryDeny,
  });

  /// Test seams; the defaults are the real sign-in route and logout.
  final VoidCallback? onReconnect;
  final Future<void> Function()? onLogout;
  final Future<SignOutOutcome> Function()? signOutAction;
  final Future<bool> Function()? retryDeny;

  @override
  State<LocalReadShell> createState() => _LocalReadShellState();
}

class _LocalReadShellState extends State<LocalReadShell> {
  bool _initialRecoveryPending = false;

  @override
  void initState() {
    super.initState();
    final recovery = AutomaticSessionRecovery.active;
    if (recovery == null || AutomaticSessionRecovery.recoveryTimedOut.value) return;
    _initialRecoveryPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Bootstrap triggers after the first frame. Wait one event-loop turn,
      // then wait for the actual attempt rather than a fixed display timeout.
      unawaited(Future<void>(() async {
        if (!mounted) return;
        await recovery.quiesced().timeout(recovery.presentationDeadline,
            onTimeout: () {});
        if (mounted) setState(() => _initialRecoveryPending = false);
      }));
    });
  }

  Future<void> _logout(NavigatorState navigator, AppL10n l10n) async {
    final outcome =
        await (widget.signOutAction ?? AppSession.instance.signOut)();
    if (SupabaseConfig.isConfigured) {
      try {
        // ASR §4.9: durable removal first, then the server revocation.
        await AuthCoordinator.logout(supabase.Supabase.instance.client.auth);
      } catch (_) {
        // The local sign-out already protects the device.
      }
    }
    if (outcome == SignOutOutcome.durableDenyIncomplete) {
      // Signed out and locked for this process, but the durable lock is not
      // established: say so, honestly, with a retry of only that step.
      await showSignOutIncompleteNotice(navigator, l10n,
          retry: widget.retryDeny);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AutomaticSessionRecovery.restoringSession,
        builder: (context, recovering, _) {
          if (_initialRecoveryPending || recovering) {
            return const Scaffold(body: AppBootLoader());
          }
          final l10n = context.l10n;
          final c = context.colors;
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(AppAssets.getLogoTagline(context),
                            width: 220),
                        const SizedBox(height: 28),
                        Text(l10n.sessionRecoveryTitle,
                            textAlign: TextAlign.center,
                            style: AppTypography.title2(c.textPrimary)),
                        const SizedBox(height: 12),
                        Text(l10n.sessionRecoveryBody,
                            textAlign: TextAlign.center,
                            style: AppTypography.body(c.textSecondary)),
                        const SizedBox(height: 24),
                        if (AutomaticSessionRecovery.active != null)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              key: const Key('session_recovery_retry'),
                              onPressed: () =>
                                  AutomaticSessionRecovery.active?.trigger(),
                              child: Text(l10n.startRetry),
                            ),
                          ),
                        TextButton(
                          key: const Key('local_read_reconnect'),
                          onPressed: widget.onReconnect ??
                              () {
                                AutomaticSessionRecovery.active
                                    ?.yieldToExplicitAttempt();
                                GoRouter.of(context).go('/onboarding/auth');
                              },
                          child: Text(l10n.sessionRecoverySignIn),
                        ),
                        TextButton(
                          key: const Key('local_read_logout'),
                          onPressed: () async {
                            final navigator =
                                Navigator.of(context, rootNavigator: true);
                            try {
                              await (widget.onLogout?.call() ??
                                  _logout(navigator, l10n));
                            } catch (_) {
                              if (context.mounted) {
                                AppToast.showError(
                                    context, l10n.localReadLogoutFailed);
                              }
                            }
                          },
                          child: Text(l10n.localReadLogout),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
