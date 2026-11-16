// Offline presentation fixtures only. Never imported by lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/features/help/coach_marks.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/features/settings/sync_status_providers.dart';
import 'package:money_companion/features/settings/sync_status_ui.dart';
import 'package:money_companion/core/theme/widgets/glass_sheet.dart';
import 'package:money_companion/core/theme/widgets/navy_sheet_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart' show TransactionEntity;
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';

const visualParityLocalReadSurfaceKeys = [
  'localReadPresentation',
  'localReadLoading',
  'localReadError',
  'localReadLogoutError',
  'coachMarks',
  'syncStatusAllSynced',
  'syncStatusSyncing',
  'syncStatusWaiting',
  'syncStatusConsentOff',
  'syncStatusSignedOut',
  'syncStatusFailed',
  'syncStatusNeedsAttention',
  'syncStatusBreakdown',
  'changeCategorySaving',
  'changeCategoryError',
];
final _events = <String, int>{};
Map<String, int> visualParityLocalReadEvents() => Map.unmodifiable(_events);

void _record(String name) => _events.update(name, (value) => value + 1,
    ifAbsent: () => 1);

void _open(Future<Object?> future) {
  unawaited(future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
    FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack,
        library: 'Qirsh offline presentation fixture'));
  }));
}

Future<bool> openVisualParityLocalReadSurface(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityLocalReadSurfaceKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('local_read_visual_requires_offline_debug');
  }
  final databases = await ref.read(appDatabaseProvider)
      .customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('local_read_visual_requires_memory_database');
  }
  if (!context.mounted) return false;
  if (key == 'changeCategorySaving' || key == 'changeCategoryError') {
    // Read an existing synthetic row; this fixture never seeds or updates it.
    final db = ref.read(appDatabaseProvider);
    final transaction = await ref.read(transactionRepositoryProvider)
        .getById(visualParityChangeCategoryTransactionId);
    final categories = await ref.read(categoryRepositoryProvider).getAll();
    if (transaction == null || transaction.rawMerchant == null ||
        categories.length < 2) {
      throw StateError('change_category_visual_requires_seeded_transaction_and_catalog');
    }
    if (!context.mounted) return false;
    final outerNavigator = Navigator.of(context);
    final repository = _ChangeCategoryOutcomeRepository(db, key);
    final catalog = CategoryCatalog(categories,
        languageCode: Localizations.localeOf(context).languageCode);
    _open(outerNavigator.push<void>(MaterialPageRoute<void>(builder: (_) =>
      ProviderScope(overrides: [
        transactionRepositoryProvider.overrideWithValue(repository),
        // Scope the real use case's normal dependency construction to this
        // Navigator. Its only altered operation is updateCategory below.
        correctCategoryUseCaseProvider.overrideWith((ref) => CorrectCategoryUseCase(
          transactionRepository: ref.watch(transactionRepositoryProvider),
          merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
          recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
          merchantIntelligence: ref.watch(merchantIntelligenceProvider),
        )),
      ], child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => _ChangeCategoryLauncher(transaction: transaction,
          catalog: catalog, onClosed: () {
            _record('${key}Closed');
            if (outerNavigator.mounted) outerNavigator.pop();
          }),
      ))))));
    return true;
  }
  if (key.startsWith('syncStatus')) {
    // Presentation values only. No identity, consent, queue, ACK or recovery
    // service is constructed. The native driver must never tap Retry here.
    final status = switch (key) {
      'syncStatusAllSynced' => SyncStatus(kind: SyncStatusKind.allSynced,
          lastSuccessAt: DateTime(2026, 10, 29, 12, 30)),
      'syncStatusSyncing' => const SyncStatus(kind: SyncStatusKind.syncing,
          count: 3, waitingForConnection: 3),
      'syncStatusWaiting' => const SyncStatus(kind: SyncStatusKind.waiting,
          count: 7, waitingForConnection: 4, waitingForServer: 3),
      'syncStatusConsentOff' => const SyncStatus(kind: SyncStatusKind.consentOff,
          count: 9),
      'syncStatusSignedOut' => const SyncStatus(kind: SyncStatusKind.signedOut,
          count: 9),
      'syncStatusFailed' => const SyncStatus(kind: SyncStatusKind.failed,
          count: 2, needsAttention: 2, stayFailed: 1),
      'syncStatusNeedsAttention' => const SyncStatus(
          kind: SyncStatusKind.needsAttention, count: 2, needsAttention: 2),
      _ => SyncStatus(kind: SyncStatusKind.failed, count: 12,
          waitingForConnection: 4, waitingForServer: 3,
          needsAttention: 5, stayFailed: 2,
          lastSuccessAt: DateTime(2026, 10, 29, 12, 30)),
    };
    _open(showGlassSheet<void>(context: context, isScrollControlled: true,
      showDragHandle: true, builder: (_) => ProviderScope(overrides: [
        syncStatusProvider.overrideWith((ref) async {
          _record('${key}PresentationRead');
          return status;
        }),
      ], child: navySheetTheme(const SyncStatusSheet()))));
    return true;
  }
  if (key == 'coachMarks') {
    // The exposed test wrapper renders the actual production tour. The real
    // once-only entry point persists to AppSession, so it is not invoked here.
    _open(showDialog<void>(context: context, builder: (_) =>
        CoachMarkTourForTest(marks: dashboardCoachMarks(context)))
        .then((_) => _record('coachMarksPresentationClosed')));
    return true;
  }
  _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => ProviderScope(overrides: [
      localReadSnapshotProvider.overrideWith((ref) async {
        _record('${key}SnapshotRead');
        if (key == 'localReadLoading') {
          return Completer<LocalReadSnapshot>().future;
        }
        if (key == 'localReadError') {
          throw StateError('synthetic_local_read_snapshot_failure');
        }
        return const LocalReadSnapshot([
            LocalReadAccountRow('Synthetic savings', 'EGP', '1250.00'),
          ], [
            LocalReadTransactionRow(id: 'synthetic-local-read-tx',
                title: 'Carrefour', amount: '59.95', currency: 'EGP',
                isDebit: true, occurredAt: '2026-10-17T12:00:00Z'),
          ]);
      }),
    ], child: LocalReadShell(
      onReconnect: () => _record('localReadReconnectPresentationCallback'),
      onLogout: () async {
        if (key == 'localReadLogoutError') {
          _record('localReadLogoutFailurePresentationCallback');
          throw StateError('synthetic_local_read_logout_failure');
        }
        _record('localReadLogoutPresentationCallback');
      },
    )),
  )));
  // No AccountScope, admission, stored proof, authentication, logout service,
  // or consent capability is created or exercised by this presentation route.
  return true;
}

const visualParityChangeCategoryTransactionId = 'p-tx-0-0';

class _ChangeCategoryOutcomeRepository extends DriftTransactionRepository {
  _ChangeCategoryOutcomeRepository(AppDatabase database, this.key) : super(database);
  final String key;

  @override
  Future<TransactionEntity> updateCategory({required String transactionId,
      required String categoryKey, bool appliedByRule = false}) {
    if (transactionId != visualParityChangeCategoryTransactionId) {
      throw StateError('change_category_visual_unexpected_transaction');
    }
    _record('${key}CorrectionAttempt');
    return key == 'changeCategorySaving'
        ? Completer<TransactionEntity>().future
        : Future<TransactionEntity>.error(
            StateError('synthetic_category_repository_failure'));
  }
}

class _ChangeCategoryLauncher extends StatefulWidget {
  const _ChangeCategoryLauncher({required this.transaction, required this.catalog,
    required this.onClosed});
  final TransactionEntity transaction;
  final CategoryCatalog catalog;
  final VoidCallback onClosed;

  @override
  State<_ChangeCategoryLauncher> createState() => _ChangeCategoryLauncherState();
}

class _ChangeCategoryLauncherState extends State<_ChangeCategoryLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _open(showChangeCategorySheet(context, widget.transaction, widget.catalog)
          .then<void>((_) {
            if (mounted) widget.onClosed();
          }));
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
