import 'package:flutter/foundation.dart';

import '../../../core/session/admission_authority.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/db/financial_cache_health.dart';
import '../../../core/sync/conflict_resolver.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/db/legacy_financial_cache_reconciler.dart';
import '../../app/legacy_reconcile_domains.dart';
import 'accounts_pull_service.dart';
import 'accounts_push_service.dart';
import 'merchant_rule_sync_service.dart';
import 'planning_outbox_queue.dart';
import 'planning_pull_service.dart';
import 'planning_push_service.dart';
import 'planning_child_sync_service.dart';
import 'planning_startup_registration_service.dart';

/// Structured outcome of the planning parent phase, so the sync body drives
/// control flow from explicit results (not inferred generation checks): the
/// accounts and planning in-slot outcomes, and whether the phase was cancelled.
class SyncParentsOutcome {
  const SyncParentsOutcome({
    required this.accounts,
    required this.planning,
  });

  final ReconcileDomainResult accounts;
  final ReconcileDomainResult planning;

  bool get cancelled =>
      accounts == ReconcileDomainResult.cancelled ||
      planning == ReconcileDomainResult.cancelled;
}

class PlanningSyncEngine {
  const PlanningSyncEngine({
    required AccountsPushService accountsPushService,
    required AccountsPullService accountsPullService,
    required PlanningPushService planningPushService,
    required PlanningPullService planningPullService,
    required PlanningChildSyncService planningChildSyncService,
    required PlanningStartupRegistrationService startupRegistrationService,
    required UniversalConflictResolver conflictResolver,
    SyncHealth? health,
    Future<void> Function()? ensureCapabilities,
    MerchantRuleSyncService? merchantRuleSync,
  })  : _health = health,
        _merchantRules = merchantRuleSync,
        _ensureCapabilities = ensureCapabilities,
        _accountsPush = accountsPushService,
        _accountsPull = accountsPullService,
        _planningPush = planningPushService,
        _planningPull = planningPullService,
        _planningChildren = planningChildSyncService,
        _startupRegistration = startupRegistrationService,
        _conflictResolver = conflictResolver;

  final AccountsPushService _accountsPush;
  final AccountsPullService _accountsPull;
  final PlanningPushService _planningPush;
  final PlanningPullService _planningPull;
  final PlanningChildSyncService _planningChildren;
  final PlanningStartupRegistrationService _startupRegistration;
  final UniversalConflictResolver _conflictResolver;
  final SyncHealth? _health;

  /// The user's learned category rules. Runs after the planning pull and the
  /// registration push, so a rule's custom category is already restored.
  final MerchantRuleSyncService? _merchantRules;

  /// Resolves runtime capability probes (planning currency) at the start of a
  /// cycle so the gates below see a fresh answer. Never throws.
  final Future<void> Function()? _ensureCapabilities;

  /// Runs one phase: isolated (never rethrows) and recorded in [SyncHealth].
  Future<void> _phase(
    SyncDomain domain,
    SyncDirection direction,
    Future<void> Function() body,
    String label, {SyncPhaseBinding? binding}
  ) async {
    final health = _health;
    try {
      if (health == null) {
        await body();
      } else {
        await health.runPhase(domain, direction, body, rethrowErrors: true, binding: binding);
      }
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] $label error: $e');
    }
  }

  Future<void> sync({LegacyFinancialCacheReconciler? reconciler}) async {
    final result = await _syncParents(reconciler: reconciler);
    if (result.outcome.cancelled || result.original?.isCurrent != true) return;
    final binding = result.original!;
    try {
      _check(binding);
      final childPhase=binding.forNextPhase();
      await _phase(SyncDomain.children, SyncDirection.push,
          () => _planningChildren.syncWithPhase(childPhase), 'children', binding: childPhase);
      _check(binding);
    } on AccountFenceDeliveryCancellation {
      return;
    }
  }

  void _check(SyncPhaseBinding binding) {
    if (!binding.isCurrent) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    }
  }

  /// Accounts and planning parents must sync before ledger rows so foreign
  /// key/server-ID correlation is available on a fresh second device.
  ///
  /// [reconciler] enables the in-slot legacy epoch reconciliation at the accounts
  /// and planning pull slots. Requirement 1: a `cancelled` outcome aborts INSIDE
  /// this method at the exact slot — no later planning push/conflict/pull/
  /// registration runs under a stale generation.
  Future<SyncParentsOutcome> syncParents({
    LegacyFinancialCacheReconciler? reconciler,
  }) async => (await _syncParents(reconciler: reconciler)).outcome;

  Future<({SyncParentsOutcome outcome, SyncPhaseBinding? original})> _syncParents({
    LegacyFinancialCacheReconciler? reconciler,
  }) async {
    final original = SyncPhaseBinding();
    const cancelled = SyncParentsOutcome(accounts: ReconcileDomainResult.cancelled,
        planning: ReconcileDomainResult.noDirtyState);
    try {
      return (outcome: await _parentsBound(original, reconciler), original: original);
    } on AccountFenceDeliveryCancellation {
      return (outcome: cancelled, original: original);
    } on StaleAdmissionException {
      return (outcome: cancelled, original: original);
    }
  }

  Future<SyncParentsOutcome> _parentsBound(SyncPhaseBinding original,
      LegacyFinancialCacheReconciler? supplied) async {
    try {
      await _ensureCapabilities?.call();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] capability probe error: $e');
    }
    await _phase(SyncDomain.accounts, SyncDirection.push,
        () => _accountsPush.pushWithPhase(original), 'accounts push', binding: original);
    _check(original);
    final reconciler = supplied == null ? null : _AccountsBoundReconciler(original, supplied);
    final accounts = await reconcileOrPull(
      reconciler: reconciler,
      domain: _boundDomain(accountsReconcileDomain(_accountsPull), original),
      normalPull: (sourceAdmitted) async {
        _check(original);
        bool admitted() => original.isCurrent && sourceAdmitted();
        await _phase(SyncDomain.accounts, SyncDirection.pull,
            () => _accountsPull.pull(isAdmitted: admitted), 'accounts pull', binding: original.forNextPhase());
        _check(original);
      },
    );
    _check(original);
    if (accounts == ReconcileDomainResult.cancelled) {
      return const SyncParentsOutcome(
        accounts: ReconcileDomainResult.cancelled,
        planning: ReconcileDomainResult.noDirtyState,
      );
    }
    final planningPhase = original.forNextPhase();
    await _phase(SyncDomain.planning, SyncDirection.push,
        () => _planningPush.pushWithPhase(planningPhase), 'planning push', binding: planningPhase);
    _check(original);
    // Auto-resolve low-stakes config conflicts (cards/categories/settings) in
    // favour of the server BEFORE the pull, so the pull overwrites the local
    // copy within this same pass — they never sit stuck in `conflict` awaiting a
    // prompt that never comes (MALI-057n). Financial entities are left for the
    // user to resolve.
    try {
      _check(original);
      await _conflictResolver.autoResolveDeterministic();
      _check(original);
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } catch (e) {
      _check(original);
      if (kDebugMode) debugPrint('[PlanningSync] auto-resolve error: $e');
    }
    // Audit NEW-H-4 — the settings-registration authority. Registration may
    // only queue the initial FULL-ROW settings CREATE when the pull POSITIVELY
    // established remote state for the settings singleton in this cycle. The
    // pull swallows per-entity transport errors into its result, so "pull()
    // returned" proves nothing — only `completedEntities` does (an entity that
    // errored mid-page is absent). A failed/cancelled pull, or the legacy
    // reconcile path, leaves this false: UNKNOWN remote existence is NOT
    // absence, and pushing fresh-device defaults over an existing remote row
    // (which this same cycle would do — registration is followed immediately
    // by a push) destroyed the user's real cloud settings/profile.
    var settingsPullCompleted = false;
    final planning = await reconcileOrPull(
      reconciler: reconciler,
      domain: _boundDomain(planningReconcileDomain(_planningPull), original),
      normalPull: (sourceAdmitted) async {
        _check(original);
        bool admitted() => original.isCurrent && sourceAdmitted();
        await _phase(SyncDomain.planning, SyncDirection.pull, () async {
          final result = await _planningPull.pull(isAdmitted: admitted);
          settingsPullCompleted = result.completedEntities
              .contains(PlanningOutboxQueue.settingsEntityType);
        }, 'planning pull', binding: original.forNextPhase());
        _check(original);
      },
    );
    _check(original);
    if (planning == ReconcileDomainResult.cancelled) {
      return SyncParentsOutcome(
          accounts: accounts, planning: ReconcileDomainResult.cancelled);
    }
    // Pull first so an existing remote singleton wins over freshly seeded
    // defaults. Only genuinely missing settings/custom categories are queued —
    // and the settings singleton only under the positive authority above.
    final registrationPhase = original.forNextPhase();
    await _phase(SyncDomain.planning, SyncDirection.push, () async {
      _check(original);
      await _startupRegistration.registerMissingRowsWithPhase(
          settingsPullCompleted: settingsPullCompleted, phase: registrationPhase);
      _check(original);
      await _planningPush.pushWithPhase(registrationPhase);
      _check(original);
    }, 'registration', binding: registrationPhase);
    _check(original);
    final rules = _merchantRules;
    if (rules != null) {
      final rulesPhase = original.forNextPhase();
      await _phase(SyncDomain.planning, SyncDirection.pull,
          () => rules.syncWithPhase(rulesPhase), 'merchant rules',
          binding: rulesPhase);
      _check(original);
    }
    return SyncParentsOutcome(accounts: accounts, planning: planning);
  }

  ReconcileDomain _boundDomain(ReconcileDomain domain, SyncPhaseBinding original) =>
      ReconcileDomain(name: domain.name, entities: domain.entities,
          isEnabled: domain.isEnabled,
          runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
            _check(original);
            final completed = await domain.runFromEpoch(dirtyEntities: dirtyEntities,
                isAdmitted: () => original.isCurrent && isAdmitted());
            _check(original);
            return completed;
          });

  /// Called after ledger sync so bill-payment transaction references and plan
  /// links can resolve both sides on their first pass.
  Future<void> syncChildren() async {
    final phase=SyncPhaseBinding();
    await _phase(SyncDomain.children, SyncDirection.push,
        () => _planningChildren.syncWithPhase(phase), 'children',binding:phase);
  }
}

class _AccountsBoundReconciler extends LegacyFinancialCacheReconciler {
  _AccountsBoundReconciler(this.binding, this.supplied)
      : super(db: binding.database!, generation: 0,
            isAdmitted: (_) => binding.isCurrent && supplied.isAdmitted());
  final SyncPhaseBinding binding;
  final LegacyFinancialCacheReconciler supplied;
  bool get current => binding.isCurrent && supplied.isAdmitted();

  Future<T> local<T>(Future<T> Function() action) {
    if (!current) throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    return binding.runLocal(action);
  }

  @override
  Future<ReconcileDomainResult> reconcileDomain(ReconcileDomain domain) async {
    try {
      final dirty = <String>{};
      for (final entity in domain.entities) {
        if (await local(() => isFinancialCacheDirty(binding.database!, entity))) {
          dirty.add(entity);
        }
      }
      if (!current) return ReconcileDomainResult.cancelled;
      if (dirty.isEmpty) return ReconcileDomainResult.noDirtyState;
      if (!domain.isEnabled()) return ReconcileDomainResult.deferred;
      final completed = await domain.runFromEpoch(dirtyEntities: dirty,
          isAdmitted: () => current);
      if (!current) return ReconcileDomainResult.cancelled;
      var allCleared = true;
      for (final entity in dirty) {
        if (completed.contains(entity)) {
          final cleared = await local(() => clearFinancialCacheDirtyIfAdmitted(
              binding.database!, entity, () => current));
          if (!cleared) allCleared = false;
        } else {
          allCleared = false;
        }
      }
      if (!current) return ReconcileDomainResult.cancelled;
      return allCleared ? ReconcileDomainResult.completed : ReconcileDomainResult.failed;
    } on AccountsDeliveryStopped {
      return ReconcileDomainResult.cancelled;
    } on StaleAdmissionException {
      return ReconcileDomainResult.cancelled;
    }
  }
}
