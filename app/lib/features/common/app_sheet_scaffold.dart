import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/large_text.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/utils/app_lucide_icons.dart';

class AppSheetScaffold extends StatelessWidget {
  const AppSheetScaffold({
    super.key,
    this.title,
    this.subtitle,
    required this.body,
    this.bottomAction,
    this.leading,
    this.trailing,
    this.padding,
    this.scrollable = false,
    this.showDragHandle = true,
    this.showCloseButton = true,
  });

  final String? title;
  final String? subtitle;
  final Widget body;
  final Widget? bottomAction;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final bool scrollable;
  final bool showDragHandle;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    Widget content = body;
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }

    if (scrollable) {
      content = SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: content,
      );
    }

    // MaliGlass sheet material: near-opaque body over a bounded backdrop
    // blur, with the translucent band + specular sheen at the top edge.
    return MaliGlass(
      variant: MaliGlassVariant.sheet,
      nativeMaterial: true,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: viewInsets.bottom > 0
                ? viewInsets.bottom + AppSpacing.s4
                : MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDragHandle) ...[
                const SizedBox(height: AppSpacing.s3),
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textMuted.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.s4),
              if (title != null || leading != null || trailing != null)
                Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.gutter,
                  ),
                  // Mockup `.sheet-h`: centered title (19px w600), optional
                  // action floated to a side.
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // UX-05: the Stack takes this child's height and clips
                      // the side buttons to it; a one-line title (~23 pt)
                      // cut the close / action buttons below 44 pt.
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (title != null)
                                  Text(
                                    title!,
                                    textAlign: TextAlign.center,
                                    maxLines: linesUnlessLargeText(context, 2),
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        AppTypography.calmTitle(c.textPrimary)
                                            .copyWith(fontSize: 19),
                                  ),
                                if (subtitle != null) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    subtitle!,
                                    textAlign: TextAlign.center,
                                    maxLines: linesUnlessLargeText(context, 2),
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        AppTypography.caption(c.textSecondary)
                                            .copyWith(fontSize: 12.5),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (leading != null)
                        PositionedDirectional(
                          start: 0,
                          top: 0,
                          bottom: 0,
                          child: Center(child: leading!),
                        ),
                      if (trailing != null)
                        PositionedDirectional(
                          end: 0,
                          top: 0,
                          bottom: 0,
                          child: Center(child: trailing!),
                        )
                      else if (showCloseButton)
                        PositionedDirectional(
                          end: 0,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              tooltip: MaterialLocalizations.of(context)
                                  .closeButtonTooltip,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(AppLucideIcons.x),
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (title != null || leading != null || trailing != null)
                const SizedBox(height: AppSpacing.s4),
              Flexible(child: content),
              if (bottomAction != null) ...[
                const SizedBox(height: AppSpacing.s4),
                Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.gutter,
                  ),
                  child: bottomAction!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
