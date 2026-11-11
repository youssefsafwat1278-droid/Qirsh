import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/widgets/qirsh_visuals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/reporting/report_request.dart';
import '../../settings/settings_providers.dart';
import '../providers/report_providers.dart';
import '../services/report_generation_controller.dart';
import '../../common/app_header.dart';
import 'report_preview_screen.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/theme/widgets/glass_dialog.dart';
import '../../../core/theme/widgets/glass_dropdown_field.dart';
import '../../../core/theme/widgets/app_toast.dart';

enum _PeriodKind { weekly, monthly, yearly, custom }


/// Opens the report configuration PAGE and returns the chosen [ReportRequest],
/// or null if the user backs out.
///
/// This is a normal full-screen route (it used to be a modal bottom sheet): the
/// form is long enough that a sheet cramped it against the keyboard. The
/// returned value and every downstream step — coordinator → ad gate →
/// generation → [ReportPreviewScreen] — are unchanged.
Future<ReportRequest?> showReportConfigPage(BuildContext context) {
  return Navigator.of(context).push<ReportRequest>(
    MaterialPageRoute<ReportRequest>(
      builder: (_) => const _ReportConfigPage(),
    ),
  );
}

class _ReportConfigPage extends ConsumerStatefulWidget {
  const _ReportConfigPage();

  @override
  ConsumerState<_ReportConfigPage> createState() => _ReportConfigPageState();
}

class _ReportConfigPageState extends ConsumerState<_ReportConfigPage> {
  _PeriodKind _period = _PeriodKind.monthly;
  DateTimeRange? _customRange;
  bool _allAccounts = true;
  String? _accountId;
  late String _lang;
  bool _details = false;
  bool _merchants = true;
  bool _accounts = true;
  bool _balances = true;
  bool _insights = true;
  bool _privacy = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(userSettingsProvider).valueOrNull;
    _lang = settings?.language == 'en' ? 'en' : 'ar';
    _privacy = settings?.privacyModeEnabled ?? false;
  }

  ReportRequest _buildRequest(String? selectedAccountId) {
    final ReportPeriod period = switch (_period) {
      _PeriodKind.weekly => const WeeklyPeriod(),
      _PeriodKind.yearly => const YearlyPeriod(),
      _PeriodKind.custom => CustomPeriod(
          from: DateTime(_customRange!.start.year, _customRange!.start.month,
              _customRange!.start.day),
          to: DateTime(_customRange!.end.year, _customRange!.end.month,
                  _customRange!.end.day)
              .add(const Duration(days: 1)),
        ),
      _PeriodKind.monthly => const MonthlyPeriod(),
    };
    final scope = _allAccounts
        ? const AllAccountsScope()
        : SingleAccountScope(selectedAccountId!);
    return ReportRequest(
      period: period,
      scope: scope,
      languageCode: _lang,
      content: ReportContentOptions(
        includeTransactionDetails: _details,
        includeMerchantNames: _merchants,
        includeAccountNames: _accounts,
        includeBalances: _balances,
        includeInsights: _insights,
      ),
      privacyMode: _privacy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <AccountEntity>[];
    final selectedAccountId = accounts.any((a) => a.id == _accountId)
        ? _accountId
        : (accounts.isEmpty ? null : accounts.first.id);
    final canGenerate = (_period != _PeriodKind.custom || _customRange != null) &&
        (_allAccounts || selectedAccountId != null);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppHeader(
          title: context.l10n.rcTitle),
      // Immersive: scrolls under the glass bar; content starts below it.
      body: Builder(builder: (bodyContext) => SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: MediaQuery.paddingOf(bodyContext).top + 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Center(child: QirshIllustration(name: 'reports', width: 170, height: 128)),
            const SizedBox(height: 12),
            _label(context.l10n.rcPeriod),
            Wrap(
              spacing: 8,
              children: <Widget>[
                _periodChip(_PeriodKind.weekly, context.l10n.txnCycleWeekly),
                _periodChip(_PeriodKind.monthly, context.l10n.txnCycleMonthly),
                _periodChip(_PeriodKind.yearly, context.l10n.txnCycleYearly),
                _periodChip(_PeriodKind.custom, context.l10n.rcCustom),
              ],
            ),
            if (_period == _PeriodKind.custom)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(AppLucideIcons.calendarRange, size: 18),
                  label: Text(_customRange == null
                      ? context.l10n.rcPickRange
                      : '${_customRange!.start.toString().split(' ').first}'
                          ' → ${_customRange!.end.toString().split(' ').first}'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(now.year - 5),
                      lastDate: now,
                      initialDateRange: _customRange,
                      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
                        value: Theme.of(context).brightness == Brightness.dark
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            appBarTheme: Theme.of(context).appBarTheme.copyWith(
                              systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
                                  ? SystemUiOverlayStyle.light
                                  : SystemUiOverlayStyle.dark,
                            ),
                          ),
                          child: child!,
                        ),
                      ),
                    );
                    if (picked != null) setState(() => _customRange = picked);
                  },
                ),
              ),
            const SizedBox(height: 16),
            _label(context.l10n.accTitleShort),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.homeAllAccounts),
              value: _allAccounts,
              onChanged: (v) => setState(() => _allAccounts = v),
            ),
            if (!_allAccounts && accounts.isNotEmpty)
              GlassDropdownField<String>(
                isExpanded: true,
                value: selectedAccountId,
                items: <DropdownMenuItem<String>>[
                  for (final a in accounts)
                    DropdownMenuItem<String>(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _accountId = v),
              ),
            const SizedBox(height: 12),
            _label(context.l10n.rcLanguage),
            SegmentedButton<String>(
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'ar', label: Text(context.l10n.rcArabic)),
                const ButtonSegment<String>(value: 'en', label: Text('English')),
              ],
              selected: <String>{_lang},
              onSelectionChanged: (s) => setState(() => _lang = s.first),
            ),
            const SizedBox(height: 8),
            _switch(context.l10n.rcTxDetails, _details,
                (v) => _details = v),
            _switch(context.l10n.rcMerchantNames, _merchants,
                (v) => _merchants = v),
            _switch(context.l10n.rcAccountNames, _accounts,
                (v) => _accounts = v),
            _switch(context.l10n.rcBalances, _balances, (v) => _balances = v),
            _switch(context.l10n.rcNotes, _insights, (v) => _insights = v),
            _switch(context.l10n.rcPrivacyMode, _privacy, (v) => _privacy = v),
          ],
        ),
      )),
      // Pinned action so the primary CTA stays reachable on a long form.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(AppLucideIcons.fileText, size: 18),
            label: Text(context.l10n.rcCreateReport),
            onPressed: canGenerate
                ? () => Navigator.of(context).pop(_buildRequest(selectedAccountId))
                : null,
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.outline)),
      );

  Widget _periodChip(_PeriodKind kind, String text) => ChoiceChip(
        label: Text(text),
        selected: _period == kind,
        onSelected: (_) => setState(() => _period = kind),
      );

  Widget _switch(String text, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(text),
        value: value,
        onChanged: (v) => setState(() => onChanged(v)),
      );
}

/// Runs generation with a progress dialog and, on success, opens the preview.
Future<void> runReportGeneration(
    BuildContext context, WidgetRef ref, ReportRequest request) async {
  // Best-effort cleanup of stale report temp files from previous sessions.
  unawaited(ref.read(reportFileServiceProvider).sweepStale());
  final controller = ref.read(reportGenerationControllerProvider)..invalidate();
  final cancel = ReportCancelToken();
  final progress = ValueNotifier<ReportProgress>(
      const ReportProgress(ReportStage.collecting, 0.05));

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        _ProgressDialog(progress: progress, cancel: cancel),
  );

  try {
    final result = await controller.generate(
      request,
      cancel: cancel,
      onProgress: (p) => progress.value = p,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReportPreviewScreen(
        bytes: result.bytes,
        export: result.export,
        fileService: ref.read(reportFileServiceProvider),
        containsSensitive: !request.privacyMode,
      ),
    ));
  } on ReportGenerationException catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress
    if (e.kind == ReportErrorKind.cancelled) return;
    AppToast.showError(context, _errorText(context, e.kind));
  } finally {
    progress.dispose();
  }
}

String _errorText(BuildContext context, ReportErrorKind kind) =>
    switch (kind) {
      ReportErrorKind.noData =>
        context.l10n.rcNoDataInPeriod,
      ReportErrorKind.fontLoadFailed =>
        context.l10n.rcFontsFailed,
      ReportErrorKind.renderFailed =>
        context.l10n.rcPdfFailed,
      ReportErrorKind.writeFailed =>
        context.l10n.rcSaveFailed,
      ReportErrorKind.cancelled => context.l10n.rcCancelled,
      ReportErrorKind.unknown =>
        context.l10n.rcUnexpectedError,
    };

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.progress, required this.cancel});

  final ValueNotifier<ReportProgress> progress;
  final ReportCancelToken cancel;

  @override
  Widget build(BuildContext context) {
    return GlassAlertDialog(
      content: ValueListenableBuilder<ReportProgress>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(context.l10n.rcGenerating),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value.fraction),
            const SizedBox(height: 8),
            Text(_stageText(context, value.stage),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: cancel.cancel,
          child: Text(context.l10n.commonCancel),
        ),
      ],
    );
  }

  String _stageText(BuildContext context, ReportStage stage) => switch (stage) {
        ReportStage.collecting => context.l10n.rcStepCollect,
        ReportStage.composing => context.l10n.rcStepMetrics,
        ReportStage.rendering => context.l10n.rcStepDraw,
        ReportStage.writing => context.l10n.rcStepSave,
        ReportStage.ready => context.l10n.rcStepDone,
        _ => '',
      };
}
