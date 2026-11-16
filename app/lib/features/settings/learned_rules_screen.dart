import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../common/app_empty_state.dart';
import '../common/app_error_state.dart';
import '../common/app_header.dart';
import '../common/category_catalog.dart';

/// Only the merchant rules the user confirmed ("Remember for this merchant").
final learnedRulesProvider =
    FutureProvider.autoDispose<List<LearnedMerchantRule>>(
        (ref) => ref.watch(learnedRulesUseCaseProvider).list());

/// Settings → Learned rules: each rule the user taught, with delete and undo.
class LearnedRulesScreen extends ConsumerWidget {
  const LearnedRulesScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LearnedRulesScreen()),
    );
  }

  /// [context] must be the SCREEN's context: the row's own context is gone
  /// once the row is deleted, but undo still needs to refresh the list.
  Future<void> _delete(
      BuildContext context, WidgetRef ref, LearnedMerchantRule rule) async {
    final useCase = ref.read(learnedRulesUseCaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await useCase.delete(rule);
    } catch (_) {
      if (context.mounted) AppToast.showError(context, l10n.lrActionFailed);
      return;
    }
    ref.invalidate(learnedRulesProvider);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(l10n.lrDeleted),
      action: SnackBarAction(
        label: l10n.lrUndo,
        onPressed: () async {
          try {
            await useCase.restore(rule);
          } catch (_) {
            if (context.mounted) {
              AppToast.showError(context, l10n.lrActionFailed);
            }
            return;
          }
          if (context.mounted) ref.invalidate(learnedRulesProvider);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final rules = ref.watch(learnedRulesProvider);
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppHeader(title: context.l10n.setLearnedRules),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => AppErrorState(
          title: context.l10n.lrLoadFailed,
          description: context.l10n.lrActionFailed,
          onRetry: () => ref.invalidate(learnedRulesProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.tag,
              title: context.l10n.lrEmptyTitle,
              subtitle: context.l10n.lrEmptyBody,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            itemCount: list.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: c.border),
            itemBuilder: (_, i) {
              final rule = list[i];
              final CategoryView? category = catalog?.byKey(rule.categoryKey);
              return ListTile(
                key: ValueKey('learned-rule-${rule.rawMerchant}'),
                contentPadding: EdgeInsets.zero,
                title: Text(rule.rawMerchant,
                    style: AppTypography.body(c.textMain)),
                subtitle: Text(category?.name ?? rule.categoryKey,
                    style: AppTypography.caption(c.textLight)),
                trailing: IconButton(
                  tooltip: context.l10n.lrDelete,
                  icon: Icon(AppLucideIcons.trash2, color: c.textLight),
                  onPressed: () => _delete(context, ref, rule),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
