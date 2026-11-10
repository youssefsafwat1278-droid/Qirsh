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

const _sectionStatusColor = Color(0xFF0C1525);

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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
                              colors: [
                                _sectionStatusColor,
                                const Color(0x8A040D20),
                                bottom == null
                                    ? const Color(0x22040D20)
                                    : const Color(0xD9040D20),
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
                                            Text(title,
                                                maxLines:
                                                    expandForText ? null : 2,
                                                overflow: expandForText
                                                    ? null
                                                    : TextOverflow.ellipsis,
                                                style: AppTypography.custom(
                                                  size: 25,
                                                  weight: FontWeight.w700,
                                                  height: 1.25,
                                                  letterSpacing: -.45,
                                                  color: Colors.white,
                                                )),
                                            if (subtitle?.isNotEmpty ==
                                                true) ...[
                                              const SizedBox(height: 5),
                                              Text(subtitle!,
                                                  maxLines:
                                                      expandForText ? null : 2,
                                                  overflow: expandForText
                                                      ? null
                                                      : TextOverflow.ellipsis,
                                                  style: AppTypography.custom(
                                                    size: 12.5,
                                                    weight: FontWeight.w400,
                                                    height: 1.4,
                                                    color:
                                                        const Color(0xFFE2E9F4),
                                                  )),
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
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(26)),
                    ),
                    child: const SizedBox(height: 24),
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

/// Extends the section's navy backdrop through the status-bar inset while the
/// SafeArea continues to keep pinned tabs clear of the clock after scrolling.
class QirshSectionBackdrop extends StatelessWidget {
  const QirshSectionBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return child;
    return Stack(children: [
      child,
      Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top,
          child: const AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: IgnorePointer(child: ColoredBox(color: _sectionStatusColor)),
          )),
    ]);
  }
}
