import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';

/// أحدث عمليات حساب محدد — لعرضها في شاشة تفاصيل الحساب. قراءة فقط.
final accountRecentTransactionsProvider =
    FutureProvider.family<List<TransactionEntity>, String>(
        (ref, accountId) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref
      .watch(transactionRepositoryProvider)
      .getRecent(limit: 20, accountId: accountId);
});

/// Decision 3.14: the latest balance a bank message reported for this account,
/// with the time of that message (null when no message carried a balance).
final accountReportedBalanceProvider =
    FutureProvider.family<ReportedBalance?, String>((ref, accountId) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref
      .watch(transactionRepositoryProvider)
      .latestReportedBalance(accountId: accountId);
});
