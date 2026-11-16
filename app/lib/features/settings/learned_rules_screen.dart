import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../common/app_empty_state.dart';
import '../common/app_error_state.dart';
import '../common/app_loading_state.dart';
import '../common/app_avatar.dart';
import '../common/category_catalog.dart';
import 'widgets/settings_v2.dart';

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
    final l10n = context.l10n;
    final c = context.colors;
    final rules = ref.watch(learnedRulesProvider);
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    return SettingsV2Page(
      title: l10n.setLearnedRules,
      subtitle: l10n.setLearnedRulesSub,
      children: [
        ...rules.when(
          loading: () => [
            const SizedBox(height: AppSpacing.s8),
            const AppLoadingState(),
          ],
          error: (_, __) => [
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(
              title: l10n.lrLoadFailed,
              description: l10n.lrActionFailed,
              onRetry: () => ref.invalidate(learnedRulesProvider),
            ),
          ],
          data: (list) => list.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        AppSpacing.gutter,
                        MediaQuery.sizeOf(context).height * 0.08,
                        AppSpacing.gutter,
                        0),
                    child: AppEmptyState(
                      icon: AppLucideIcons.tag,
                      title: l10n.lrEmptyTitle,
                      subtitle: l10n.lrEmptyBody,
                    ),
                  ),
                ]
              : [
                  const SizedBox(height: AppSpacing.s5),
                  settingsV2Enter(
                    0,
                    SettingsV2Group(children: [
                      for (final rule in list)
                        _ruleRow(context, ref, c, rule,
                            catalog?.byKey(rule.categoryKey)),
                    ]),
                  ),
                ],
        ),
      ],
    );
  }

  /// A v2 row: the category's own tile, the merchant, the category it is
  /// remembered as, and a trailing delete (undo follows in a snackbar).
  Widget _ruleRow(BuildContext context, WidgetRef ref, AppColors c,
      LearnedMerchantRule rule, CategoryView? category) {
    return SettingsV2Row(
      key: ValueKey('learned-rule-${rule.rawMerchant}'),
      leading:
          AppAvatar.category(category: category, size: AppSpacing.avatarSm),
      title: rule.rawMerchant,
      subtitle: category?.name ?? rule.categoryKey,
      showChevron: false,
      trailing: IconButton(
        tooltip: context.l10n.lrDelete,
        icon: Icon(AppLucideIcons.trash2, size: 20, color: c.danger),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: () => _delete(context, ref, rule),
      ),
    );
  }
}
