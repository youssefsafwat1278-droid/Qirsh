import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/immediate_deletion_flow.dart';
import '../../core/di/app_providers.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../common/app_card.dart';
import '../common/app_header.dart';

enum _Phase {
  idle,
  running,
  pending,
  unconfirmed,
  failed,
  adminBlocked,
  rateLimited,
  rejected,
  localCleanupPending,
  completed,
}

/// Where the person goes after a CONFIRMED deletion (remote completion and
/// original local removal). Overridable in tests.
final deleteAccountAfterCompletionProvider =
    Provider<void Function()>((ref) => () => appRouter.go('/welcome'));

/// Delete account: immediate, permanent, confirmed with Apple. The operation is
/// captured BEFORE the confirmation dialog; on confirm it runs challenge ->
/// Apple re-authentication -> request. Success is shown, and the person is sent
/// to onboarding, ONLY after operation-bound remote completion AND confirmed
/// removal of the original local replica. Pending, unknown, refused and failed
/// states are reported as such and never touch local data.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  _Phase _phase = _Phase.idle;
  bool _retryable = true;
  bool _canCheckStatus = true;
  bool _running = false;
  DeletionFlowSession? _session;

  @override
  void initState() {
    super.initState();
    // A request that survived a restart (or a closed screen) is resumed, never
    // duplicated: status only.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resumeExisting());
    });
  }

  @override
  void dispose() {
    // A session mid-run settles itself (including local removal); only an
    // idle, never-confirmed one is released.
    if (!_running) _session?.close();
    super.dispose();
  }

  ImmediateDeletionFlow? _flow() {
    try {
      return ref.read(immediateDeletionFlowProvider);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _resumeExisting() async {
    if (_running) return false;
    final flow = _flow();
    if (flow == null) return false;
    final DeletionFlowSession? existing;
    DeletionFlowSession? cleanup;
    try {
      existing = await flow.resume();
      if (existing == null) cleanup = await flow.resumeLocalCleanup();
    } catch (_) {
      return false;
    }
    if ((existing == null && cleanup == null) || !mounted || _running) {
      existing?.close();
      cleanup?.close();
      return false;
    }
    if (existing != null) {
      _session = existing;
      unawaited(_run(existing.checkStatus));
    } else {
      // Completed remotely earlier; only this device's cleanup is outstanding.
      _session = cleanup;
      unawaited(_run(cleanup!.retryLocalCleanup));
    }
    return true;
  }

  Future<void> _confirmAndStart() async {
    if (_running) return;
    final l10n = context.l10n;
    final flow = _flow();
    // Replace an abandoned, never-requested capture instead of leaking it.
    _session?.close();
    _session = null;
    _running = true;
    setState(() => _phase = _Phase.running);
    DeletionFlowSession? session;
    try {
      session = await flow?.begin();
    } catch (_) {
      session = null;
    }
    _running = false;
    if (!mounted) {
      session?.close();
      return;
    }
    if (session == null) {
      // No admitted original account, or an operation already exists.
      if (await _resumeExisting()) return;
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _retryable = false;
      });
      return;
    }
    final captured = session;
    setState(() => _phase = _Phase.idle);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(l10n.deleteAccountConfirmTitle),
        content: Text(l10n.deleteAccountConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel)),
          TextButton(
              key: const Key('deleteAccountConfirm'),
              style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.deleteAccountConfirmAction)),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      captured.close();
      if (mounted) setState(() => _phase = _Phase.idle);
      return;
    }
    _session = captured;
    unawaited(_run(() => _confirmIdentity(captured)));
  }

  Future<void> _retry() async {
    final session = _session;
    if (session == null) return _confirmAndStart();
    unawaited(_run(() => _confirmIdentity(session)));
  }

  Future<DeletionFlowResult> _confirmIdentity(DeletionFlowSession session) =>
      session is EmailProofDeletionSession
          ? session.confirmWithEmailProof(_readDeletionCode)
          : session.confirm();

  Future<String?> _readDeletionCode() async {
    if (!mounted) return null;
    final l10n = context.l10n;
    var code = '';
    final form = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(l10n.deleteAccountEmailProofTitle),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.deleteAccountEmailProofBody),
              const SizedBox(height: 12),
              TextFormField(
                autofocus: true,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                decoration: InputDecoration(
                    labelText: l10n.deleteAccountEmailProofTitle),
                onChanged: (value) => code = value,
                validator: (value) =>
                    (value?.length ?? 0) < 6 ? l10n.authCodeVerifyFailed : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () {
              if (form.currentState?.validate() ?? false) {
                Navigator.pop(ctx, code);
              }
            },
            child: Text(l10n.deleteAccountConfirmAction),
          ),
        ],
      ),
    );
  }

  Future<void> _retryCleanup() async {
    var session = _session;
    if (session == null) {
      try {
        session = await _flow()?.resumeLocalCleanup();
      } catch (_) {
        session = null;
      }
      if (session == null || !mounted) {
        session?.close();
        return;
      }
      _session = session;
    }
    unawaited(_run(session.retryLocalCleanup));
  }

  Future<void> _check() async {
    final session = _session;
    if (session == null) return;
    unawaited(_run(session.checkStatus));
  }

  Future<void> _run(Future<DeletionFlowResult> Function() action) async {
    if (_running) return;
    _running = true;
    // Captured before any await: a confirmed removal replaces the account scope
    // and disposes this screen, but navigation must still happen.
    final afterCompletion = ref.read(deleteAccountAfterCompletionProvider);
    if (mounted) setState(() => _phase = _Phase.running);
    DeletionFlowResult result;
    try {
      result = await action();
    } catch (_) {
      result = const DeletionFlowUnconfirmed(canCheckStatus: true);
    }
    _running = false;
    if (result is DeletionFlowCompleted) {
      if (mounted) setState(() => _phase = _Phase.completed);
      afterCompletion();
      return;
    }
    if (!mounted) return;
    setState(() {
      switch (result) {
        case DeletionFlowCompleted():
          _phase = _Phase.completed;
        case DeletionFlowLocalCleanupPending():
          _phase = _Phase.localCleanupPending;
        case DeletionFlowPending():
          _phase = _Phase.pending;
        case DeletionFlowUnconfirmed(:final canCheckStatus):
          _phase = _Phase.unconfirmed;
          _canCheckStatus = canCheckStatus;
        case DeletionFlowFailed(:final retryable):
          _phase = _Phase.failed;
          _retryable = retryable;
        case DeletionFlowRejected():
          // Nothing was deleted and the failed operation was abandoned: the
          // next attempt is a fresh capture.
          _phase = _Phase.rejected;
          _session?.close();
          _session = null;
        case DeletionFlowAdminBlocked():
          _phase = _Phase.adminBlocked;
        case DeletionFlowRateLimited():
          _phase = _Phase.rateLimited;
        case DeletionFlowCancelled():
          // The person dismissed Apple: nothing was sent.
          _phase = _Phase.idle;
          _session = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final busy = _phase == _Phase.running ||
        _phase == _Phase.completed ||
        _phase == _Phase.pending ||
        _phase == _Phase.unconfirmed ||
        _phase == _Phase.localCleanupPending;

    Widget message(String text, {Color? color, String? key}) => Text(text,
        key: key == null ? null : Key(key),
        style: AppTypography.body(color ?? c.textMain));

    Widget action(String keyName, String label, VoidCallback onPressed) =>
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s2),
          child: TextButton(
              key: Key(keyName), onPressed: onPressed, child: Text(label)),
        );

    Widget status() {
      switch (_phase) {
        case _Phase.idle:
          return const SizedBox.shrink();
        case _Phase.running:
          return Row(
            key: const Key('deleteAccountProgress'),
            children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                  child: Text(l10n.deleteAccountProgress,
                      style: AppTypography.body(c.textMain))),
            ],
          );
        case _Phase.completed:
          return Text(l10n.deleteAccountSuccess,
              key: const Key('deleteAccountSuccess'),
              style: AppTypography.bodyStrong(c.textMain));
        case _Phase.pending:
          return Column(
            key: const Key('deleteAccountPending'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(l10n.deleteAccountPendingBody),
              action('deleteAccountCheckStatus', l10n.deleteAccountCheckStatus,
                  _check),
            ],
          );
        case _Phase.unconfirmed:
          return Column(
            key: const Key('deleteAccountUnconfirmed'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(
                  _canCheckStatus
                      ? l10n.deleteAccountUnconfirmed
                      : l10n.deleteAccountUnconfirmedStale,
                  color: c.danger),
              if (_canCheckStatus)
                action('deleteAccountCheckStatus',
                    l10n.deleteAccountCheckStatus, _check),
            ],
          );
        case _Phase.failed:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(
                  _retryable
                      ? l10n.deleteAccountFailed
                      : l10n.deleteAccountFailedFinal,
                  color: c.danger),
              if (_retryable)
                action('deleteAccountRetry', l10n.deleteAccountRetry, _retry),
            ],
          );
        case _Phase.adminBlocked:
          return message(l10n.deleteAccountAdminBlocked,
              color: c.danger, key: 'deleteAccountAdminBlocked');
        case _Phase.rateLimited:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(l10n.deleteAccountRateLimited,
                  color: c.danger, key: 'deleteAccountRateLimited'),
              action('deleteAccountRetry', l10n.deleteAccountRetry, _retry),
            ],
          );
        case _Phase.rejected:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(l10n.deleteAccountRejected,
                  color: c.danger, key: 'deleteAccountRejected'),
              action('deleteAccountRetry', l10n.deleteAccountRetry, _retry),
            ],
          );
        case _Phase.localCleanupPending:
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message(l10n.deleteAccountLocalCleanupPending,
                  color: c.danger, key: 'deleteAccountLocalCleanupPending'),
              action('deleteAccountRetryCleanup', l10n.deleteAccountRetry,
                  _retryCleanup),
            ],
          );
      }
    }

    return Scaffold(
      backgroundColor: c.bg,
      extendBodyBehindAppBar: true,
      appBar: AppHeader(title: l10n.deleteAccountTitle),
      // Immersive: scrolls under the glass bar; content starts below it.
      body: Builder(builder: (bodyContext) => ListView(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            MediaQuery.paddingOf(bodyContext).top + AppSpacing.gutter,
            AppSpacing.gutter,
            AppSpacing.gutter),
        children: [
          AppCard(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                  child: QirshIllustration(
                      name: 'privacy', width: 112, height: 84)),
              const SizedBox(height: AppSpacing.s3),
              Text(l10n.deleteAccountIntro,
                  style: AppTypography.body(c.textMain)),
            ],
          )),
          const SizedBox(height: AppSpacing.s4),
          FilledButton(
            key: const Key('deleteAccountAction'),
            style: FilledButton.styleFrom(
                backgroundColor: c.danger, foregroundColor: c.onDanger),
            onPressed: busy ? null : _confirmAndStart,
            child: Text(l10n.deleteAccountAction),
          ),
          const SizedBox(height: AppSpacing.s4),
          status(),
        ],
      )),
    );
  }
}
