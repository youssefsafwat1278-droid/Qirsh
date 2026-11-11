import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/privacy/gated_url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/admission_authority.dart';
import '../../core/session/consent_capability.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../coupons/coupons_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../core/config/legal_urls.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import 'consent_status.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../common/app_card.dart';
import '../common/app_status_pill.dart';
import 'widgets/settings_v2.dart';
import 'settings_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_dialog.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  // C-5: configured in one place — see core/config/legal_urls.dart.
  static final Uri _privacyPolicyUrl = kPrivacyPolicyUrl;
  static final Uri _termsUrl = kTermsUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    // v2 §24: QNavBar + QLargeTitle, shield illustration, the control
    // statement as a success-tinted card, link rows in ONE Group, the
    // processing card, then a danger Group. Copy is unchanged and nothing is
    // folded away.
    return SettingsV2Page(
      title: l10n.privTitle,
      showBack: Navigator.of(context).canPop(),
      children: [
        const SizedBox(height: AppSpacing.s2),
        const Center(
          child: QirshIllustration(
            name: 'privacy', width: 187, height: 140,
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        SettingsV2Tinted(
          background: c.successBg,
          accent: c.success,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.helpPrivacyTitle,
                style: AppTypography.custom(size: 18, weight: FontWeight.w700,
                    height: 1.35, color: c.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.helpPrivacyBody,
                style: AppTypography.callout(c.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(l10n.privIntro,
                style: AppTypography.caption(c.textSecondary)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        SettingsV2Group(children: [
          _PrivacyCard(
            icon: AppLucideIcons.fileText,
            title: context.l10n.privPolicy,
            onTap: () => _openExternalLink(context, _privacyPolicyUrl),
          ),
          _PrivacyCard(
            icon: AppLucideIcons.gavel,
            title: context.l10n.privTerms,
            onTap: () => _openExternalLink(context, _termsUrl),
          ),
          _PrivacyCard(
            icon: AppLucideIcons.arrowUpDown,
            title: context.l10n.privTransferMyData,
            onTap: () => context.push('/data-transfer'),
          ),
        ]),
        SettingsV2Label(context.l10n.privDataProcessing),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: ref.watch(userSettingsProvider).maybeWhen(
                skipLoadingOnReload: true,
                data: (settings) => Column(
                  children: [
                    // Cloud sync and Smart Analysis are one disclosed
                    // permission: a status the person can trust and
                    // deliberate actions, not a daily switch. Re-consent
                    // reopens the existing disclosure; withdrawal is
                    // confirmed and stops both together.
                    _ConsentManagementCard(
                      settings: settings,
                      withdraw: _withdrawConsent,
                    ),
                    if (settings.cloudProcessingEnabled &&
                        ref
                                .watch(captureRegistrationStatusProvider)
                                .phase !=
                            CaptureRegistrationPhase.notRequested)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.s3),
                        child: SmartAnalysisRegistrationStatus(),
                      ),
                    // COUPONS Phase 1 — merchant personalization.
                    //
                    // Sits here, next to the cloud and AI consents, because
                    // it is the same KIND of decision even though it involves
                    // no server: it is the user choosing whether their
                    // spending shapes what they are shown. Burying it in the
                    // Offers screen would make it look like a display
                    // preference rather than a data one.
                    //
                    // Only shown when the capability flag is on — asking
                    // about a feature that cannot run would be noise. Unlike
                    // the two above it never leaves the device, so the copy
                    // says so plainly rather than describing an upload that
                    // does not happen.
                    if (ref.watch(merchantOffersEnabledProvider))
                      _ConsentSwitchCard(
                        icon: AppLucideIcons.store,
                        title: l10n.couponsPersonalizationTitle,
                        subtitle: l10n.couponsPersonalizationBody,
                        value: settings.merchantPersonalizationEnabled,
                        onChanged: (value) =>
                            _setMerchantPersonalization(ref, value),
                      ),
                  ],
                ),
                orElse: () => const SizedBox.shrink(),
              ),
        ),
        SettingsV2Label(context.l10n.privDangerZone, color: c.danger),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: ref.watch(accountDeletionStatusProvider).maybeWhen(
                data: (status) => status.isPending
                    ? _PendingDeletionCard(
                        scheduledAt: status.scheduledAt!,
                        onCancel: () => _confirmCancelDeletion(context, ref),
                      )
                    : const SizedBox.shrink(),
                orElse: () => const SizedBox.shrink(),
              ),
        ),
        SettingsV2Group(children: [
          _PrivacyCard(
            icon: AppLucideIcons.trash2,
            title: context.l10n.privDeleteAccountAll,
            subtitle: context.l10n.setDeleteAccountSub,
            onTap: () => context.push('/delete-account'),
            danger: true,
          ),
        ]),
      ],
    );
  }

  /// Withdraws BOTH permissions (Cloud sync and Smart Analysis) and pushes the
  /// new state to the native capture layer immediately (the iOS extension reads
  /// it from the App Group), so revoking cloud processing takes effect without
  /// waiting for a restart.
  ///
  /// This screen never widens consent. Turning on is only the disclosure
  /// ([showSmartAnalysisConsentSheet] -> [saveConsentChoice] -> the typed
  /// enable of the registration service), whose route follows the stored choice
  /// AND the live/pending authority; there is no enable branch here.
  ///
  /// [work] is the consent capability of the lifecycle the person confirmed the
  /// withdrawal in, captured BEFORE the confirmation opened and verified by the
  /// caller; it is the only authority this uses. The choices are merged into
  /// the CURRENT stored row (never a stale snapshot) through the TYPED consent
  /// transaction, which verifies the capability, database and replica owner. A
  /// Cloud ON->OFF is the restrictive disable protocol, not a plain save. If
  /// that lifecycle ends meanwhile (logout, removal, readmission) nothing
  /// further happens: no later write, diagnostics change, sync or cache refresh
  /// reaches whatever scope is live now. Network (the revoke, the backend sync)
  /// stays outside the bounded local work.
  ///
  /// [report] hears an honest failure (only while this lifecycle is still the
  /// live one); the caller never infers success from the absence of one.
  Future<void> _withdrawConsent(
    WidgetRef ref,
    ConsentLocalWork work, {
    VoidCallback? report,
  }) async {
    if (!work.current) return; // the lifecycle ended: nothing is changed
    const choices = ConsentChoices(
        cloud: ConsentState.declined, ai: ConsentState.declined);
    final registration = ref.read(captureDeviceRegistrationServiceProvider);
    final repository = ref.read(userSettingsRepositoryProvider);
    final writer = ref.read(consentSettingsWriterProvider);

    void applied(UserSettingsEntity persisted) {
      if (!work.current) return;
      if (ref.context.mounted) ref.invalidate(userSettingsProvider);
      // OD-05 (C-3) — apply the diagnostics gate IMMEDIATELY, in the same turn as
      // the withdrawal. Sentry's beforeSend is synchronous and cannot await a
      // settings read, so the gate is pushed rather than pulled: a revocation
      // must take effect before the next crash, not at the next startup.
      DiagnosticsConsentGate.set(
        ConsentAuthority.decide(EgressClass.diagnostics, persisted),
      );
    }

    Future<void> commit() async {
      applied(await writer.saveConsentChoice(work.capability, choices));
    }

    try {
      final before = await work.run(repository.getSettings);
      if (!work.current) return;
      // The would-be row: the CURRENT stored settings with the withdrawal applied.
      final updated = choices.applyTo(before);
      // R18: a pending/uncertain enable is withdrawn by the verified restrictive
      // operation, which clears only the exact attributable pending evidence; a
      // plain save or a plain disable would leave the durable pending behind.
      if (await registration.pendingEnableState(before,
              ownerUid: work.capability.uid) !=
          PendingEnableState.none) {
        if (!work.current) return;
        DiagnosticsConsentGate.set(false);
        try {
          await registration.withdrawPendingEnable(
              capability: work.capability,
              commitLocalOff: () => work.run(commit));
        } on StaleAdmissionException {
          return;
        } catch (_) {
          // FAIL CLOSED: not verified; egress stays denied.
          if (work.current) report?.call();
          return;
        }
      } else if (registration.isDisablingCloud(before, updated)) {
        // E1: Cloud ON->OFF is a transition, not a plain save: freeze egress, one
        // best-effort revoke, then commit OFF whatever the revoke did.
        DiagnosticsConsentGate.set(false);
        try {
          await registration.disableCloud(
              commitLocalOff: () => work.run(commit));
        } catch (_) {
          // FAIL CLOSED: local OFF failed; egress stays frozen, next launch completes.
          if (work.current) report?.call();
          return;
        }
      } else {
        await work.run(commit);
      }
    } on StaleAdmissionException {
      return; // the lifecycle ended: nothing reaches the live scope
    }
    if (!work.current) return;
    try {
      await registration.syncBackendState();
    } catch (_) {
      // Best-effort: the startup sync re-applies the stored value anyway.
    }
  }

  /// Merchant personalization uses the authenticated local drain and changes
  /// only its own column; it never performs a consent transition or sync.
  Future<void> _setMerchantPersonalization(WidgetRef ref, bool value) async {
    final context = ref.context;
    final work = AdmittedLocalWork.capture(ref);
    if (work == null) return;
    final writer = ref.read(merchantPreferenceWriterProvider);
    // Bind the retained authority to this widget's exact current database too.
    final authority = AdmissionAuthority(
      work.authority.uid,
      () => work.current,
      epoch: work.authority.epoch,
    );
    try {
      await work.local(() =>
          writer.saveMerchantPersonalization(authority, work.database, value));
    } on StaleAdmissionException {
      return;
    } catch (_) {
      if (context.mounted && work.current) {
        AppToast.showError(context, context.l10n.setupSaveFailed);
      }
      return;
    }
    if (work.current) ref.invalidate(userSettingsProvider);
  }

  Future<void> _openExternalLink(BuildContext context, Uri url) async {
    final opened = await launchExternalUrl(url);
    if (!opened && context.mounted) {
      AppToast.showError(context, context.l10n.privLinkFailed);
    }
  }

  Future<void> _confirmCancelDeletion(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(context.l10n.privCancelDeleteTitle),
        content: Text(context.l10n.privCancelDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.privKeepAccount)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.privCancelDeletion)),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(accountDeletionServiceProvider).cancelDeletion();
      ref.invalidate(accountDeletionStatusProvider);
    } catch (error) {
      if (!context.mounted) return;
      final message = error is RepoException
          ? repoErrorMessage(context, error)
          : context.l10n.privCancelFailed;
      AppToast.showError(context, message);
    }
  }
}

/// Cloud sync + Smart Analysis as ONE disclosed permission: an honest status and
/// deliberate actions. Nothing here changes a choice by being rendered; Turn on
/// reopens the existing disclosure (only its Accept grants), Turn off asks first
/// and then stops both together through the restrictive disable protocol.
class _ConsentManagementCard extends ConsumerStatefulWidget {
  const _ConsentManagementCard({
    required this.settings,
    required this.withdraw,
  });

  final UserSettingsEntity settings;
  final Future<void> Function(WidgetRef ref, ConsentLocalWork work,
      {VoidCallback? report}) withdraw;

  @override
  ConsumerState<_ConsentManagementCard> createState() =>
      _ConsentManagementCardState();
}

class _ConsentManagementCardState
    extends ConsumerState<_ConsentManagementCard> {
  bool _busy = false;

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(userSettingsProvider);
    ref.invalidate(consentLiveFactsProvider);
  }

  Future<void> _turnOn() async {
    if (_busy) return;
    final work = ref.read(consentLocalWorkProvider)();
    setState(() => _busy = true);
    try {
      await showSmartAnalysisConsentSheet(context, ref,
          management: true, work: work);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // A lifecycle that ended meanwhile leaves the live scope untouched.
    if (work != null && !work.current) return;
    _refresh();
  }

  Future<void> _turnOff() async {
    if (_busy) return;
    // G5: the outgoing scope is captured and BOUND before the confirmation
    // opens. The confirmation belongs to that lifecycle only: after a
    // readmission or account switch, a NEW valid capability exists, but this
    // dialog must not act through it.
    final scope = ref.read(consentLocalWorkProvider)();
    if (scope == null) return; // no committed lifecycle: nothing to withdraw
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(l10n.consentWithdrawTitle),
        content: Text(l10n.consentWithdrawBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel)),
          TextButton(
              key: const Key('consentWithdrawConfirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.consentWithdrawConfirm)),
        ],
      ),
    );
    // Verify that SAME scope before acting.
    if (confirmed != true || !mounted || !scope.current) return;
    setState(() => _busy = true);
    var failed = false;
    try {
      // Both permissions, together: the withdrawal never leaves one behind.
      await widget.withdraw(
        ref,
        scope,
        report: () => failed = true,
      );
    } catch (_) {
      failed = true;
    }
    if (mounted) setState(() => _busy = false);
    if (!mounted || !scope.current) return;
    _refresh();
    if (failed) {
      AppToast.showError(context, context.l10n.consentWithdrawFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final facts = ref.watch(consentLiveFactsProvider).valueOrNull;
    final status = deriveConsentStatus(widget.settings, facts);
    final (label, body, icon, _) = switch (status) {
      ConsentStatus.active => (
          l10n.consentStatusActive,
          l10n.consentStatusActiveBody,
          AppLucideIcons.cloud,
          c.success
        ),
      ConsentStatus.partial => (
          l10n.consentStatusPartial,
          l10n.consentStatusPartialBody,
          AppLucideIcons.cloud,
          c.warning
        ),
      ConsentStatus.off => (
          l10n.consentStatusOff,
          l10n.consentStatusOffBody,
          AppLucideIcons.cloud,
          c.textMuted
        ),
      ConsentStatus.unknown => (
          l10n.consentStatusUnknown,
          l10n.consentStatusUnknownBody,
          AppLucideIcons.cloud,
          c.warning
        ),
      ConsentStatus.turningOn => (
          l10n.consentStatusTurningOn,
          l10n.consentStatusTurningOnBody,
          AppLucideIcons.cloud,
          c.warning
        ),
      ConsentStatus.turningOff => (
          l10n.consentStatusTurningOff,
          l10n.consentStatusTurningOffBody,
          AppLucideIcons.cloud,
          c.warning
        ),
    };
    final settled = facts != null;
    // G1: Turn on only where a verified transition exists. Off and a verified
    // partial go through the disclosure's enable; Turning on offers the exact
    // resume of its own pending operation. "Can't confirm" (a stored ON whose
    // live state is not verified) has no safe enable: it offers the withdrawal
    // (the verified restrictive disable) and a re-check, then a fresh enable.
    // R17/R18: "Turning on…" offers Turn on only for an exactly resumable
    // pending enable, and Turn off (the verified withdrawal) for every pending.
    final canTurnOn = settled &&
        (status == ConsentStatus.off ||
            status == ConsentStatus.partial ||
            (status == ConsentStatus.turningOn &&
                facts.pendingResumable));
    // N-CR-4: unresolved pending provenance has no supported action but a
    // re-check: Turn on is refused by the route and the withdrawal cannot clear
    // the evidence, so neither is offered, and no recovery is promised.
    final unresolved = settled && facts.pendingUnresolved;
    final canTurnOff = settled &&
        !unresolved &&
        (status == ConsentStatus.active ||
            status == ConsentStatus.partial ||
            status == ConsentStatus.unknown ||
            status == ConsentStatus.turningOn);
    final canRefresh = settled &&
        (status == ConsentStatus.unknown ||
            status == ConsentStatus.turningOn ||
            status == ConsentStatus.turningOff);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // v2 Group card (light white + e1 / dark hairline).
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                SettingsV2Tile(icon: icon),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(l10n.consentMgmtTitle,
                      style: AppTypography.cardTitle(c.textMain)),
                ),
              ]),
              const SizedBox(height: AppSpacing.s3),
              Row(
                key: const Key('consentStatus'),
                children: [
                  AppStatusPill(
                    label: label,
                    tone: switch (status) {
                      ConsentStatus.active => AppStatusTone.success,
                      ConsentStatus.off => AppStatusTone.neutral,
                      _ => AppStatusTone.warning,
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(body, style: AppTypography.subhead(c.textSecondary)),
              // Field diagnostic: which site froze egress (a constant tag only).
              if (settled &&
                  facts.frozen &&
                  ConsentAuthority.egressFreezeTag.isNotEmpty)
                Text('freeze: ${ConsentAuthority.egressFreezeTag}',
                    key: const Key('freezeTag'),
                    style: AppTypography.caption(c.textLight)),
              if (settled &&
                  !unresolved &&
                  (status == ConsentStatus.unknown ||
                      (status == ConsentStatus.turningOn &&
                          !facts.pendingResumable))) ...[
                const SizedBox(height: AppSpacing.s1),
                Text(l10n.consentStatusUnknownRecovery,
                    style: AppTypography.caption(c.textLight)),
              ],
              const SizedBox(height: AppSpacing.s2),
              Text(l10n.privCloudProcessingBody,
                  style: AppTypography.caption(c.textSecondary)),
              const SizedBox(height: AppSpacing.s1),
              Text(l10n.privAiAnalysisBody,
                  style: AppTypography.caption(c.textSecondary)),
              if (canTurnOn || canTurnOff || canRefresh) ...[
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: AppSpacing.s2,
                  children: [
                    if (canTurnOn)
                      FilledButton(
                        key: const Key('consentTurnOn'),
                        onPressed: _busy ? null : _turnOn,
                        child: Text(l10n.consentTurnOn),
                      ),
                    if (canTurnOff)
                      OutlinedButton(
                        key: const Key('consentTurnOff'),
                        style: Theme.of(context).brightness == Brightness.dark
                            ? OutlinedButton.styleFrom(foregroundColor: c.primary)
                            : null,
                        onPressed: _busy ? null : _turnOff,
                        child: Text(l10n.consentTurnOff),
                      ),
                    if (canRefresh)
                      TextButton(
                        key: const Key('consentRefresh'),
                        style: Theme.of(context).brightness == Brightness.dark
                            ? TextButton.styleFrom(foregroundColor: c.primary)
                            : null,
                        onPressed: _busy ? null : _refresh,
                        child: Text(l10n.consentRefresh),
                      ),
                  ],
                ),
              ],
            ],
          ),
      ),
    );
  }
}


class _PendingDeletionCard extends StatelessWidget {
  const _PendingDeletionCard({
    required this.scheduledAt,
    required this.onCancel,
  });

  final DateTime scheduledAt;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final local = scheduledAt.toLocal();
    final label =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.privScheduledForDeletion(label),
              style: AppTypography.bodyStrong(c.danger)),
          const SizedBox(height: AppSpacing.s2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              // v2: the theme's light action blue (#155DFC) is 4.3:1 on the
              // danger tint; actionText keeps the cancel link at AA.
              style: TextButton.styleFrom(foregroundColor: c.actionText),
              onPressed: onCancel,
              child: Text(context.l10n.privCancelDeletion),
            ),
          ),
        ],
      ),
    );
  }
}

/// Revocable data-processing consent switch (MALI-001) — same card language
/// as [_PrivacyCard], with an honest subtitle describing what leaves the
/// device and what stops when the switch is off.
class _ConsentSwitchCard extends StatelessWidget {
  const _ConsentSwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: SwitchListTile.adaptive(
          contentPadding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.s4, 4, AppSpacing.s3, 4),
          secondary: SettingsV2Tile(icon: icon),
          title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle, style: AppTypography.caption(c.textSecondary)),
          ),
          value: value,
          activeThumbColor: c.onCta,
          activeTrackColor: c.cta,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  /// A row inside a v2 Group; danger rows carry the tinted danger tile and
  /// danger label.
  @override
  Widget build(BuildContext context) => SettingsV2Row(
        icon: icon,
        title: title,
        subtitle: subtitle,
        danger: danger,
        onTap: onTap,
      );
}
