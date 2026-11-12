import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/hero_amount_size.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';

/// Phase J — the batch of findings whose common shape is *"the data was there
/// and the screen did not say it"*, plus the two destructive/notification
/// safety ones.
///
/// Structural where the finding is a property of a surface's source, and
/// behavioural where a value can actually be computed.
void main() {
  group('UX-001 — a budget card can no longer contradict itself', () {
    // The reported card: limit 1,200, spend 355.50. Rounding spend and
    // remaining independently printed «356» and «845» — 1,201 against a limit
    // of 1,200, wrong by a riyal and visible in one glance.
    final limit = Money(120000, 'SAR');
    final spent = Money(35550, 'SAR');
    final remaining = limit - spent;

    test('the three figures reconcile exactly', () {
      expect(spent + remaining, limit);
      expect(formatMoney(spent), '355.50');
      expect(formatMoney(remaining), '844.50');
      expect(formatMoney(limit), '1,200.00');
    });

    test('the OLD rounding is what produced the contradiction', () {
      // Kept as the reproduction: this is the arithmetic the screen used to do,
      // and it is why "just round consistently" was not a fix.
      final roundedSpent = (spent.minorUnits / 100).round();
      final roundedRemaining = (remaining.minorUnits / 100).round();
      expect(roundedSpent + roundedRemaining, 1201);
      expect(roundedSpent + roundedRemaining, isNot(1200));
    });

    test('بقالة reconciled only by luck, not by rule', () {
      // 1,644.30 spent against 2,500.00 — rounds the other way and happens to
      // add up. A rule that is right half the time is the defect.
      final b = Money(164430, 'SAR');
      final bLimit = Money(250000, 'SAR');
      final bRemaining = bLimit - b;
      expect(
          (b.minorUnits / 100).round() + (bRemaining.minorUnits / 100).round(),
          2500);
    });

    final screen =
        File('lib/features/budgets/budgets_screen.dart').readAsStringSync();

    test('the amount tile takes Money, so a caller cannot round on the way in',
        () {
      expect(screen, contains('final Money amount;'));
      expect(screen, contains('MoneyText(\n          amount,'));
    });

    test('no budget figure is formatted through an integer rounding', () {
      expect(screen.contains('Formatters.integer(entry.spent'), isFalse);
      expect(screen.contains('Formatters.integer(entry.remaining'), isFalse);
      expect(screen.contains('Formatters.integer((-entry.remaining)'), isFalse);
    });

    test('the limit tile reads the exact field, not the legacy REAL one', () {
      expect(screen, contains('amount: entry.budget.amountMoney'));
      expect(
          screen.contains('Formatters.integer(entry.budget.amount)'), isFalse);
    });
  });

  group('UX-035 — large values keep their digits and stay legible', () {
    test('an amount past 2^53 is exact, where a double is not', () {
      // The literal form of "silently rounding": a double cannot represent
      // consecutive integers this large, so the digits printed were not the
      // digits stored.
      final huge = Money(9007199254740993, 'SAR');
      expect(formatMoney(huge), '90,071,992,547,409.93');
      expect(huge.toDouble().toStringAsFixed(2),
          isNot(equals('90071992547409.93')),
          reason: 'the double path is what the finding describes');
    });

    test('the hero has a legibility floor rather than shrinking to nothing',
        () {
      expect(heroAmountFontSize('12,345.67'.length), 40);
      expect(heroAmountFontSize('1,234,567.89'.length), lessThan(40));
      expect(heroAmountFontSize('1,234,567,890.12'.length),
          lessThan(heroAmountFontSize('1,234,567.89'.length)));
    });

    test('the floor holds no matter how long the value gets', () {
      final absurd = formatMoney(Money(1 << 62, 'SAR'));
      expect(heroAmountFontSize(absurd.length), greaterThanOrEqualTo(40 * 0.55),
          reason: 'a size that keeps shrinking is the «0 0 0» the QA reported');
    });
  });

  group('UX-037 — a budget alert says which budget crossed which threshold',
      () {
    BudgetAlertContent? plan({String? account}) {
      final budget = BudgetEntity(
        id: 'b1',
        categoryId: 'shopping',
        amountMoney: Money(100000, 'SAR'),
        lastNotifiedSpentMoney: Money.zero('SAR'),
        currency: 'SAR',
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
        accountId: 'a1',
      );
      return const BudgetAlertPlanner().plan(
        entry: BudgetProgressEntry(
          budget: budget,
          spent: Money(110000, 'SAR'),
          remaining: Money(-10000, 'SAR'),
          ratio: 1.1,
          periodStart: DateTime.utc(2026, 8, 1),
          periodEnd: DateTime.utc(2026, 9, 1),
          health: BudgetHealth.over,
        ),
        now: DateTime.utc(2026, 8, 15),
        currencyLabel: 'ريال',
        categoryLabel: 'تسوق',
        accountLabel: account,
      );
    }

    test('it names the account the budget belongs to', () {
      final content = plan(account: 'الراجحي')!;
      expect(content.body, contains('تسوق في الراجحي'),
          reason: 'the QA case: a shopping warning arriving after an unrelated '
              'food purchase read as though the food belonged to shopping, '
              'because the alert named neither the budget nor its account');
    });

    test('it states the threshold that fired it', () {
      expect(plan(account: 'الراجحي')!.body, contains('١٠٠٪'));
    });

    test('with no account it still reads correctly, without inventing one', () {
      final content = plan()!;
      expect(content.body, contains('ميزانية تسوق'));
      expect(content.body.contains(' في null'), isFalse);
    });
  });

  group('R-8 — a capture notification cannot mis-scale a currency', () {
    test('a 3-decimal currency is not rounded to 2', () {
      expect(fmtCaptureMoney(Money(12345, 'KWD')), '12.345',
          reason:
              'the old double formatter printed 12.35 — a different number');
    });

    test('the approved brevity rule survives', () {
      expect(fmtCaptureMoney(Money(15000, 'SAR')), '150');
      expect(fmtCaptureMoney(Money(15050, 'SAR')), '150.50');
    });

    test('a 0-decimal currency shows no phantom fraction', () {
      expect(fmtCaptureMoney(Money(150, 'JPY')), '150');
    });

    test('a category is shown only when it is actually resolved', () {
      // The finding's second half: "should show the resolved category when one
      // is actually known and should not fabricate it when confidence is
      // insufficient."
      expect(captureCategoryLabel('groceries'), isNotNull);
      expect(captureCategoryLabel(null), isNull);
      expect(captureCategoryLabel('not_a_real_key'), isNull);
    });
  });

  group('the information gaps are closed at the surfaces that render them', () {
    test('UX-004 — a plan names the accounts it counts', () {
      final src =
          File('lib/features/plans/plans_screen.dart').readAsStringSync();
      expect(src, contains('_planScopeLabel'));
      expect(src, contains('context.l10n.plAllSpendInPeriod'),
          reason: 'MALI-048n: an empty selection means ALL expenses, and '
              'rendering it blank would hide the widest scope the app has');
      expect(src, contains('PlanScopeMode.allExpenses'));
    });

    test('UX-024 — Subscriptions names the account it is scoped to', () {
      final providers =
          File('lib/features/subscriptions/subscriptions_providers.dart')
              .readAsStringSync();
      expect(providers, contains('billsScopeAccountProvider'),
          reason: 'the label must come from the SAME resolution the filter '
              'used, or the two can drift apart');
      expect(providers,
          contains('await ref.watch(billsScopeAccountProvider.future)'));

      final screen =
          File('lib/features/subscriptions/subscriptions_screen.dart')
              .readAsStringSync();
      expect(screen, contains('scopeAccountName'));
      expect(screen, contains('billsScopeAccountProvider'));
    });

    test('UX-031 — the message centre dates its rows', () {
      final src = File('lib/features/announcements/announcements_screen.dart')
          .readAsStringSync();
      expect(src, contains('dateLabel(context)'));
      expect(src, contains('context.l10n.annFromDate(date)'),
          reason: 'a campaign/announcement `sortAt` is validFrom — when it '
              'STARTED being shown — not when it was delivered');
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(ar['annFromDate'], 'من {date}');
      expect(en['annFromDate'], 'From {date}');
    });

    test('UX-015 — the card source is stated in customer language', () {
      // The copy moved to the ARB, so that is where the contract is asserted —
      // and English is held to the same standard, which the source grep could
      // not do. «أضفتها بنفسك» rendered to English readers until this screen
      // was captured; a grep for the Arabic would have passed throughout.
      final src = File('lib/features/accounts/account_detail_screen.dart')
          .readAsStringSync();
      expect(src.contains("? 'تلقائية' : 'يدوية'"), isFalse,
          reason: 'the jargon wording is back');
      expect(src, contains('cardSourceAuto'));
      expect(src, contains('cardSourceManual'));

      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(ar['cardSourceAuto'], 'اتُعرِّفت من رسائل البنك');
      expect(ar['cardSourceManual'], 'أضفتها بنفسك');
      // Customer language in English too: no "auto"/"manual" jargon.
      expect(en['cardSourceAuto'], 'Detected from bank messages');
      expect(en['cardSourceManual'], 'You added it yourself');
      for (final k in ['cardSourceAuto', 'cardSourceManual']) {
        expect(RegExp(r'[؀-ۿ]').hasMatch(en[k] as String), isFalse,
            reason: '$k still reads Arabic in English');
      }
    });

    test('UX-026 — the ambiguous tab names its domain', () {
      // The copy now lives in the ARB, so that is where the contract is
      // asserted — and it holds the English tab to the same standard.
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(ar['bdgTabHistory'], 'سجل الميزانيات');
      expect(ar['bdgTabHistory'], isNot('السجل'),
          reason: 'a bare «السجل» does not say a record OF WHAT');
      expect(en['bdgTabHistory'], contains('history'));
      expect(en['bdgTabHistory'], isNot('History'),
          reason: 'the English tab must name its domain too');
    });
  });

  group('UX-028 / UX-029 / UX-030 — Settings', () {
    final src =
        File('lib/features/settings/settings_screen.dart').readAsStringSync();
    // Settings copy moved into the ARB during the English localisation pass,
    // so the source no longer carries these literals. The contract is about
    // the COPY THAT SHIPS, which is now the ARB — and asserting there also
    // covers English, which asserting the Dart never did.
    final arAr = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final enAr = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;

    test('«الحساب» is no longer two different sections', () {
      // Scoped to Settings' own keys. A bare «الحساب» is a perfectly good ROW
      // LABEL elsewhere (transaction details names the account a transaction
      // belongs to); the finding was about two SECTION HEADINGS in this one
      // screen sharing a name, and that is what this guards.
      final settingsHeadings = {
        for (final e in arAr.entries)
          if (e.key.startsWith('set')) e.key: e.value
      };
      expect(settingsHeadings.values.where((v) => v == 'الحساب').length, 0,
          reason: 'two unrelated groups shared one heading; both are now named '
              'for what they contain');
      expect(arAr['setAccountData'], 'بيانات حسابك');
      expect(arAr['setExitAndErase'], 'الخروج وحذف البيانات');
      // The same split must exist in English, or the fix is Arabic-only.
      expect(enAr['setAccountData'], isNot(enAr['setExitAndErase']));
    });

    test('the Reports duplicate route is gone from Settings', () {
      // UX-029's own instruction: "Fixing UX-012 should reduce this list, not
      // duplicate it." UX-012 is fixed — every bottom-nav tab now carries a
      // text label, Analytics among them.
      expect(src.contains("title: 'الرؤى والتقارير'"), isFalse);
      final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
      // The label used to be an Arabic literal in `_items`, which this test
      // grepped for. It now comes from the ARB, so assert the wiring AND both
      // languages — an Arabic-only label would have passed the old grep.
      expect(shell, contains('l.navAnalytics'));
      expect(arAr['navAnalytics'], 'التحليلات');
      expect(enAr['navAnalytics'], isA<String>());
      expect(enAr['navAnalytics'], isNot(arAr['navAnalytics']));
    });

    test('the ten-entry hub is split into destinations and configuration', () {
      expect(arAr.values.contains('إدارة أموالك'), isFalse);
      expect(arAr['setAccountsAndDues'], 'حساباتك والتزاماتك');
      expect(arAr['setToolsAndSettings'], 'أدوات وإعدادات');
      expect(enAr['setAccountsAndDues'], isNotNull);
      expect(enAr['setToolsAndSettings'], isNotNull);
    });

    test('UX-030 — the encryption claim is made, and is TRUE', () {
      expect(arAr['setEncryptedDbPart1'], contains('قاعدة بيانات مشفّرة'));
      expect(enAr['setEncryptedDbPart1'], contains('encrypted database'),
          reason: 'the claim must be made in both languages, not just Arabic');
      // The claim must be verifiable, not marketing. Both halves are asserted
      // against the code that implements them.
      final db = File('lib/data/db/app_database.dart').readAsStringSync();
      expect(db, contains("PRAGMA cipher = 'sqlcipher';"));
      expect(db, contains('would not be encrypted'),
          reason: 'the open FAILS CLOSED rather than continuing unencrypted — '
              'without that, the claim would be conditional');
      expect(File('lib/data/db/database_key_store.dart').readAsStringSync(),
          contains('FlutterSecureStorage'),
          reason: 'the key is in the platform keychain, as the copy says');
    });

    test('the claim does NOT overreach into end-to-end encryption', () {
      // Local-database encryption is what the code does. Claiming end-to-end
      // would be a stronger promise than the product keeps, and a privacy claim
      // that overstates is worse than the silence it replaces.
      expect(src.contains('تشفير طرف لطرف'), isFalse);
      expect(src.contains('تشفير من طرف إلى طرف'), isFalse);
    });
  });

  group('UX-032 — the announcement banner keeps its own vertical rhythm', () {
    final src = File('lib/features/common/widgets/announcement_banner.dart')
        .readAsStringSync();

    test('the banner carries bottom spacing in BOTH layouts', () {
      // Two padding sites: the single-banner path and the horizontal-scroll
      // path. The QA required the rhythm to hold "at every announcement
      // length", and a multi-banner row is one of those lengths.
      expect('EdgeInsets.fromLTRB('.allMatches(src).length, 2,
          reason: 'single-banner and horizontal-scroll paths both need it');
      expect(
          src.contains('EdgeInsets.symmetric(horizontal: AppSpacing.gutter)'),
          isFalse,
          reason: 'horizontal-only padding is what left it flush against the '
              'smart-inbox card below');
    });

    test('the spacing lives inside the widget, not beside it on Home', () {
      // The widget collapses to SizedBox.shrink() when there is nothing to
      // show. A spacer on Home would leave a permanent gap on the far more
      // common no-announcement screen.
      expect(src, contains('SizedBox.shrink()'));
      final home = File('lib/features/dashboard/dashboard_screen.dart')
          .readAsStringSync();
      expect(
        RegExp(r'AnnouncementBanner\(\),\s*const SizedBox').hasMatch(home),
        isFalse,
        reason: 'no compensating spacer was added at the call site',
      );
    });
  });

  group('Home hides empty sections and preserves populated sections', () {
    // The dashboard redesign moved the budgets section into its own widget, so
    // the empty copy no longer all lives in one file. The contract is about
    // what Home RENDERS, not about which file holds the string — so the search
    // spans Home plus the section widgets it composes.
    final home =
        File('lib/features/dashboard/dashboard_screen.dart').readAsStringSync();
    test('empty account sections have explicit visibility guards', () {
      expect(home, contains('if (data.budgetProgress.isEmpty)'));
      expect(
          home, contains('if (bills.isEmpty) return const SizedBox.shrink();'));
      expect(home, contains('if (goals.isEmpty && plans.isEmpty)'));
    });

    test('each says which account has nothing, not just "empty"', () {
      // The QA paired this with UX-007: now that the chip names the active
      // account, "nothing on THIS account" is a sentence the user can act on.
      // The copy ships from the ARB now, so the contract is asserted there —
      // and in both languages, because a bare "empty" is just as useless in
      // English as it was in Arabic.
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      const keys = [
        'homeNoBudgetsOnAccount',
        'homeNoGoalsOnAccount',
        // Subscriptions and instalments share one section, so that sentence
        // names both — still the account, still not a bare "empty".
        'homeNoBillsOnAccount',
      ];
      for (final k in keys) {
        expect(home, isNot(contains('context.l10n.$k')),
            reason: 'Home hides empty sections after the approved redesign');
        expect(ar[k], contains('هذا الحساب'),
            reason: '$k must name the account, not just say "empty"');
        expect(en[k], contains('this account'),
            reason: '$k must name the account in English too');
      }
    });

    test('the sections a user OWNS survive a period with no transactions', () {
      // Regression guard for a defect an earlier redesign fixed: the whole body
      // used to sit behind `data.isEmpty`, so a range with no rows hid the
      // budgets the user set, the subscriptions they still pay and the goals
      // they are still saving for. Those are not a function of the selected
      // period, so nothing in Home's body may gate on it.
      expect(home.contains('if (data.isEmpty) ...['), isFalse);
      final regular = home
          .split('class _HomeBody')
          .last
          .split('] else ...[')
          .last
          .split('// THE BANNER')
          .first;
      for (final owned in [
        '_BudgetsSection(data: data, privacyMode: privacyMode)',
        '_UpcomingSection(privacyMode: privacyMode)',
        '_GoalsPlansSection(privacyMode: privacyMode)',
      ]) {
        expect(regular, contains(owned),
            reason: '$owned must render unconditionally once the account has '
                'any transaction');
      }
    });

    test('a first-run account gets the welcome screen, not empty sections', () {
      // Three empty section headers would be a worse answer than one clear one.
      // First-run means the account has NEVER had a transaction — not that the
      // selected period is empty.
      expect(home, contains('final firstRun = !data.hasAnyTransactions;'));
      expect(
          home,
          contains(
              'if (firstRun) ...[\n                _WelcomeBody(data: data),'));
      // What the user already created before their first transaction still
      // shows there.
      expect(home, contains('if (goals.isEmpty && plans.isEmpty)'));
    });

    test('the note is quiet, not a stack of full empty-state archetypes', () {
      expect(home, isNot(contains('class _SectionEmptyNote')));
      expect(
          home, contains('if (bills.isEmpty) return const SizedBox.shrink();'));
    });
  });

  group('UX-014 — a long account name is readable', () {
    test('the header title may wrap when the title is user data', () {
      final header =
          File('lib/features/common/app_header.dart').readAsStringSync();
      expect(header, contains('this.titleMaxLines = 1'),
          reason: 'opt-in: a fixed screen name does not need two lines');
      expect(header, contains('maxLines: titleMaxLines'));
    });

    test('the bar grows with the lines it permits', () {
      final header =
          File('lib/features/common/app_header.dart').readAsStringSync();
      expect(header, contains('(titleMaxLines - 1) * 28.0'),
          reason: 'allowing a wrap without room for it just clips lower');
    });

    test('the account detail screen opts in', () {
      final src = File('lib/features/accounts/account_detail_screen.dart')
          .readAsStringSync();
      expect(src, contains('titleMaxLines: 2'));
    });
  });

  group('UX-003 — the budget sheet is honest and actionable', () {
    final src =
        File('lib/features/budgets/budgets_screen.dart').readAsStringSync();

    test('the 20-row cap is disclosed rather than silent', () {
      expect(src, contains('_kPeriodTransactionLimit'));
      expect(src,
          contains('history.transactions.length > _kPeriodTransactionLimit'));
      expect(src, contains('باقي '),
          reason:
              'F-009 class — a silent cap makes 60 transactions look like 20');
    });

    test('the count is stated even when nothing is truncated', () {
      expect(src, contains('history.transactions.isNotEmpty'));
    });

    test('the sheet offers an action, not just a read-only view', () {
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(ar['bdgEditBudget'], 'تعديل الميزانية');
      expect(en['bdgEditBudget'], 'Edit budget');
      expect(src, contains('context.l10n.bdgEditBudget'));
      expect(src, contains('budgetId: entry.budget.id'));
    });
  });

  group('UX-016 — pending transactions can be isolated FROM the list', () {
    final src = File('lib/features/transactions/transactions_screen.dart')
        .readAsStringSync();

    test('the screen offers a «قيد المراجعة» filter of its own', () {
      // The filter itself already existed. It was reachable from exactly two
      // places, both OUTSIDE this screen — the Home banner and a notification
      // tap — while Transactions showed «1 قيد المراجعة» in its header and told
      // the user to review those items.
      expect(src, contains('class _PendingFilterChip'));
      expect(src, contains('_PendingFilterChip(),'),
          reason: 'declared and MOUNTED — an unmounted control fixes nothing');
    });

    test('it is a toggle, not a fifth kind chip', () {
      // «مصروفات» + «قيد المراجعة» is a meaningful combination; a fifth kind
      // chip would have made them mutually exclusive, and the provider ANDs
      // pendingOnly with the kind filter rather than replacing it.
      expect(RegExp(r'\.state\s*=\s*!active').hasMatch(src), isTrue);
      final providers =
          File('lib/features/transactions/transactions_providers.dart')
              .readAsStringSync();
      expect(providers, contains('transactionsPendingFilterProvider'));
    });
  });

  group('UX-036 — a plan is labelled in ITS currency, not the base one', () {
    final src =
        File('lib/features/plans/plan_form_sheet.dart').readAsStringSync();

    test('the hardcoded «جنيه» is gone', () {
      expect(src.contains("'جنيه'"), isFalse);
    });

    test('editing an existing plan shows that plan currency', () {
      // The residual half: the suffix read the BASE currency while `_save`
      // writes `existing.currency`. Editing an EGP plan on a SAR base labelled
      // the field «ريال» while storing EGP.
      expect(src, contains('widget.existing?.currency ??'));
      // `arabicLabel` is now the Arabic HALF of a locale-aware pair; the screen
      // must go through `label`, or an English user reads «ريال».
      expect(src, contains('Currency.label(context, planCurrencyCode)'));
    });

    test('the save path and the label read the SAME source', () {
      final saveIdx = src.indexOf('Future<void> _save()');
      final saveBody = src.substring(saveIdx, saveIdx + 400);
      expect(saveBody, contains('widget.existing?.currency ??'));
    });

    test('the mixed-currency rule is stated, not left to be discovered', () {
      expect(src, contains('context.l10n.pfCurrencyOnly'));
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      // Which currencies a plan counts is a rule a user cannot infer from the
      // screen, so it has to be spelled out — in whichever language they read.
      expect(ar['pfCurrencyOnly'], contains('ولا يُحتسب فيها'));
      expect(en['pfCurrencyOnly'], contains('not included'));
    });
  });

  group('NEW — «تجاهل الكل» was a bulk destructive action with no guard', () {
    final src = File('lib/features/transactions/transactions_screen.dart')
        .readAsStringSync();

    test('it now states how many it will dismiss', () {
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      // The count must survive into BOTH languages — an English user facing a
      // bulk delete needs the number just as much as an Arabic one.
      for (final m in [ar, en]) {
        expect(m['txnDismissAllCount'], contains('{count}'));
        expect(m['txnDismissNAlerts'], contains('{count}'));
      }
      expect(src, contains('txnDismissAllCount(dupes.length)'));
      expect(src, contains('txnDismissNAlerts(dupes.length)'));
    });

    test('it is confirmed before anything is deleted', () {
      final i = src.indexOf('تجاهل الكل');
      final body = src.substring(i - 200, i + 2200);
      expect(body, contains('if (proceed != true) return;'));
      expect(body.indexOf('showDialog<bool>'),
          lessThan(body.indexOf('.dismissAll(dupes)')),
          reason: 'the confirmation must precede the deletion, not follow it');
    });

    test('it says what is and is NOT affected', () {
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
          as Map<String, dynamic>;
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      expect(ar['txnDismissAllDupesBody'], contains('العمليات نفسها'),
          reason: 'it discards duplicate FLAGS, not transactions — the '
              'difference is the whole reason the action is acceptable at all');
      expect(en['txnDismissAllDupesBody'], contains('not affected'),
          reason: 'the same reassurance must reach an English user, or the '
              'bulk action is unguarded for them');
      expect(src, contains('txnDismissAllDupesBody'));
    });
  });

  group('UX-034 — the account and the card are separate facts', () {
    final src =
        File('lib/features/transactions/transaction_details_screen.dart')
            .readAsStringSync();

    final arArb = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final enArb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;

    test('they are separate labelled rows, not one «المصدر» string', () {
      expect(
          src.contains(r"${tx.cardLast4 != null ? ' · ${tx.cardLast4}' : ''}"),
          isFalse);
      expect(src, contains('context.l10n.commonAccountDefinite'));
      expect(src, contains('context.l10n.txdCard'));
      expect(arArb['commonAccountDefinite'], 'الحساب');
      expect(arArb['txdCard'], 'البطاقة');
      expect(enArb['commonAccountDefinite'], 'Account');
      expect(enArb['txdCard'], 'Card');
    });

    test('«بدون بطاقة» exists as an explicit action', () {
      expect(src, contains('context.l10n.txdNoCard'));
      expect(arArb['txdNoCard'], 'بدون بطاقة');
      expect(enArb['txdNoCard'], 'No card');
    });

    test('the consequence is STATED, because the finding requires it', () {
      // The consequence is the whole reason the action is safe to offer. It
      // must be stated in whichever language the user is reading.
      expect(arArb['txdCardSheetNote'],
          contains('تغيير البطاقة لا ينقل العملية إلى حساب آخر'));
      expect(
          arArb['txdCardRemoved'], contains('ما زالت العملية في الحساب نفسه'));
      expect(enArb['txdCardSheetNote'],
          contains('does not move the transaction to another account'));
      expect(enArb['txdCardRemoved'], contains('still in the same account'));
    });

    test('and the stated consequence is true of the repository', () {
      // The claim is only safe because `updateCard` writes card_last4 and
      // nothing else. If that ever changes, the copy becomes a lie.
      final repo =
          File('lib/data/repositories/drift_transaction_repository.dart')
              .readAsStringSync();
      final i = repo.indexOf('Future<void> updateCard');
      final body = repo.substring(i, i + 700);
      expect(body, contains('UPDATE transactions SET card_last4 = ?'));
      expect(body.contains('account_id ='), isFalse,
          reason: 'changing a card must not move the transaction to another '
              'account — the sheet promises exactly this');
    });

    test('only cards on the transaction OWN account are offered', () {
      expect(src, contains('card.accountId == tx.accountId'),
          reason: 'offering every card would invite a pairing that '
              'contradicts the account shown one row above');
    });

    test('a dismissed sheet is not read as «detach the card»', () {
      expect(src, contains("'__none__'"),
          reason: 'null is also what a dismissed sheet returns');
    });
  });
}
