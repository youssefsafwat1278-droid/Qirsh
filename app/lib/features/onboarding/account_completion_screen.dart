import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/auth_coordinator.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';
import '../app/app_boot_loader.dart';
import '../common/app_error_state.dart';
import 'auth_screen.dart' show signInFailureCode;

/// Verifies the admitted account before routing to setup. A failed lookup can
/// be retried with the current session, without another provider sign-in, or
/// left with "Use another account". The failure shows a non-sensitive reason
/// code so a field report can be diagnosed.
class OnboardingAccountCompletionScreen extends StatefulWidget {
  const OnboardingAccountCompletionScreen({
    super.key,
    required this.client,
    this.signOutAction,
  });

  final SupabaseClient client;

  /// Test seam; defaults to the local sign-out plus the session revocation.
  final Future<void> Function()? signOutAction;

  @override
  State<OnboardingAccountCompletionScreen> createState() =>
      _AccountCompletionState();
}

class _AccountCompletionState extends State<OnboardingAccountCompletionScreen> {
  bool _busy = false;
  bool _failed = false;
  String? _failureCode;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final completed = await AppSession.instance.reconcileAccountOnboarding(
        widget.client,
        requireRemoteResult: true,
      );
      if (mounted) context.go(completed ? '/' : '/onboarding/setup');
    } catch (error) {
      if (!mounted) return;
      final session = widget.client.auth.currentSession;
      if (session == null || session.isExpired) {
        context.go('/onboarding/auth');
      } else {
        final cause =
            error is OnboardingStatusUnavailable ? error.cause : error;
        setState(() {
          _failed = true;
          _failureCode = cause == null ? null : signInFailureCode(cause);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useAnotherAccount() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final action = widget.signOutAction;
      if (action != null) {
        await action();
      } else {
        await AppSession.instance.signOut();
        try {
          await AuthCoordinator.logout(widget.client.auth);
        } catch (_) {
          // The local sign-out already protects the device.
        }
      }
      if (mounted) context.go('/onboarding/auth');
    } catch (_) {
      // Stay on this screen; retry and sign-out both remain available.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.bg,
        body: _failed
            ? SafeArea(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.sizeOf(context).height -
                          MediaQuery.paddingOf(context).vertical,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AppErrorState(
                          title: context.l10n.startFailed,
                          description:
                              context.l10n.onboardingAccountCheckFailed,
                          retryLabel: context.l10n.startRetry,
                          onRetry: _busy ? null : _check,
                        ),
                        if (_failureCode != null)
                          Text('(E: $_failureCode)',
                              key: const Key('account_check_code'),
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: context.colors.textSecondary)),
                        TextButton(
                          key: const Key('account_check_other_account'),
                          onPressed: _busy ? null : _useAnotherAccount,
                          child:
                              Text(context.l10n.onboardingUseAnotherAccount),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : const AppBootLoader(),
      );
}
