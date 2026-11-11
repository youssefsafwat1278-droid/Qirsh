import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../cards/brand_mark.dart';
import 'app_avatar.dart';
import '../../core/utils/l10n_ext.dart';

/// صف معاملة قياسي — UI فقط، لا يستورد طبقة البيانات.
///
/// يدعم بادج "معلق"، بادج "ذكاء اصطناعي"، وضع الخصوصية، RTL، والوصول.
/// الحد الأدنى لمنطقة النقر 44px وفق إرشادات iOS/Material.
///
/// لا يُلغي [TransactionRow] الموجود — مكوّن جديد للاستخدام في الشاشات
/// القادمة (المراحل 4-9).
class AppTransactionRow extends StatelessWidget {
  const AppTransactionRow({
    super.key,
    required this.title,
    required this.amount,
    required this.currency,
    this.amountMoney,
    this.subtitle,
    this.categoryIcon,
    this.categoryIconName,
    this.categoryColor,
    this.brandLogoUrl,
    this.isPending = false,
    this.awaitingPrice = false,
    this.isAi = false,
    this.confidencePercent,
    this.isConfirmed = true,
    this.onTap,
    this.trailing,
    this.privacyMode = false,
    this.isDebit = true,
    this.semanticsLabel,
    this.horizontalPadding = AppSpacing.gutter,
  });

  final String title;
  final double amount;
  final String currency;

  /// Canonical precision for ledger callers; [currency] may be a translated
  /// display label, so it cannot determine the currency's decimal scale.
  final Money? amountMoney;
  final String? subtitle;
  final IconData? categoryIcon;
  final String? categoryIconName;
  final Color? categoryColor;

  /// Admin-managed brand logo URL (resolved by the caller). When set, shows the
  /// brand logo instead of the category icon.
  final String? brandLogoUrl;
  final bool isPending;

  /// Confirmed row whose home-currency value has not been entered yet.
  final bool awaitingPrice;
  final bool isAi;
  final int? confidencePercent;
  final bool isConfirmed;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool privacyMode;
  final bool isDebit;
  final String? semanticsLabel;

  /// Horizontal inset. Full [AppSpacing.gutter] on a bare list; smaller when
  /// the row sits inside a day card.
  final double horizontalPadding;

  Widget _categoryTile() => categoryIcon != null
      ? AppAvatar.icon(icon: categoryIcon!, color: categoryColor)
      : AppAvatar.category(iconName: categoryIconName, color: categoryColor);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final canonical = amountMoney;
    final magnitude = canonical == null
        ? Formatters.amount(amount.abs())
        : formatMoney(canonical.isNegative ? -canonical : canonical);
    final isZero = canonical?.isZero ?? amount == 0;
    final formattedAmount = privacyMode ? '••••' : '$magnitude $currency';
    // Calm Capital ledger: expense stays neutral (primary text), income green.
    final amountColor = isDebit ? c.textPrimary : c.success;
    final amountPrefix = isZero ? '' : isDebit ? '−' : '+';

    // The screen-reader label. It was Arabic in every locale, which is worse
    // than a visible untranslated string: a blind English user hears the row
    // read out in a language they may not speak, and nothing on screen shows
    // it is wrong. The separator follows the locale too — Arabic uses «،».
    final l = context.l10n;
    final sep = Directionality.of(context) == TextDirection.rtl ? '، ' : ', ';
    final semantics = semanticsLabel ??
        '$title$sep${isDebit ? l.a11yDebit : l.a11yCredit} $formattedAmount'
            '${isPending ? '$sep${l.a11yPending}' : ''}'
            '${awaitingPrice ? '$sep${l.txnAwaitingPrice}' : ''}'
            '${isAi ? '$sep${l.a11yAi}' : ''}';

    return Semantics(
      label: semantics,
      button: onTap != null,
      child: _RowPress(
        onTap: onTap,
        child: ConstrainedBox(
          // v2 QRow: 64pt two-line row.
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: AppSpacing.s3,
            ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    (brandLogoUrl != null || BrandMark.hasBrand(title))
                        ? AppAvatar.brand(
                            name: title,
                            logoUrl: brandLogoUrl,
                            fallback: _categoryTile())
                        : _categoryTile(),
                    // v2: a 6pt warning dot on the tile corner marks a row
                    // that still needs review.
                    if (isPending)
                      PositionedDirectional(
                        top: -2,
                        end: -2,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c.warning,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: AppTypography.bodyStrong(c.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // v3: a small sparkle after the title replaces
                          // the «ذكي» pill; the word stays in semantics.
                          if (isAi)
                            Padding(
                              padding:
                                  const EdgeInsetsDirectional.only(start: 4),
                              child: Icon(
                                AppLucideIcons.sparkles,
                                size: 12,
                                color: c.actionText,
                                semanticLabel: context.l10n.commonSmart,
                              ),
                            ),
                        ],
                      ),
                      // v2 QRow meta line: category · time, then the review
                      // chip (moved off the title line).
                      if (subtitle != null || isPending || awaitingPrice) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (subtitle != null)
                              Flexible(
                                child: Text(
                                  subtitle!,
                                  style: AppTypography.caption(c.textMuted),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (isPending)
                              _RowBadge(
                                  label: context.l10n.commonUnderReview,
                                  color: c.warningText,
                                  background: c.warningBg),
                            if (awaitingPrice)
                              _RowBadge(
                                  label: context.l10n.txnAwaitingPrice,
                                  color: c.warningText,
                                  background: c.warningBg),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                trailing ??
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .4,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: _RowAmount(
                          text: privacyMode ? '••••' : '$amountPrefix$magnitude',
                          style: AppTypography.amountSmall(
                            privacyMode ? c.textMuted : amountColor,
                          ),
                          fractionColor:
                              privacyMode ? c.textMuted : c.textSecondary,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact tinted pill for a ledger row (قيد المراجعة / بانتظار السعر) — matches the
/// Calm Capital mockup: colored text on a soft same-color tint.
class _RowBadge extends StatelessWidget {
  const _RowBadge({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Container(
        // v2 QStatusChip (compact): tinted bg + matching text, pill.
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(label, style: AppTypography.overline(color)),
      ),
    );
  }
}

/// v2 MoneyText inside a row: sign leads, decimals at 62% and dimmed.
class _RowAmount extends StatelessWidget {
  const _RowAmount({
    required this.text,
    required this.style,
    required this.fractionColor,
  });

  final String text;
  final TextStyle style;
  final Color fractionColor;

  @override
  Widget build(BuildContext context) {
    final dot = text.lastIndexOf('.');
    if (dot < 0) {
      return Text(text, textDirection: TextDirection.ltr, style: style);
    }
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, dot), style: style),
        TextSpan(
          text: text.substring(dot),
          style: style.copyWith(
            fontSize: (style.fontSize ?? 17) * .62,
            color: fractionColor,
          ),
        ),
      ]),
      textDirection: TextDirection.ltr,
    );
  }
}

/// v2 m.press for rows: highlight fill (card → raised) + 0.985 scale.
class _RowPress extends StatefulWidget {
  const _RowPress({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_RowPress> createState() => _RowPressState();
}

class _RowPressState extends State<_RowPress> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _down ? AppMotion.pressScaleRow : 1,
        duration: _down ? AppMotion.press : AppMotion.base,
        curve: _down ? Curves.easeOut : AppMotion.springSnappyCurve,
        child: AnimatedContainer(
          duration: AppMotion.micro,
          color: _down ? c.surfaceElevated : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
