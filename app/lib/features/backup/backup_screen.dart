import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:go_router/go_router.dart';

import '../../core/backup/backup_service.dart';
import '../../core/backup/remote_backup_state.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'backup_error_messages.dart';

class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(backupStatusProvider);
    final c = context.colors;
    final isGuest = AppSession.instance.isGuest;
    final content = async.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(context.l10n.txnError)),
      data: (status) => isGuest
          ? const _GuestBackupGate()
          : status.enabled
              ? _EnabledView(status: status)
              : const _EnableFlow(),
    );
    // SP-09: at large text the header scrolls away with the content instead
    // of taking a fixed share of the screen (the column overflowed at 3.1x).
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 20;
    return Scaffold(
      backgroundColor: c.bg,
      body: largeText
          ? NestedScrollView(
              headerSliverBuilder: (context, _) =>
                  const [SliverToBoxAdapter(child: _BackupHeader())],
              body: content,
            )
          : Column(
              children: [
                const _BackupHeader(),
                Expanded(child: content),
              ],
            ),
    );
  }
}

class _BackupHeader extends StatelessWidget {
  const _BackupHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  context.l10n.bkTitle,
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.bkSubtitle,
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _GuestBackupGate extends StatelessWidget {
  const _GuestBackupGate();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Icon(AppLucideIcons.userPlus, size: 48, color: c.primary),
        const SizedBox(height: AppSpacing.s3),
        Text(context.l10n.bkCreateAccountTitle,
            style: AppTypography.headline(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        Text(
          context.l10n.bkCreateAccountBody,
          style: AppTypography.body(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s5),
        FilledButton(
          onPressed: () => context.push('/onboarding/auth'),
          child: Text(context.l10n.homeSignIn),
        ),
      ],
    );
  }
}

class _EnabledView extends ConsumerWidget {
  const _EnabledView({required this.status});

  final BackupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    // MALI-076n §16 — the label + icon derive from the TRUTHFUL typed state, so
    // "محمي" (Protected) shows only for a committed + verified remote generation.
    final state = ref.watch(remoteBackupControllerProvider);
    final controller = ref.read(remoteBackupControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Row(
          children: [
            Icon(
              state.isProtected ? AppLucideIcons.cloud : AppLucideIcons.cloud,
              color: state.isProtected ? c.success : c.textLight,
            ),
            const SizedBox(width: AppSpacing.s3),
            Text(_stateLabel(context, state),
                style: AppTypography.headline(c.textMain)),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        Text(
          status.lastBackupAt == null
              ? context.l10n.bkNoBackupYet
              : context.l10n.bkLastBackup(
                    Formatters.fullDate(status.lastBackupAt!, context),
                    Formatters.time(status.lastBackupAt!, context)),
          style: AppTypography.body(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s5),
        FilledButton(
          onPressed: state.isInFlight
              ? null
              : () async {
                  await controller.backupNow();
                  ref.invalidate(backupStatusProvider);
                },
          child: Text(context.l10n.bkBackupNow),
        ),
        const SizedBox(height: AppSpacing.s3),
        const _RestoreBackupButton(),
        const SizedBox(height: AppSpacing.s3),
        OutlinedButton(
          onPressed: () async {
            await controller.disableStop();
            ref.invalidate(backupStatusProvider);
          },
          child:
              Text(context.l10n.bkTurnOff, style: TextStyle(color: c.danger)),
        ),
        const SizedBox(height: AppSpacing.s3),
        Text(context.l10n.bkLocalDataStays,
            style: AppTypography.caption(c.textLight)),
      ],
    );
  }
}

class _EnableFlow extends ConsumerStatefulWidget {
  const _EnableFlow();

  @override
  ConsumerState<_EnableFlow> createState() => _EnableFlowState();
}

class _EnableFlowState extends ConsumerState<_EnableFlow> {
  final _passphrase = TextEditingController();
  String? _recoveryCode;
  String? _error;
  bool _saved = false;
  bool _busy = false;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final passphrase = _passphrase.text.trim();
    if (passphrase.length < 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // C-3 — through the CONTROLLER, never the service directly. The
      // controller is where the cloud-consent gate lives; calling
      // `backupServiceProvider.enable` from here uploaded an encrypted copy of
      // the whole ledger with cloud consent OFF, and left
      // `RemoteBackupState.consentRequired` — which this screen already knows
      // how to render — unreachable from the one flow that can turn backup on.
      //
      // The controller returns null exactly when consent is missing; it has
      // already moved its own state to `consentRequired`, so the status line
      // explains it and no upload happened.
      final code = await ref
          .read(remoteBackupControllerProvider.notifier)
          .enable(passphrase: passphrase);
      if (!mounted) return;
      if (code == null) {
        setState(() {
          _busy = false;
          _error = context.l10n.bkStateNeedsCloudSync;
        });
        return;
      }
      setState(() {
        _busy = false;
        _recoveryCode = code;
      });
    } on BackupException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = backupExceptionMessage(context, error);
      });
      ref.invalidate(backupStatusProvider);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.bkEnableFailed;
      });
      ref.invalidate(backupStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Icon(AppLucideIcons.lock, size: 48, color: c.primary),
        const SizedBox(height: AppSpacing.s3),
        Text(context.l10n.bkEncryptedWeCannotRead,
            style: AppTypography.headline(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        Text(
            context.l10n.bkOptionalOffByDefault,
            style: AppTypography.body(c.textLight)),
        const SizedBox(height: AppSpacing.s5),
        if (_recoveryCode == null) ...[
          Text(context.l10n.bkPassphrase,
              style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          TextField(
            controller: _passphrase,
            obscureText: true,
            style: AppTypography.body(c.textMain),
            decoration: InputDecoration(
              filled: true,
              fillColor: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : c.surface2.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.primary, width: 2),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Container(
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: c.danger.withValues(alpha: 0.24)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AppLucideIcons.alertCircle, color: c.danger, size: 20),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      _error!,
                      style: AppTypography.caption(c.textMain),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _busy ? null : _generate,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(context.l10n.bkContinue, style: AppTypography.bodyStrong(c.onInk)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          const _RestoreBackupButton(),
        ] else ...[
          Text(context.l10n.bkRecoveryCode,
              style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: c.border, style: BorderStyle.solid),
            ),
            child: Center(
              child: SelectableText(_recoveryCode!,
                  style: AppTypography.title2(c.textMain)),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: _recoveryCode!)),
            icon: const Icon(AppLucideIcons.copy, size: 18),
            label: Text(context.l10n.bkCopyCode),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(AppLucideIcons.alertTriangle, color: c.accent, size: 20),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    context.l10n.bkLoseBothWarning,
                    style: AppTypography.caption(c.textMain),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          CheckboxListTile(
            value: _saved,
            onChanged: (v) => setState(() => _saved = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: c.primary,
            title: Text(context.l10n.bkSavedTheCode,
                style: AppTypography.body(c.textMain)),
          ),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _saved
                  ? () {
                      ref.invalidate(backupStatusProvider);
                      Navigator.of(context).pop();
                    }
                  : null,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(context.l10n.bkEnable, style: AppTypography.bodyStrong(c.onInk)),
            ),
          ),
        ],
      ],
    );
  }
}

class _RestoreBackupButton extends StatelessWidget {
  const _RestoreBackupButton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OutlinedButton.icon(
      onPressed: () => context.push('/backup/restore'),
      icon: const Icon(AppLucideIcons.rotateCcw, size: 18),
      label: Text(
        context.l10n.bkRestoreFromBackup,
        style: AppTypography.bodyStrong(c.primary),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: c.primary,
        side: BorderSide(color: c.primary.withValues(alpha: 0.35)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }
}

/// Truthful user-facing label for each backup state (MALI-076n §16). Only
/// `enabledIdle` — a committed AND verified generation — renders as "Protected".
///
/// This used to live in `remote_backup_controller` as a context-free function,
/// which meant the words could never follow the locale. The controller owns the
/// STATE; the screen owns how it reads.
String _stateLabel(BuildContext context, RemoteBackupState s) {
  final l = context.l10n;
  switch (s) {
    case RemoteBackupState.disabled:
      return l.bkStateDisabled;
    case RemoteBackupState.enabling:
      return l.bkStateEnabling;
    case RemoteBackupState.preparing:
      return l.bkStatePreparing;
    case RemoteBackupState.encrypting:
      return l.bkStateEncrypting;
    case RemoteBackupState.uploading:
      return l.bkStateUploading;
    case RemoteBackupState.verifyingUpload:
    case RemoteBackupState.verifyingDownload:
      return l.bkStateVerifying;
    case RemoteBackupState.downloading:
      return l.bkStateDownloading;
    case RemoteBackupState.enabledIdle:
      return l.bkStateProtected;
    case RemoteBackupState.pausedOffline:
      return l.bkStateWaitingForConnection;
    case RemoteBackupState.retryScheduled:
      return l.bkStateWillRetry;
    case RemoteBackupState.authenticationRequired:
      return l.bkStateNeedsSignIn;
    case RemoteBackupState.consentRequired:
      return l.bkStateNeedsCloudSync;
    case RemoteBackupState.failedRetryable:
      return l.bkStateFailedRetryable;
    case RemoteBackupState.failedTerminal:
      return l.bkStateFailed;
    case RemoteBackupState.deleting:
      return l.bkStateDeleting;
    case RemoteBackupState.cancelled:
      return l.bkStateCancelled;
  }
}
