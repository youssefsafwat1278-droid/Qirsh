import '../../data/capture/proof_correction_log.dart' show ProofEditOrigin;
import '../entities/card_summary.dart';
import '../entities/category_spend.dart';
import '../entities/report_models.dart';
import '../entities/transaction_entity.dart';
import '../finance/money.dart';
import '../services/card_account_grouper.dart';

/// The list's kind filter, pushed into SQL (B2-C). Mirrors the transactions
/// screen's kind chips; kept in the domain so the repository has no dependency
/// on the feature layer.
enum TransactionPageKind { all, expenses, income, transfers }

/// Keyset cursor for [TransactionRepository.getTransactionPage] — the last row
/// of the previous page. Ordering is `occurred_at DESC, id DESC`, so the next
/// page is everything strictly "older" than this (occurred_at earlier, or equal
/// occurred_at with a smaller id).
class TransactionPageCursor {
  const TransactionPageCursor({required this.occurredAt, required this.id});
  final DateTime occurredAt;
  final String id;
}

/// The full filter state for one transaction-list page, pushed into SQL. A null
/// field means "no predicate for this dimension"; the notifier maps the screen's
/// pending-only mode to (no date, no kind) exactly as the old Dart filter did.
class TransactionPageFilter {
  const TransactionPageFilter({
    this.accountId,
    this.from,
    this.to,
    this.kind = TransactionPageKind.all,
    this.categoryId,
    this.search,
    this.pendingOnly = false,
  });

  final String? accountId;
  final DateTime? from; // half-open [from, to)
  final DateTime? to;
  final TransactionPageKind kind;
  final String? categoryId;
  final String? search; // free-text; matched per-field (see the SQL impl)
  final bool pendingOnly;
}

abstract class TransactionRepository {
  Future<TransactionEntity?> findDuplicate({
    required Money amount,
    required String rawMerchant,
    required DateTime occurredAt,
  });

  Future<TransactionEntity?> findSuspiciousDuplicate({
    required Money amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  });

  /// [categoryKey] is the stable category key to resolve+validate to a local
  /// category id (unknown key → null category, i.e. fails closed to
  /// uncategorised — the DB has NOT NULL FKs elsewhere but transactions allow a
  /// null category).
  ///
  /// [resolvedCategoryId] (MALI-029) is a fast path for BULK callers that have
  /// ALREADY resolved the category id against `categories` in one batch (ledger
  /// pull's primed key→id map; import's prefetched category list). When non-null
  /// it is used directly instead of re-resolving [categoryKey] per row. It is
  /// still fail-closed: `transactions.category_id` has an enforced FK to
  /// `categories(id)` (PRAGMA foreign_keys=ON), so a non-existent id makes the
  /// INSERT throw rather than store a dangling reference. A null value falls back
  /// to the [categoryKey] resolution, so manual/single-entry callers are
  /// unchanged.
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    String? resolvedCategoryId,
  });

  Future<TransactionEntity?> getById(String id);

  Future<TransactionEntity> confirm(String id);

  /// [appliedByRule] marks a write made because the user taught a merchant
  /// rule and asked to update past transactions — not a per-transaction hand
  /// edit. Such a write still enqueues a normal sync update, but it neither
  /// confirms a pending transaction nor records user edit provenance, so the
  /// row keeps counting as automatically categorised.
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
    bool appliedByRule = false,
  });

  /// The local category id for a stable category key, or null.
  Future<String?> categoryIdForKey(String categoryKey);

  /// Every other transaction of the same merchant (stable identity + verified
  /// aliases), across all accounts and cards of this replica's user. The
  /// caller decides which of them a bulk category update may change.
  Future<List<TransactionEntity>> sameMerchantTransactions({
    required String rawMerchant,
    String? excludeTransactionId,
  });

  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required Money amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  });

  Future<void> deleteTransaction(String id);

  /// يعيد ربط العملية بحساب آخر (بدون تغيير باقي الحقول).
  /// [origin] declares WHO caused this. A background repair must pass
  /// `systemRepair` so it cannot be recorded as a user correcting the parse —
  /// `AccountCurrencyRepairService` backfills orphaned rows at every boot.
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
    ProofEditOrigin origin = ProofEditOrigin.user,
  });

  /// يربط العملية ببطاقة (آخر 4 أرقام)، أو يفصلها عند null.
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  });

  /// يحدّث مبلغ العملية بعملة الحساب — يُستخدم لتسعير عملية أجنبية «بانتظار
  /// التسعير» (amount = 0) بقيمتها المحلية التي يدخلها المستخدم.
  Future<void> updateAmount({
    required String transactionId,
    required Money amount,
  });

  // ── قراءة (Sprint 3) ──

  /// أحدث العمليات (تتجاهل المُلغاة) — للـ Dashboard.
  /// [accountId] لتصفية حساب محدد (null = كل الحسابات).
  Future<List<TransactionEntity>> getRecent({int limit = 5, String? accountId});

  /// كل العمليات (تتجاهل المُلغاة) مرتّبة بالأحدث — لشاشة العمليات.
  Future<List<TransactionEntity>> getAll();

  /// صفحة واحدة من العمليات مرتبة بالأحدث. [offset] صفري و[limit] حد أعلى.
  Future<List<TransactionEntity>> getPage(
      {required int offset, int limit = 500});

  /// B2-C — the instant of the most recent BANK-source capture
  /// (`MAX(COALESCE(sms_received_at, created_at))` where `source = 'bank'`), or
  /// null if there are none. A bounded aggregate for the capture-health provider
  /// (was a whole-ledger `getAll()` + Dart max).
  Future<DateTime?> latestBankCaptureAt();

  /// B2-C — the distinct non-empty currencies present across ALL transactions
  /// (bounded: the result is the small set of currencies, never the ledger). Used
  /// to ensure a per-currency account exists without loading every transaction.
  Future<List<String>> distinctCurrencies();

  /// B2-C — a keyset page of transactions with NO account assigned, newest first
  /// (`occurred_at DESC, id DESC`). Used by the dashboard's account backfill so it
  /// touches only the (normally empty, post-backfill) null-account set instead of
  /// the whole ledger. Pass the previous page's last row via [beforeOccurredAt]/
  /// [beforeId] for the next page.
  Future<List<TransactionEntity>> transactionsWithoutAccount({
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  });

  /// B2-C — a keyset-paged, SQL-**filtered** slice of the transaction list.
  /// Every supported filter (account / date / kind / category / search /
  /// pending) is pushed into the SQL predicate, so the first visible page never
  /// loads the full history and never loads-then-discards in Dart. Ordering is
  /// `occurred_at DESC, id DESC` (stable for equal timestamps). Pass the previous
  /// page's last row as [after] for the next page — never OFFSET.
  Future<List<TransactionEntity>> getTransactionPage({
    required int limit,
    TransactionPageCursor? after,
    TransactionPageFilter filter,
  });

  /// صافي المصروفات (payment + withdrawal - refund) خلال فترة نصف-مفتوحة
  /// `[from, to)` — الحد الأعلى غير شامل (MALI-028). لحساب «وفّرت» وعنوان
  /// شاشة العمليات (MALI-047n). المؤكّد فقط؛ الاسترداد يخصم؛ التحويل/unknown
  /// خارج المجموع؛ الحسابات المستبعَدة تُستثنى فقط عند `accountId == null`.
  Future<Money> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  /// UX-022 — the REFUND component of [expenseTotalBetween], as a positive
  /// magnitude, over the same window and scope.
  ///
  /// Reports must be able to show `gross − refunds = net` without changing the
  /// netting contract, which is correct and centrally documented. This reports
  /// an input to that contract; it does not alter it.
  Future<Money> refundTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  /// إجمالي الدخل خلال فترة نصف-مفتوحة `[from, to)` (MALI-028) — يُعرض في
  /// Dashboard/العمليات ولا يستهلك الميزانيات. الاسترداد ليس دخلاً.
  Future<Money> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  /// آخر رصيد معروف من رسائل البنك، إن وُجد.
  Future<Money?> latestBalanceAfter({String? accountId});

  /// إجمالي المصروف والدخل مجمّعاً حسب العملة خلال فترة نصف-مفتوحة `[from, to)`
  /// (MALI-028) — لعرض «كل الحسابات» دون جمع عملات مختلفة تحت وسم واحد.
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  });

  /// صرف يومي خلال فترة — يستخدم للرسم البياني في Insights.
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  /// تفصيل الإنفاق الصافي لكل تصنيف خلال فترة نصف-مفتوحة `[from, to)`
  /// (MALI-028) — لـ «أين ذهبت أموالك» ولمجاميع تصنيفات الرئيسية (MALI-050n).
  /// نفس السياسة الموحّدة: المؤكّد فقط، الاسترداد يخصم، استبعاد الحسابات
  /// المُعلَّمة عند `accountId == null`. عند تمرير [currency] يُقصر التجميع على
  /// تلك العملة فقط (لتقارير «كل الحسابات» متعددة العملات — MALI-063n)، فلا
  /// تُجمع عملات مختلفة تحت مجموع واحد.
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  Future<Money> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  });

  /// أكثر المتاجر صرفاً خلال فترة — للتقارير.
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    required String currency,
    int limit = 3,
    String? accountId,
  });

  /// أكبر [limit] مصروفات (payment/withdrawal مؤكّدة) داخل النافذة نصف-المفتوحة
  /// `[from, to)`، مرتّبة تنازليًا بالمبلغ، عبر SQL `ORDER BY ... LIMIT` — لا يُحمّل
  /// الجدول كاملًا في Dart. يطبّق نفس سياسة استبعاد الحسابات المُعلَّمة
  /// `exclude_from_totals` في النطاق الكلّي، والملكية الدقيقة لحساب بعينه.
  Future<List<TransactionEntity>> largestExpenses({
    required DateTime from,
    required DateTime to,
    String? accountId,
    int limit = 10,
  });

  /// صفحة KEYSET من العمليات المؤكّدة داخل `[from, to)` مرتّبة `(occurred_at DESC,
  /// id DESC)`. عند تمرير مؤشّر `(before*)` تُعيد ما بعده فقط — بلا `OFFSET` — فلا
  /// تكرار أو فقدان صف بين الصفحات، وتبقى ذاكرة كل صفحة محدودة بـ [limit]. نفس
  /// سياسة استبعاد الحسابات الكلّية/ملكية حساب بعينه كالمجاميع. للملحق (appendix).
  Future<List<TransactionEntity>> confirmedInRangePage({
    required DateTime from,
    required DateTime to,
    String? accountId,
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  });

  /// اشتراكات متكررة مُكتشَفة (نفس المتجر بمبلغ متقارب عبر ≥2 أشهر).
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId});

  /// ملخّص لكل بطاقة (آخر 4 أرقام + الشبكة + الداخل/الخارج).
  Future<List<CardSummary>> getCardSummaries();

  /// صفوف تجميعية لكل (آخر 4 أرقام، حساب) — أساس ربط البطاقة بحسابها بثقة.
  /// قراءة فقط؛ لا يكتب account_id.
  Future<List<CardAccountBreakdownRow>> getCardAccountBreakdown();

  /// عمليات بطاقة محددة (بآخر 4 أرقام) مرتّبة بالأحدث.
  Future<List<TransactionEntity>> getByCard(String last4);
}
