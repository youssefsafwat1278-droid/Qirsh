import 'dart:ui' show FontFeature;

import 'package:flutter/widgets.dart';

import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';

/// **R-8 / UX-001 — the one way to put money on screen.**
///
/// Every user-checkable amount renders at its currency's FULL scale, so no two
/// figures on a screen can contradict each other. UX-001 was exactly that: a
/// budget card rounded spend and remaining independently and then printed
/// `356 + 845 = 1,201` against a limit of `1,200` on the same card.
///
/// ## Why full precision does not cost the density pass
///
/// The owner asked for a more compact UI in the same brief. The fraction is
/// rendered at ~70% size and reduced opacity, so `355.50` costs roughly two
/// small characters more than `356` while remaining exact and checkable against
/// the bank SMS the value came from. Density is taken out of chrome — padding,
/// label sizes, bar thickness — not out of the user's money.
///
/// ## Two correctness properties this widget owns
///
/// **Bidi isolation.** An amount is an LTR run inside RTL Arabic text. Without
/// isolation the bidi algorithm reorders it against neighbouring text — a
/// leading minus can paint on the wrong end, turning `-355.50` into something
/// that reads as positive. The amount is emitted inside FSI…PDI so it is
/// atomic regardless of what sits beside it.
///
/// **Digits are ASCII, always** — see `money_format.dart`. Locale-driven
/// formatting renders `ar_EG` in Arabic-Indic digits and `ar_SA` in ASCII, which
/// would show two different number systems to the two core markets.
///
/// ## What this widget must never do
///
/// It takes a [Money]. It does not accept a `double`, and it performs no
/// arithmetic. Derived figures (a remaining, a total) are computed in exact
/// minor units by the caller and passed in already computed — never derived
/// from a rounded or formatted value, which is how the original contradiction
/// was produced.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.money, {
    super.key,
    required this.style,
    // v2 MoneyText: decimals at 62% size, dimmed.
    this.fractionScale = 0.62,
    this.fractionOpacity = 0.62,
    this.textAlign,
  });

  final Money money;
  final TextStyle style;

  /// Relative size of the fractional part. 1.0 renders it at full size for
  /// surfaces where the fils genuinely carry equal weight.
  final double fractionScale;
  final double fractionOpacity;
  final TextAlign? textAlign;

  /// Unicode isolates. The amount is a self-contained LTR run: without these,
  /// Arabic text on either side reorders it.
  // Written as escapes, not literals: the raw code points reorder this source
  // file in an editor, so the compiler and the reader would see different text.
  static const String _fsi = '\u2068';
  static const String _pdi = '\u2069';

  @override
  Widget build(BuildContext context) {
    final parts = splitMoneyForDisplay(money);
    final base = style.copyWith(
      // Fixed-width digits so amounts align down a list and worst-case width is
      // predictable at layout time. A font without `tnum` ignores this rather
      // than breaking.
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final fractionStyle = base.copyWith(
      fontSize: (base.fontSize ?? 14) * fractionScale,
      color: base.color?.withValues(alpha: fractionOpacity),
    );

    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: _fsi),
          // v2: a true minus sign (U+2212), always leading the digits.
          if (parts.negative) TextSpan(text: '\u2212', style: base),
          TextSpan(text: parts.integerPart, style: base),
          if (parts.fraction.isNotEmpty)
            TextSpan(text: '.${parts.fraction}', style: fractionStyle),
          const TextSpan(text: _pdi),
        ],
      ),
      textAlign: textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textDirection: TextDirection.ltr,
    );
  }
}
