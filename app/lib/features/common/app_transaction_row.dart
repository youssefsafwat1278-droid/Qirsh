import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
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
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: AppSpacing.s2,
            ),
            child: Row(
              children: [
                (brandLogoUrl != null || BrandMark.hasBrand(title))
                    ? AppAvatar.brand(
                        name: title,
                        logoUrl: brandLogoUrl,
                        fallback: _categoryTile())
                    : _categoryTile(),
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
                          if (isPending)
                            _RowBadge(label: context.l10n.commonUnderReview, color: c.warning),
                          if (awaitingPrice)
                            _RowBadge(label: context.l10n.txnAwaitingPrice, color: c.warning),
                          if (isAi) _RowBadge(label: context.l10n.commonSmart, color: c.cta),
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: AppTypography.caption(c.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                        child: Text(
                          privacyMode ? '••••' : '$amountPrefix$magnitude',
                          textDirection: TextDirection.ltr,
                          style: AppTypography.bodyStrong(
                            privacyMode ? c.textMuted : amountColor,
                          ),
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

/// Compact tinted pill for a ledger row (قيد المراجعة / ذكاء) — matches the
/// Calm Capital mockup: colored text on a soft same-color tint.
class _RowBadge extends StatelessWidget {
  const _RowBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style:
              AppTypography.micro(color).copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
