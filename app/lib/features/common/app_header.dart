import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

final _navBlur = ImageFilter.blur(sigmaX: 12, sigmaY: 12);

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.action,
    this.showBack = true,
    this.compact = false,
    this.titleMaxLines = 1,
    this.sectionPhoto,
    this.sectionHeight = 186,
  });

  final String title;
  final QirshSectionPhoto? sectionPhoto;
  final double sectionHeight;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? action;
  final bool showBack;
  final bool compact;

  /// UX-014 — how many lines the title may occupy before it ellipsises.
  ///
  /// One line is right for a fixed screen name («الحسابات والمحافظ»). It is
  /// wrong for a title that is USER DATA: an account named «الراجحي — الحساب
  /// الجاري» rendered as «الراجحي — الحساب ال…» while «مدى — البطاقة الرئيسية»
  /// happened to fit, so whether you could read your own account's name
  /// depended on how long you had made it.
  ///
  /// Opt-in rather than a global default: raising it everywhere would give
  /// every screen a two-line header for no benefit, and the bar's height has to
  /// grow with it.
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (sectionPhoto != null) {
      return QirshSectionHero(
        photo: sectionPhoto!, title: title, subtitle: subtitle,
        height: sectionHeight, expandForText: false,
        leading: leading ?? (showBack && Navigator.of(context).canPop()
            ? const BackButton(color: Colors.white) : null),
        trailing: trailing == null && action == null ? null : Row(
          mainAxisSize: MainAxisSize.min,
          children: [if (trailing != null) trailing!, if (action != null) action!],
        ),
      );
    }
    // v2 QNavBar scroll edge (immersive): clear at rest, frosted glass once
    // content scrolls beneath it. Screens that extend their body behind the
    // bar let that content pass under the status bar / Dynamic Island.
    final glass = c.bg.withValues(alpha: .62);
    return AppBar(
      backgroundColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.scrolledUnder)
              ? glass
              : c.bg.withValues(alpha: 0)),
      surfaceTintColor: Colors.transparent,
      shadowColor: c.border,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: _navBlur,
          child: const SizedBox.expand(),
        ),
      ),
      elevation: 0,
      scrolledUnderElevation: .5,
      automaticallyImplyLeading: leading == null && showBack,
      leading: leading,
      iconTheme: IconThemeData(color: c.textPrimary),
      titleSpacing: AppSpacing.s4,
      toolbarHeight: preferredSize.height,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
            // The approved HTML pushed-screen navigation title.
            style: AppTypography.custom(size: 17, weight: FontWeight.w600,
              height: 1.25, color: c.textPrimary),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // Mockup `.hsub`: 13px secondary.
              style: AppTypography.caption(c.textSecondary)
                  .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
            ),
          ],
        ],
      ),
      actions: [
        if (trailing != null) trailing!,
        if (action != null) action!,
        if (trailing != null || action != null)
          const SizedBox(width: AppSpacing.gutter),
      ],
      centerTitle: true,
    );
  }

  @override
  Size get preferredSize {
    if (sectionPhoto != null) return Size.fromHeight(sectionHeight);
    final base = subtitle == null ? 56.0 : 68.0;
    // The title style is 24px with tight leading; each extra permitted line
    // needs its own room or the AppBar clips what it just allowed to wrap.
    return Size.fromHeight(base + (titleMaxLines - 1) * 28.0);
  }
}
