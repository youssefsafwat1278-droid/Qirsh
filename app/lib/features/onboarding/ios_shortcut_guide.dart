import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'shortcut_guide_video.dart';
import 'shortcut_setup_actions.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return AppTypography.custom(
    size: size,
    weight: weight,
    height: height,
    color: color,
    shadows: shadows,
    tabular: tabular,
  );
}

const String _defaultShortcutCurrency = 'SAR';

String _shortcutCurrency(String? currency) {
  final normalized = currency?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return _defaultShortcutCurrency;
  return normalized;
}

class IosShortcutGuide extends StatelessWidget {
  const IosShortcutGuide({
    super.key,
    this.currencyCode = _defaultShortcutCurrency,
  });

  final String currencyCode;

  /// One list, both languages.
  ///
  /// This used to be `if (locale == 'en') return [...]; return [...]` — two
  /// complete step lists, maintained in parallel, already visibly drifting
  /// (the Arabic steps carried colloquial forms the English ones did not, and
  /// one Arabic step had been half-migrated to the ARB while its neighbour had
  /// not). The ARB does the switching now, so there is one list and one place
  /// to change a step.
  static List<_ShortcutStep> _getSteps(
    BuildContext context,
    String currencyCode,
  ) {
    final l = context.l10n;
    return [
      _ShortcutStep(l.iosStep1, l.iosStep1Body, AppLucideIcons.layers),
      _ShortcutStep(l.iosStep2, l.iosStep2Body, AppLucideIcons.plusCircle),
      _ShortcutStep(
          l.iosStep3, l.iosStep3Body(currencyCode), AppLucideIcons.filter),
      _ShortcutStep(l.iosStep4, l.iosStep4Body, AppLucideIcons.zap),
      _ShortcutStep(l.iosStep5, l.iosStep5Body, AppLucideIcons.send),
      _ShortcutStep(l.iosStep6, l.iosStep6Body, AppLucideIcons.fileText),
      _ShortcutStep(l.iosStep7, l.iosStep7Body, AppLucideIcons.volumeX),
      _ShortcutStep(l.iosStep8, l.iosStep8Body, AppLucideIcons.checkCircle),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final steps = _getSteps(context, _shortcutCurrency(currencyCode));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ShortcutGuideVideo(),
        const SizedBox(height: 16),
        ShortcutSetupActions(currencyCode: _shortcutCurrency(currencyCode)),
        const SizedBox(height: 20),
        ExpansionTile(
          title: Text(context.l10n.shortcutManualSteps,
              style: _alex(15, FontWeight.w800, 1.3, c.textMain)),
          children: [
            Text(
              context.l10n.doStepsOnceFromShortcuts,
              style: _alex(11, FontWeight.w600, 1.45, c.textLight),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < steps.length; i++) ...[
              _ShortcutStepRow(index: i + 1, step: steps[i]),
              if (i != steps.length - 1) const SizedBox(height: 12),
            ],
          ],
        ),
      ],
    );
  }
}

class _ShortcutStep {
  const _ShortcutStep(this.title, this.body, this.icon);

  final String title;
  final String body;
  final IconData icon;
}

class _ShortcutStepRow extends StatelessWidget {
  const _ShortcutStepRow({required this.index, required this.step});

  final int index;
  final _ShortcutStep step;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            border: Border.all(color: c.primary.withValues(alpha: 0.18)),
          ),
          alignment: Alignment.center,
          child: Text(
            '$index',
            style: _alex(12, FontWeight.w800, 1, c.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      step.title,
                      style: _alex(13, FontWeight.w800, 1.25, c.textMain),
                    ),
                  ),
                  Icon(step.icon, color: c.accent, size: 16),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                step.body,
                style: _alex(11, FontWeight.w600, 1.45, c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// يفتح دليل اختصار آبل كـ bottom sheet قابل للسحب لأسفل.
Future<void> showIosShortcutSheet(BuildContext context) {
  final c = context.colors;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: c.bg,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (_) => navySheetTheme(const _IosShortcutSheet()),
  );
}

class _IosShortcutSheet extends ConsumerWidget {
  const _IosShortcutSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final shortcutCurrency =
        _shortcutCurrency(ref.watch(baseCurrencyProvider).valueOrNull);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.gutter,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
              child:
                  QirshIllustration(name: 'capture', width: 220, height: 165)),
          const SizedBox(height: 12),
          Text(context.l10n.setupAppleShortcut,
              textAlign: TextAlign.center,
              style: _alex(22, FontWeight.w700, 1.3, c.textPrimary)),
          const SizedBox(height: 8),
          Text(context.l10n.autoTrackingSubtitleIos,
              textAlign: TextAlign.center,
              style: _alex(13, FontWeight.w400, 1.7, c.textMuted)),
          const SizedBox(height: 16),
          MaliCard(
            padding: const EdgeInsets.all(18),
            child: IosShortcutGuide(
              currencyCode: shortcutCurrency,
            ),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
