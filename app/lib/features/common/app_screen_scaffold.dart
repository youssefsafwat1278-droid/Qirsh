import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import 'app_header.dart';

/// هيكل شاشة قياسي — خلفية مع أوربت مضيئة خافتة للوضع الداكن، SafeArea، وهيدر اختياري.
class AppScreenScaffold extends StatelessWidget {
  const AppScreenScaffold({
    super.key,
    required this.body,
    this.header,
    this.scrollHeader = false,
    this.padding,
    this.bottomNavPadding,
    this.bottomArea,
    this.resizeToAvoidBottomInset = true,
    this.extendBodyBehindHeader = false,
    this.safeArea = true,
    this.ambient = true,
  });

  final Widget body;

  /// Widget فوق المحتوى. يُعرَض قبل [body].
  final Widget? header;

  /// Photographic headers collapse while the content surface covers them.
  final bool scrollHeader;

  /// padding للمحتوى داخل body.
  final EdgeInsetsGeometry? padding;

  /// مسافة إضافية في الأسفل لتجنب تغطية شريط التنقل العائم.
  ///
  /// يجب تطبيق هذه المسافة داخل الـ scrollable content نفسه، وليس حول جسم
  /// الشاشة بالكامل، حتى لا يتم ضغط ارتفاع الصفحة عند وجود bottom navigation.
  final double? bottomNavPadding;

  /// مساحة ثابتة اختيارية أسفل المحتوى، مثل أزرار إجراءات الشاشة.
  final Widget? bottomArea;

  final bool resizeToAvoidBottomInset;
  final bool extendBodyBehindHeader;
  final bool safeArea;
  final bool ambient;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget content = body;

    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }

    if (scrollHeader && header != null) {
      return Scaffold(
        backgroundColor: c.bg,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: QirshSectionBackdrop(
          child: SafeArea(
            // Immersive: the section photo runs under the status bar.
            top: false,
            bottom: false,
            child: NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverToBoxAdapter(child: header!),
              ],
              body: Material(
                color: c.bg,
                child: Column(children: [
                  Expanded(child: content),
                  if (bottomArea != null) bottomArea!,
                ]),
              ),
            ),
          ),
        ),
      );
    }

    // A plain AppHeader nav bar becomes the Scaffold's app bar with the body
    // extended behind it (immersive): content scrolls beneath its glass and
    // the status bar. Such bodies add MediaQuery.paddingOf(context).top to
    // their own scroll padding.
    final h = header;
    final navBar = h is AppHeader && h.sectionPhoto == null ? h : null;
    final bodyColumn = Column(
      children: [
        if (header != null && navBar == null) header!,
        Expanded(child: content),
        if (bottomArea != null)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.gutter,
              AppSpacing.s3,
              AppSpacing.gutter,
              AppSpacing.s3,
            ),
            child: bottomArea!,
          ),
      ],
    );

    // شبكة الإضاءة المحيطية - تدعم الهوية البصرية الفاخرة للوضع الداكن
    Widget baseBackground = Container(
      color: c.bg,
    );

    if (isDark && ambient) {
      baseBackground = Stack(
        children: [
          Positioned.fill(child: Container(color: c.bg)),
          // هالة بنفسجية خفيفة في الأعلى، ثابتة ورخيصة بصريًا.
          Positioned(
            right: -100,
            top: -100,
            width: 320,
            height: 320,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.cta.withValues(alpha: 0.05),
                    c.cta.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // هالة وردية خافتة في الأسفل، بلا blur أو shader.
          Positioned(
            left: -120,
            bottom: -120,
            width: 360,
            height: 360,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.cta.withValues(alpha: 0.035),
                    c.cta.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBodyBehindAppBar: extendBodyBehindHeader || navBar != null,
      appBar: navBar,
      body: Stack(
        children: [
          Positioned.fill(child: baseBackground),
          // Bottom spacing is owned by scrollable content. In the app shell,
          // extendBody exposes the floating nav height through MediaQuery, and
          // applying it here would shrink the whole page viewport.
          _MaybeSafeArea(
            enabled: safeArea,
            top: navBar == null,
            bottom: false,
            child: bodyColumn,
          ),
        ],
      ),
    );
  }
}

class _MaybeSafeArea extends StatelessWidget {
  const _MaybeSafeArea({
    required this.enabled,
    this.top = true,
    required this.bottom,
    required this.child,
  });

  final bool enabled;
  final bool top;
  final bool bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return SafeArea(top: top, bottom: bottom, child: child);
  }
}
