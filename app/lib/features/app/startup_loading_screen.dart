import 'package:flutter/material.dart';

import '../../core/startup/bootstrap_runner.dart';
import 'app_boot_loader.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';

/// Shown by `runApp()` immediately on cold start, before real async
/// initialization (DB open, session restore, feature flags, ...) has
/// finished. Never shown again after the first successful bootstrap — normal
/// navigation, resume, and background sync use inline/silent indicators
/// instead (see `docs/` refresh policy notes).
class StartupLoadingScreen extends StatelessWidget {
  const StartupLoadingScreen({
    super.key,
    required this.onRetry,
    this.error,
    this.lastStep,
    this.updatingData = false,
  });

  /// WP-7: a rebootstrap swap is in flight (the account is being re-opened on its
  /// fresh replica). Shows "Updating your data…" instead of the startup text.
  final bool updatingData;

  /// Non-null once bootstrap has failed or timed out — switches the screen
  /// to the retry state.
  final Object? error;

  /// Name of the bootstrap step that was running when [error] occurred, for
  /// the optional diagnostic identifier. Never contains user data.
  final String? lastStep;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) return const AppBootLoader();
    final c = context.colors;
    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: _ErrorBody(
                error: error!,
                lastStep: lastStep,
                onRetry: onRetry,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({
    required this.error,
    required this.lastStep,
    required this.onRetry,
  });

  final Object error;
  final String? lastStep;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isTimeout = error is BootstrapTimeoutException;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.primary.withValues(alpha: 0.22)),
          ),
          child: Icon(
            AppLucideIcons.alertTriangle,
            color: c.primary,
            size: 34,
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        Text(
          isTimeout ? context.l10n.startTookLonger : context.l10n.startFailed,
          textAlign: TextAlign.center,
          style: AppTypography.headline(c.textMain),
        ),
        const SizedBox(height: AppSpacing.s2),
        Text(
          context.l10n.startCheckConnection,
          textAlign: TextAlign.center,
          style: AppTypography.callout(c.textLight)
              .copyWith(decoration: TextDecoration.none),
        ),
        if (lastStep != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(
            context.l10n.startStepId(lastStep!),
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textLight),
          ),
        ],
        const SizedBox(height: AppSpacing.s5),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onRetry,
            // سطح ink الموحّد من الثيم (كان primary الكحلي القديم).
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(context.l10n.startRetry),
          ),
        ),
      ],
    );
  }
}
