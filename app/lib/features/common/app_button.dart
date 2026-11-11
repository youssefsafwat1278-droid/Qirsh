import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// الزر الرئيسي — سطح ink (أسود في الفاتح، ينقلب أبيض في الداكن): للفعل
/// الأساسي الواحد في الشاشة. الأزرق [AppColors.cta] محفوظ للأكسنت
/// (حلقات/روابط/اختيار) فلا يُحرق على كل زر.
class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = AppSpacing.buttonHeight,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: c.ink,
      foregroundColor: c.onInk,
      disabledBg: c.disabled,
      // v2: disabled label is text.muted (legible), fill disabled.fill.
      disabledFg: c.textMuted,
      side: null,
      gradient: null,
      // v2 QButton primary: light carries 0 6 16 action@28%; dark none.
      shadow: Theme.of(context).brightness == Brightness.dark
          ? null
          : AppShadows.actionLift,
    );
  }
}

/// زر ثانوي — حد بلون CTA، خلفية شفافة وميكرو-تفاعل.
class AppSecondaryButton extends StatelessWidget {
  const AppSecondaryButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = AppSpacing.buttonHeight,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      // v2 QButton tinted: action.soft fill + action.text label.
      backgroundColor: c.ctaSoft,
      foregroundColor: c.actionText,
      disabledBg: c.disabled,
      disabledFg: c.textMuted,
      side: null,
      gradient: null,
      shadow: null,
    );
  }
}

/// زر شبحي — نص فقط، بدون حد ولا خلفية مع ميكرو-تفاعل.
class AppGhostButton extends StatelessWidget {
  const AppGhostButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = AppSpacing.buttonHeight,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: Colors.transparent,
      foregroundColor: c.actionText,
      disabledBg: Colors.transparent,
      disabledFg: c.textFaint,
      side: null,
      gradient: null,
      shadow: null,
    );
  }
}

/// زر خطر — للإجراءات المدمرة أو الأخطاء القابلة للتصحيح.
class AppDangerButton extends StatelessWidget {
  const AppDangerButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = AppSpacing.buttonHeight,
    this.semanticsLabel,
    this.filled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: filled ? c.danger : Colors.transparent,
      foregroundColor: filled ? c.onDanger : c.danger,
      disabledBg: filled ? c.disabled : Colors.transparent,
      disabledFg: c.disabledFg,
      side: filled
          ? null
          : BorderSide(
              color: disabled ? c.border : c.danger,
              width: 1.5,
            ),
      gradient: null,
      shadow: null,
    );
  }
}

// ── Private shared implementation ─────────────────────────────────────────────

class _AppButtonBase extends StatefulWidget {
  const _AppButtonBase({
    required this.label,
    required this.onTap,
    required this.icon,
    required this.loading,
    required this.disabled,
    required this.height,
    required this.semanticsLabel,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.disabledBg,
    required this.disabledFg,
    required this.side,
    required this.gradient,
    required this.shadow,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color disabledBg;
  final Color disabledFg;
  final BorderSide? side;
  final Gradient? gradient;
  final List<BoxShadow>? shadow;

  @override
  State<_AppButtonBase> createState() => _AppButtonBaseState();
}

class _AppButtonBaseState extends State<_AppButtonBase> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled =
        !widget.disabled && !widget.loading && widget.onTap != null;
    final borderRadius = BorderRadius.circular(AppRadius.button);

    return Semantics(
      label: widget.semanticsLabel ?? widget.label,
      button: true,
      enabled: isEnabled,
      child: GestureDetector(
        onTapDown: isEnabled ? (_) => setState(() => _isPressed = true) : null,
        onTapUp: isEnabled ? (_) => setState(() => _isPressed = false) : null,
        onTapCancel:
            isEnabled ? () => setState(() => _isPressed = false) : null,
        child: AnimatedScale(
          scale: _isPressed ? AppMotion.pressScaleButton : 1.0,
          duration: _isPressed ? AppMotion.press : AppMotion.base,
          curve: _isPressed
              ? AppMotion.buttonCurve
              : AppMotion.springSnappyCurve,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: isEnabled ? widget.gradient : null,
              borderRadius: borderRadius,
              boxShadow: isEnabled ? widget.shadow : null,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.height),
              child: ElevatedButton(
                onPressed: isEnabled ? widget.onTap : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.gradient == null
                      ? widget.backgroundColor
                      : Colors.transparent,
                  foregroundColor: widget.foregroundColor,
                  disabledBackgroundColor: widget.disabledBg,
                  disabledForegroundColor: widget.disabledFg,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  minimumSize: Size(0, widget.height),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                  shape: RoundedRectangleBorder(
                    borderRadius: borderRadius,
                    side: widget.side ?? BorderSide.none,
                  ),
                ),
                child: widget.loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.foregroundColor,
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 18),
                            const SizedBox(width: AppSpacing.s2),
                          ],
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              widget.label,
                              textAlign: TextAlign.center,
                              style: AppTypography.bodyStrong(
                                      widget.foregroundColor)
                                  .copyWith(fontWeight: FontWeight.w600),
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
  }
}

// Backwards compatibility wrapper
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.isPrimary = false,
    this.isDanger = false,
    this.loading = false,
    this.disabled = false,
    this.height = AppSpacing.buttonHeight,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isDanger;
  final bool loading;
  final bool disabled;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (isDanger) {
      return AppDangerButton(
        label: label,
        onTap: onPressed,
        height: height,
        icon: icon,
        loading: loading,
        disabled: disabled,
      );
    }
    if (isPrimary) {
      return AppPrimaryButton(
        label: label,
        onTap: onPressed,
        height: height,
        icon: icon,
        loading: loading,
        disabled: disabled,
      );
    } else {
      return AppSecondaryButton(
        label: label,
        onTap: onPressed,
        height: height,
        icon: icon,
        loading: loading,
        disabled: disabled,
      );
    }
  }
}
