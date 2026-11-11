import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/app_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/app_empty_state.dart';
import '../common/app_error_state.dart';
import '../common/app_loading_state.dart';
import '../common/app_screen_scaffold.dart';
import '../common/top_banner.dart';
import 'referral_error.dart';
import 'referral_models.dart';
import 'referrals_providers.dart';

/// Invite Friends — the mobile referral experience (Phase R3). Presents the
/// server-authoritative summary (get_referral_summary): code, cycle progress,
/// reward, and ad-free entitlement, plus the one-time manual code-apply flow.
/// The client never computes progress or entitlement — it only displays what
/// the server returns.
class ReferralsScreen extends ConsumerStatefulWidget {
  const ReferralsScreen({super.key});

  @override
  ConsumerState<ReferralsScreen> createState() => _ReferralsScreenState();
}

class _ReferralsScreenState extends ConsumerState<ReferralsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final summaryAsync = ref.watch(referralSummaryProvider);

    return AppScreenScaffold(
      header: AppHeader(title: l10n.referralTitle),
      // Immersive: the body runs under the glass bar; every state starts
      // below it (this context sees the bar's top inset).
      body: Builder(builder: (bodyContext) => summaryAsync.when(
        skipLoadingOnReload: true,
        loading: () => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(bodyContext).top),
          child: AppLoadingState(label: l10n.referralLoading),
        ),
        error: (_, __) => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(bodyContext).top),
          child: AppErrorState(
            title: l10n.referralErrorTitle,
            description: l10n.referralErrorBody,
            retryLabel: l10n.referralRetry,
            onRetry: () => ref.invalidate(referralSummaryProvider),
          ),
        ),
        data: (summary) {
          // null == feature gated off (or Supabase unconfigured): present the
          // controlled unavailable state, never active referral functionality.
          //
          // v2 (spec 22): centred at the optical centre (44%) with a 200pt
          // illustration. No action — there is nothing for the user to do.
          if (summary == null) {
            final top = MediaQuery.paddingOf(bodyContext).top;
            return LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: EdgeInsets.only(top: top),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight:
                      (box.maxHeight - top).clamp(0.0, double.infinity)),
                  child: Align(
                    alignment: const Alignment(0, -.12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.gutter),
                      child: AppEmptyState(
                        icon: AppLucideIcons.gift,
                        illustration: const QirshIllustration(
                            name: 'referral', width: 267, height: 200),
                        title: l10n.referralUnavailableTitle,
                        subtitle: l10n.referralUnavailableBody,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return _ReferralBody(summary: summary);
        },
      )),
    );
  }
}

class _ReferralBody extends ConsumerStatefulWidget {
  const _ReferralBody({required this.summary});
  final ReferralSummary summary;

  @override
  ConsumerState<_ReferralBody> createState() => _ReferralBodyState();
}

class _ReferralBodyState extends ConsumerState<_ReferralBody> {
  final _codeController = TextEditingController();
  bool _applying = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    showTopInfo(context, context.l10n.referralCopiedToast);
  }

  Future<void> _shareCode(String code) async {
    await Share.share(context.l10n.referralShareMessage(code));
  }

  Future<void> _applyCode() async {
    final l10n = context.l10n;
    final code = _codeController.text.trim();
    if (code.isEmpty || _applying) return;
    setState(() => _applying = true);
    try {
      final outcome = await ref.read(referralServiceProvider).applyCode(code);
      if (!mounted) return;
      if (outcome.ok) {
        _codeController.clear();
        showTopInfo(context, l10n.referralApplySuccess);
        // If the inline qualification already counted, surface that too.
        if (outcome.qualification?.qualified == true) {
          showTopInfo(context, l10n.referralQualifiedToast);
        }
        ref.invalidate(referralSummaryProvider);
      } else {
        showTopError(context, referralReasonMessage(l10n, outcome.reason));
      }
    } catch (error) {
      if (mounted) {
        showTopError(context, referralThrownMessage(l10n, error));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        MediaQuery.paddingOf(context).top + AppSpacing.s2,
        AppSpacing.gutter,
        AppSpacing.s8,
      ),
      children: [
        const Center(
          child: QirshIllustration(
              name: 'referral', width: 250, height: 187.5),
        ),
        const SizedBox(height: AppSpacing.s3),
        Text(context.l10n.referralSubtitle, textAlign: TextAlign.center,
            style: AppTypography.callout(context.colors.textMuted)),
        const SizedBox(height: AppSpacing.s4),
        _CodeCard(
          code: summary.referralCode,
          onCopy: () => _copyCode(summary.referralCode),
          onShare: () => _shareCode(summary.referralCode),
        ),
        const SizedBox(height: AppSpacing.s3),
        _ProgressCard(summary: summary),
        const SizedBox(height: AppSpacing.s3),
        _RewardCard(summary: summary),
        if (summary.attributionStatus == AttributionStatus.none) ...[
          const SizedBox(height: AppSpacing.s3),
          _ApplyCard(
            controller: _codeController,
            applying: _applying,
            onApply: _applyCode,
          ),
        ] else ...[
          const SizedBox(height: AppSpacing.s3),
          _AlreadyReferredNote(),
        ],
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.onCopy, required this.onShare});
  final String code;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    return MaliCard(
      style: MaliSurfaceStyle.glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.referralYourCodeLabel,
              style: AppTypography.caption(c.textSecondary)),
          const SizedBox(height: AppSpacing.s2),
          Semantics(
            label: '${l10n.referralYourCodeLabel} $code',
            child: Text(
              code.isEmpty ? '—' : code,
              style: AppTypography.title(c.textPrimary).copyWith(
                fontSize: 30,
                letterSpacing: 3,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.copy_rounded,
                  label: l10n.referralCopyAction,
                  onTap: code.isEmpty ? null : onCopy,
                  filled: true,
                ),
              ),
              const SizedBox(width: AppSpacing.buttonGap),
              Expanded(
                child: _ActionButton(
                  icon: Icons.ios_share_rounded,
                  label: l10n.referralShareAction,
                  onTap: code.isEmpty ? null : onShare,
                  filled: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.summary});
  final ReferralSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final required = summary.requiredReferrals;
    final fraction = (required != null && required > 0)
        ? (summary.progress / required).clamp(0.0, 1.0)
        : 0.0;

    return MaliCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  required != null
                      ? l10n.referralProgressLabel(summary.progress, required)
                      : l10n.referralUnavailableTitle,
                  style: AppTypography.bodyStrong(c.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                l10n.referralCycleLabel(summary.cycleIndex),
                style: AppTypography.caption(c.textSecondary),
              ),
            ],
          ),
          if (required != null) ...[
            const SizedBox(height: AppSpacing.s2),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: c.surfaceMuted,
                valueColor: AlwaysStoppedAnimation<Color>(c.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({required this.summary});
  final ReferralSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final days = summary.rewardDays;

    String entitlementLine;
    if (summary.entitlementActive && summary.entitlementEndsAt != null) {
      final locale = Localizations.localeOf(context).toString();
      final date = DateFormat.yMMMMd(locale).format(summary.entitlementEndsAt!.toLocal());
      entitlementLine = l10n.referralRewardActiveUntil(date);
    } else {
      entitlementLine = l10n.referralEntitlementInactive;
    }

    return MaliCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.referralRewardTitle, style: AppTypography.bodyStrong(c.textPrimary)),
          const SizedBox(height: AppSpacing.s2),
          if (days != null)
            Text(l10n.referralRewardDays(days), style: AppTypography.body(c.textPrimary)),
          const SizedBox(height: 4),
          // §5: the reward is REPORT-EXPORT ad-free only, never a global ad-free.
          Text(
            l10n.referralRewardScopeNote,
            style: AppTypography.caption(c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s3),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3,
              vertical: AppSpacing.s2,
            ),
            decoration: BoxDecoration(
              color: summary.entitlementActive ? c.successBg : c.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(
                  summary.entitlementActive
                      ? Icons.verified_rounded
                      : Icons.schedule_rounded,
                  size: 18,
                  color: summary.entitlementActive ? c.onSuccess : c.textSecondary,
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    entitlementLine,
                    style: AppTypography.caption(
                      summary.entitlementActive ? c.onSuccess : c.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApplyCard extends StatelessWidget {
  const _ApplyCard({
    required this.controller,
    required this.applying,
    required this.onApply,
  });
  final TextEditingController controller;
  final bool applying;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    return MaliCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.referralApplyTitle, style: AppTypography.bodyStrong(c.textPrimary)),
          const SizedBox(height: 4),
          Text(l10n.referralApplyHint, style: AppTypography.caption(c.textSecondary)),
          const SizedBox(height: AppSpacing.s3),
          TextField(
            controller: controller,
            enabled: !applying,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: l10n.referralApplyPlaceholder,
              filled: true,
              fillColor: c.surfaceMuted,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            width: double.infinity,
            child: _ActionButton(
              icon: Icons.check_rounded,
              label: applying ? '…' : l10n.referralApplyAction,
              onTap: applying ? null : onApply,
              filled: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _AlreadyReferredNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    return MaliCard(
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 20, color: c.success),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              l10n.referralAlreadyReferredNote,
              style: AppTypography.caption(c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.filled,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = filled ? c.onCta : c.textPrimary;
    final bg = filled ? c.cta : Colors.transparent;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          height: AppSpacing.buttonHeight,
          alignment: Alignment.center,
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: c.border),
                ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: onTap == null ? c.disabledFg : fg),
              const SizedBox(width: AppSpacing.iconGap),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label(onTap == null ? c.disabledFg : fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
