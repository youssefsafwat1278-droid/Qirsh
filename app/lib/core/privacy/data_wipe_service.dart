import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../di/app_providers.dart';

/// حذف كل البيانات المالية المحلية والشخصية (Privacy → «حذف كل بياناتي»،
/// وتسجيل الخروج العادي — انظر AppSession.signOut).
///
/// يمسح كل بيانات المستخدم المرتبطة بالهوية الحالية: العمليات، الحسابات،
/// الميزانيات، الأهداف، الاشتراكات، الخطط، صندوق الوارد الذكي، بيانات الملف
/// الشخصي (user_settings)، وكل طوابير المزامنة/الالتقاط المحلية حتى لا تُرفع
/// لاحقاً باسم مستخدم آخر على نفس الجهاز. لا يمسح كتالوج التصنيفات/البنوك/
/// المحلّلات (بيانات مرجعية عامة، ليست شخصية). الحساب/الجلسة تُمسح عبر
/// AppSession. الجداول ذات الصف الوحيد (user_settings, streaks, xp_levels)
/// تُعاد بذرتها فوراً بعد المسح عبر reseedDefaultsAfterWipe.
class DataWipeService {
  DataWipeService(this._db);

  final AppDatabase _db;

  /// Every table `wipeAll` empties outright. Exposed so a test can assert the
  /// schema has no unclassified table silently escaping the wipe (MALI-011).
  /// `categories` is not here — it is special-cased below (custom rows only).
  static const List<String> wipedTables = [
    'transactions',
    'accounts',
    'cards',
    'goal_contributions',
    'goals',
    'budgets',
    'merchant_category_map',
    // Deletion history of saved category rules (schema v44): which merchants'
    // rules the user removed, the backup rules still waiting for their choice,
    // and how far back the history reaches. Personal (merchant names). Listed
    // AFTER merchant_category_map on purpose: emptying that table is recorded
    // as removals by its triggers, and those must not outlive the wipe. (The
    // `rule_history_wipe` trigger on user_settings clears them again at the end
    // whatever the order.)
    'merchant_rule_tombstones',
    'merchant_rule_restore_choices',
    'merchant_rule_history',
    // Verified merchant aliases are the user's own confirmations.
    'merchant_aliases',
    'merchants',
    'subscriptions',
    'bill_payments',
    'plans',
    'plan_transaction_links',
    'smart_inbox_items',
    'suspected_duplicates',
    'sender_bank_mappings',
    'dedup_hashes',
    'ledger_sync_outbox',
    'planning_sync_outbox',
    'sync_cursors',
    'parked_child_rows',
    // WP-5 — durable conflict snapshots hold the user's own edit and the cloud
    // version of a record: financial data, so a wipe removes them too.
    'sync_conflicts',
    'engagement_events',
    'pending_merchant_feedback',
    'financial_cache_health',
    // PHASE 8 — durable capture work items hold derived model output keyed to a
    // captured message. They are operational recovery state, not user data, and
    // must not survive sign-out/account change as an orphan record of a message
    // the previous owner asked to be forgotten.
    'capture_work_items',
    // PHASE 9A — review labels are derived from a user's own captures. They are
    // evidence about this person's corrections and must not survive a
    // sign-out/account change into the next owner's session.
    'capture_review_labels',
    // Proof shadow observations are derived from the user's captures. They hold
    // no amounts or message text, but they are a record that THIS user's
    // messages were evaluated, so a wipe must remove them like any other
    // capture-derived data. Diagnostics do not get a privacy exemption.
    'proof_shadow_evaluations',
    // Correctness provenance is derived from the user's own review actions on
    // their own captures. It holds no amounts and no message text, but it is a
    // record of what they did, so a wipe removes it like any other
    // capture-derived data.
    'proof_correction_events',
    // COUPONS Phase 3 + 4 — both are user-scoped. A click receipt is a
    // credential for one person's click and a savings entry is a statement
    // about their spending; the next account on this device must inherit
    // neither.
    'affiliate_click_receipts',
    'local_offer_savings',
    // MALI-014 Batch-5 — the durable restore-operation journal is per-session
    // recovery state; clear it on sign-out/account change so a previous owner's
    // restore operations never carry into the next session (MALI-011).
    'restore_operations',
    // User-scoped operational rows that used to survive sign-out and leak into
    // the next user's session on this device (the SQLCipher key and DB file are
    // reused across users, so an unwiped table is readable as-is): the previous
    // user's statement/CSV import outcomes and their notification history.
    'financial_import_runs',
    'notification_log_events',
    'achievements',
    'streaks',
    'xp_levels',
    'user_settings',
  ];

  Future<void> wipeAll() async {
    // MALI-011: the wipe must be ATOMIC. A crash mid-loop previously left a
    // partially-deleted database that the owner gate would then treat as
    // "owned" once the owner uid was (re)claimed — leaking one user's residue
    // into the next session. Wrapping the deletes + reseed in one transaction
    // makes the wipe all-or-nothing.
    await _db.transaction(() async {
      for (final table in wipedTables) {
        await _db.customStatement('DELETE FROM $table;');
      }
      // Recovery provenance belongs to the deleted settings, not the retained
      // device version frontier.
      await _db.customStatement('UPDATE consent_version_watermark '
          'SET seed_source_fingerprint = NULL;');
      // Built-in categories are catalog data and remain available. Custom rows
      // belong to the signed-out user and must not leak into the next session.
      await _db.customStatement('''
        DELETE FROM categories
        WHERE key LIKE 'custom_%'
           OR server_id IS NOT NULL
           OR sync_status IS NOT NULL;
      ''');
      await _db.reseedDefaultsAfterWipe();
    });
  }
}

final dataWipeServiceProvider = Provider<DataWipeService>((ref) {
  return DataWipeService(ref.watch(appDatabaseProvider));
});
