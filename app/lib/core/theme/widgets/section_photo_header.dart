import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';
import 'scroll_over_hero.dart';

/// New section-only photography. Existing QirshPhoto assets stay in place.
enum QirshSectionPhoto {
  transactions,
  bills,
  budgets,
  goals,
  plans,
  accounts,
  cards,
  reports;

  String get asset => 'assets/photos/qirsh-section-$name-v1.webp';
}

/// Full-width photographic title with the next surface overlapping its foot.
///
/// Owns decoration only. Callers keep their routes, controls and money data.
class QirshSectionHero extends StatelessWidget {
  const QirshSectionHero({
    super.key,
    required this.photo,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.bottom,
    this.child,
    this.height = 220,
    this.useSafeAreaTop = true,
    this.expandForText = true,
    this.fitTitle = false,
  });

  final QirshSectionPhoto photo;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? bottom;
  final Widget? child;
  final double height;
  final bool useSafeAreaTop;
  final bool expandForText;

  /// Keep the title on ONE line, scaled down to fit, instead of wrapping.
  final bool fitTitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final safeTop = useSafeAreaTop ? MediaQuery.paddingOf(context).top : 0.0;
    final overlay = Theme.of(context).copyWith(
      iconTheme: const IconThemeData(color: Colors.white),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Colors.white),
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            key: ValueKey('section-hero-${photo.name}'),
            children: [
              ClipRect(
                child: ScrollOverHero(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ExcludeSemantics(
                          child: Image.asset(
                            photo.asset,
                            fit: BoxFit.cover,
                            alignment: const Alignment(0, .15),
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              // v2 QPhotoHeader: dark — the photo dissolves
                              // into the black canvas (no sheet edge); light —
                              // a navy scrim behind the title over a crisp
                              // canvas sheet.
                              // Immersive: the photo runs under the status
                              // bar / Dynamic Island; only a translucent scrim
                              // keeps the white status icons legible.
                              colors: isDark
                                  ? [
                                      const Color(0x99040D20),
                                      const Color(0x8A040D20),
                                      bottom == null
                                          ? const Color(0xE6000000)
                                          : const Color(0xF2000000),
                                    ]
                                  : [
                                      const Color(0x99011341),
                                      const Color(0x8C011341),
                                      bottom == null
                                          ? const Color(0x1A011341)
                                          : const Color(0xD9011341),
                                    ],
                              stops: const [0, .56, 1],
                            ),
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: height + safeTop),
                        child: Padding(
                          padding: EdgeInsetsDirectional.fromSTEB(
                            AppSpacing.gutter,
                            safeTop + AppSpacing.s3,
                            AppSpacing.gutter,
                            38,
                          ),
                          child: Theme(
                            data: overlay,
                            child: IconTheme(
                              data: const IconThemeData(color: Colors.white),
                              child: Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (leading != null) ...[
                                        leading!,
                                        const SizedBox(width: AppSpacing.s2),
                                      ],
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (fitTitle)
                                              // One line that shrinks to fit
                                              // instead of wrapping.
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment: AlignmentDirectional
                                                    .centerStart,
                                                child: Text(title,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    textScaler: MediaQuery
                                                            .textScalerOf(
                                                                context)
                                                        .clamp(
                                                            maxScaleFactor:
                                                                1.35),
                                                    style: AppTypography
                                                        .titleLarge(
                                                            Colors.white)),
                                              )
                                            else
                                            Text(title,
                                                maxLines:
                                                    expandForText ? null : 2,
                                                overflow: expandForText
                                                    ? null
                                                    : TextOverflow.ellipsis,
                                                // v2: title.large clamps
                                                // at 1.35× Dynamic Type.
                                                textScaler: MediaQuery
                                                        .textScalerOf(context)
                                                    .clamp(
                                                        maxScaleFactor: 1.35),
                                                style: AppTypography
                                                    .titleLarge(Colors.white)),
                                            if (subtitle?.isNotEmpty ==
                                                true) ...[
                                              const SizedBox(height: 5),
                                              Text(subtitle!,
                                                  maxLines:
                                                      expandForText ? null : 2,
                                                  overflow: expandForText
                                                      ? null
                                                      : TextOverflow.ellipsis,
                                                  style: AppTypography.callout(
                                                      Colors.white.withValues(
                                                          alpha: .80))),
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
                                  if (bottom != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                          top: AppSpacing.s3),
                                      child: bottom!,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: -1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.bg,
                      borderRadius: isDark
                          ? null
                          : const BorderRadius.vertical(
                              top: Radius.circular(AppRadius.sheet)),
                      boxShadow: isDark
                          ? null
                          : const [
                              BoxShadow(
                                color: Color(0x1F0C1330),
                                blurRadius: 24,
                                offset: Offset(0, -8),
                              ),
                            ],
                    ),
                    child: SizedBox(height: isDark ? 1 : 24),
                  ),
                ),
              ),
            ],
          ),
          if (child != null) ColoredBox(color: c.bg, child: child!),
        ],
      ),
    );
  }
}

/// The status-bar region of a section screen (v2 `QNavBar` scroll edge).
///
/// While the section photo sits under the clock the band IS the photo's top
/// stop (seamless, light status icons). Once content scrolls beneath it, it
/// cross-fades into the canvas glass bar with a hairline and theme-matched
/// status icons — no opaque navy slab over a pale page. The SafeArea inside
/// [child] still keeps pinned tabs clear of the clock.
class QirshSectionBackdrop extends StatefulWidget {
  const QirshSectionBackdrop(
      {super.key, required this.child, this.glassFrom = 120});
  final Widget child;

  /// Outer scroll offset where the band starts turning to glass (it is fully
  /// glass 60px later). Short heroes pass a smaller value so their title
  /// never slides under the clock on bare photo.
  final double glassFrom;

  @override
  State<QirshSectionBackdrop> createState() => _QirshSectionBackdropState();
}

class _QirshSectionBackdropState extends State<QirshSectionBackdrop> {
  final ValueNotifier<double> _t = ValueNotifier<double>(0);

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    // The outer scrollable only (a NestedScrollView's inner lists are
    // deeper): the bar turns to glass once the hero has scrolled away.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    _t.value = ((n.metrics.pixels - widget.glassFrom) / 60).clamp(0.0, 1.0);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return widget.child;
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: top,
        child: IgnorePointer(
          child: ValueListenableBuilder<double>(
            valueListenable: _t,
            builder: (context, t, _) {
              final style = t < .5 || isDark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark;
              final glass = c.bg.withValues(alpha: .62);
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: style,
                child: ClipRect(
                  child: BackdropFilter(
                    enabled: t > 0,
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.lerp(glass.withValues(alpha: 0), glass, t),
                        border: Border(
                          bottom: BorderSide(
                            color: c.border.withValues(alpha: t),
                            width: .5,
                          ),
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
