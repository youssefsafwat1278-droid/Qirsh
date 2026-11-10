import '../../../core/sync/sync_health.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/account_fence_store.dart';
import 'dart:convert';

import '../../../core/sync/outbox_operation_id.dart';

import '../../../core/sync/conflict_policy.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/outbox_owner.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_repository_support.dart'
    show userSettingsFromRow;
import '../../../domain/entities/account_entity.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../../domain/entities/card_entity.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/category_entity.dart';
import '../../../domain/entities/goal_entity.dart';
import '../../../domain/entities/plan_entity.dart';
import '../../../domain/entities/supporting_entities.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';

enum PlanningSyncOperation { create, update, delete }

/// مفتاح تفعيل الجيل الثاني من مزامنة البطاقات (حساب اختياري + تصميم مخصّص).
///
/// خامل الآن (`false`): البطاقات بلا حساب تبقى محلية فقط، وحقول التصميم
/// (color_theme/accent_hex) لا تُرسَل — لأن جدول `user_cards` على Supabase ما
/// زال يفرض `local_account_id NOT NULL` ولا يملك عمودَي التصميم.
///
/// للتفعيل: انشر `supabase/migrations/0064_user_cards_optional_account_and_design.sql`
/// ثم اضبط هذا العلم على `true` — عندها تُزامَن البطاقات غير المخصّصة والتصميم.
const bool kUserCardsCloudV2 = false;

class PlanningOutboxItem {
  const PlanningOutboxItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.attemptCount,
    this.opSeq = 0,
    this.operationId,
    this.baseRevision,
    this.ownerUid,
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String entityType;
  final String entityId;
  final PlanningSyncOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;

  /// A-2 (G3): the row's edit counter when it was read; an ACK only consumes the
  /// row while it still matches (an edit folded in flight keeps it pending).
  final int opSeq;

  /// WP-5: the operation receipt id (server `last_op_id`); regenerated on every
  /// edit of the row, reused by retries of the same op_seq.
  final String? operationId;

  /// WP-5: the server revision the edit was made against (CAS base).
  final int? baseRevision;

  /// Operation ids this row carried earlier while possibly on the wire.
  List<String> get priorOpIds => priorOpIdsOf(payloadJson);

  /// A-2 (G18): the local-data owner the row was recorded for (null = legacy).
  final String? ownerUid;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class PlanningOutboxQueue {
  PlanningOutboxQueue({
    required AppDatabase db,
    required bool Function(String entityType) isSyncEnabled,
    required Future<String?> Function() getAuthUserId,
    // A-2 (G18/G5): the LOCAL DATA OWNER uid (AppSession's owner marker); rows
    // are stamped with it and intent is recorded whenever it exists, even with
    // no live session. Defaults to [getAuthUserId].
    Future<String?> Function()? getOwnerUid,
    void Function()? onQueued,
    // MALI-026 (B8-2.10 §10): the money-authority mode. Legacy (v29 today)
    // emits the current JSON-number wire shape; canonical emits the exact
    // decimal STRING. Defaults to legacy, so today's payloads are byte-identical.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _isSyncEnabled = isSyncEnabled,
        _getAuthUserId = getAuthUserId,
        _getOwnerUid = getOwnerUid ?? getAuthUserId,
        _onQueued = onQueued,
        _coordinator = coordinator;

  static const String accountsEntityType = 'account';
  static const String budgetsEntityType = 'budget';
  static const String subscriptionsEntityType = 'subscription';
  static const String goalsEntityType = 'goal';
  static const String plansEntityType = 'plan';
  static const String cardsEntityType = 'card';
  static const String categoriesEntityType = 'category';
  static const String settingsEntityType = 'settings';
  static const String billPaymentsEntityType = 'bill_payment';
  static const String goalContributionsEntityType = 'goal_contribution';
  static const String planLinksEntityType = 'plan_transaction_link';

  /// MALI-055n — a dedicated default-account command (NOT an account field
  /// mutation). It carries only the target account + an operation id, so a
  /// default switch never rewrites unrelated account fields. Written under a
  /// singleton entity id so successive switches coalesce to the latest target.
  static const String accountDefaultCommandType = 'account_default_command';
  static const String _accountDefaultCommandKey = '__current__';

  /// معرّف محلي ثابت للإعدادات (singleton) — نفسه على كل الأجهزة، فيُصبح صف
  /// user_settings واحدًا لكل مستخدم على الخادم (يلتقي عبر الأجهزة).
  static const String settingsLocalId = 'user_settings';

  final AppDatabase _db;
  final bool Function(String entityType) _isSyncEnabled;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getOwnerUid;
  final void Function()? _onQueued;
  final PlanningCutoverCoordinator _coordinator;

  Future<bool> enqueueAccount(
    PlanningSyncOperation op,
    AccountEntity account,
  ) {
    // Route through _enqueue (like every other parent entity) so the payload
    // carries the server_updated_at + server_revision base tokens (MALI-022 /
    // 0068). Previously accounts wrote the outbox directly with NO base token,
    // so the push could only blindly overwrite the remote row.
    return _enqueue(
      entityType: accountsEntityType,
      entityId: account.id,
      op: op,
      table: 'accounts',
      payload: _buildAccountPayload(op, account),
    );
  }

  /// MALI-055n — queue the single default-account command. It rewrites NO
  /// account fields; the push resolves it to the atomic `set_default_account`
  /// server RPC (which demotes the old default + promotes the target in one
  /// transaction). [operationId] gives the command a stable identity for
  /// idempotent replay. Written under a singleton key so switching A→B→C
  /// coalesces to a single command for the latest target.
  Future<bool> enqueueAccountDefault(
    String targetLocalId,
    String operationId,
  ) async {
    final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
    if (intent == null) return false;
    await _writeOutbox(
      ownerUid: intent.ownerUid,
      entityType: accountDefaultCommandType,
      entityId: _accountDefaultCommandKey,
      opName: PlanningSyncOperation.update.name,
      payload: {
        'target_local_id': targetLocalId,
        'operation_id': operationId,
      },
      // No local row to flag — the caller has already set is_default locally.
      localUpdateSql: 'UPDATE accounts SET id = id WHERE 1 = 0;',
    );
    return true;
  }

  Future<bool> enqueueBudget(
    PlanningSyncOperation op,
    BudgetEntity budget,
  ) async {
    // A tombstone is matched on local_id; its category is irrelevant, so a
    // dangling reference must not block the delete from propagating.
    final categoryWireId = op == PlanningSyncOperation.delete
        ? (await _categoryWireId(budget) ?? budget.categoryId)
        : await _categoryWireId(budget);
    // Fail CLOSED on the wire: the only value we could send for an unresolved
    // category is the per-device local id — precisely the value whose arrival on
    // the server silently re-categorises this budget to `other` on every other
    // device. So it is NEVER put in the payload. A-2 (G5): the intent is still
    // recorded, PARKED `dependency_wait` with an empty category; the push cycle
    // fills it in and unparks once the category resolves. A delete needs no
    // category, so it is resolved above.
    return _enqueue(
      entityType: budgetsEntityType,
      entityId: budget.id,
      op: op,
      table: 'budgets',
      payload: _buildBudgetPayload(op, budget, categoryWireId),
      parkReason: categoryWireId == null ? kParkDependencyWait : null,
    );
  }

  /// F-029 — the server `category_id` column carries the STABLE category key
  /// ('groceries', …): the budgets pull resolves it via
  /// `categories WHERE key IN (…)`. Pushing the local Drift id corrupted that
  /// column — another device's pull cannot resolve an opaque per-device id and
  /// silently re-categorises the budget to `other`. Map id → key at enqueue
  /// time; the sentinel travels as its key form.
  ///
  /// Returns null when the category cannot be resolved (dangling FK). It
  /// deliberately does NOT fall back to the raw local id: that is the exact
  /// value that corrupts the server column, so sending it would re-create the
  /// bug in the one case where we already know the value is wrong. Callers
  /// fail closed instead.
  Future<String?> _categoryWireId(BudgetEntity budget) async {
    if (budget.isAllExpenses) return BudgetEntity.allExpensesCategoryKey;
    final row = await _db
        .customSelect(
          'SELECT key FROM categories '
          'WHERE id = ${sqlString(budget.categoryId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('key');
  }

  Future<bool> enqueueSubscription(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    return _enqueue(
      entityType: subscriptionsEntityType,
      entityId: bill.id,
      op: op,
      table: 'subscriptions',
      payload: _buildSubscriptionPayload(op, bill),
    );
  }

  Future<bool> enqueueGoal(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    return _enqueue(
      entityType: goalsEntityType,
      entityId: goal.id,
      op: op,
      table: 'goals',
      payload: _buildGoalPayload(op, goal),
    );
  }

  Future<bool> enqueuePlan(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    return _enqueue(
      entityType: plansEntityType,
      entityId: plan.id,
      op: op,
      table: 'plans',
      payload: _buildPlanPayload(op, plan),
    );
  }

  Future<bool> enqueueBillPayment(
    PlanningSyncOperation op,
    BillPaymentEntity payment,
  ) {
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);

    return _enqueue(
      entityType: billPaymentsEntityType,
      entityId: payment.id,
      // WP-5: immutable child — an edit is never an `update` (replay = create).
      op: op == PlanningSyncOperation.update ? PlanningSyncOperation.create : op,
      table: 'bill_payments',
      payload: _withDelete(op, {
        'local_id': payment.id,
        'local_subscription_id': payment.billId,
        'local_transaction_id': payment.transactionId,
        'amount': amountWire(payment.amountMoney),
        'currency': payment.currency,
        'period_start': payment.periodStart.toUtc().toIso8601String(),
        'period_end': payment.periodEnd.toUtc().toIso8601String(),
        'paid_at': payment.paidAt.toUtc().toIso8601String(),
        'installment_index': payment.installmentIndex,
        'note': payment.note,
      }),
    );
  }

  Future<bool> enqueueGoalContribution(
    PlanningSyncOperation op,
    GoalContributionEntity contribution,
  ) {
    // MALI-026 (B8-3 §7): canonical contribution push is exact — amount → decimal
    // STRING. The contribution carries no currency of its own; the parent goal is
    // the server-side currency authority (§10). Legacy keeps the JSON number.
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    return _enqueue(
      entityType: goalContributionsEntityType,
      entityId: contribution.id,
      // WP-5: immutable child — an edit is never an `update` (replay = create).
      op: op == PlanningSyncOperation.update ? PlanningSyncOperation.create : op,
      table: 'goal_contributions',
      payload: _withDelete(op, {
        'local_id': contribution.id,
        'local_goal_id': contribution.goalId,
        'amount': amountWire(contribution.amountMoney),
        'created_at': contribution.createdAt.toUtc().toIso8601String(),
        'note': contribution.note,
      }),
    );
  }

  Future<bool> enqueuePlanLink(
    PlanningSyncOperation op, {
    required String planId,
    required String transactionId,
    required DateTime createdAt,
  }) async {
    final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
    if (intent == null) return false;
    final entityId = '$planId:$transactionId';
    final payload = _withDelete(op, {
      'local_plan_id': planId,
      'local_transaction_id': transactionId,
      'created_at': createdAt.toUtc().toIso8601String(),
    });
    await _writeOutbox(
      ownerUid: intent.ownerUid,
      entityType: planLinksEntityType,
      entityId: entityId,
      opName: op.name,
      payload: payload,
      localUpdateSql: "UPDATE plan_transaction_links SET sync_status = 'pending' "
          'WHERE plan_id = ${sqlString(planId)} '
          'AND transaction_id = ${sqlString(transactionId)};',
    );
    return true;
  }

  /// إدراج بطاقة في طابور المزامنة. حارس [kUserCardsCloudV2]: قبل نشر ترقية
  /// Supabase، البطاقات بلا حساب لا تُدرَج (عمود الخادم `local_account_id`
  /// NOT NULL) — تبقى محلية فقط. البطاقات المربوطة بحساب تُزامَن كالمعتاد.
  Future<bool> enqueueCard(
    PlanningSyncOperation op,
    CardEntity card,
  ) {
    final accountless = !kUserCardsCloudV2 && card.accountId == null;
    if (accountless && op == PlanningSyncOperation.delete) {
      return _enqueueAccountlessCardDelete(card);
    }
    // A-2 (G5): an accountless card cannot reach the server yet, but its intent
    // is recorded, parked `dependency_wait` until an account exists.
    return _enqueue(
      entityType: cardsEntityType,
      entityId: card.id,
      op: op,
      table: 'cards',
      payload: _buildCardPayload(op, card),
      parkReason: accountless ? kParkDependencyWait : null,
    );
  }

  /// Deleting an accountless card: if it never reached the server there is
  /// nothing remote to delete, so any row parked waiting for its account is
  /// dropped — but ONLY when it was provably never on the wire (D-6: a parked
  /// row keeps its durable `in_flight_seq` marker, so a create whose ack was
  /// lost is converted into a delete instead). If it DID sync earlier the
  /// tombstone is a normal delete.
  Future<bool> _enqueueAccountlessCardDelete(CardEntity card) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM cards WHERE id = ${sqlString(card.id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row?.readNullable<String>('server_id') == null) {
      final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
      final ownerSql = outboxOwnerMatchSql(intent?.ownerUid);
      await _db.customStatement(
        'DELETE FROM planning_sync_outbox '
        'WHERE entity_type = ${sqlString(cardsEntityType)} '
        'AND entity_id = ${sqlString(card.id)} '
        "AND status = 'parked' AND failure_class = '$kParkDependencyWait' "
        'AND in_flight_seq IS NULL AND $ownerSql;',
      );
      final possiblySent = await _db
          .customSelect(
            'SELECT 1 AS x FROM planning_sync_outbox '
            'WHERE entity_type = ${sqlString(cardsEntityType)} '
            'AND entity_id = ${sqlString(card.id)} '
            'AND in_flight_seq IS NOT NULL AND $ownerSql LIMIT 1;',
          )
          .getSingleOrNull();
      if (possiblySent == null) return false;
    }
    return _enqueue(
      entityType: cardsEntityType,
      entityId: card.id,
      op: PlanningSyncOperation.delete,
      table: 'cards',
      payload: _buildCardPayload(PlanningSyncOperation.delete, card),
    );
  }

  /// إدراج تفضيلات المستخدم (singleton) في طابور المزامنة. تُرسَل الأعمدة
  /// السحابية فقط — لا مفتاح تشفير، لا مسار أفاتار، لا بيانات ملف شخصي.
  Future<bool> enqueueSettings(
    PlanningSyncOperation op,
    UserSettingsEntity settings, {
    bool consentChanged = false,
    // WP-5: the settings before this write, so the push can send only the
    // fields this device changed (per-field last-writer-wins). Null = unknown:
    // every non-consent field is treated as changed.
    UserSettingsEntity? previous,
  }) async {
    // Updates are only valid once the local singleton is bound to the server
    // row (server_id attached by the first pull / registration push). Before
    // that, a local settings write is post-wipe reseeded DEFAULTS — automatic
    // writers (e.g. the notification history store) fire within seconds of
    // sign-in, and pushing that update would clobber the user's real cloud
    // settings before the first pull restores them (observed in production:
    // country/currency reset to SA/SAR). Creates stay allowed only for the
    // post-pull registration bootstrap (a genuinely new user).
    //
    // Audit NEW-H-3: an explicit pre-bind CONSENT change is durable user intent
    // and must reach the server — but it must NEVER travel as a full settings
    // row. The engine pushes before it pulls, so a full-row upsert built from
    // this device's post-wipe defaults would overwrite the user's real cloud
    // settings and null their profile columns. The revocation is therefore
    // queued as a CONSENT-ONLY create: the push layer sends just the consent
    // columns (a PostgREST merge-upsert touches only the provided columns) and
    // deliberately does not bind the row, so the guard above keeps protecting
    // every other pre-bind write until a genuine pull merges the remote state.
    var effectiveOp = op;
    var consentOnly = false;
    if (effectiveOp == PlanningSyncOperation.update) {
      final bound = await _db
          .customSelect('SELECT server_id FROM user_settings LIMIT 1;')
          .getSingleOrNull();
      if (bound?.readNullable<String>('server_id') == null) {
        if (!consentChanged) {
          // Automatic writers must still not upload freshly reseeded defaults.
          // A-2 (G5): the intent is NOT dropped — it is parked `dependency_wait`
          // and unparked once the singleton is bound; at that point the payload
          // is rebuilt from the then-current local row (never from this stale
          // pre-bind snapshot) and carries no consent columns.
          return _enqueue(
            entityType: settingsEntityType,
            entityId: settings.id,
            op: effectiveOp,
            table: 'user_settings',
            payload: _buildSettingsPayload(settings),
            parkReason: kParkDependencyWait,
          );
        }
        effectiveOp = PlanningSyncOperation.create;
        consentOnly = true;
      }
    }
    final payload = consentOnly
        ? _buildConsentOnlyPayload(settings)
        : _buildSettingsPayload(settings);
    if (!consentOnly) {
      payload['changed_fields'] =
          _changedSettingsFields(payload, previous, consentChanged);
    }
    return _enqueue(
      entityType: settingsEntityType,
      entityId: settings.id,
      op: effectiveOp,
      table: 'user_settings',
      payload: payload,
    );
  }

  /// Audit NEW-H-3 — the narrow pre-bind consent payload. It carries ONLY the
  /// consent authority columns (cloud is the master gate, so cloud OFF also
  /// forces AI OFF, mirroring [_buildSettingsPayload]) plus the singleton key.
  /// No profile/theme/currency/country field may ever appear here: this payload
  /// is upserted while the local row still holds fresh-device defaults, and a
  /// merge-upsert writes every provided column.
  Map<String, dynamic> _buildConsentOnlyPayload(UserSettingsEntity s) {
    final cloudConsent = s.cloudProcessingEnabled;
    return <String, dynamic>{
      'local_id': settingsLocalId,
      'consent_only': true,
      'ai_consent_granted': cloudConsent && s.aiConsentGranted,
      'cloud_processing_enabled': cloudConsent,
      'consent_version': s.consentVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// WP-5: keys of [payload] that differ from [previous], plus `consent` when
  /// the user explicitly changed consent. Consent keys never count as ordinary
  /// field changes (consent is excluded from last-writer-wins).
  List<String> _changedSettingsFields(
    Map<String, dynamic> payload,
    UserSettingsEntity? previous,
    bool consentChanged,
  ) {
    const meta = {'local_id', 'updated_at', 'changed_fields'};
    const consent = {
      'ai_consent_granted',
      'cloud_processing_enabled',
      'consent_version',
    };
    final before = previous == null ? null : _buildSettingsPayload(previous);
    return [
      for (final e in payload.entries)
        if (!meta.contains(e.key) &&
            !consent.contains(e.key) &&
            (before == null || before[e.key] != e.value))
          e.key,
      if (consentChanged) 'consent',
    ];
  }

  Map<String, dynamic> _buildSettingsPayload(UserSettingsEntity s) {
    final cloudConsent = s.cloudProcessingEnabled;
    return <String, dynamic>{
      'local_id': settingsLocalId,
      // Profile fields sync too (migration 0063) — otherwise the sign-out
      // wipe destroys the user's name/phone/birth date permanently. The
      // avatar stays device-local (it is a file path, not a column).
      'display_name': s.displayName,
      'phone_number': s.phoneNumber,
      'date_of_birth': s.dateOfBirth?.toUtc().toIso8601String(),
      'theme': s.theme,
      'currency': s.currency,
      'language': s.language,
      'country': s.country,
      'input_method': s.inputMethod,
      'notifications_json': s.notificationsJson,
      'privacy_mode_enabled': s.privacyModeEnabled,
      // user_settings is the JWT endpoint's server-side consent authority.
      // Cloud is the master gate, so a cloud revocation clears both grants on
      // the server even when the device keeps an accepted AI preference.
      // Include these on CREATE too: an explicit local choice made before the
      // singleton is bound must not be replaced by the server defaults. This
      // does not change those defaults; it only carries the user's actual state.
      'ai_consent_granted': cloudConsent && s.aiConsentGranted,
      'cloud_processing_enabled': cloudConsent,
      // WP-6: the proof of an explicit grant. The server counts a TRUE only with
      // consent_version > 0 (0109); the client's own versioned choice is the only
      // source, never anything pulled.
      'consent_version': s.consentVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<bool> _enqueue({
    required String entityType,
    required String entityId,
    required PlanningSyncOperation op,
    required String table,
    required Map<String, dynamic> payload,
    String? parkReason,
  }) async {
    // A-2 (G5): record intent whenever a local owner identity exists (even with
    // no live session / sync flag off). Only a true guest stays local-only.
    final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
    if (intent == null) return false;

    return _enqueueFixedIntent(intent.ownerUid, entityType: entityType,
        entityId: entityId, op: op, table: table, payload: payload, parkReason: parkReason);
  }

  Future<bool> _enqueueFixedIntent(String? ownerUid, {required String entityType,
      required String entityId, required PlanningSyncOperation op,
      required String table, required Map<String, dynamic> payload, String? parkReason,
      bool notify = true}) async {
    // MALI-022: snapshot the last-known server version as an optimistic base
    // token, so the push can detect a concurrent remote edit and conflict
    // instead of blindly overwriting it (mirrors the ledger's server_updated_at
    // token, MALI-009). Null for a never-synced row → the push does a create.
    // MALI-022 / 0068 — snapshot the CAS base revision alongside the timestamp
    // token, so the push can do an atomic compare-and-set when the capability is
    // on. Only revision-CAS entities have a `server_revision` column — append-
    // only children (bill_payment/goal_contribution) do not, so we must not
    // SELECT it for them. A null revision is carried as absent → the push falls
    // back to the guarded timestamp compare, never a blind overwrite.
    final readsRevision = kConflictPolicies[entityType]?.mechanism ==
        ConflictMechanism.revisionCas;
    final cols =
        readsRevision ? 'server_updated_at, server_revision' : 'server_updated_at';
    final baseRow = await _db
        .customSelect(
          'SELECT $cols FROM $table WHERE id = ${sqlString(entityId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final baseToken = baseRow?.readNullable<String>('server_updated_at');
    final baseRevision =
        readsRevision ? baseRow?.readNullable<int>('server_revision') : null;
    final enriched = <String, dynamic>{
      ...payload,
      if (baseToken != null) 'server_updated_at': baseToken,
      if (baseRevision != null) 'server_revision': baseRevision,
    };

    await _writeOutbox(
      ownerUid: ownerUid,
      entityType: entityType,
      entityId: entityId,
      opName: op.name,
      payload: enriched,
      baseRevision: baseRevision,
      // A settings row parked for its bind must NOT flip to 'pending': the pull
      // treats a pending settings row as a conflict and would refuse to merge
      // the remote state that binds it.
      localUpdateSql: entityType == settingsEntityType &&
              parkReason == kParkDependencyWait
          ? 'UPDATE $table SET id = id WHERE 1 = 0;'
          : "UPDATE $table SET sync_status = 'pending' WHERE id = ${sqlString(entityId)};",
      parkReason: parkReason,
      notify: notify,
    );
    return true;
  }

  /// MALI-052n: coalescing writer shared by every planning enqueue path — folds
  /// an incoming op into an existing PENDING row for the same (entity_type,
  /// entity_id) so consecutive offline edits become one row (one base token,
  /// no self-conflict), then marks the local row pending.
  Future<void> _writeOutbox({
    required String? ownerUid,
    required String entityType,
    required String entityId,
    required String opName,
    required Map<String, dynamic> payload,
    required String localUpdateSql,
    String? parkReason,
    int? baseRevision,
    bool notify = true,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      // Coalesce into a PENDING row, or one parked by the A-2 self-healing layer
      // (never in flight). Every coalesce bumps op_seq (A-2 G3).
      //
      // D-9: only a row recorded for the SAME owner. D-2: a settings write never
      // folds into (or out of) a pre-bind `consent_only` row — that row is the
      // deliverable consent revocation and must keep its narrow payload; the
      // other write is queued as its own row. (A NON-parked full-row write,
      // i.e. the post-bind requeue, carries the consent columns itself and may
      // still fold in; only a write that is parked dependency_wait — whose
      // payload is later rebuilt consent-free — must stay separate.)
      final incomingConsentOnly = payload['consent_only'] == true;
      final consentOnlyClause = entityType != settingsEntityType
          ? ''
          : incomingConsentOnly
              ? "AND payload_json LIKE '%\"consent_only\":true%'"
              : parkReason != null
              ? "AND payload_json NOT LIKE '%\"consent_only\":true%'"
              : '';
      final existing = await _db.customSelect(
        'SELECT id, operation, status, failure_class, in_flight_seq, operation_id, payload_json FROM planning_sync_outbox '
        'WHERE entity_type = ${sqlString(entityType)} '
        'AND entity_id = ${sqlString(entityId)} '
        "AND ($kOutboxCoalescibleSql OR (entity_type IN ('account','account_default_command','budget','subscription','goal','plan','card','category','settings','goal_contribution','bill_payment','plan_transaction_link') AND status = 'parked' AND failure_class = '$kParkAccountDeletionGone')) AND ${outboxOwnerMatchSql(ownerUid)} "
        '$consentOnlyClause ORDER BY created_at ASC LIMIT 1;',
      ).getSingleOrNull();
      String rowId;
      var deletionHeld = false;
      if (existing != null) {
        rowId = existing.read<String>('id');
        deletionHeld = existing.read<String>('status') == 'parked' &&
            (existing.readNullable<String>('failure_class') == kParkAccountDeletionPending ||
                ((_childTypes.contains(entityType) || _parentTypes.contains(entityType) || entityType == accountsEntityType || entityType == accountDefaultCommandType) &&
                existing.readNullable<String>('failure_class') == kParkAccountDeletionGone));
        final coalesced =
            coalesceOutboxOperation(existing.read<String>('operation'), opName);
        // WP-5: a NEW operation id for the edited row; the previous one is
        // remembered only if it may already have reached the server.
        if (entityType == settingsEntityType) {
          // Per-field LWW: the folded row must still send every field ANY of
          // its edits changed.
          final old = (jsonDecode(existing.read<String>('payload_json')) as Map)
              .cast<String, dynamic>();
          final merged = {
            ...((old['changed_fields'] as List?) ?? const []).cast<String>(),
            ...((payload['changed_fields'] as List?) ?? const []).cast<String>(),
          };
          if (payload.containsKey('changed_fields') ||
              old.containsKey('changed_fields')) {
            payload['changed_fields'] = merged.toList();
          }
        }
        withPriorOpIds(
          payload,
          existingPayloadJson: existing.read<String>('payload_json'),
          previousOpId: existing.readNullable<String>('operation_id'),
          possiblySent: existing.readNullable<int>('in_flight_seq') != null,
        );
        if (!deletionHeld && coalesced == null &&
            existing.readNullable<int>('in_flight_seq') == null) {
          // Never on the wire (never handed to a push — the durable
          // in_flight_seq marker is NULL; D-6: parking alone never proves it was
          // not sent): create+delete truly cancels.
          await _db.customStatement(
            'DELETE FROM planning_sync_outbox WHERE id = ${sqlString(rowId)};',
          );
          await _db.customStatement(localUpdateSql);
          return;
        }
        // A-2 (G3): a create cancelled by a delete while IN FLIGHT is never
        // dropped — it becomes a delete, resolved by the push (confirmed-absent
        // is ACKed, a row that landed is tombstoned).
        await _db.customStatement('''
          UPDATE planning_sync_outbox
          SET operation = ${sqlString(coalesced ?? 'delete')},
              payload_json = ${sqlString(jsonEncode(payload))},
              attempt_count = ${deletionHeld ? 'attempt_count' : '0'},
                status = ${sqlString(deletionHeld ? 'parked' : 'pending')},
                failure_class = ${sqlNullableString(deletionHeld ? existing.readNullable<String>('failure_class') : null)},
              last_error = NULL, next_retry_at = NULL,
              op_seq = op_seq + 1,
              operation_id = ${sqlString(IdGenerator.uuidV4())},
              base_revision = ${baseRevision ?? 'NULL'},
              owner_uid = COALESCE(owner_uid, ${sqlNullableString(ownerUid)}),
              updated_at = ${sqlString(now)}
          WHERE id = ${sqlString(rowId)};
        ''');
      } else {
        rowId = IdGenerator.next();
        await _db.customStatement('''
          INSERT INTO planning_sync_outbox(
            id, entity_type, entity_id, operation, payload_json,
            attempt_count, status, created_at, updated_at, op_seq, owner_uid,
            operation_id, base_revision
          ) VALUES (
            ${sqlString(rowId)}, ${sqlString(entityType)},
            ${sqlString(entityId)}, ${sqlString(opName)},
            ${sqlString(jsonEncode(payload))}, 0, 'pending',
            ${sqlString(now)}, ${sqlString(now)},
            1, ${sqlNullableString(ownerUid)},
            ${sqlString(IdGenerator.uuidV4())}, ${baseRevision ?? 'NULL'}
          );
        ''');
      }
      if (parkReason != null && !deletionHeld) {
        await _db.customStatement('''
          UPDATE planning_sync_outbox
          SET status = 'parked', failure_class = ${sqlString(parkReason)}
          WHERE id = ${sqlString(rowId)};
        ''');
      }
      await _db.customStatement(localUpdateSql);
    });
    if (notify && parkReason == null && _isSyncEnabled(entityType)) _onQueued?.call();
  }

  /// D-1: SQL predicate true for an outbox row whose (user-resolved) entity is in
  /// `sync_status = 'conflict'`. Deterministic prefer-remote entities (settings,
  /// cards, categories) are excluded: they auto-resolve, and a consent
  /// revocation on settings must stay deliverable.
  static final String _conflictHeldSql = [
    for (final p in kConflictPolicies.values)
      if (p.isInteractive && p.outbox == OutboxKind.planning)
        "(entity_type = '${p.entityType}' AND EXISTS ("
            'SELECT 1 FROM ${p.localTable} t '
            "WHERE t.id = planning_sync_outbox.entity_id "
            "AND t.sync_status = 'conflict'))",
  ].join(' OR ');

  Future<List<PlanningOutboxItem>> pendingItems({
    String? entityType,
    int limit = 50,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final entityClause =
        entityType == null ? '' : 'AND entity_type = ${sqlString(entityType)}';
    // A-3: hand-out and the durable "possibly sent" marker are ONE transaction.
    final rows = await _db.transaction(() async {
      final picked = await _db.customSelect('''
        SELECT id, entity_type, entity_id, operation, payload_json,
               attempt_count, last_error, next_retry_at, op_seq, owner_uid,
               operation_id, base_revision
        FROM planning_sync_outbox
        WHERE status = 'pending'
          AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
          $entityClause
          -- D-1: an entity awaiting the user's conflict resolution is not pushed.
          AND NOT ($_conflictHeldSql)
        ORDER BY created_at ASC
        LIMIT $limit;
      ''').get();
      for (final row in picked) {
        await _db.customStatement(
          'UPDATE planning_sync_outbox SET in_flight_seq = op_seq, '
          // WP-5: rows queued before v41 get their operation id before send.
          'operation_id = COALESCE(operation_id, ${sqlString(IdGenerator.uuidV4())}) '
          'WHERE id = ${sqlString(row.read<String>('id'))};',
        );
      }
      return [
        for (final row in picked)
          (
            row,
            await _db
                .customSelect(
                    'SELECT operation_id FROM planning_sync_outbox WHERE id = '
                    '${sqlString(row.read<String>('id'))};')
                .getSingle()
                .then((r) => r.read<String>('operation_id'))
          ),
      ];
    });
    return rows.map((pair) {
      final row = pair.$1;
      final opStr = row.read<String>('operation');
      final op = PlanningSyncOperation.values.firstWhere(
        (e) => e.name == opStr,
        orElse: () => PlanningSyncOperation.update,
      );
      final retryStr = row.readNullable<String>('next_retry_at');
      return PlanningOutboxItem(
        id: row.read<String>('id'),
        entityType: row.read<String>('entity_type'),
        entityId: row.read<String>('entity_id'),
        operation: op,
        payloadJson:
            (jsonDecode(row.read<String>('payload_json')) as Map).cast(),
        attemptCount: row.read<int>('attempt_count'),
        opSeq: row.read<int>('op_seq'),
        operationId: pair.$2,
        baseRevision: row.readNullable<int>('base_revision'),
        ownerUid: row.readNullable<String>('owner_uid'),
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  /// A-2 (G3): ACK [item]. The row is deleted ONLY while its `op_seq` still
  /// equals the pushed one. If the entity was edited while the push was in
  /// flight the edit was folded into this same row: it stays pending, carrying
  /// the version this ACK produced as its new base token (the entity row already
  /// holds the server id), and the caller must NOT mark the entity synced.
  /// Returns true when the row was consumed.
  Future<bool> acknowledge(
    PlanningOutboxItem item, {
    String? serverUpdatedAt,
    int? serverRevision,
  }) {
    return _db.transaction(() async {
      final deleted = await _db.customUpdate(
        'DELETE FROM planning_sync_outbox '
        'WHERE id = ${sqlString(item.id)} AND op_seq = ${item.opSeq};',
      );
      if (deleted > 0) return true;
      final row = await _db
          .customSelect(
            'SELECT payload_json FROM planning_sync_outbox '
            'WHERE id = ${sqlString(item.id)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (row == null) return false;
      final payload = (jsonDecode(row.read<String>('payload_json')) as Map)
          .cast<String, dynamic>();
      // D-1: replace the base tokens ONLY when this ACK produced new ones; a
      // token-less ACK (conflict / idempotent delete) keeps the existing base so
      // the next push can never blind-overwrite another device's edit.
      if (serverUpdatedAt != null) {
        payload['server_updated_at'] = serverUpdatedAt;
      }
      if (serverRevision != null) {
        payload['server_revision'] = serverRevision;
      }
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET payload_json = ${sqlString(jsonEncode(payload))},
            ${serverRevision != null ? 'base_revision = $serverRevision,' : ''}
            attempt_count = 0, next_retry_at = NULL, in_flight_seq = NULL,
            updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(item.id)};
      ''');
      return false;
    });
  }

  /// WP-5: nothing was written (stale epoch) — the row is simply not in flight.
  Future<void> releaseInFlight(String id) => _db.customStatement(
      'UPDATE planning_sync_outbox SET in_flight_seq = NULL '
      'WHERE id = ${sqlString(id)};');

  /// ACK without a server version to carry (conflict/abandon/idempotent delete).
  Future<bool> markSuccess(PlanningOutboxItem item) => acknowledge(item);

  /// A-2 (G18): park rows recorded for another owner / unverified legacy rows,
  /// and re-arm the ones whose owner is the current identity again. Runs at the
  /// start of every push cycle, so nothing is ever sent under a different uid.
  Future<bool> ownershipVerified(String currentUid) =>
      isOutboxOwnerVerified(_getOwnerUid, currentUid);

  Future<void> reconcileVerifiedOwnership(String currentUid, bool verified) =>
      reconcileOutboxOwnership(db: _db, table: 'planning_sync_outbox',
          currentUid: currentUid, ownershipVerified: verified);

  Future<void> reconcileOwnership(String currentUid) async {
    await reconcileVerifiedOwnership(currentUid, await ownershipVerified(currentUid));
  }

  /// A-2 (G5): re-evaluate rows parked `dependency_wait` and unpark the ones
  /// whose dependency now resolves — settings once the singleton is bound
  /// (payload rebuilt from the current local row, without consent columns),
  /// budgets once their category resolves, cards once they have an account.
  /// Runs at the start of every push cycle. Returns the number unparked.
  Future<int> resolveDependencies() async {
    final parked = await _db.customSelect('''
      SELECT id, entity_type, entity_id, payload_json FROM planning_sync_outbox
      WHERE status = 'parked' AND failure_class = '$kParkDependencyWait';
    ''').get();
    var unparked = 0;
    for (final row in parked) {
      final id = row.read<String>('id');
      final entityId = row.read<String>('entity_id');
      final payload = (jsonDecode(row.read<String>('payload_json')) as Map)
          .cast<String, dynamic>();
      final patched = switch (row.read<String>('entity_type')) {
        settingsEntityType => await _resolveSettingsDependency(entityId),
        budgetsEntityType => await _resolveBudgetDependency(entityId, payload),
        cardsEntityType => await _resolveCardDependency(entityId, payload),
        _ => null,
      };
      if (patched == null) continue;
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET payload_json = ${sqlString(jsonEncode(patched))},
            status = 'pending', failure_class = NULL, attempt_count = 0,
            next_retry_at = NULL, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)} AND status = 'parked'
          AND failure_class = '$kParkDependencyWait';
      ''');
      unparked++;
    }
    if (unparked > 0) _onQueued?.call();
    return unparked;
  }

  Future<Map<String, dynamic>?> _resolveSettingsDependency(
      String entityId) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM user_settings WHERE id = ${sqlString(entityId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null || row.readNullable<String>('server_id') == null) {
      return null;
    }
    final payload = _buildSettingsPayload(userSettingsFromRow(row))
      // Consent is device-local authority and travels only through the explicit
      // consent paths — a deferred automatic write must never carry it.
      ..remove('ai_consent_granted')
      ..remove('cloud_processing_enabled');
    final updatedAt = row.readNullable<String>('server_updated_at');
    final revision = row.readNullable<int>('server_revision');
    if (updatedAt != null) payload['server_updated_at'] = updatedAt;
    if (revision != null) payload['server_revision'] = revision;
    return payload;
  }

  Future<Map<String, dynamic>?> _resolveBudgetDependency(
      String entityId, Map<String, dynamic> payload) async {
    final budget = await _db
        .customSelect(
          'SELECT category_id FROM budgets WHERE id = ${sqlString(entityId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final categoryId = budget?.readNullable<String>('category_id');
    if (categoryId == null) return null;
    final cat = await _db
        .customSelect(
          'SELECT key FROM categories WHERE id = ${sqlString(categoryId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final key = cat?.readNullable<String>('key');
    if (key == null) return null;
    return {...payload, 'category_id': key};
  }

  Future<Map<String, dynamic>?> _resolveCardDependency(
      String entityId, Map<String, dynamic> payload) async {
    final card = await _db
        .customSelect(
          'SELECT account_id FROM cards WHERE id = ${sqlString(entityId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final accountId = card?.readNullable<String>('account_id');
    if (accountId == null) return null;
    return {...payload, 'local_account_id': accountId};
  }

  /// The same queued snapshot must still own the mutation before every retry.
  Future<bool> accountFenceCurrent(PlanningOutboxItem item) async {
    final row = await _db.customSelect(
      "SELECT 1 FROM planning_sync_outbox WHERE id = ${sqlString(item.id)} "
      "AND status = 'pending' AND op_seq = ${item.opSeq} "
      "AND in_flight_seq = ${item.opSeq} "
      "AND operation_id = ${sqlNullableString(item.operationId)} "
      "AND owner_uid IS ${sqlNullableString(item.ownerUid)};").getSingleOrNull();
    return row != null;
  }

  static const _parentTypes = {'budget', 'subscription', 'goal', 'plan',
      'card', 'category', 'settings'};

  Future<bool> parentHolderCurrent(PlanningOutboxItem item) async {
    if (!_parentTypes.contains(item.entityType)) return false;
    return await _db.customSelect("SELECT 1 FROM planning_sync_outbox "
      "WHERE id = ${sqlString(item.id)} AND status = 'pending' "
      "AND entity_type = ${sqlString(item.entityType)} AND entity_id = ${sqlString(item.entityId)} "
      "AND owner_uid IS ${sqlNullableString(item.ownerUid)} "
      "AND in_flight_seq = ${item.opSeq};").getSingleOrNull() != null;
  }

  Future<bool> parkParentDenial(PlanningOutboxItem item, AccountFenceState state,
      AccountFenceParentParking ticket) async {
    ticket.requireExact(_db, rowId: item.id, entityType: item.entityType,
        entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
        operationId: item.operationId, state: state);
    return await _db.customUpdate("""
      UPDATE planning_sync_outbox SET status = 'parked',
        failure_class = ${sqlString(state == AccountFenceState.pending
            ? kParkAccountDeletionPending : kParkAccountDeletionGone)},
        last_error = NULL, next_retry_at = NULL,
        updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(item.id)} AND status = 'pending'
        AND entity_type = ${sqlString(item.entityType)} AND entity_id = ${sqlString(item.entityId)}
        AND owner_uid IS ${sqlNullableString(item.ownerUid)} AND in_flight_seq = ${item.opSeq};
    """) > 0;
  }

  static const _childTypes={'goal_contribution','bill_payment','plan_transaction_link'};
  Future<bool> childHolderCurrent(PlanningOutboxItem item) async {
    if (!_childTypes.contains(item.entityType)) return false;
    return await _db.customSelect("SELECT 1 FROM planning_sync_outbox "
      "WHERE id = ${sqlString(item.id)} AND status = 'pending' "
      "AND entity_type = ${sqlString(item.entityType)} AND entity_id = ${sqlString(item.entityId)} "
      "AND owner_uid IS ${sqlNullableString(item.ownerUid)} "
      "AND in_flight_seq = ${item.opSeq};").getSingleOrNull() != null;
  }

  Future<bool> parkChildDenial(PlanningOutboxItem item, AccountFenceState state,
      AccountFenceChildParking ticket) async {
    ticket.requireExact(_db, rowId: item.id, entityType: item.entityType,
        entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
        operationId: item.operationId, state: state);
    return await _db.customUpdate("""
      UPDATE planning_sync_outbox SET status = 'parked',
        failure_class = ${sqlString(state == AccountFenceState.pending
            ? kParkAccountDeletionPending : kParkAccountDeletionGone)},
        last_error = NULL, next_retry_at = NULL,
        updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(item.id)} AND status = 'pending'
        AND entity_type = ${sqlString(item.entityType)} AND entity_id = ${sqlString(item.entityId)}
        AND owner_uid IS ${sqlNullableString(item.ownerUid)} AND in_flight_seq = ${item.opSeq};
    """) > 0;
  }

  /// Every dependency rebuild is a separate, original-bound local transaction.
  Future<int> resolveParentDependencies(AccountFenceAuthority authority,
      AccountFenceHandle handle, SyncPhaseBinding phase) async {
    void check() {
      if (!phase.isCurrent || !identical(phase.database, _db)) throw const StaleAdmissionException();
      authority.requireCurrentForDatabase(handle, _db);
    }
    check();
    final candidates = await authority.runCurrentLocal(handle, _db, () => _db.customSelect(
      "SELECT id FROM planning_sync_outbox WHERE status = 'parked' "
      "AND failure_class = '$kParkDependencyWait';").get());
    check();
    var changed = 0;
    for (final candidate in candidates) {
      check();
      changed += await authority.runCurrentLocal(handle, _db, () => _db.transaction(() async {
        final id = candidate.read<String>('id');
        final row = await _db.customSelect("SELECT entity_type, entity_id, payload_json FROM planning_sync_outbox "
            "WHERE id = ${sqlString(id)} AND status = 'parked' AND failure_class = '$kParkDependencyWait' "
            "AND (owner_uid IS NULL OR owner_uid = ${sqlString(authority.ownerUid(handle))});").getSingleOrNull();
        if (row == null || !_parentTypes.contains(row.read<String>('entity_type'))) return 0;
        final payload = (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
        final entity = row.read<String>('entity_id');
        final patched = switch (row.read<String>('entity_type')) {
          settingsEntityType => await _resolveSettingsDependency(entity),
          budgetsEntityType => await _resolveBudgetDependency(entity, payload),
          cardsEntityType => await _resolveCardDependency(entity, payload),
          _ => null,
        };
        if (patched == null) return 0;
        return _db.customUpdate("UPDATE planning_sync_outbox SET payload_json = ${sqlString(jsonEncode(patched))}, "
            "status = 'pending', failure_class = NULL, attempt_count = 0, next_retry_at = NULL, "
            "updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))} WHERE id = ${sqlString(id)};");
      }));
    }
    check();
    if (changed > 0) _onQueued?.call();
    return changed;
  }

  /// Rebuild registration payload from the actual current row, atomically with
  /// eligibility and fixed-owner enqueue. No async owner reader enters the unit.
  Future<bool> enqueueRegisteredParent(AccountFenceAuthority authority,
      AccountFenceHandle handle, {required String entityType, required String entityId,
      required bool settingsPullCompleted, required SyncPhaseBinding phase}) async {
    void check() {
      if (phase.isBound && (!phase.isCurrent || !identical(phase.database, _db))) {
        throw const StaleAdmissionException();
      }
      authority.requireCurrentForDatabase(handle, _db);
    }
    check();
    final changed = await authority.runCurrentLocal(handle, _db,
      () => _db.transaction(() async {
    if (entityType == settingsEntityType) {
      if (!settingsPullCompleted) return false;
      final row = await _db.customSelect("SELECT * FROM user_settings WHERE id = ${sqlString(entityId)} "
          "AND server_id IS NULL AND COALESCE(sync_status, '') != 'pending' LIMIT 1;").getSingleOrNull();
      if (row == null) return false;
      final held = await _db.customSelect(
          "SELECT entity_id, owner_uid, operation, status, failure_class, "
          "in_flight_seq, payload_json FROM planning_sync_outbox "
          "WHERE entity_type = 'settings';").get();
      // A pre-bind automatic edit waits for this very registration. Once the
      // pull positively confirms absence, promote that unsent, same-owner edit
      // to CREATE through the normal coalescer. Rebuild from the current row;
      // never release consent-only, in-flight, ambiguous or other-owner work.
      if (held.isNotEmpty) {
        if (held.length != 1) return false;
        final edit = held.single;
        if (edit.read<String>('entity_id') != entityId ||
            edit.readNullable<String>('owner_uid') != authority.ownerUid(handle) ||
            edit.read<String>('operation') != 'update' ||
            edit.read<String>('status') != 'parked' ||
            edit.readNullable<String>('failure_class') != kParkDependencyWait ||
            edit.readNullable<int>('in_flight_seq') != null) {
          return false;
        }
        final payload = jsonDecode(edit.read<String>('payload_json')) as Map;
        if (payload['consent_only'] == true) return false;
      }
      return _enqueueFixedIntent(authority.ownerUid(handle), entityType: settingsEntityType,
          entityId: entityId, op: PlanningSyncOperation.create, table: 'user_settings',
          payload: _buildSettingsPayload(userSettingsFromRow(row)), notify: false);
    }
    if (entityType != categoriesEntityType) return false;
    final row = await _db.customSelect("SELECT * FROM categories WHERE id = ${sqlString(entityId)} "
        "AND deleted_at IS NULL AND key LIKE 'custom_%' AND server_id IS NULL "
        "AND COALESCE(sync_status, '') != 'pending' AND NOT EXISTS (SELECT 1 FROM planning_sync_outbox "
        "WHERE entity_type = 'category' AND entity_id = ${sqlString(entityId)});").getSingleOrNull();
    if (row == null) return false;
    final category = CategoryEntity(id: entityId, key: row.read<String>('key'),
        nameAr: row.read<String>('name_ar'), icon: row.read<String>('icon'),
        color: row.read<String>('color'), isIncome: row.read<int>('is_income') == 1,
        sort: row.read<int>('sort_order'));
    return _enqueueFixedIntent(authority.ownerUid(handle), entityType: categoriesEntityType,
        entityId: entityId, op: PlanningSyncOperation.create, table: 'categories',
        payload: _buildCategoryPayload(PlanningSyncOperation.create, category), notify: false);
  }));
    check();
    if (changed && _isSyncEnabled(entityType)) _onQueued?.call();
    return changed;
  }

  /// Holder evidence for account-only finalization. A coalesced edit may have a
  /// newer op_seq while the rejected/successful request still owns this marker.
  Future<bool> accountsHolderCurrent(PlanningOutboxItem item) async {
    if (item.entityType != accountsEntityType &&
        item.entityType != accountDefaultCommandType) {
      return false;
    }
    return await _db.customSelect("SELECT 1 FROM planning_sync_outbox "
      "WHERE id = ${sqlString(item.id)} AND status = 'pending' "
      "AND entity_type = ${sqlString(item.entityType)} "
      "AND entity_id = ${sqlString(item.entityId)} "
      "AND owner_uid IS ${sqlNullableString(item.ownerUid)} "
      "AND in_flight_seq = ${item.opSeq};").getSingleOrNull() != null;
  }

  Future<bool> parkAccountDenial(PlanningOutboxItem item,
      AccountFenceState state, AccountFenceAccountsParking ticket) async {
    ticket.requireExact(_db, rowId: item.id, entityType: item.entityType,
        entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
        operationId: item.operationId, state: state);
    return await _db.customUpdate("""
      UPDATE planning_sync_outbox SET status = 'parked',
        failure_class = ${sqlString(state == AccountFenceState.pending
            ? kParkAccountDeletionPending : kParkAccountDeletionGone)},
        last_error = NULL, next_retry_at = NULL,
        updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(item.id)} AND status = 'pending'
        AND entity_type = ${sqlString(item.entityType)}
        AND entity_id = ${sqlString(item.entityId)}
        AND owner_uid IS ${sqlNullableString(item.ownerUid)}
        AND in_flight_seq = ${item.opSeq};
    """) > 0;
  }

  /// A refusal is not an ACK or business attempt. Preserve payload, operation
  /// identity and ALL possibly-sent history. A stale outcome cannot overwrite
  /// a newer in-flight holder. A queued edit may inherit QD001's same-row hold.
  Future<bool> recordAccountFenceFailure(PlanningOutboxItem item,
      OutboxFailureClass failure, DateTime retryAt) async {
    final pending = failure == OutboxFailureClass.accountDeletionPending;
    final now = dateTimeToSql(DateTime.now().toUtc());
    final changed = await _db.customUpdate("""
      UPDATE planning_sync_outbox
      SET status = '${pending ? 'parked' : 'pending'}',
          failure_class = ${sqlString(failure.reason)}, last_error = NULL,
          next_retry_at = ${pending ? 'NULL' : sqlString(dateTimeToSql(retryAt.toUtc()))},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(item.id)} AND status = 'pending'
        AND owner_uid IS ${sqlNullableString(item.ownerUid)}
        AND ${pending
          ? 'in_flight_seq = ${item.opSeq}'
          : 'op_seq = ${item.opSeq} AND in_flight_seq = ${item.opSeq} AND operation_id = ${sqlNullableString(item.operationId)}'};
    """);
    return changed > 0;
  }

  /// MALI-023: typed failure handling — permanent → dead-letter immediately;
  /// retryable → bounded backoff, dead-letter after [kOutboxMaxAttempts].
  Future<void> markFailed(
    String id,
    String error,
    OutboxFailureClass failureClass,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT attempt_count FROM planning_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());

    // A-3: the marker is cleared on a definite outcome. A transport/5xx failure
    // is AMBIGUOUS (the request may have landed), so the row stays possibly-sent.
    if (failureClass != OutboxFailureClass.transientNetwork &&
        failureClass != OutboxFailureClass.serverError) {
      await _db.customStatement(
        'UPDATE planning_sync_outbox SET in_flight_seq = NULL WHERE id = ${sqlString(id)};',
      );
    }

    // A-5: an auth rejection is not this row's fault and not a retry — park it
    // WITHOUT consuming an attempt; re-armed on the next authenticated session /
    // token refresh or an explicit Retry. The raw error is not retained.
    if (failureClass == OutboxFailureClass.auth) {
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET status = 'parked', failure_class = '$kParkAuthRequired',
            last_error = NULL, next_retry_at = NULL, in_flight_seq = NULL,
            updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)} AND status = 'pending';
      ''');
      return;
    }

    if (failureClass.isPermanent) {
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET status = 'dead_letter', failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final attempts = row.read<int>('attempt_count') + 1;
    if (attempts >= kOutboxMaxAttempts) {
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET status = 'dead_letter', attempt_count = $attempts,
            failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: _backoff(attempts))),
    );
    await _db.customStatement('''
      UPDATE planning_sync_outbox
      SET attempt_count = $attempts, failure_class = ${sqlString(failureClass.reason)},
          last_error = ${sqlString(error)}, next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// MALI-023: re-arm dead-lettered rows (e.g. after an app/schema upgrade).
  Future<int> reArmDeadLetter() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE status = 'dead_letter';
    ''');
  }

  /// A-5: user-triggered Retry — re-arms every dead letter that a retry can
  /// plausibly fix; business-rule duplicates and unsupported operations stay
  /// dead-lettered ([kRetryableDeadLetterSql]). Returns the number re-armed.
  Future<int> reArmRetryableDeadLetters() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE $kRetryableDeadLetterSql;
    ''');
  }

  /// A-5: re-arm rows parked `auth_required` (authenticated session restored or
  /// Retry). The SAME durable rows; no attempt was ever consumed. Also clears the
  /// backoff of pending rows so a user Retry runs them now.
  ///
  /// D-7: [entityTypes] scopes the re-arm to the caller's own entity types, so a
  /// push service re-arming at cycle start never undoes the auth park a sibling
  /// service (accounts / children) recorded earlier in the same cycle.
  Future<int> reArmAuthParked({Iterable<String>? entityTypes}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final typeClause = entityTypes == null
        ? ''
        : 'AND entity_type IN (${entityTypes.map(sqlString).join(', ')})';
    return _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked' AND failure_class = '$kParkAuthRequired'
        $typeClause;
    ''');
  }

  /// A-5: Retry-now — drop the backoff wait of pending rows (no attempt reset).
  Future<int> clearRetryBackoff() => _db.customUpdate(
        "UPDATE planning_sync_outbox SET next_retry_at = NULL "
        "WHERE status = 'pending' AND next_retry_at IS NOT NULL "
        "AND COALESCE(failure_class, '') != '$kFailAccountFenceContention';",
      );

  /// MALI-026 (B8-2.10 §8): park a canonical money row whose exact push
  /// transport is unverified. Parked rows are excluded from [pendingItems],
  /// retained durably, and consume no retry attempt.
  ///
  /// D-follow-up: [ifOpSeq] parks only while the row was not edited since it was
  /// handed out; returns true when the row was parked.
  Future<bool> park(String id, String reason, {int? ifOpSeq}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final n = await _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'parked', failure_class = ${sqlString(reason)},
          last_error = NULL, next_retry_at = NULL, in_flight_seq = NULL,
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)} AND status = 'pending'
        ${ifOpSeq == null ? '' : 'AND op_seq = $ifOpSeq'};
    ''');
    return n > 0;
  }

  /// MALI-026 (B8-2.10 §9): re-arm the same durable rows after exact push
  /// transport is verified. Returns the number re-armed.
  Future<int> reArmParked() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked'
        AND COALESCE(failure_class, '') NOT IN $kOutboxSelfHealingParkReasonsSql
        AND COALESCE(failure_class, '') != '$kParkAccountDeletionPending'
        AND NOT (entity_type IN ('account','account_default_command','budget','subscription','goal','plan','card','category','settings','goal_contribution','bill_payment','plan_transaction_link')
          AND COALESCE(failure_class, '') = '$kParkAccountDeletionGone');
    ''');
  }

  /// Parked-row count for diagnostics (no financial payload exposed).
  Future<int> parkedCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM planning_sync_outbox WHERE status = 'parked';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  Future<int> deadLetterCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM planning_sync_outbox WHERE status = 'dead_letter';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildAccountPayload(
    PlanningSyncOperation op,
    AccountEntity account,
  ) {
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object? amountWireOrNull(Money? m) => canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);

    final payload = <String, dynamic>{
      'local_id': account.id,
      'name': account.name,
      'currency': account.currency,
      'type': account.type.name,
      'initial_balance': amountWireOrNull(account.initialBalanceMoney),
      'current_balance': amountWireOrNull(account.currentBalanceMoney),
      'bank_account_number': account.bankAccountNumber,
      'credit_limit': amountWireOrNull(account.creditLimitMoney),
      'available_credit': amountWireOrNull(account.availableCreditMoney),
      'payment_due_day': account.paymentDueDay,
      'wallet_provider': account.walletProvider,
      'exclude_from_totals': account.excludeFromTotals,
      'metadata': account.metadata ?? const <String, dynamic>{},
      'is_default': account.isDefault,
      'sort_order': account.sortOrder,
      'created_at': account.createdAt.toUtc().toIso8601String(),
      'updated_at': account.updatedAt.toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Future<bool> enqueueCategory(
    PlanningSyncOperation op,
    CategoryEntity category,
  ) {
    return _enqueue(
      entityType: categoriesEntityType,
      entityId: category.id,
      op: op,
      table: 'categories',
      payload: _buildCategoryPayload(op, category),
    );
  }

  Map<String, dynamic> _buildCategoryPayload(
    PlanningSyncOperation op,
    CategoryEntity category,
  ) {
    final payload = <String, dynamic>{
      'local_id': category.id,
      'key': category.key,
      'name_ar': category.nameAr,
      'icon': category.icon,
      'color': category.color,
      'is_income': category.isIncome,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _buildCardPayload(
    PlanningSyncOperation op,
    CardEntity card,
  ) {
    final payload = <String, dynamic>{
      'local_id': card.id,
      'local_account_id': card.accountId,
      'nickname': card.nickname,
      'last4': card.last4,
      'network': card.network.name,
      'source': card.source.name,
      'color_theme': card.colorTheme,
      'accent_hex': card.accentHex,
      'created_at': card.createdAt.toUtc().toIso8601String(),
      'updated_at': card.updatedAt.toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _withDelete(
    PlanningSyncOperation op,
    Map<String, dynamic> payload,
  ) {
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _buildBudgetPayload(
    PlanningSyncOperation op,
    BudgetEntity budget,
    String? categoryWireId,
  ) {
    // MALI-026 (B8-3 §7): canonical planning push is exact — money → decimal
    // STRING (moneyToNumericText) + the row's own currency (server column 0077).
    // Legacy (pre-cutover) keeps the historical JSON-number shape and no
    // currency column. NEVER a display double / toDouble on the canonical path.
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    return _withDelete(op, {
      'local_id': budget.id,
      // F-029: the stable category KEY — see _categoryWireId.
      'category_id': categoryWireId,
      'amount': amountWire(budget.amountMoney),
      if (canonical) 'currency': budget.currency,
      'period': budget.period.name,
      'start_date': budget.startDate.toUtc().toIso8601String(),
      'is_active': budget.isActive,
      'last_notified_spent_amount': amountWire(budget.lastNotifiedSpentMoney),
      'last_notified_period_start':
          budget.lastNotifiedPeriodStart.toUtc().toIso8601String(),
      'show_on_header': budget.showOnHeader,
      'local_account_id': budget.accountId,
      'alert_threshold_percent': budget.alertThresholdPercent,
    });
  }

  Map<String, dynamic> _buildSubscriptionPayload(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    Object? amountWireOrNull(Money? m) => canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);

    return _withDelete(op, {
      'local_id': bill.id,
      'local_account_id': bill.accountId,
      'merchant_id': bill.merchantId,
      'name': bill.name,
      'amount': amountWire(bill.amountMoney),
      'currency': bill.currency,
      'type': bill.type.name,
      'frequency': bill.frequency.name,
      'next_due_date': bill.nextDueDate.toUtc().toIso8601String(),
      'reminder_on': bill.reminderOn,
      'is_confirmed': bill.isConfirmed,
      'custom_interval_days': bill.customIntervalDays,
      'note': bill.note,
      'status': bill.status.name,
      'total_installments': bill.totalInstallments,
      'paid_count': bill.paidCount,
      'manual_paid_amount': amountWireOrNull(bill.manualPaidMoney),
      'total_purchase_amount': amountWireOrNull(bill.totalPurchaseMoney),
      'lender_name': bill.lenderName,
      'interest_rate': bill.interestRate,
      'created_at': bill.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildGoalPayload(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    // MALI-026 (B8-3 §7): canonical goal push is exact — every money field →
    // decimal STRING + the goal's own currency (server column 0077). Legacy keeps
    // the JSON-number shape. NEVER a display double on the canonical path.
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    Object? amountWireOrNull(Money? m) => canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);
    return _withDelete(op, {
      'local_id': goal.id,
      'local_account_id': goal.accountId,
      'name': goal.name,
      'target_amount': amountWire(goal.targetMoney),
      'saved_amount': amountWire(goal.savedMoney),
      if (canonical) 'currency': goal.currency,
      'deadline': goal.deadline?.toUtc().toIso8601String(),
      'vault_skin': goal.vaultSkin,
      'status': goal.status,
      'auto_save_amount': amountWireOrNull(goal.autoSaveMoney),
      'auto_save_period': goal.autoSavePeriod,
      'auto_save_last_run': goal.autoSaveLastRun?.toUtc().toIso8601String(),
      'last_notified_saved_amount': amountWire(goal.lastNotifiedSavedMoney),
      'created_at': goal.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildPlanPayload(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);

    return _withDelete(op, {
      'local_id': plan.id,
      'name': plan.name,
      'budget_amount': amountWire(plan.budgetAmountMoney),
      'currency': plan.currency,
      'start_date': plan.startDate.toUtc().toIso8601String(),
      'end_date': plan.endDate.toUtc().toIso8601String(),
      'local_account_ids': plan.accountIds,
      'card_last4s': plan.cardLast4s,
      'status': plan.status.name,
      'icon': plan.icon,
      'created_at': plan.createdAt.toUtc().toIso8601String(),
    });
  }
}
