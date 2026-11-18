import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/merchant_rule_restore.dart';
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
import '../common/app_loading_state.dart';
import '../common/app_avatar.dart';
import '../common/category_catalog.dart';
import 'widgets/settings_v2.dart';

/// Only the merchant rules the user confirmed ("Remember for this merchant").
final learnedRulesProvider =
    FutureProvider.autoDispose<List<LearnedMerchantRule>>(
        (ref) => ref.watch(learnedRulesUseCaseProvider).list());

/// Backup rules a restore left for the user's choice (see
/// MerchantRuleRestore). They are not rules until the user adds them.
final ruleRestoreChoicesProvider =
    FutureProvider.autoDispose<List<RuleRestoreChoice>>((ref) =>
        MerchantRuleRestore(ref.watch(appDatabaseProvider)).pending());

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

  /// Adds (through the ordinary "remember" path, so the rule is queued for
  /// the cloud and the on-device model learns it) or leaves out each of
  /// [choices]. A choice that cannot be added is skipped and stays listed.
  Future<void> _decide(
      BuildContext context, WidgetRef ref, List<RuleRestoreChoice> choices,
      {required bool add}) async {
    final store = MerchantRuleRestore(ref.read(appDatabaseProvider));
    final useCase = ref.read(learnedRulesUseCaseProvider);
    final l10n = context.l10n;
    try {
      for (final choice in choices) {
        if (add && !choice.canAdd) continue;
        await store.decide(
          choice.merchantKey,
          add: add,
          save: (merchant, categoryKey) => useCase.restore(LearnedMerchantRule(
              rawMerchant: merchant, categoryKey: categoryKey)),
        );
      }
    } catch (_) {
      if (context.mounted) AppToast.showError(context, l10n.lrActionFailed);
    }
    ref.invalidate(ruleRestoreChoicesProvider);
    ref.invalidate(learnedRulesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final rules = ref.watch(learnedRulesProvider);
    // Nothing is shown while these load or on a read failure: the rules list
    // below reports its own state, and the choices stay stored.
    final pending = ref.watch(ruleRestoreChoicesProvider).valueOrNull ??
        const <RuleRestoreChoice>[];
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    return SettingsV2Page(
      title: l10n.setLearnedRules,
      subtitle: l10n.setLearnedRulesSub,
      children: [
        if (pending.isNotEmpty) ...[
          SettingsV2Label(l10n.lrRestoreCount(pending.length)),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.gutter + 4, 0, AppSpacing.gutter + 4, 0),
            child: Text(l10n.lrRestoreExplanation,
                style: AppTypography.caption(c.textMuted)),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Wrap(
              spacing: AppSpacing.s2,
              children: [
                TextButton(
                  key: const ValueKey('restore-rules-add-all'),
                  onPressed: pending.any((r) => r.canAdd)
                      ? () => _decide(context, ref, pending, add: true)
                      : null,
                  child: Text(l10n.lrRestoreAddAll),
                ),
                TextButton(
                  key: const ValueKey('restore-rules-leave-all'),
                  onPressed: () => _decide(context, ref, pending, add: false),
                  child: Text(l10n.lrRestoreLeaveAll),
                ),
              ],
            ),
          ),
          SettingsV2Group(children: [
            for (final choice in pending)
              _choiceRow(context, ref, choice,
                  catalog?.byKey(choice.categoryKey)),
          ]),
        ],
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

  /// A rule waiting for the user's choice: the merchant, the category the
  /// backup remembered it as, and Add / Leave out.
  Widget _choiceRow(BuildContext context, WidgetRef ref,
      RuleRestoreChoice choice, CategoryView? category) {
    final l10n = context.l10n;
    final name = category?.name ?? choice.categoryKey;
    return SettingsV2Row(
      key: ValueKey('restore-rule-${choice.merchantKey}'),
      leading:
          AppAvatar.category(category: category, size: AppSpacing.avatarSm),
      title: choice.merchant,
      subtitle:
          choice.canAdd ? name : '$name\n${l10n.lrRestoreMissingCategory}',
      showChevron: false,
      valueWidget: Wrap(
        children: [
          TextButton(
            onPressed: choice.canAdd
                ? () => _decide(context, ref, [choice], add: true)
                : null,
            child: Text(l10n.lrRestoreAdd),
          ),
          TextButton(
            onPressed: () => _decide(context, ref, [choice], add: false),
            child: Text(l10n.lrRestoreLeave),
          ),
        ],
      ),
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
