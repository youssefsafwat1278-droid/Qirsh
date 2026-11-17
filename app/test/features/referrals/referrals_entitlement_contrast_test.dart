import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/referrals_providers.dart';
import 'package:money_companion/features/referrals/referrals_screen.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../core/theme/contrast_test.dart' show contrast;

class _Service implements ReferralService {
  @override
  Future<ReferralSummary?> getSummary() async => ReferralSummary(
        referralCode: 'QK7F9X2M',
        progress: 5,
        requiredReferrals: 5,
        rewardDays: 7,
        repeatable: true,
        cycleIndex: 1,
        cycleState: 'open',
        referralsAvailable: true,
        attributionStatus: AttributionStatus.none,
        entitlementStatus: 'active',
        entitlementEndsAt: DateTime.utc(2026, 8, 24),
        serverNow: DateTime.utc(2026, 8, 17),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// UX-07 (round 2): the active-entitlement line was white (`onSuccess`) on the
// pale green `successBg` in light, 1.15:1.
void main() {
  for (final dark in [false, true]) {
    testWidgets('active entitlement line is >= 4.5:1 (${dark ? 'dark' : 'light'})',
        (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
          overrides: [
            referralsEnabledProvider.overrideWithValue(true),
            referralServiceProvider.overrideWithValue(_Service()),
          ],
          child: MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: const Locale('en'),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: const ReferralsScreen())));
      await tester.pump();
      await tester.pump();
      final icon = find.byIcon(Icons.verified_rounded);
      expect(icon, findsOneWidget);
      final box = find.ancestor(of: icon, matching: find.byType(Container)).first;
      final bg = (tester.widget<Container>(box).decoration! as BoxDecoration).color!;
      // The text line (the icon is a 3:1 graphic and renders as RichText too).
      final line = find.descendant(
          of: find.descendant(of: box, matching: find.byType(Text)).first,
          matching: find.byType(RichText));
      final fg = tester.widget<RichText>(line).text.style!.color!;
      expect(contrast(fg, bg), greaterThanOrEqualTo(4.5),
          reason: '${contrast(fg, bg).toStringAsFixed(2)}:1');
    });
  }
}
