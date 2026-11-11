import 'dart:async';

import 'package:file_picker/file_picker.dart';
import '../../core/utils/l10n_ext.dart';
import 'data_portability_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/backup/backup_service.dart';
import '../../core/data_portability/data_portability_models.dart';
import '../../core/exporting/export_providers.dart';
import '../../core/exporting/managed_export_store.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../domain/entities/account_entity.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/app_card.dart';
import '../report_ads/report_ad_notice.dart';
import '../report_ads/report_ads_providers.dart';
import '../reporting/ui/report_config_page.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'widgets/settings_v2.dart';
import 'import_issue_messages.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

class DataTransferScreen extends ConsumerStatefulWidget {
  const DataTransferScreen({super.key, this.initialAction});

  final String? initialAction;

  @override
  ConsumerState<DataTransferScreen> createState() => _DataTransferScreenState();
}

class _DataTransferScreenState extends ConsumerState<DataTransferScreen> {
  ImportPreview? _preview;
  ImportMode _mode = ImportMode.merge;
  ImportResult? _result;
  bool _busy = false;
  bool _legacyBackupExists = false;

  @override
  void initState() {
    super.initState();
    _checkLegacyBackup();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runInitialAction();
    });
  }

  Future<void> _runInitialAction() async {
    await _waitForRouteTransition();
    if (!mounted) return;
    switch (widget.initialAction) {
      case 'import':
        await _pickFile();
      case 'transactions':
        await _export(fullPackage: false);
      case 'package':
        await _export(fullPackage: true);
    }
  }

  Future<void> _waitForRouteTransition() async {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return;
    }
    final completer = Completer<void>();
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (!completer.isCompleted) completer.complete();
      }
    }

    animation.addStatusListener(listener);
    if (animation.status == AnimationStatus.completed &&
        !completer.isCompleted) {
      completer.complete();
    }
    try {
      await completer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // A custom route may not report completion; one second is still safely
      // beyond the standard iOS and Material navigation transitions.
    } finally {
      animation.removeStatusListener(listener);
    }
  }

  /// Does this account still have a cloud backup from an earlier build?
  ///
  /// C-3 — this probe is EGRESS and must be gated. It asks Supabase for the
  /// generation pointer and lists the user's storage prefix: two authenticated
  /// requests carrying the auth token and the user id, made the moment this
  /// screen opens. It was gated on `SupabaseConfig.isConfigured` alone, which
  /// asks whether the app CAN reach the server, not whether the user agreed
  /// that it should.
  ///
  /// With cloud consent off there is also nothing to offer: a cloud restore
  /// cannot run either. So the tile stays hidden and no request is made.
  Future<void> _checkLegacyBackup() async {
    if (!SupabaseConfig.isConfigured) return;
    final allowed = await ConsentAuthority(
      () => ref.read(userSettingsRepositoryProvider).getSettings(),
    ).allows(EgressClass.backup);
    if (!allowed) {
      if (mounted) setState(() => _legacyBackupExists = false);
      return;
    }
    try {
      final exists = await ref.read(backupServiceProvider).hasRemoteBackup();
      if (mounted) setState(() => _legacyBackupExists = exists);
    } catch (_) {}
  }

  Future<void> _pickFile() async {
    final l10n = context.l10n;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'zip'],
        allowMultiple: false,
        withData: false,
      );
      final path = picked?.files.single.path;
      if (path == null || !mounted) return;

      setState(() {
        _result = null;
      });

      final preview =
          await ref.read(dataPortabilityServiceProvider).inspectFile(path);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _mode = ImportMode.merge;
      });
    } on DataPortabilityException catch (error) {
      _message(_portabilityMessage(error));
    } catch (_) {
      _message(l10n.dtxScanFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runImport() async {
    final l10n = context.l10n;
    final preview = _preview;
    if (preview == null || _busy) return;
    if (_mode == ImportMode.replace && !await _confirmReplace()) return;
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(dataPortabilityServiceProvider).import(preview, _mode);
      if (!mounted) return;
      setState(() => _result = result);
    } on DataPortabilityException catch (error) {
      _message(_portabilityMessage(error));
    } catch (_) {
      _message(l10n.dtxImportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace() async {
    return showReplaceConfirmationDialog(context);
  }

  Future<void> _export({required bool fullPackage}) async {
    final l10n = context.l10n;
    if (_busy) return;
    setState(() => _busy = true);
    ManagedExport? export;
    ExportedFile exported;
    try {
      final service = ref.read(dataPortabilityServiceProvider);
      exported = fullPackage
          ? await service.exportFinancialPackage()
          : await service.exportTransactionsCsv();
    } on DataPortabilityException catch (error, stackTrace) {
      _logExportFailure('prepare', error, stackTrace);
      _message(_portabilityMessage(error));
      if (mounted) setState(() => _busy = false);
      return;
    } catch (error, stackTrace) {
      _logExportFailure('prepare', error, stackTrace);
      _message(l10n.dtxReadFailed);
      if (mounted) setState(() => _busy = false);
      return;
    }

    final store = ref.read(managedExportStoreProvider);
    try {
      // MALI-065n: opaque on-disk name + platform file-protection; the friendly
      // date-based `exported.name` is presented only in the share sheet.
      export = await store.writeBytes(
        exported.bytes,
        shareName: exported.name,
        extension: _extensionOf(exported.name),
        mimeType: exported.mimeType,
      );
    } catch (error, stackTrace) {
      _logExportFailure('write', error, stackTrace);
      _message(l10n.dtxSaveFailed);
      if (mounted) setState(() => _busy = false);
      return;
    }

    if (!mounted) {
      await store.dispose(export);
      return;
    }

    try {
      final overlayBox = Overlay.of(context).context.findRenderObject();
      final shareOrigin = overlayBox is RenderBox && overlayBox.hasSize
          ? overlayBox.localToGlobal(Offset.zero) & overlayBox.size
          : null;
      await Share.shareXFiles(
        [
          XFile(export.file.path,
              mimeType: export.mimeType, name: export.shareName)
        ],
        subject: fullPackage ? 'Qirsh financial data' : 'Qirsh transactions',
        text: fullPackage
            ? context.l10n.dtxZipShareText
            : context.l10n.dtxCsvShareText,
        sharePositionOrigin: shareOrigin,
        fileNameOverrides: [export.shareName],
      );
    } catch (error, stackTrace) {
      // MALI-065n: no clipboard fallback for full ledger/package — surface the
      // failure and let the user retry sharing.
      _logExportFailure('share', error, stackTrace);
      _message(l10n.dtxShareSheetFailed);
    } finally {
      // Delete on success, cancel, AND failure (the share outcome is unknown).
      await store.dispose(export);
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? 'bin' : name.substring(dot + 1);
  }

  void _logExportFailure(
    String stage,
    Object error,
    StackTrace stackTrace,
  ) {
    assert(() {
      debugPrint(
          '[DataTransfer] export failed stage=$stage type=${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      return true;
    }());
  }

  Future<void> _openPdfReport() async {
    final request = await showReportConfigPage(context);
    if (request == null || !mounted) return;
    await ref.read(reportExportCoordinatorProvider).run(() async {
      if (!mounted) return;
      await runReportGeneration(context, ref, request);
    }, confirmAdNotice: () async =>
        mounted && await showReportAdNotice(context));
  }

  /// The failure in the reader's language, falling back to the exception's own
  /// Arabic message for any throw site that has no code yet.
  String _portabilityMessage(DataPortabilityException e) =>
      mounted ? dataPortabilityMessage(context, e) : e.message;

  void _message(String text) {
    if (!mounted) return;
    AppToast.showError(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    // v2 §26/27: export and import are separate Groups; each file type has
    // its own tinted tile, and rows that ACT carry an action glyph rather than
    // a navigation chevron.
    return SettingsV2Page(
      title: l10n.dtxTitle,
      subtitle: l10n.dtxSubtitle,
      overlay: _busy
          ? const ColoredBox(
              color: Color(0x22000000),
              child: Center(child: CircularProgressIndicator()),
            )
          : null,
      children: [
        const Center(
          child: QirshIllustration(
            name: 'dataTransfer', width: 187, height: 140,
          ),
        ),
        SettingsV2Group(
          label: l10n.dtxExportSection,
          dividerIndent: 68,
          children: [
            _ActionTile(
              icon: AppLucideIcons.fileText,
              accent: colors.danger,
              title: l10n.dtxPdfReport,
              subtitle: l10n.dtxPdfReportSub,
              action: AppLucideIcons.share,
              onTap: _openPdfReport,
            ),
            _ActionTile(
              icon: AppLucideIcons.table,
              accent: colors.success,
              title: l10n.dtxExportCsv,
              subtitle: l10n.dtxExportCsvSub,
              action: AppLucideIcons.share,
              onTap: () => _export(fullPackage: false),
            ),
            _ActionTile(
              icon: AppLucideIcons.archive,
              accent: colors.info,
              title: l10n.dtxExportZip,
              subtitle: l10n.dtxExportZipSub,
              action: AppLucideIcons.share,
              onTap: () => _export(fullPackage: true),
            ),
            if (_legacyBackupExists)
              _ActionTile(
                icon: AppLucideIcons.rotateCcw,
                accent: colors.info,
                title: l10n.dtxRestoreOld,
                subtitle: l10n.dtxRestoreOldSub,
                onTap: () => context.push('/backup/restore'),
              ),
          ],
        ),
        SettingsV2Group(
          label: l10n.dtxImportSection,
          children: [
            _ActionTile(
              icon: AppLucideIcons.folderOpen,
              accent: colors.warning,
              title: l10n.dtxImportFile,
              subtitle: l10n.dtxImportFileSub,
              action: AppLucideIcons.download,
              onTap: _pickFile,
            ),
          ],
        ),
        if (_preview != null || _result != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_preview != null) ...[
                  const SizedBox(height: AppSpacing.s6),
                  _PreviewPanel(
                    preview: _preview!,
                    mode: _mode,
                    accounts:
                        ref.watch(accountsProvider).valueOrNull ?? const [],
                    onPreviewChanged: (value) =>
                        setState(() => _preview = value),
                    onModeChanged: (value) => setState(() => _mode = value),
                    onImport: _runImport,
                  ),
                ],
                if (_result != null) ...[
                  const SizedBox(height: AppSpacing.s5),
                  _ResultPanel(result: _result!),
                ],
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.s4),
        // The most important sentence on the page is no longer its smallest:
        // a warning-tinted notice at `subhead`.
        SettingsV2Tinted(
          background: colors.warningBg,
          accent: colors.warning,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(AppLucideIcons.lock,
                    size: 18, color: colors.warningText),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  l10n.dtxExportNotice,
                  style: AppTypography.subhead(colors.textSecondary)
                      .copyWith(height: 22 / 14),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
Future<bool> showReplaceConfirmationDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _ReplaceConfirmationDialog(),
  );
  return result ?? false;
}

class _ReplaceConfirmationDialog extends StatefulWidget {
  const _ReplaceConfirmationDialog();

  @override
  State<_ReplaceConfirmationDialog> createState() =>
      _ReplaceConfirmationDialogState();
}

class _ReplaceConfirmationDialogState
    extends State<_ReplaceConfirmationDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop(_controller.text.trim() == context.l10n.dtxReplace);
  }

  @override
  Widget build(BuildContext context) {
    return GlassAlertDialog(
      title: Text(context.l10n.dtxConfirmReplace),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.dtxReplaceBody(context.l10n.dtxReplace),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                  labelText: context.l10n.dtxTypeReplace(context.l10n.dtxReplace)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.danger,
            foregroundColor: context.colors.onDanger,
          ),
          onPressed: _confirm,
          child: Text(context.l10n.txnConfirm),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.accent,
    this.action,
  });

  final Color accent;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Trailing action glyph (share / download) for rows that act; rows that
  /// navigate keep the chevron.
  final IconData? action;

  @override
  Widget build(BuildContext context) => SettingsV2Row(
        leading: SettingsV2Tile(icon: icon, color: accent, size: 40),
        title: title,
        subtitle: subtitle,
        trailing: action == null
            ? null
            : Icon(action, size: 20, color: context.colors.actionText),
        onTap: onTap,
      );
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.preview,
    required this.mode,
    required this.accounts,
    required this.onPreviewChanged,
    required this.onModeChanged,
    required this.onImport,
  });

  final ImportPreview preview;
  final ImportMode mode;
  final List<AccountEntity> accounts;
  final ValueChanged<ImportPreview> onPreviewChanged;
  final ValueChanged<ImportMode> onModeChanged;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    ImportPreview remapped(CsvColumnMapping mapping) => preview.copyWith(
          mapping: mapping,
          issues: preview.issues
              .where((issue) => issue.severity == ImportIssueSeverity.warning)
              .toList(growable: false),
        );
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.dtxImportPreview,
              style: AppTypography.headline(colors.textMain)),
          const SizedBox(height: 8),
          Text(
              context.l10n.dtxPreviewRows(
                  preview.totalRows,
                  preview.format == ImportFormat.qirshPackage
                      ? context.l10n.dtxQirshPackage
                      : 'CSV')),
          if (preview.format == ImportFormat.qirshPackage) ...[
            const SizedBox(height: 8),
            for (final entry in preview.tableCounts.entries)
              Text('${entry.key}: ${entry.value}'),
          ],
          if (preview.format == ImportFormat.genericCsv &&
              preview.mapping != null) ...[
            const SizedBox(height: 16),
            _MappingField(
              label: context.l10n.dtxColDate,
              value: preview.mapping!.dateColumn,
              headers: preview.headers,
              onChanged: (value) => onPreviewChanged(
                remapped(preview.mapping!.copyWith(dateColumn: value)),
              ),
            ),
            _MappingField(
              label: context.l10n.dtxColAmount,
              value: preview.mapping!.amountColumn,
              headers: preview.headers,
              onChanged: (value) => onPreviewChanged(
                remapped(preview.mapping!.copyWith(amountColumn: value)),
              ),
            ),
            if (accounts.isNotEmpty)
              GlassDropdownField<String>(
                value: preview.defaultAccountId,
                decoration:
                    InputDecoration(labelText: context.l10n.dtxDefaultAccount),
                items: [
                  for (final account in accounts)
                    DropdownMenuItem<String>(
                      value: account.id,
                      child: Text('${account.name} • ${account.currency}'),
                    ),
                ],
                onChanged: (value) => onPreviewChanged(
                  preview.copyWith(defaultAccountId: value),
                ),
              ),
            _OptionalMappingField(
              label: context.l10n.dtxDebit,
              value: preview.mapping!.debitColumn,
              headers: preview.headers,
              onChanged: (value) => onPreviewChanged(
                remapped(preview.mapping!.copyWith(debitColumn: value)),
              ),
            ),
            _OptionalMappingField(
              label: context.l10n.dtxCredit,
              value: preview.mapping!.creditColumn,
              headers: preview.headers,
              onChanged: (value) => onPreviewChanged(
                remapped(preview.mapping!.copyWith(creditColumn: value)),
              ),
            ),
            for (final spec
                in <(String, String?, CsvColumnMapping Function(String))>[
              (
                context.l10n.dtxCurrency,
                preview.mapping!.currencyColumn,
                (value) => preview.mapping!.copyWith(currencyColumn: value)
              ),
              (
                context.l10n.commonAccountDefinite,
                preview.mapping!.accountColumn,
                (value) => preview.mapping!.copyWith(accountColumn: value)
              ),
              (
                context.l10n.dtxMerchantDesc,
                preview.mapping!.merchantColumn,
                (value) => preview.mapping!.copyWith(merchantColumn: value)
              ),
              (
                context.l10n.txnCategory,
                preview.mapping!.categoryColumn,
                (value) => preview.mapping!.copyWith(categoryColumn: value)
              ),
              (
                context.l10n.dtxNotes,
                preview.mapping!.noteColumn,
                (value) => preview.mapping!.copyWith(noteColumn: value)
              ),
              (
                context.l10n.dtxTxType,
                preview.mapping!.typeColumn,
                (value) => preview.mapping!.copyWith(typeColumn: value)
              ),
            ])
              _OptionalMappingField(
                label: spec.$1,
                value: spec.$2,
                headers: preview.headers,
                onChanged: (value) => onPreviewChanged(
                  remapped(spec.$3(value)),
                ),
              ),
            GlassDropdownField<ImportDateFormat>(
              value: preview.mapping!.dateFormat,
              decoration: InputDecoration(labelText: context.l10n.dtxDateFormat),
              items: [
                DropdownMenuItem(
                    value: ImportDateFormat.automatic,
                    child: Text(context.l10n.dtxDateAuto)),
                DropdownMenuItem(
                    value: ImportDateFormat.dayMonthYear,
                    child: Text(context.l10n.dtxDateDMY)),
                DropdownMenuItem(
                    value: ImportDateFormat.monthDayYear,
                    child: Text(context.l10n.dtxDateMDY)),
                DropdownMenuItem(
                    value: ImportDateFormat.yearMonthDay,
                    child: Text(context.l10n.dtxDateYMD)),
                const DropdownMenuItem(
                    value: ImportDateFormat.iso8601, child: Text('ISO-8601')),
              ],
              onChanged: (value) {
                if (value == null) return;
                onPreviewChanged(remapped(
                  preview.mapping!.copyWith(dateFormat: value),
                ));
              },
            ),
            if (preview.mapping!.accountColumn != null ||
                preview.mapping!.categoryColumn != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.l10n.dtxWillCreate,
                  style: AppTypography.caption(colors.textSecondary),
                ),
              ),
            if (preview.duplicateRecordIds.isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    context.l10n.dtxImportDupesAsNew(
                        preview.duplicateRecordIds.length)),
                value: preview.confirmedDuplicateRecordIds.length ==
                    preview.duplicateRecordIds.length,
                onChanged: (enabled) => onPreviewChanged(preview.copyWith(
                  confirmedDuplicateRecordIds:
                      enabled ? preview.duplicateRecordIds : const {},
                )),
              ),
          ],
          if (preview.canReplace) ...[
            const SizedBox(height: 16),
            SegmentedButton<ImportMode>(
              segments: [
                ButtonSegment(value: ImportMode.merge, label: Text(context.l10n.dtxMerge)),
                ButtonSegment(
                    value: ImportMode.replace, label: Text(context.l10n.dtxReplace)),
              ],
              selected: {mode},
              onSelectionChanged: (value) => onModeChanged(value.first),
            ),
          ],
          if (!preview.canReplace &&
              preview.format == ImportFormat.qirshPackage) ...[
            const SizedBox(height: 12),
            Text(
              context.l10n.dtxReplaceGuestOnly,
              style: AppTypography.caption(colors.textSecondary),
            ),
          ],
          if (preview.issues.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final issue in preview.issues.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  importIssueLine(context, issue),
                  style: AppTypography.caption(
                    issue.severity == ImportIssueSeverity.error
                        ? colors.danger
                        : colors.textSecondary,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: preview.hasErrors ? null : onImport,
            icon: const Icon(AppLucideIcons.download),
            label: Text(context.l10n.dtxConfirmImport),
          ),
        ],
      ),
    );
  }
}

class _MappingField extends StatelessWidget {
  const _MappingField({
    required this.label,
    required this.value,
    required this.headers,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> headers;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => GlassDropdownField<String>(
        value: value,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final header in headers)
            DropdownMenuItem(value: header, child: Text(header)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      );
}

class _OptionalMappingField extends StatelessWidget {
  const _OptionalMappingField({
    required this.label,
    required this.value,
    required this.headers,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> headers;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => GlassDropdownField<String>(
        value: headers.contains(value) ? value : null,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final header in headers)
            DropdownMenuItem(value: header, child: Text(header)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      );
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});
  final ImportResult result;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.dtxImportDone,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(context.l10n.dtxAdded(result.imported)),
          Text(context.l10n.dtxDuplicates(result.duplicates)),
          Text(context.l10n.dtxQuarantined(result.skipped)),
          Text(context.l10n.dtxFailed(result.failed)),
          if (result.cacheRepairPending)
            Text(
                context.l10n.dtxCacheRepair),
        ],
      );
}
