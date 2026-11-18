import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/common/charts/spending_charts.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/domain/finance/money.dart';

void main() {
  Future<void> pumpDaily(WidgetTester tester, Widget chart,
      {String language = 'en'}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light, locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: Center(child: chart)),
    ));
    await tester.pumpAndSettle();
  }

  for (final language in ['en', 'ar']) {
    testWidgets('daily axis uses actual sparse dates and exact average in $language', (tester) async {
      final days = [DateTime(2026, 1, 11), DateTime(2026, 2, 2)];
      await pumpDaily(tester, DailySpendBarChart(values: const [12.345, 5.555],
          days: days, average: Money(8950, 'KWD'), averageLabel: 'Daily average'),
          language: language);
      expect(find.text(_axisDate(language, days[0])), findsWidgets);
      expect(find.text(_axisDate(language, days[1])), findsWidgets);
      expect(find.text('1'), findsNothing);
      final data = tester.widget<BarChart>(find.byType(BarChart)).data;
      expect(data.barGroups, hasLength(2), reason: 'no records are invented for gap days');
      final average = data.extraLinesData.horizontalLines.single;
      expect(average.y, 8.950);
      expect(average.dashArray, [5, 4]);
      expect(average.label.labelResolver(average), 'Daily average');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('daily chart keeps refund-dominated values below a visible zero baseline', (tester) async {
    await pumpDaily(tester, DailySpendBarChart(values: const [-20.0, 5.0],
        average: Money(-750, 'SAR'), averageLabel: 'Daily average'));
    final data = tester.widget<BarChart>(find.byType(BarChart)).data;
    expect(data.minY, lessThan(-20));
    expect(data.maxY, greaterThan(5));
    expect(data.barGroups.first.barRods.single.toY, -20);
    expect(data.extraLinesData.horizontalLines.map((line) => line.y), [-7.5, 0.0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty daily chart invents neither a day nor an average', (tester) async {
    await pumpDaily(tester, DailySpendBarChart(values: const [],
        days: const [], average: Money.zero('SAR')));
    final data = tester.widget<BarChart>(find.byType(BarChart)).data;
    expect(data.barGroups, isEmpty);
    expect(data.extraLinesData.horizontalLines, isEmpty);
    expect(data.maxY, greaterThan(data.minY));
    expect(tester.takeException(), isNull);
  });

  for (final language in ['ar', 'en']) {
    testWidgets('dense daily dates are filtered by the actual title callback in $language', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final days = List.generate(29, (i) => DateTime(2026, 1, 11 + i));
      await pumpDaily(tester, Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: DailySpendBarChart(values: List.filled(29, 10), days: days),
      ), language: language);
      final data = tester.widget<BarChart>(find.byType(BarChart)).data;
      final side = data.titlesData.bottomTitles.sideTitles;
      final visible = <int>[];
      // Invoke every group, matching fl_chart's behaviour. The SideTitles
      // interval alone does not suppress labels for a dense bar chart.
      for (var i = 0; i < days.length; i++) {
        final label = side.getTitlesWidget(i.toDouble(), TitleMeta(
          min: 0, max: 28, parentAxisSize: 311,
          axisPosition: i * 311 / 28, appliedInterval: 1,
          sideTitles: side, formattedValue: '$i', axisSide: AxisSide.bottom,
        ));
        if (label is Text) visible.add(i);
      }
      expect(visible.length, lessThanOrEqualTo(4));
      expect(visible.first, 0);
      expect(visible.last, 28);
      for (var i = 1; i < visible.length; i++) {
        expect((visible[i] - visible[i - 1]) * 311 / 28, greaterThanOrEqualTo(66));
      }
      final labels = [for (final index in visible)
        find.text(_axisDate(language, days[index]))];
      for (final label in labels) { expect(label, findsWidgets); }
      final rects = [for (final label in labels) tester.getRect(label.first)];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse,
              reason: 'actual date labels must not overlap at375px');
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('spending charts render in RTL without throwing', (tester) async {
    final category = CategoryView(
      const CategoryEntity(
        id: 'food',
        key: 'food',
        nameAr: 'مطاعم',
        icon: 'utensils',
        color: '#00C853',
        isIncome: false,
        sort: 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        theme: AppTheme.light,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: ListView(
              children: [
                CategoryDonutChart(
                  slices: [
                    SpendingChartSlice(
                      category: category,
                      total: 120,
                      percent: 1,
                    ),
                  ],
                ),
                const DailySpendBarChart(values: [10, 20, 5]),
                const CompactSparkline(values: [1, 4, 2, 8]),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.byType(CategoryDonutChart), findsOneWidget);
    expect(find.byType(DailySpendBarChart), findsOneWidget);
    expect(find.byType(CompactSparkline), findsOneWidget);
  });
}

/// V1-068: the axis dates use Western digits in Arabic too, like the amounts
/// («11 يناير», not «١١ يناير»). This replaced intl's Arabic `MMMd`.
String _axisDate(String language, DateTime day) {
  final label = language == 'en'
      ? DateFormat.MMMd('en').format(day)
      : '${day.day} ${DateFormat.MMMM(language).format(day)}';
  expect(label, isNot(matches(RegExp('[\u0660-\u0669]'))));
  return label;
}
