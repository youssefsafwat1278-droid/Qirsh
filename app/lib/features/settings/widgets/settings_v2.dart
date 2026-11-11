import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/directional_chevron.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../common/app_card.dart';
import '../../common/motion.dart';

/// Calm Capital v2 building blocks shared by the «المزيد» hub, its sub-pages
/// and the secondary screens reached from it (help, privacy, data transfer,
/// message centre). Presentation only — every row takes its behaviour from the
/// caller unchanged.

/// v2 `QNavBar` + `QLargeTitle`: a 44pt bar under the status bar (back chevron
/// on pushed pages, nothing on a tab root) whose centred `title.nav` fades in
/// once the large title has scrolled away, turning into canvas glass with a
/// hairline. The large title is `title.large` at the leading edge.
class SettingsV2Page extends StatefulWidget {
  const SettingsV2Page({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.showBack = true,
    this.onBack,
    this.bottomPadding = AppSpacing.s8,
    this.onRefresh,
    this.overlay,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showBack;

  /// Defaults to popping the current route.
  final VoidCallback? onBack;
  final double bottomPadding;
  final RefreshCallback? onRefresh;

  /// Painted above the scroll view (e.g. a busy veil).
  final Widget? overlay;

  static const double barHeight = 44;

  @override
  State<SettingsV2Page> createState() => _SettingsV2PageState();
}

class _SettingsV2PageState extends State<SettingsV2Page> {
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    _offset.value = n.metrics.pixels;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final top = media.padding.top;
    final barExtent = top + SettingsV2Page.barHeight;

    Widget list = ListView(
      physics: widget.onRefresh == null
          ? null
          : const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: barExtent,
        bottom: widget.bottomPadding + media.padding.bottom,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(widget.title,
                    style: AppTypography.titleLarge(c.textPrimary)),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: AppSpacing.s1),
                Text(widget.subtitle!,
                    style: AppTypography.callout(c.textSecondary)),
              ],
            ],
          ),
        ),
        ...widget.children,
      ],
    );
    if (widget.onRefresh != null) {
      list = RefreshIndicator(
        edgeOffset: barExtent,
        onRefresh: widget.onRefresh!,
        child: list,
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: c.bg,
        body: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: list,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: barExtent,
              child: _V2NavBar(
                offset: _offset,
                title: widget.title,
                topInset: top,
                showBack: widget.showBack,
                onBack: widget.onBack,
              ),
            ),
            if (widget.overlay != null) Positioned.fill(child: widget.overlay!),
          ],
        ),
      ),
    );
  }
}

class _V2NavBar extends StatelessWidget {
  const _V2NavBar({
    required this.offset,
    required this.title,
    required this.topInset,
    required this.showBack,
    required this.onBack,
  });

  final ValueNotifier<double> offset;
  final String title;
  final double topInset;
  final bool showBack;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ValueListenableBuilder<double>(
      valueListenable: offset,
      builder: (context, px, _) {
        // Glass between 8–40pt of scroll; the nav title between 28–56pt, i.e.
        // once the large title has left.
        final glass = ((px - 8) / 32).clamp(0.0, 1.0);
        final titleT = ((px - 28) / 28).clamp(0.0, 1.0);
        final bar = IgnorePointer(
          child: ClipRect(
            child: BackdropFilter(
              enabled: glass > 0,
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.62 * glass),
                  border: Border(
                    bottom: BorderSide(
                      color: c.border.withValues(alpha: glass),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: SizedBox(
                    height: SettingsV2Page.barHeight,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (titleT > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 56),
                            child: Opacity(
                              opacity: titleT,
                              child: ExcludeSemantics(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.titleNav(c.textPrimary),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // The glass is decoration only: content scrolled beneath it stays
        // reachable, and just the back button takes taps.
        if (!showBack) return bar;
        return Stack(
          fit: StackFit.expand,
          children: [
            bar,
            Padding(
              padding: EdgeInsets.only(top: topInset),
              child: SizedBox(
                height: SettingsV2Page.barHeight,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding:
                        const EdgeInsetsDirectional.only(start: AppSpacing.s1),
                    child: IconButton(
                      tooltip: context.l10n.setBack,
                      onPressed:
                          onBack ?? () => Navigator.of(context).maybePop(),
                      icon: const BackButtonIcon(),
                      color: c.textPrimary,
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// `overline` group label above a Group card, aligned with the card's text.
class SettingsV2Label extends StatelessWidget {
  const SettingsV2Label(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.gutter + 4,
            AppSpacing.s6, AppSpacing.gutter + 4, AppSpacing.s2),
        child: Semantics(
          header: true,
          child: Text(text,
              style: AppTypography.overline(color ?? context.colors.textMuted)),
        ),
      );
}

/// v2 Group: one card (light white + e1, dark hairline) holding a run of rows
/// separated by 1px dividers inset to the text edge — never one card per row.
class SettingsV2Group extends StatelessWidget {
  const SettingsV2Group({
    super.key,
    required this.children,
    this.label,
    this.labelColor,
    this.dividerIndent = 60,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
  });

  final String? label;
  final Color? labelColor;
  final List<Widget> children;
  final double dividerIndent;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final card = Padding(
      padding: margin,
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: dividerIndent,
                  color: c.divider,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
    if (label == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [SettingsV2Label(label!, color: labelColor), card],
    );
  }
}

/// Leading 32pt icon tile. Action tone: dark white@8% / light action.soft, the
/// glyph in `action.text`. Danger tone: dangerBg + danger glyph.
class SettingsV2Tile extends StatelessWidget {
  const SettingsV2Tile({
    super.key,
    required this.icon,
    this.danger = false,
    this.color,
    this.size = 32,
  });

  final IconData icon;
  final bool danger;

  /// A semantic colour (success, warning…) — tinted @16% dark / @12% light.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (Color fill, Color glyph) = danger
        ? (c.dangerBg, c.danger)
        : color != null
            ? (color!.withValues(alpha: isDark ? 0.16 : 0.12), color!)
            : (
                isDark ? Colors.white.withValues(alpha: 0.08) : c.ctaSoft,
                c.actionText
              );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Icon(icon, size: size * 0.56, color: glyph),
    );
  }
}

/// Row press feedback per v2: a background step (card → raised), no ripple.
Color settingsV2PressedColor(BuildContext context) =>
    context.colors.surfaceElevated;

/// v2 link row: 52pt single-line (taller when it carries a subtitle), 32pt
/// tile, `body.strong` title, optional current value in `text.muted` at the
/// trailing side, chevron.
class SettingsV2Row extends StatelessWidget {
  const SettingsV2Row({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.value,
    this.valueWidget,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.danger = false,
    this.tileColor,
    this.showChevron = true,
    this.valueLtr = false,
  });

  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final String? value;
  final Widget? valueWidget;

  /// Replaces the chevron (e.g. an action glyph on rows that act).
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool danger;
  final Color? tileColor;
  final bool showChevron;
  final bool valueLtr;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final titleColor = danger ? c.danger : c.textPrimary;
    final lead = leading ??
        (icon == null
            ? null
            : SettingsV2Tile(icon: icon!, danger: danger, color: tileColor));
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashFactory: NoSplash.splashFactory,
      highlightColor: settingsV2PressedColor(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s4,
              AppSpacing.s2 + 2, AppSpacing.s3, AppSpacing.s2 + 2),
          child: Row(
            children: [
              if (lead != null) ...[
                lead,
                const SizedBox(width: AppSpacing.s3),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: AppTypography.bodyStrong(titleColor)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: AppSpacing.s2),
                Flexible(
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    textDirection: valueLtr ? TextDirection.ltr : null,
                    style: AppTypography.subhead(c.textMuted),
                  ),
                ),
              ],
              if (valueWidget != null) ...[
                const SizedBox(width: AppSpacing.s2),
                valueWidget!,
              ],
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.s2),
                trailing!,
              ] else if (showChevron && onTap != null) ...[
                const SizedBox(width: AppSpacing.s1),
                DirectionalChevron(color: c.textMuted, size: 18),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// v2 toggle row: an iOS-native 51×31 switch (`Switch.adaptive` — Cupertino on
/// Apple platforms) on `action`, `selectionClick` on change (`mediumImpact`
/// for commits such as app lock). The switch's behaviour is the caller's
/// [onChanged], unchanged.
class SettingsV2SwitchRow extends StatelessWidget {
  const SettingsV2SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.subtitle,
    this.tileColor,
    this.commitHaptic = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? tileColor;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool commitHaptic;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final changed = onChanged;
    return SwitchListTile.adaptive(
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s4, 2, AppSpacing.s3, 2),
      minVerticalPadding: AppSpacing.s2,
      secondary:
          icon == null ? null : SettingsV2Tile(icon: icon!, color: tileColor),
      value: value,
      onChanged: changed == null
          ? null
          : (v) {
              if (commitHaptic) {
                HapticFeedback.mediumImpact();
              } else {
                HapticFeedback.selectionClick();
              }
              changed(v);
            },
      activeThumbColor: c.onCta,
      activeTrackColor: c.cta,
      title: Text(title, style: AppTypography.bodyStrong(c.textPrimary)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.caption(c.textMuted)),
    );
  }
}

/// v2 Tinted card (insights, notices, banners): `*Bg` fill, plus a 1px border
/// in the matching colour @24% on the dark canvas only.
class SettingsV2Tinted extends StatelessWidget {
  const SettingsV2Tinted({
    super.key,
    required this.background,
    required this.accent,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
    this.padding = const EdgeInsets.all(AppSpacing.s4),
  });

  final Color background;
  final Color accent;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(AppRadius.card);
    return Padding(
      padding: margin,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: isDark
              ? BorderSide(color: accent.withValues(alpha: 0.24))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// v2 raised surface (profile card): dark `surface.raised` + hairline, light
/// white + e2.
BoxDecoration settingsV2RaisedDecoration(BuildContext context,
    {double radius = 24}) {
  final c = context.colors;
  final b = Theme.of(context).brightness;
  return BoxDecoration(
    color: b == Brightness.dark ? c.surfaceElevated : c.surface,
    borderRadius: BorderRadius.circular(radius),
    border: b == Brightness.dark ? Border.all(color: c.border) : null,
    boxShadow: AppShadows.raised(b),
  );
}

/// Staggered v2 enter for the first above-the-fold blocks (40ms apart, capped
/// at six), played once; Reduce Motion is honoured by [PremiumMotion].
Widget settingsV2Enter(int index, Widget child) => PremiumMotion(
      delay: Duration(milliseconds: 40 * index.clamp(0, 5)),
      child: child,
    );
