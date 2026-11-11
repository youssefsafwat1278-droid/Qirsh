import 'package:flutter/material.dart';

import 'qirsh_visuals.dart';
import 'section_photo_header.dart';
export 'section_photo_header.dart' show QirshSectionPhoto, QirshSectionBackdrop;

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_shadows.dart';
import '../app_typography.dart';

/// One cell in a [CalmPageHeader] metric strip.
class CalmMetric {
  const CalmMetric({required this.label, required this.value});
  final String label;
  final String value;
}

/// CalmPageHeader — the shared top-of-page pattern for the whole app
/// (docs/MALI_DESIGN_SYSTEM.md). Every screen uses this one widget — edit it
/// here and every page updates.
///
/// Follows the approved redesign prototype (design-preview/qirsh-redesign):
/// a large title on the calm canvas, then — when the page has a statement
/// amount — one soft brand "feature hero" card with the amount (and optional
/// art), then the metrics as a row of white KPI tiles. Only Home keeps the
/// full-bleed melting blue (dashboard_screen.dart); every other page reads as
/// a quiet iOS large-title page.
///
/// [child] is rendered inside a navy card, so callers that built white-on-blue
/// content for the old band keep working unchanged.
class CalmPageHeader extends StatelessWidget {
  const CalmPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.amount,
    this.amountLabel,
    this.amountFootnote,
    this.currency,
    this.metrics,
    this.art,
    this.photo,
    this.sectionPhoto,
    this.sectionHeight = 220,
    this.inkAmount = false,
    this.coverBottom,
    this.showTitle = true,
    this.child,
    this.topInset = AppSpacing.headerTopInset,
    this.useSafeAreaTop = true,
    this.meltOverflow = _defaultMeltOverflow,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Big statement amount (e.g. the period total), shown in the feature hero.
  final String? amount;

  /// The hero's caption above [amount]. Falls back to [subtitle] (most callers
  /// pass the amount's label as their subtitle), in which case the subtitle is
  /// not repeated under the title.
  final String? amountLabel;
  final String? amountFootnote;

  /// Smaller, secondary currency next to [amount].
  final String? currency;

  final List<CalmMetric>? metrics;

  /// Optional illustration on the feature hero's trailing side.
  final Widget? art;

  /// Original photographic artwork from the approved HTML feature hero.
  final QirshPhoto? photo;

  final QirshSectionPhoto? sectionPhoto;
  final double sectionHeight;
  final bool inkAmount;
  final Widget? coverBottom;
  final bool showTitle;

  /// Optional extra content, rendered on a navy card under the hero (e.g. the
  /// settings profile row) — white-on-navy, as it was on the old blue band.
  final Widget? child;

  /// Fallback top padding when [useSafeAreaTop] is false (e.g. the header is
  /// embedded, not at the screen top).
  final double topInset;

  /// When true (screens that extend under the status bar) the top padding is
  /// the real device safe-area inset + a small gap, so the title always clears
  /// the notch / Dynamic Island.
  final bool useSafeAreaTop;

  /// Kept for API compatibility with the melting-band header. The canvas
  /// header paints nothing below itself, so the value no longer matters.
  final double meltOverflow;

  static const double _defaultMeltOverflow = 220;

  /// The colour at the header's bottom edge. With the canvas header this is
  /// the page background, so [MeltTail]/[MeltSlice] paint nothing visible.
  static Color meltEdgeColor(bool isDark) =>
      isDark ? AppColors.dark.bg : AppColors.light.bg;

  /// Length of the (now flat) melt under the header, in pixels.
  static const double meltLength = 220;

  /// The melt colour [px] below the header's edge — the canvas, everywhere.
  static Color meltColorAt(BuildContext context, double px) =>
      context.colors.bg;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compactTitle = leading is BackButton;
    final topPad = !showTitle || sectionPhoto != null ? 0.0 : useSafeAreaTop
        ? MediaQuery.paddingOf(context).top + AppSpacing.s2
        : topInset;
    final heroLabel = amountLabel ?? subtitle;
    final showSubtitle = !compactTitle && subtitle != null &&
        subtitle!.isNotEmpty &&
        !(amount != null && amountLabel == null);
    final content = Padding(
      padding: EdgeInsets.only(top: topPad, bottom: AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle && sectionPhoto == null) Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: IconTheme(
              data: IconThemeData(color: c.textPrimary),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: AppSpacing.s2),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // v2 QLargeTitle: title.large (Alexandria 700 30/38).
                        Text(
                          title,
                          textScaler: MediaQuery.textScalerOf(context)
                              .clamp(maxScaleFactor: 1.35),
                          style: compactTitle
                              ? AppTypography.titleNav(c.textPrimary)
                                  .copyWith(fontSize: 20, height: 1.3)
                              : AppTypography.titleLarge(c.textPrimary),
                        ),
                        if (showSubtitle) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.callout(c.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: AppSpacing.s2),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
          if (amount != null) ...[
            const SizedBox(height: 14),
            if (photo != null)
              QirshPhotoCard(
                photo: photo!,
                height: 150,
                child: _PhotoHeroCopy(label: heroLabel, amount: amount!, currency: currency,
                  footnote: amountFootnote),
              )
            else _FeatureHero(
              label: heroLabel,
              amount: amount!,
              currency: currency,
              art: art,
              ink: sectionPhoto != null || inkAmount,
              footnote: amountFootnote,
            ),
          ],
          if (metrics != null && metrics!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            CalmKpiTiles(metrics: metrics!),
          ],
          if (child != null) ...[
            const SizedBox(height: AppSpacing.s3),
            _NavyCard(child: child!),
          ],
        ],
      ),
    );
    if (sectionPhoto != null) {
      return QirshSectionHero(
        photo: sectionPhoto!, title: title,
        subtitle: showSubtitle ? subtitle : null,
        leading: leading, trailing: trailing, bottom: coverBottom,
        height: sectionHeight, useSafeAreaTop: useSafeAreaTop,
        child: content,
      );
    }
    return content;
  }
}

/// The prototype's `.feature-hero`: a soft brand card holding one figure.
class _FeatureHero extends StatelessWidget {
  const _FeatureHero({
    required this.label,
    required this.amount,
    required this.currency,
    required this.art,
    this.footnote,
    this.ink = false,
  });

  final String? label;
  final String amount;
  final String? currency;
  final Widget? art;
  final String? footnote;
  final bool ink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onInk = ink ? Colors.white : c.textPrimary;
    final mutedInk = ink ? const Color(0xFFC6D3E5) : c.textMuted;
    // v2 Soft hero: dark #181A20 + 10% hairline; light white + e2.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      constraints: const BoxConstraints(minHeight: 96),
      padding: EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s5, AppSpacing.s4, art == null ? AppSpacing.s5 : 6, AppSpacing.s4),
      decoration: BoxDecoration(
        color: ink ? const Color(0xFF10223C)
            : isDark ? c.surfaceElevated : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: ink || !isDark
            ? null
            : Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: ink || isDark ? null : AppShadows.e2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null && label!.isNotEmpty)
                  Text(
                    label!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.custom(
                        size: 12.5,
                        weight: FontWeight.w400,
                        height: 1.3,
                        color: mutedInk),
                  ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        amount,
                        style: AppTypography.custom(
                          size: 30,
                          weight: FontWeight.w700,
                          height: 1.1,
                          letterSpacing: -0.6,
                          tabular: true,
                          color: onInk,
                        ),
                      ),
                      if (currency != null && currency!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          currency!,
                          style: AppTypography.custom(
                              size: 14,
                              weight: FontWeight.w500,
                              height: 1.2,
                              color: mutedInk),
                        ),
                      ],
                    ],
                  ),
                ),
                if (footnote != null) ...[
                  const SizedBox(height: 6),
                  Text(footnote!, style: AppTypography.caption(ink ? mutedInk : c.textSecondary)),
                ],
              ],
            ),
          ),
          if (art != null) SizedBox(width: 128, height: 96, child: art),
        ],
      ),
    );
  }
}

class _PhotoHeroCopy extends StatelessWidget {
  const _PhotoHeroCopy({required this.label, required this.amount, this.currency, this.footnote});
  final String? label;
  final String amount;
  final String? currency;
  final String? footnote;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      if (label != null) Text(label!, textAlign: TextAlign.right,
        style: AppTypography.custom(size: 12.5, weight: FontWeight.w400,
          height: 1.35, color: Colors.white.withValues(alpha: .76))),
      const SizedBox(height: 6),
      Text.rich(TextSpan(children: [
        TextSpan(text: amount, style: AppTypography.custom(size: 24,
          weight: FontWeight.w700, height: 1.2, color: Colors.white, tabular: true)),
        if (currency != null) TextSpan(text: ' $currency',
          style: AppTypography.custom(size: 13, weight: FontWeight.w400,
            height: 1.2, color: Colors.white.withValues(alpha: .76))),
      ]), textAlign: TextAlign.right),
      if (footnote != null) ...[
        const SizedBox(height: 6),
        Text(footnote!, textAlign: TextAlign.right,
          style: AppTypography.custom(size: 11, weight: FontWeight.w400,
            height: 1.35, color: Colors.white.withValues(alpha: .76))),
      ],
    ],
  );
}

/// The prototype's `.kpis`: equal white tiles, label above value.
class CalmKpiTiles extends StatelessWidget {
  const CalmKpiTiles({super.key, required this.metrics,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.s4)});
  final EdgeInsetsGeometry margin;
  final List<CalmMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Three per row reads as a grid; four becomes 2 + 2 rather than 3 + 1.
    final perRow = metrics.length <= 3 ? metrics.length : (metrics.length + 1) ~/ 2;
    final valueStyle = AppTypography.custom(
        size: 17, weight: FontWeight.w700, height: 1.25,
        tabular: true, color: c.textPrimary);
    Widget tile(CalmMetric m, {bool wrapValue = false}) => Container(
          padding: const EdgeInsets.all(AppSpacing.s3),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: isDark ? Border.all(color: c.border) : null,
            boxShadow: isDark ? null : AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                m.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.custom(
                    size: 11.5,
                    weight: FontWeight.w400,
                    height: 1.3,
                    color: c.textMuted),
              ),
              const SizedBox(height: 3),
              if (wrapValue)
                Text(m.value, style: valueStyle)
              else FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  m.value,
                  maxLines: 1,
                  style: valueStyle,
                ),
              ),
            ],
          ),
        );
    return Padding(
      padding: margin,
      child: LayoutBuilder(builder: (context, constraints) {
        // A complete value that only fits at a tiny scale is not readable.
        // Measure the same style/scaler as the rendered text; keep the normal
        // grid unless a value would fall below 80% of its natural text size.
        const minimumScale = .8;
        final tileInsets = AppSpacing.s3 * 2 + (isDark ? 2 : 0);
        final widths = <CalmMetric, double>{};
        for (final metric in metrics) {
          final painter = TextPainter(
            text: TextSpan(text: metric.value, style: valueStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
          )..layout();
          widths[metric] = painter.width;
          painter.dispose();
        }
        final ordinaryContentWidth =
            (constraints.maxWidth - (perRow - 1) * AppSpacing.s2) / perRow -
                tileInsets;
        bool needsFullRow(CalmMetric metric) =>
            widths[metric]! * minimumScale > ordinaryContentWidth;
        final adaptive = metrics.any(needsFullRow);
        final groups = <List<CalmMetric>>[];
        var pending = <CalmMetric>[];
        for (final metric in metrics) {
          if (adaptive && needsFullRow(metric)) {
            if (pending.isNotEmpty) groups.add(pending);
            pending = [];
            groups.add([metric]);
          } else {
            pending.add(metric);
            if (pending.length == perRow) {
              groups.add(pending);
              pending = [];
            }
          }
        }
        if (pending.isNotEmpty) groups.add(pending);
        final rows = <Widget>[];
        for (final row in groups) {
          final columns = adaptive ? row.length : perRow;
          final contentWidth =
              (constraints.maxWidth - (columns - 1) * AppSpacing.s2) / columns -
                  tileInsets;
          // Labels may wrap to two lines; each row keeps its tiles one height.
          rows.add(IntrinsicHeight(child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) const SizedBox(width: AppSpacing.s2),
                Expanded(child: j < row.length
                    ? tile(row[j], wrapValue:
                        widths[row[j]]! * minimumScale > contentWidth)
                    : const SizedBox()),
              ],
            ],
          )));
        }
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: AppSpacing.s2),
              rows[r],
            ],
          ],
        );
      }),
    );
  }
}

/// White-on-navy card for [CalmPageHeader.child].
class _NavyCard extends StatelessWidget {
  const _NavyCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0B1A33) : const Color(0xFF0A2540),
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      child: IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: child,
        ),
      ),
    );
  }
}

/// A round header action that reads on the canvas — the prototype's
/// `.icon-btn` (surface) and `.icon-btn.primary` (brand blue, white glyph).
class CalmHeaderAction extends StatelessWidget {
  const CalmHeaderAction({
    super.key,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = primary ? AppBrandBlue.mid : c.surface;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: bg,
        shape: CircleBorder(
            side: !primary && isDark
                ? BorderSide(color: c.border)
                : BorderSide.none),
        elevation: 0,
        shadowColor: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: isDark
                  ? null
                  : primary
                      ? const [
                          BoxShadow(
                              color: Color(0x9E1653F3),
                              blurRadius: 16,
                              spreadRadius: -6,
                              offset: Offset(0, 6)),
                        ]
                      : AppShadows.card,
            ),
            child: Icon(icon,
                size: 20, color: primary ? Colors.white : c.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// MeltTail — خلفية ذوبان **مش بتاخد أي مساحة**: بتلفّ محتوى الصفحة وبترسم
/// تدرّج من حافة الهيدر الزرقا لخلفية الكانفاس ورا أول [height] بكسل من
/// المحتوى، فالكروت بتقعد على اللون بدل ما يقعد لوحده في فراغ.
///
/// بتتلفّ حوالين الـ scrollable اللي جاي بعد [CalmPageHeader] وهي
/// `meltOverflow: 0` (صفحات NestedScrollView/CustomScrollView) — لأن الشرائح
/// بترسم أول شريحة فوق اللي بعدها، فامتداد الهيدر نفسه كان هيغطّي المحتوى.
class MeltTail extends StatelessWidget {
  const MeltTail({super.key, required this.child, this.startAt = 0});

  final Widget child;

  /// كام بكسل من الذوبان اتغطّى فوق الودجت دي (زي شريط تبويبات مثبّت بين
  /// الهيدر والمحتوى) — الباقي بيتكمّل من نفس اللون بالظبط.
  final double startAt;

  @override
  Widget build(BuildContext context) {
    final remaining = CalmPageHeader.meltLength - startAt;
    if (remaining <= 0) return child;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: remaining,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 1.0],
                  colors: [
                    CalmPageHeader.meltColorAt(context, startAt),
                    context.colors.bg,
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// شريحة من الذوبان بتتحط ورا ودجت مثبّتة بين الهيدر والمحتوى (زي شريط
/// التبويبات) — التدرّج بيكمّل من وراها بدل ما تبان خلفية الصفحة كلحام تحت
/// حافة الهيدر مباشرة. الـ [MeltTail] اللي بعدها لازم يبقى `startAt: height`.
class MeltSlice extends StatelessWidget {
  const MeltSlice({
    super.key,
    required this.height,
    required this.child,
    this.startAt = 0,
  });

  final double height;

  /// How far below the header's edge this slice begins.
  ///
  /// Zero — the default, and what every existing caller gets — is the slice
  /// sitting directly under the header, which is where the pinned tab bars
  /// are. A slice placed BELOW another one has to start where that one ended,
  /// or the gradient jumps back toward the header colour at the seam.
  ///
  /// Added for the ad section on Reports and Subscriptions, which sits between
  /// the header card and the tab bar and so pushes the tab bar further down the
  /// melt.
  final double startAt;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            CalmPageHeader.meltColorAt(context, startAt),
            CalmPageHeader.meltColorAt(context, startAt + height),
          ],
        ),
      ),
      child: child,
    );
  }
}

/// Keeps scrolled content out from under the status bar on a screen whose
/// [CalmPageHeader] scrolls away with no pinned bar to cover it (Settings,
/// Goals, Achievements). It is the canvas colour, so it is invisible at rest
/// and only shows once content passes beneath it — iOS's scroll-edge bar.
class StatusBarScrim extends StatelessWidget {
  const StatusBarScrim({super.key, required this.child});

  final Widget child;

  static const double _fade = 10;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bg = context.colors.bg;
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top + _fade,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg, bg, bg.withValues(alpha: 0)],
                  stops: [0, top / (top + _fade), 1],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}


/// A neutral statement card for an amount and its supporting metrics.
class CalmFinancialSummary extends StatelessWidget {
  const CalmFinancialSummary({
    super.key,
    required this.label,
    required this.amount,
    this.currency,
    this.footnote,
    this.metrics = const [],
  });

  final String label;
  final String amount;
  final String? currency;
  final String? footnote;
  final List<CalmMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v2 Soft hero (summary cards on 08 / 13 / 15): dark #181A20 + 10%
    // hairline; light white + e2.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 0),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: isDark ? c.surfaceElevated : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: isDark ? Border.all(color: const Color(0x1AFFFFFF)) : null,
          boxShadow: isDark ? null : AppShadows.e2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTypography.subhead(c.textSecondary)),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(amount, style: AppTypography.amountLarge(c.textMain)),
                if (currency != null)
                  Text(currency!, style: AppTypography.caption(c.textMuted)),
              ],
            ),
            if (footnote != null) ...[
              const SizedBox(height: AppSpacing.s2),
              Text(footnote!, style: AppTypography.caption(c.textSecondary)),
            ],
            if (metrics.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s3),
              Divider(height: 1, color: c.border),
              const SizedBox(height: AppSpacing.s3),
              LayoutBuilder(builder: (context, constraints) {
                final perRow = constraints.maxWidth < 270 ||
                        MediaQuery.textScalerOf(context).scale(14) > 20
                    ? 2
                    : 3;
                final width =
                    (constraints.maxWidth - (perRow - 1) * AppSpacing.s2) /
                        perRow;
                return Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s3,
                  children: [
                    for (final metric in metrics)
                      SizedBox(
                        width: width,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(metric.value,
                                style: AppTypography.amountSmall(c.textMain)),
                            Text(metric.label,
                                style: AppTypography.caption(c.textMuted)),
                          ],
                        ),
                      ),
                  ],
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
