import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'tx-detail-small';
  @override
  Future<String?> readStoredKey() async => 'tx-detail-small';
}

// UX-10 / UX-05: transaction details on a 320x568 screen at the app's
// maximum text scale (1.25x, `app.dart`) — no RenderFlex overflow, the
// «Change category» pill shows its whole label and is a 44 pt target.
void main() {
  for (final language in ['ar', 'en']) {
   for (final size in const [Size(320, 568), Size(375, 667)]) {
    testWidgets('details fits $size at 1.25x in $language', (tester) async {
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(top: 20);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final loader = FontLoader('Vazirmatn');
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
        }
        await loader.load();
      });
      final now = DateTime(2026, 1, 15, 10, 30);
      final tx = TransactionEntity(
        id: 'small-tx', amountMoney: Money(8750, 'SAR'), currency: 'SAR',
        accountId: 'own', rawMerchant: 'Synthetic Cafe',
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.unknown,
        occurredAt: now, rawMessage: '', parseConfidence: 1,
        status: TransactionStatus.confirmed, createdAt: now, updatedAt: now,
      );
      final db = (await tester.runAsync(() async {
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
        await DriftAccountRepository(db).create(AccountEntity(
          id: 'own', name: 'Synthetic account', currency: 'SAR',
          type: AccountType.bank, isDefault: true, sortOrder: 0,
          createdAt: now, updatedAt: now,
        ));
        await DriftTransactionRepository(db)
            .saveTransaction(transaction: tx, categoryKey: 'groceries');
        return db;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(db.close);
      });
      final catalog = CategoryCatalog(const [
        CategoryEntity(id: 'cat', key: 'groceries', nameAr: 'بقالة',
            icon: 'shopping-cart', color: '#16A37F', isIncome: false, sort: 0),
      ], languageCode: language);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          transactionRepositoryProvider
              .overrideWithValue(DriftTransactionRepository(db)),
          transactionByIdProvider(tx.id).overrideWith((ref) async => tx),
          categoryCatalogProvider.overrideWith((ref) async => catalog),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.25)),
            child: child!,
          ),
          home: const TransactionDetailsScreen(transactionId: 'small-tx'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow at 320x568, 1.25x');

      final l10n = AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
      final label = find.text(l10n.txnChangeCategory);
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse, reason: 'the whole «Change category» label is visible');
      final pill = find.ancestor(of: label, matching: find.byType(InkWell)).first;
      expect(tester.getSize(pill).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });
   }
  }
}
