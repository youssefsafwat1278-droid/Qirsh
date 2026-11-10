import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/dashboard/home_hero_period_controller.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing and obsolete preferences use the monthly default', () async {
    for (final value in [null, 'obsolete']) {
      SharedPreferences.setMockInitialValues({
        if (value != null) HomeHeroPeriodController.preferenceKey: value,
      });
      await HomeHeroPeriodController.preload();
      final container = ProviderContainer();
      expect(container.read(heroPeriodProvider), HeroPeriod.month);
      container.dispose();
    }
  });

  for (final period in HeroPeriod.values) {
    test('restores $period before the next provider graph first read',
        () async {
      SharedPreferences.setMockInitialValues({});
      await HomeHeroPeriodController.preload();
      final first = ProviderContainer();
      final activityRange = first.read(transactionsDateRangeProvider);
      await first.read(heroPeriodProvider.notifier).select(period);
      expect(first.read(heroPeriodProvider), period);
      expect(first.read(transactionsDateRangeProvider), same(activityRange));
      first.dispose();

      final saved = (await SharedPreferences.getInstance())
          .getString(HomeHeroPeriodController.preferenceKey);
      expect(saved, period.name);
      await HomeHeroPeriodController.preload();
      final reopened = ProviderContainer();
      expect(reopened.read(heroPeriodProvider), period);
      reopened.dispose();
    });
  }

  test('rapid taps persist in order across replacement provider scopes',
      () async {
    SharedPreferences.setMockInitialValues({});
    await HomeHeroPeriodController.preload();
    final first = ProviderContainer();
    final day = first.read(heroPeriodProvider.notifier).select(HeroPeriod.day);
    final week =
        first.read(heroPeriodProvider.notifier).select(HeroPeriod.week);
    first.dispose();
    final next = ProviderContainer();
    expect(next.read(heroPeriodProvider), HeroPeriod.week);
    final month =
        next.read(heroPeriodProvider.notifier).select(HeroPeriod.month);
    await Future.wait([day, week, month]);
    next.dispose();
    await HomeHeroPeriodController.preload();
    final reopened = ProviderContainer();
    expect(reopened.read(heroPeriodProvider), HeroPeriod.month);
    reopened.dispose();
  });
}
