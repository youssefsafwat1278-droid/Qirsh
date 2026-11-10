import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lets the following opaque content surface scroll over a slower-moving hero.
class ScrollOverHero extends StatelessWidget {
  const ScrollOverHero({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll == null || MediaQuery.disableAnimationsOf(context)) return child;

    return AnimatedBuilder(
      animation: scroll,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, math.max(0, scroll.pixels) * .28),
        child: child,
      ),
    );
  }
}
