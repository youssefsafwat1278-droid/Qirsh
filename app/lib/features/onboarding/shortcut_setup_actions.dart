import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';
import '../capture/services/native_capture_bridge.dart';

const qirshShortcutInstallUrl =
    'https://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20';
const qirshShortcutProbe = 'QIRSH_SETUP_CHECK_V1';

Uri qirshShortcutTestUrl() =>
    Uri(scheme: 'shortcuts', host: 'run-shortcut', queryParameters: {
      'name': 'QIRSH',
      'input': 'text',
      'text': qirshShortcutProbe
    });

class ShortcutSetupActions extends StatefulWidget {
  const ShortcutSetupActions(
      {super.key, this.openUrl, this.readProbe, this.currencyCode = 'EGP'});
  final String currencyCode;
  final Future<bool> Function(Uri)? openUrl;
  final Future<int> Function()? readProbe;
  @override
  State<ShortcutSetupActions> createState() => _ShortcutSetupActionsState();
}

class _ShortcutSetupActionsState extends State<ShortcutSetupActions> {
  String _query = '';
  final _search = TextEditingController();
  final Set<String> _reviewed = {};
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
                readProbe: widget.readProbe)));
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
            if (_reviewed.contains(_selected.term))
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(l.shortcutCatalogReviewed)),
            const SizedBox(height: 14),
            FilledButton.icon(
                key: const Key('shortcut_begin'),
                onPressed: () => _show(_selected),
                icon: const Icon(Icons.link),
                label: Text(l.shortcutStudioBegin(_selected.term))),
          ])),
      const SizedBox(height: 12),
      Text(l.shortcutCatalogSingleTemplate,
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

class ShortcutKeyword {
  const ShortcutKeyword(this.term, this.currency);
  final String term;
  final String currency;
}

const qirshShortcutKeywords = [
  ShortcutKeyword('EGP', 'EGP'),
  ShortcutKeyword('جم', 'EGP'),
  ShortcutKeyword('جنيه', 'EGP'),
  ShortcutKeyword('ج.م', 'EGP'),
  ShortcutKeyword('USD', 'USD'),
  ShortcutKeyword('EUR', 'EUR'),
  ShortcutKeyword('SAR', 'SAR'),
  ShortcutKeyword('ر.س', 'SAR'),
  ShortcutKeyword('AED', 'AED'),
  ShortcutKeyword('د.إ', 'AED'),
  ShortcutKeyword('KWD', 'KWD'),
  ShortcutKeyword('د.ك', 'KWD'),
];

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

class _ShortcutWalkthrough extends StatefulWidget {
  const _ShortcutWalkthrough(
      {required this.keyword, this.openUrl, this.readProbe});
  final ShortcutKeyword keyword;
  final Future<bool> Function(Uri)? openUrl;
  final Future<int> Function()? readProbe;
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
      opened = await (widget.openUrl?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
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
    final titles = [
      l.shortcutVisualInstallTitle,
      l.shortcutVisualFilterTitle,
      l.shortcutVisualArrowTitle,
      l.shortcutVisualAutomationTitle,
      l.shortcutVisualTestTitle
    ];
    final bodies = [
      l.shortcutVisualInstallBody,
      l.shortcutVisualFilterBody(widget.keyword.term),
      l.shortcutVisualArrowBody,
      l.shortcutVisualAutomationBody,
      l.shortcutVisualTestBody
    ];
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
                            child: Text(l.shortcutVisualStep(_step + 1, 5),
                                key: const Key('shortcut_step'),
                                style: Theme.of(context).textTheme.labelLarge)),
                      ]),
                      const SizedBox(height: 14),
                      ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                              key: const Key('shortcut_progress'),
                              minHeight: 5,
                              value: (_step + 1) / 5,
                              color: AppBrandAccent.gold,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant)),
                      const SizedBox(height: 24),
                      Text(titles[_step],
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(bodies[_step]),
                      const SizedBox(height: 20),
                      if (_step == 0) _KeywordExample(keyword: widget.keyword),
                      if (_step >= 1 && _step <= 3) ...[
                        _ShortcutScreenshot(focus: _step),
                        const SizedBox(height: 12),
                        Text(l.shortcutVisualImageCaption,
                            style: Theme.of(context).textTheme.bodySmall)
                      ],
                      if (_step == 4) ...[
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
                      if (_step == 0)
                        FilledButton.icon(
                            key: const Key('shortcut_install'),
                            onPressed: _opening
                                ? null
                                : () =>
                                    _open(Uri.parse(qirshShortcutInstallUrl)),
                            icon: const Icon(Icons.add),
                            label: Text(l.shortcutAddReady)),
                      if (_step >= 1 && _step <= 3)
                        OutlinedButton.icon(
                            key: const Key('shortcut_edit'),
                            onPressed: _opening
                                ? null
                                : () => _open(Uri(
                                    scheme: 'shortcuts',
                                    host: 'open-shortcut',
                                    queryParameters: {'name': 'QIRSH'})),
                            icon: const Icon(Icons.open_in_new),
                            label: Text(l.shortcutOpenEditor)),
                      if (_step == 4)
                        OutlinedButton.icon(
                            key: const Key('shortcut_test'),
                            onPressed: _opening
                                ? null
                                : () =>
                                    _open(qirshShortcutTestUrl(), test: true),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(l.shortcutTestConnection)),
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
                                  if (_step < 4) {
                                    _move(1);
                                  } else {
                                    Navigator.pop(context, true);
                                  }
                                },
                                child:
                                    Text(_step == 4 ? l.rcStepDone : l.next))),
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
