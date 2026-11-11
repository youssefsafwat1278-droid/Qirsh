import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'manual_paste_screen.dart';
import '../../core/utils/l10n_ext.dart';

class SmsPermissionScreen extends StatefulWidget {
  const SmsPermissionScreen({super.key});

  static Future<void> showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      // v2 sheet scrim per theme (dark #000@60%, light #0C1330@36%) — not
      // a black backdrop in light.
      barrierColor: context.colors.scrim,
      // v2: an informational sheet hugs its content (no fixed 82% height and
      // no dead strip under it); the body scrolls only if it cannot fit.
      builder: (_) => navySheetTheme(const SmsPermissionScreen()),
    );
  }

  @override
  State<SmsPermissionScreen> createState() => _SmsPermissionScreenState();
}

class _SmsPermissionScreenState extends State<SmsPermissionScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v2 Inset role inside the sheet: dark well #0C0D11, light #EEF1F8.
    final well = isDark ? c.surfaceMuted : c.surfaceElevated;

    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: SafeArea(
            top: false,
            child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s3,
              AppSpacing.gutter,
              AppSpacing.s4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(child: SingleChildScrollView(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textMuted.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Align(
                  // DIRECTIONAL. `Alignment.topLeft` is absolute, so the
                  // close button sat on the left in BOTH languages — correct
                  // for Arabic by coincidence, wrong for English. Every
                  // other sheet in the app puts close at the END.
                  alignment: AlignmentDirectional.topEnd,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(AppLucideIcons.x, size: 20),
                    constraints:
                        const BoxConstraints.tightFor(width: 44, height: 44),
                    style: IconButton.styleFrom(
                      foregroundColor: c.textSecondary,
                      backgroundColor: well,
                    ),
                  ),
                ),
                const Center(
                  child: QirshIllustration(
                    name: 'capture', width: 186, height: 140,
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(
                  context.l10n.smsShareTitle,
                  textAlign: TextAlign.center,
                  style: AppTypography.titleLarge(c.textPrimary)
                      .copyWith(fontSize: 24, height: 32 / 24),
                ),
                const SizedBox(height: AppSpacing.s4),
                // v2: the instruction paragraph, split into its three steps
                // (same words), then the privacy line on its own.
                for (final (i, step) in [
                  context.l10n.smsV2Step1,
                  context.l10n.smsV2Step2,
                  context.l10n.smsV2Step3,
                ].indexed) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.s2),
                  _Step(number: i + 1, label: step),
                ],
                const SizedBox(height: AppSpacing.s3),
                Text(
                  context.l10n.smsV2PrivacyLine,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption(c.textMuted),
                ),
                const SizedBox(height: AppSpacing.s4),
                // Example — Inset well (dark #0C0D11 / light #EEF1F8), mono.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
                  decoration: BoxDecoration(
                    color: well,
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  child: Text(
                    context.l10n.smsShareExample,
                    textAlign: TextAlign.center,
                    style: AppTypography.mono(
                        size: 13, height: 1.5, color: c.textPrimary),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  context.l10n.smsShareFallback,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption(c.textMuted),
                ),
                  ],
                ))),
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: AppSpacing.buttonHeight,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      ManualPasteScreen.showSheet(context);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.cta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: Text(
                      context.l10n.smsPasteManually,
                      style: AppTypography.bodyStrong(c.onCta),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s1),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    context.l10n.smsPasteLater,
                    style: AppTypography.bodyStrong(c.actionText),
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// One numbered step: a 32pt `action.soft` disc + `subhead` label.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.label});

  final int number;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.ctaSoft, shape: BoxShape.circle),
          child: Text('$number', style: AppTypography.subhead(c.actionText)
              .copyWith(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Text(label, style: AppTypography.subhead(c.textPrimary)),
        ),
      ],
    );
  }
}
