import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/glass_sheet.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../domain/entities/account_entity.dart';
import '../transactions_providers.dart';

/// The account (and so currency) picker behind the Activity filters and the
/// bills summary scope chip. Viewing an account is UI/filter state only.
Future<void> showAccountScopeSheet(
  BuildContext context,
  WidgetRef ref,
  String currentId,
) {
  final c = context.colors;
  final container = ProviderScope.containerOf(context, listen: false);
  final accounts = ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
  return showGlassSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => navySheetTheme(Directionality(
      textDirection: Directionality.of(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                context.l10n.txnPickAccount,
                style: AppTypography.sectionTitle(c.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            for (final account in accounts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  AppLucideIcons.walletCards,
                  color: account.id == currentId ? c.cta : c.textMuted,
                ),
                title: Text(account.name),
                subtitle: Text(Currency.label(context, account.currency)),
                trailing: account.id == currentId
                    ? Icon(AppLucideIcons.checkCircle, color: c.cta)
                    : null,
                onTap: () async {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).pop();
                  // F-020: viewing an account is UI/filter state only — it
                  // must NOT call setDefault() (persistent preference +
                  // server command). The explicit make-default action lives
                  // in the account form sheet.
                  container.read(activeAccountIdProvider.notifier).state =
                      account.id;
                  container.invalidate(accountsProvider);
                  container.invalidate(baseCurrencyProvider);
                  container.invalidate(transactionsListProvider);
                  container.invalidate(billsViewProvider);
                },
              ),
          ],
        ),
      ),
    )),
  );
}
