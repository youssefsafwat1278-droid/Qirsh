import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/privacy/gated_url_launcher.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';
import '../capture/services/native_capture_bridge.dart';

const qirshShortcutInstallUrl =
    'https://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20';
const qirshShortcutProbe = 'QIRSH_SETUP_CHECK_V1';

Uri qirshShortcutTestUrl({String name = qirshTemplateShortcutName}) =>
    Uri(scheme: 'shortcuts', host: 'run-shortcut', queryParameters: {
      'name': name,
      'input': 'text',
      'text': qirshShortcutProbe
    });

class ShortcutSetupActions extends StatefulWidget {
  const ShortcutSetupActions(
      {super.key,
      this.openUrl,
      this.readProbe,
      this.currencyCode = 'EGP',
      this.store = const ShortcutSetupStore()});
  final String currencyCode;
  final Future<bool> Function(Uri)? openUrl;
  final Future<int> Function()? readProbe;
  final ShortcutSetupStore store;
  @override
  State<ShortcutSetupActions> createState() => _ShortcutSetupActionsState();
}

class _ShortcutSetupActionsState extends State<ShortcutSetupActions> {
  String _query = '';
  final _search = TextEditingController();
  final Set<String> _reviewed = {};
  Map<String, ShortcutSetupRecord> _records = {};
  late String _currency;
  late ShortcutKeyword _selected;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _currency =
        qirshShortcutKeywords.any((k) => k.currency == widget.currencyCode)
            ? widget.currencyCode
            : 'EGP';
    _selected =
        qirshShortcutKeywords.firstWhere((k) => k.currency == _currency);
    unawaited(widget.store.load().then((records) {
      if (mounted) setState(() => _records = records);
    }));
  }

  void _record(String term,
      ShortcutSetupRecord Function(ShortcutSetupRecord) update) {
    if (!mounted) return;
    setState(() => _records = {
          ..._records,
          term: update(_records[term] ?? const ShortcutSetupRecord())
        });
    unawaited(widget.store.save(_records));
  }

  /// Another keyword of the same currency already set up: two automations
  /// can both fire for one SMS and queue it twice.
  ShortcutKeyword? _overlapFor(ShortcutKeyword keyword) {
    for (final other in qirshShortcutKeywords) {
      if (other.term == keyword.term || other.currency != keyword.currency) {
        continue;
      }
      final record = _records[other.term];
      if (record?.testedAt != null || record?.confirmedAt != null) return other;
    }
    return null;
  }

  Future<void> _show(ShortcutKeyword keyword) async {
    FocusScope.of(context).unfocus();
    final reviewed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .94,
            child: _ShortcutWalkthrough(
                keyword: keyword,
                openUrl: widget.openUrl,
                readProbe: widget.readProbe,
                onTested: (at) => _record(
                    keyword.term,
                    (r) => ShortcutSetupRecord(
                        testedAt: at, confirmedAt: r.confirmedAt)),
                onConfirmed: (at) => _record(
                    keyword.term,
                    (r) => ShortcutSetupRecord(
                        testedAt: r.testedAt, confirmedAt: at)))));
    if (mounted && reviewed == true) {
      setState(() => _reviewed.add(keyword.term));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final query = _query.trim().toLowerCase();
    final matching = qirshShortcutKeywords
        .where((k) => query.isEmpty
            ? k.currency == _currency
            : '${k.term} ${k.currency}'.toLowerCase().contains(query))
        .toList();
    final currencies = qirshShortcutKeywords.map((k) => k.currency).toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
          key: const Key('shortcut_connection_hero'),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
              gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppBrandBlue.deep, AppBrandBlue.brand]),
              borderRadius: BorderRadius.circular(28)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.shortcutStudioTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: Colors.white)),
            const SizedBox(height: 8),
            Text(l.shortcutStudioBody,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: const Color(0xFFCBD7F3))),
            const SizedBox(height: 22),
            Row(children: [
              _RouteNode(
                  icon: const Icon(Icons.sms_outlined, color: Colors.white),
                  label: l.shortcutRouteMessage),
              const Expanded(child: Divider(color: Color(0xFF5575BE))),
              _RouteNode(
                  icon: const Icon(Icons.bolt, color: AppBrandAccent.gold),
                  label: l.shortcutRouteAutomation),
              const Expanded(child: Divider(color: Color(0xFF5575BE))),
              _RouteNode(
                  icon: Image.asset(AppAssets.qirshCoinGold,
                      width: 32, height: 32),
                  label: l.appTitle),
            ]),
          ])),
      const SizedBox(height: 22),
      Text(l.shortcutStudioCurrency,
          style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final currency in currencies)
          ChoiceChip(
              key: ValueKey('shortcut_currency_$currency'),
              label: Text(currency),
              selected: _currency == currency,
              onSelected: (_) => setState(() {
                    _currency = currency;
                    _query = '';
                    _search.clear();
                    _selected = qirshShortcutKeywords
                        .firstWhere((k) => k.currency == currency);
                  }))
      ]),
      const SizedBox(height: 18),
      TextField(
          key: const Key('shortcut_search'),
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l.shortcutCatalogSearch)),
      const SizedBox(height: 14),
      Text(l.shortcutStudioWord, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 8, children: [
        for (final keyword in matching)
          ChoiceChip(
              key: ValueKey('shortcut_choose_${keyword.term}'),
              selected: _selected.term == keyword.term,
              label: Text(keyword.term),
              onSelected: (_) => setState(() => _selected = keyword))
      ]),
      if (matching.isEmpty) Text(l.shortcutCatalogNoMatches),
      const SizedBox(height: 20),
      Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.tune,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(l.shortcutStudioPreview,
                      style: Theme.of(context).textTheme.titleSmall))
            ]),
            const SizedBox(height: 12),
            _KeywordExample(keyword: _selected),
            if (_records[_selected.term]?.confirmedAt != null)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l.shortcutStateConfirmed,
                      key: const Key('shortcut_state_confirmed')))
            else if (_records[_selected.term]?.testedAt != null)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l.shortcutStateTested,
                      key: const Key('shortcut_state_tested')))
            else if (_reviewed.contains(_selected.term))
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l.shortcutCatalogReviewed)),
            if (_overlapFor(_selected) case final other?)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l.shortcutOverlapWarning(other.term),
                      key: const Key('shortcut_overlap'),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 14),
            FilledButton.icon(
                key: const Key('shortcut_begin'),
                onPressed: () => _show(_selected),
                icon: const Icon(Icons.link),
                label: Text(l.shortcutStudioBegin(_selected.term))),
          ])),
      const SizedBox(height: 12),
      Text(
          _selected.hasDedicatedShortcut
              ? l.shortcutCatalogDedicated(_selected.term)
              : l.shortcutCatalogSingleTemplate,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _RouteNode extends StatelessWidget {
  const _RouteNode({required this.icon, required this.label});
  final Widget icon;
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 66,
      child: Column(children: [
        Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .09),
                shape: BoxShape.circle),
            child: icon),
        const SizedBox(height: 8),
        Text(label,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Colors.white)),
      ]));
}

/// The shared template's name in Shortcuts; also what the connection test runs
/// for a keyword that has no dedicated shortcut yet.
const qirshTemplateShortcutName = 'QIRSH';

/// One SMS keyword and the Apple Shortcut that captures it.
///
/// [installUrl] is set only for a published iCloud link whose shortcut already
/// carries "Message contains [term]" — the user then has nothing to type. The
/// signed files come from `tools/shortcuts/build_qirsh_shortcuts.py`; a link is
/// added here only after it is imported into Shortcuts and shared from there.
/// Without one, the keyword falls back to the shared QIRSH template plus the
/// edit-the-filter step.
class ShortcutKeyword {
  const ShortcutKeyword(this.term, this.currency,
      {required this.shortcutName, this.installUrl});
  final String term;
  final String currency;
  final String shortcutName;
  final String? installUrl;

  bool get hasDedicatedShortcut => installUrl != null;

  /// The name Shortcuts knows this keyword's shortcut by.
  String get runName =>
      hasDedicatedShortcut ? shortcutName : qirshTemplateShortcutName;

  String get installLink => installUrl ?? qirshShortcutInstallUrl;
}

const qirshShortcutKeywords = [
  // The published QIRSH link is itself the EGP shortcut: its trigger is
  // "Message contains EGP" and existing users already have it under this name.
  ShortcutKeyword('EGP', 'EGP',
      shortcutName: qirshTemplateShortcutName,
      installUrl: qirshShortcutInstallUrl),
  ShortcutKeyword('جم', 'EGP',
      shortcutName: 'Qirsh جم',
      installUrl:
          'https://www.icloud.com/shortcuts/f4427bb0ae21448eb6b621586d21d1c7'),
  ShortcutKeyword('جنيه', 'EGP',
      shortcutName: 'Qirsh جنيه',
      installUrl:
          'https://www.icloud.com/shortcuts/fc8937c697834e039242e4525b04b9da'),
  ShortcutKeyword('ج.م', 'EGP',
      shortcutName: 'Qirsh ج.م',
      installUrl:
          'https://www.icloud.com/shortcuts/f1b358880ece40c48ef27cf471bcffbb'),
  ShortcutKeyword('USD', 'USD',
      shortcutName: 'Qirsh USD',
      installUrl:
          'https://www.icloud.com/shortcuts/48e9741970124e459d24d59882ebfe5f'),
  ShortcutKeyword('EUR', 'EUR',
      shortcutName: 'Qirsh EUR',
      installUrl:
          'https://www.icloud.com/shortcuts/d6eeae970aa6427d892a93da483cf620'),
  ShortcutKeyword('SAR', 'SAR',
      shortcutName: 'Qirsh SAR',
      installUrl:
          'https://www.icloud.com/shortcuts/e95495d9fbea4f788fb1ea4afd30d2d3'),
  ShortcutKeyword('ر.س', 'SAR',
      shortcutName: 'Qirsh ر.س',
      installUrl:
          'https://www.icloud.com/shortcuts/5f4cfd84db674faf8593a3ab0c4f48e8'),
  ShortcutKeyword('AED', 'AED',
      shortcutName: 'Qirsh AED',
      installUrl:
          'https://www.icloud.com/shortcuts/1086750a822242959694c7f916a3777b'),
  // Shortcuts stored this name decomposed (alef + U+0655 hamza below), so
  // runName matches the installed shortcut exactly; the trigger text is 'د.إ'.
  ShortcutKeyword('د.إ', 'AED',
      shortcutName: 'Qirsh \u062F.\u0627\u0655',
      installUrl:
          'https://www.icloud.com/shortcuts/069ddee8430b4c858db38d952d0f021d'),
  ShortcutKeyword('KWD', 'KWD',
      shortcutName: 'Qirsh KWD',
      installUrl:
          'https://www.icloud.com/shortcuts/5fb21c20eecb4b75814c243829398842'),
  ShortcutKeyword('د.ك', 'KWD',
      shortcutName: 'Qirsh د.ك',
      installUrl:
          'https://www.icloud.com/shortcuts/4ae1c26d5be844cb83be057c3fd0abc2'),
];

/// What Qirsh knows about one keyword's setup. iOS offers no API to read a
/// Personal Automation, so the strongest states are a fresh probe from the
/// shortcut ([testedAt]) and the user's own word ([confirmedAt]).
class ShortcutSetupRecord {
  const ShortcutSetupRecord({this.testedAt, this.confirmedAt});
  final int? testedAt;
  final int? confirmedAt;

  Map<String, int> toJson() => {
        if (testedAt != null) 'tested': testedAt!,
        if (confirmedAt != null) 'confirmed': confirmedAt!,
      };

  static ShortcutSetupRecord fromJson(Object? json) {
    if (json is! Map) return const ShortcutSetupRecord();
    int? read(String key) => (json[key] as num?)?.toInt();
    return ShortcutSetupRecord(
        testedAt: read('tested'), confirmedAt: read('confirmed'));
  }
}

/// Per-keyword setup state, kept on this device only: it describes this
/// phone's Shortcuts, and holds keywords and times, never message text.
class ShortcutSetupStore {
  const ShortcutSetupStore();
  static const _key = 'shortcut_setup_v1';

  Future<Map<String, ShortcutSetupRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          '${entry.key}': ShortcutSetupRecord.fromJson(entry.value)
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, ShortcutSetupRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key,
          jsonEncode({for (final e in records.entries) e.key: e.value.toJson()}));
    } catch (_) {
      // State is a convenience; capture itself never depends on it.
    }
  }
}

class _KeywordExample extends StatelessWidget {
  const _KeywordExample({required this.keyword});
  final ShortcutKeyword keyword;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final parts = l.shortcutCatalogExample(keyword.term).split(keyword.term);
    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14)),
        child: Text.rich(
            TextSpan(children: [
              for (var i = 0; i < parts.length; i++) ...[
                if (i > 0)
                  TextSpan(
                      text: keyword.term,
                      style: const TextStyle(
                          color: Color(0xFF13234A),
                          backgroundColor: Color(0xFFFFE7A0),
                          fontWeight: FontWeight.w700)),
                TextSpan(text: parts[i]),
              ]
            ]),
            style: Theme.of(context).textTheme.bodyMedium));
  }
}

enum _WalkStep { install, filter, arrow, automation, test }

class _ShortcutWalkthrough extends StatefulWidget {
  const _ShortcutWalkthrough(
      {required this.keyword,
      this.openUrl,
      this.readProbe,
      required this.onTested,
      required this.onConfirmed});
  final ShortcutKeyword keyword;
  final Future<bool> Function(Uri)? openUrl;
  final Future<int> Function()? readProbe;
  final void Function(int at) onTested;
  final void Function(int at) onConfirmed;
  @override
  State<_ShortcutWalkthrough> createState() => _ShortcutWalkthroughState();
}

class _ShortcutWalkthroughState extends State<_ShortcutWalkthrough> {
  late final AppLifecycleListener _lifecycle;
  final _scroll = ScrollController();
  int _step = 0;
  int? _testStartedAt;
  bool _verified = false;
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_readResult()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _readResult() async {
    final started = _testStartedAt;
    if (started == null) return;
    final received = await (widget.readProbe ??
        NativeCaptureBridge.shortcutSetupProbeStatus)();
    if (mounted && _testStartedAt == started && received >= started) {
      setState(() => _verified = true);
      widget.onTested(received);
    }
  }

  Future<void> _open(Uri uri, {bool test = false}) async {
    setState(() {
      _opening = true;
      if (test) {
        _testStartedAt = DateTime.now().millisecondsSinceEpoch;
        _verified = false;
      }
    });
    bool opened;
    try {
      opened = await (widget.openUrl?.call(uri) ?? launchShortcutSetupUrl(uri));
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (!opened) {
      if (test) _testStartedAt = null;
      AppToast.showError(context, context.l10n.shortcutOpenFailed);
    } else if (test) {
      await _readResult();
    }
  }

  void _move(int delta) {
    setState(() => _step += delta);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final keyword = widget.keyword;
    // A dedicated shortcut already carries "Message contains <term>", so the
    // edit-the-filter step only exists for the shared template.
    final steps = [
      _WalkStep.install,
      if (!keyword.hasDedicatedShortcut) _WalkStep.filter,
      _WalkStep.arrow,
      _WalkStep.automation,
      _WalkStep.test
    ];
    final kind = steps[_step];
    final last = steps.length - 1;
    final title = switch (kind) {
      _WalkStep.install => l.shortcutVisualInstallTitle,
      _WalkStep.filter => l.shortcutVisualFilterTitle,
      _WalkStep.arrow => l.shortcutVisualArrowTitle,
      _WalkStep.automation => l.shortcutVisualAutomationTitle,
      _WalkStep.test => l.shortcutVisualTestTitle,
    };
    final body = switch (kind) {
      _WalkStep.install => keyword.hasDedicatedShortcut
          ? l.shortcutVisualInstallDedicatedBody(keyword.term)
          : l.shortcutVisualInstallBody,
      _WalkStep.filter => l.shortcutVisualFilterBody(keyword.term),
      _WalkStep.arrow => l.shortcutVisualArrowBody(keyword.runName),
      _WalkStep.automation => l.shortcutVisualAutomationBody,
      _WalkStep.test => l.shortcutVisualTestBody,
    };
    final editing = kind == _WalkStep.filter ||
        kind == _WalkStep.arrow ||
        kind == _WalkStep.automation;
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
              key: const Key('shortcut_close'),
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: l.rcStepDone,
              onPressed: () => Navigator.pop(context)),
          backgroundColor: AppBrandBlue.deep,
          foregroundColor: Colors.white,
          title: Text(l.shortcutStudioTitle,
              style: const TextStyle(color: Colors.white,
                  fontSize: 18, fontWeight: FontWeight.w700))),
      body: Column(children: [
        Expanded(
            child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                                color: AppBrandBlue.brand,
                                borderRadius: BorderRadius.circular(12)),
                            child: Text(widget.keyword.term,
                                style: const TextStyle(color: Colors.white))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(l.shortcutVisualStep(_step + 1, steps.length),
                                key: const Key('shortcut_step'),
                                style: Theme.of(context).textTheme.labelLarge)),
                      ]),
                      const SizedBox(height: 14),
                      ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                              key: const Key('shortcut_progress'),
                              minHeight: 5,
                              value: (_step + 1) / steps.length,
                              color: AppBrandAccent.gold,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant)),
                      const SizedBox(height: 24),
                      Text(title,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(body),
                      const SizedBox(height: 20),
                      if (kind == _WalkStep.install)
                        _KeywordExample(keyword: keyword),
                      if (editing) ...[
                        _ShortcutScreenshot(focus: kind.index),
                        const SizedBox(height: 12),
                        Text(l.shortcutVisualImageCaption,
                            style: Theme.of(context).textTheme.bodySmall)
                      ],
                      if (kind == _WalkStep.test) ...[
                        Icon(
                            _verified
                                ? Icons.check_circle_outline
                                : Icons.mark_email_unread_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 16),
                        if (_testStartedAt != null)
                          Text(
                              _verified
                                  ? l.shortcutProbePassed
                                  : l.shortcutProbeWaiting,
                              key: Key(_verified
                                  ? 'shortcut_verified'
                                  : 'shortcut_waiting')),
                        const SizedBox(height: 12),
                        Text(l.shortcutVisualReviewed),
                      ],
                    ]))),
        const Divider(height: 1),
        SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (kind == _WalkStep.install)
                        FilledButton.icon(
                            key: const Key('shortcut_install'),
                            onPressed: _opening
                                ? null
                                : () => _open(Uri.parse(keyword.installLink)),
                            icon: const Icon(Icons.add),
                            label: Text(l.shortcutAddReady)),
                      if (editing)
                        OutlinedButton.icon(
                            key: const Key('shortcut_edit'),
                            onPressed: _opening
                                ? null
                                : () => _open(Uri(
                                    scheme: 'shortcuts',
                                    host: 'open-shortcut',
                                    queryParameters: {
                                      'name': keyword.runName
                                    })),
                            icon: const Icon(Icons.open_in_new),
                            label: Text(l.shortcutOpenEditor(keyword.runName))),
                      if (kind == _WalkStep.test) ...[
                        OutlinedButton.icon(
                            key: const Key('shortcut_test'),
                            onPressed: _opening
                                ? null
                                : () => _open(
                                    qirshShortcutTestUrl(
                                        name: keyword.runName),
                                    test: true),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(l.shortcutTestConnection)),
                        const SizedBox(height: 8),
                        // iOS cannot report whether the Personal Automation is
                        // on; this records only the user's own confirmation.
                        OutlinedButton.icon(
                            key: const Key('shortcut_confirm'),
                            onPressed: () {
                              widget.onConfirmed(
                                  DateTime.now().millisecondsSinceEpoch);
                              Navigator.pop(context, true);
                            },
                            icon: const Icon(Icons.check),
                            label: Text(l.shortcutConfirmAutomation)),
                      ],
                      const SizedBox(height: 8),
                      Row(children: [
                        if (_step > 0) ...[
                          TextButton(
                              key: const Key('shortcut_previous'),
                              onPressed: () => _move(-1),
                              child: Text(l.setBack)),
                          const SizedBox(width: 12)
                        ],
                        Expanded(
                            child: FilledButton(
                                key: const Key('shortcut_next'),
                                onPressed: () {
                                  if (_step < last) {
                                    _move(1);
                                  } else {
                                    Navigator.pop(context, true);
                                  }
                                },
                                child:
                                    Text(_step == last ? l.rcStepDone : l.next))),
                      ]),
                    ]))),
      ]),
    );
  }
}

/// Layout-time crops of the original Qirsh/iOS references with code-drawn
/// highlights. These are explanatory images; the real iOS controls are external.
class _ShortcutScreenshot extends StatelessWidget {
  const _ShortcutScreenshot({required this.focus});
  final int focus;
  @override
  Widget build(BuildContext context) {
    final automation = focus == 3;
    final asset =
        'assets/shortcut_guide/${automation ? 'automation' : 'message-filter'}.png';
    return Semantics(
      button: true,
      label: context.l10n.shortcutVisualEnlarge,
      child: InkWell(
          onTap: () => showDialog<void>(
              context: context,
              builder: (context) => Dialog(
                  backgroundColor: Colors.black,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                        child: InteractiveViewer(
                            minScale: 1,
                            maxScale: 4,
                            child: Image.asset(asset, fit: BoxFit.contain))),
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.rcStepDone)),
                  ]))),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LayoutBuilder(builder: (context, constraints) {
                final w = constraints.maxWidth;
                Widget highlight(
                        double x, double y, double width, double height) =>
                    Positioned(
                        left: w * x,
                        top: w * y,
                        width: w * width,
                        height: w * height,
                        child: IgnorePointer(
                            child: DecoratedBox(
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: AppBrandAccent.gold,
                                        width: 3)))));
                return SizedBox(
                    height: w * (automation ? .43 : .56),
                    child: ClipRect(
                        child: Stack(children: [
                      Positioned(
                          top: -w * (automation ? 1.08 : .72),
                          left: 0,
                          right: 0,
                          child: Image.asset(asset, fit: BoxFit.fitWidth)),
                      if (focus == 1) highlight(.56, .27, .18, .11),
                      if (focus == 2) highlight(.24, .08, .12, .13),
                      if (automation) ...[
                        highlight(.80, .13, .16, .13),
                        highlight(.80, .25, .16, .13)
                      ],
                    ])));
              }))),
    );
  }
}
