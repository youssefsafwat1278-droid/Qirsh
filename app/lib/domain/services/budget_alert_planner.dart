import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../entities/budget_entity.dart';
import '../entities/transaction_entity.dart';
import '../entities/engagement_entities.dart';
import '../finance/money.dart';

/// Deterministic notification id for a (budget, period, threshold) triple —
/// SHA-256 instead of hashCode for the same stability reason documented in
/// notification_planner.dart. Distinct base (95000) from bill (92000) and
/// goal (93000) reminder ids.
int _budgetAlertNotificationId(
  String budgetId,
  DateTime periodStart,
  int bucket,
) {
  final stableId = '$budgetId:${periodStart.toIso8601String()}:$bucket';
  final digest = sha256.convert(utf8.encode(stableId));
  final value = (digest.bytes[0] << 24) |
      (digest.bytes[1] << 16) |
      (digest.bytes[2] << 8) |
      digest.bytes[3];
  return 95000 + (value.abs() % 900000);
}

class BudgetAlertContent {
  const BudgetAlertContent({
    required this.notifId,
    required this.type,
    required this.title,
    required this.body,
  });

  final int notifId;
  final NotificationType type;
  final String title;
  final String body;
}

/// Turns a budget's current spend snapshot into a local-notification payload
/// once it crosses one of the budget's thresholds. Pure and side-effect free —
/// callers (SMS capture, manual transaction add) own the actual
/// LocalNotificationService.showBudgetAlert call and its dedup id.
///
/// ## The thresholds
///
/// The EARLY WARNING is the budget's own `alertThresholdPercent`, chosen by the
/// user in the budget form. It used to be a hardcoded 75, which was also a
/// quiet lie: the Settings toggle beside it has always read «تنبيه 80% من
/// الميزانية» / "Alert at 80% of a budget".
///
/// Above it sit two thresholds that are NOT preferences:
///
///  * 90% — the "almost used up" escalation, kept because a warning at 30% and
///    silence from there to 100% is worse than either. It is skipped when the
///    user's own threshold is 90 or higher, so the two can never collide or
///    fire out of order.
///  * 100% — exceeded. Not a warning and not configurable: a budget you have
///    gone past is a fact about your money, not a preference.
///
/// Buckets stay strictly ordered for any threshold in 10..100, which is what
/// keeps the dedup id below meaningful — see [_thresholdsFor].
class BudgetAlertPlanner {
  const BudgetAlertPlanner();

  /// UX-037 — [accountLabel] is REQUIRED and nullable rather than optional.
  ///
  /// The account was already resolved by the only caller and simply never
  /// reached the text. Making it optional would let a future caller silently
  /// drop it again and reproduce the finding; making it required-and-nullable
  /// forces the caller to state that it genuinely does not know, which happens
  /// only when there is no account at all.
  ///
  /// [lang] is the reader's language, read from the settings row by the caller.
  /// This runs in a background isolate with no BuildContext, so it follows the
  /// same contract as every other notification builder: the words are chosen
  /// here from a language code, not resolved from an ARB at a widget.
  BudgetAlertContent? plan({
    required BudgetProgressEntry entry,
    required DateTime now,
    required String currencyLabel,
    required String categoryLabel,
    required String? accountLabel,
    String lang = 'ar',
  }) {
    final ratio = entry.ratio;
    final thresholds = _thresholdsFor(entry.budget.alertThresholdPercent);
    // The HIGHEST crossed threshold wins, so crossing straight from 40% to
    // 120% in one transaction reports "exceeded" and not "you reached 50%".
    var crossed = -1;
    for (var i = 0; i < thresholds.length; i++) {
      if (ratio >= thresholds[i] / 100) crossed = i;
    }
    if (crossed < 0) return null;
    final budget = entry.budget;
    if (budget.lastNotifiedPeriodStart.isAtSameMomentAs(entry.periodStart)) {
      final previous = BigInt.from(budget.lastNotifiedSpentMoney.minorUnits);
      final limit = BigInt.from(budget.amountMoney.minorUnits);
      final alreadyReached = previous * BigInt.from(100) >=
          limit * BigInt.from(thresholds[crossed]);
      final furtherOver = thresholds[crossed] == 100 &&
          (BigInt.from(entry.spent.minorUnits) - previous) * BigInt.from(10) >= limit;
      if (alreadyReached && !furtherOver) return null;
    }
    final percent = thresholds[crossed];
    // The dedup bucket is the PERCENTAGE, not the index. Two budgets with
    // different thresholds then never share a notification id, and a user who
    // moves their threshold mid-period gets one alert for the new threshold
    // rather than a silent one suppressed by the old bucket number.
    final bucket = percent;
    final isExceeded = percent >= 100;
    // The crossed threshold is either the user's own or the fixed 90%
    // escalation — never both, because `_thresholdsFor` drops the 90 when the
    // user's threshold has reached it. Testing `percent >= 90` instead of
    // "is this the user's number" made a 95% threshold report "almost used up"
    // and never mention 95 at all.
    final isEscalation = !isExceeded &&
        percent != BudgetEntity.normalizeAlertThreshold(
            entry.budget.alertThresholdPercent);

    final daysTotal =
        entry.periodEnd.difference(entry.periodStart).inDays.clamp(1, 3660);
    final daysPassed =
        now.difference(entry.periodStart).inDays.clamp(1, daysTotal);
    final daysRemaining = (daysTotal - daysPassed).clamp(0, daysTotal);
    final projectedIncrement = entry.spent.applyRate(
      rateNumerator: BigInt.from(daysRemaining),
      rateDenominator: BigInt.from(daysPassed),
    );
    final projected = entry.spent + projectedIncrement;
    final zero = Money.zero(budget.currency);
    final remaining = entry.remaining.compareTo(zero) < 0
        ? zero
        : entry.remaining.compareTo(budget.amountMoney) > 0
            ? budget.amountMoney
            : entry.remaining;

    String fmt(Money value) => value.toDecimalString();

    // UX-037 — a budget alert must say WHICH budget crossed WHICH threshold.
    //
    // The QA's case: a shopping-budget warning arriving right after an
    // unrelated food purchase read as though the food transaction had been
    // filed under shopping. The notification named neither the account nor the
    // threshold, so the only context the user had was the transaction they had
    // just watched arrive — and they attributed the alert to it.
    //
    // Naming the budget's own account and the crossed threshold removes that
    // reading: the alert now describes a state of a named budget rather than
    // an unattributed reaction to a recent event.
    final en = lang == 'en';
    final scope = accountLabel == null
        ? categoryLabel
        : en
            ? '$categoryLabel in $accountLabel'
            : '$categoryLabel في $accountLabel';

    final String title;
    final String body;
    if (isExceeded) {
      final over = fmt(entry.spent - budget.amountMoney);
      title = en ? 'You went over $categoryLabel' : 'تجاوزت $categoryLabel';
      body = en
          ? 'The $scope budget reached 100% of its limit — '
              'you spent $over $currencyLabel over it.'
          : 'ميزانية $scope بلغت ١٠٠٪ من حدّها — '
              'أنفقت $over $currencyLabel زيادة عنها.';
    } else if (isEscalation) {
      final left = fmt(remaining);
      title = en
          ? '$categoryLabel is almost used up'
          : '$categoryLabel على وشك الاكتمال';
      body = en
          ? 'The $scope budget reached 90% — only $left $currencyLabel left, '
              'and at your current rate it runs out in '
              '${_enDays(daysRemaining)}.'
          : 'ميزانية $scope بلغت ٩٠٪ — تبقّى لك $left $currencyLabel '
              'فقط، ومعدّلك الحالي سيستهلكها خلال ${_arDays(daysRemaining)}.';
    } else {
      final left = fmt(remaining);
      // The percentage in the words is the user's own threshold. Saying "75%"
      // to someone who asked to be told at 30% describes a moment that has not
      // happened yet, and is how a correct alert reads as a wrong one.
      final pct = _percentIn(percent, en);
      title = en
          ? '$categoryLabel has reached $pct'
          : 'وصلت $pct من $categoryLabel';
      if (projected.compareTo(budget.amountMoney) > 0) {
        final overBy = fmt(projected - budget.amountMoney);
        body = en
            ? 'The $scope budget reached $pct — $left $currencyLabel left. '
                'At your current rate you may go over by '
                '$overBy $currencyLabel.'
            : 'ميزانية $scope بلغت $pct — تبقّى لك $left $currencyLabel. '
                'إذا استمرّ معدّلك فقد تتجاوز الميزانية بـ$overBy $currencyLabel.';
      } else {
        body = en
            ? 'The $scope budget reached $pct — $left $currencyLabel left '
                'for the rest of the period.'
            : 'ميزانية $scope بلغت $pct — تبقّى لك $left $currencyLabel '
                'حتى نهاية الفترة.';
      }
    }

    final type = isExceeded
        ? NotificationType.budgetOver
        : NotificationType.budgetWarning;

    return BudgetAlertContent(
      notifId: _budgetAlertNotificationId(budget.id, entry.periodStart, bucket),
      type: type,
      title: title,
      body: body,
    );
  }
}

/// Arabic counts days with five categories; a bare "$n يوم" is wrong for every
/// value except 1 and is the kind of agreement error the MSA guard exists to
/// catch. `ar.arb` handles this with an ICU plural, but this builder has no
/// ARB, so the same five categories are spelled out here.
String _arDays(int n) => switch (n) {
      0 => 'أقل من يوم',
      1 => 'يوم واحد',
      2 => 'يومين',
      >= 3 && <= 10 => '$n أيام',
      _ => '$n يومًا',
    };

String _enDays(int n) => n == 1 ? '1 day' : '$n days';

/// The ordered percentages this budget can alert at.
///
/// Always ends at 100. The 90% escalation is included only when the user's own
/// threshold is below it, so the list is strictly increasing for every
/// threshold in 10..100 and no two buckets can describe the same crossing.
List<int> _thresholdsFor(int alertThresholdPercent) {
  final warn = BudgetEntity.normalizeAlertThreshold(alertThresholdPercent);
  return <int>[
    if (warn < 100) warn,
    if (warn < 90) 90,
    100,
  ];
}

/// A percentage in the reader's own digits. Arabic copy in this app uses
/// Eastern Arabic numerals — «٧٥٪» — and a bare "75%" inside an Arabic
/// sentence is the kind of mixed-script detail that reads as untranslated.
String _percentIn(int percent, bool english) {
  if (english) return '$percent%';
  const eastern = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  final digits =
      percent.toString().split('').map((d) => eastern[int.parse(d)]).join();
  return '$digits٪';
}

/// Event eligibility mirrors canonical budget consumption. Refunds reduce spend
/// and do not trigger expense alerts. Exclusion applies only to global budgets.
bool budgetAlertAffectedBy(
  BudgetProgressEntry entry,
  TransactionEntity transaction, {
  required Set<String> excludedAccountIds,
}) {
  final budget = entry.budget;
  return budget.isActive &&
      transaction.status == TransactionStatus.confirmed &&
      (transaction.type == TransactionTypeEntity.payment ||
          transaction.type == TransactionTypeEntity.withdrawal) &&
      transaction.amountMoney.minorUnits > 0 &&
      transaction.currency.trim().toUpperCase() ==
          budget.currency.trim().toUpperCase() &&
      (budget.accountId == null
          ? !excludedAccountIds.contains(transaction.accountId)
          : transaction.accountId == budget.accountId) &&
      (budget.isAllExpenses || transaction.categoryId == budget.categoryId) &&
      !transaction.occurredAt.isBefore(entry.periodStart) &&
      transaction.occurredAt.isBefore(entry.periodEnd);
}
