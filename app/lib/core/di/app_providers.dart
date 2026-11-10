import '../session/admission_authority.dart';
import 'account_access_mode.dart';
import '../session/account_scope.dart' show AccountAccessMode, AccountScopeHost;
import '../session/consent_capability.dart';
import '../session/merchant_preference_writer.dart';
import '../sync/pending_sync_reconciler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../auth/account_deletion_gateway.dart';
import '../auth/account_deletion_service.dart';
import '../auth/apple_deletion_reauth.dart';
import '../auth/supabase_auth_service.dart' show authorizeIosGoogle;
import '../auth/immediate_deletion_flow.dart';
import '../auth/immediate_deletion_receipt_store.dart';
import '../auth/prepared_immediate_deletion_gateway.dart';
import '../backend/metrics_client.dart';
import '../backend/rules_client.dart';
import '../backend/supabase_config.dart';
import '../sync/conflict_policy.dart';
import '../sync/conflict_resolver.dart';
import '../sync/sync_conflict_store.dart';
import '../../domain/entities/transaction_entity.dart' show TransactionStatus;
import '../sync/sync_health.dart';
import '../sync/sync_recovery.dart';
import '../sync/sync_wakeup.dart';
import '../session/app_session.dart';
import '../../features/gamification/services/achievement_unlocks.dart';
import '../../features/planning_sync/services/outbox_queue_factory.dart'
    show localDataOwnerUid;
import '../session/unsynced_inventory.dart';
import '../data_portability/app_data_portability_service.dart';
import '../data_portability/data_portability_models.dart';
import '../../engine/ai/ai_parser_client.dart';
import '../../engine/intelligence/merchant_intelligence_store.dart';
import '../../engine/ai/bank_discovery_client.dart';
import '../../data/catalog/announcement_service.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../data/catalog/catalog_sync_service.dart';
import '../../data/catalog/feature_flag_service.dart';
import '../../data/catalog/growth_campaign_service.dart';
import '../../data/catalog/parser_authority.dart';
import '../../data/catalog/seed_loader.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/install_id.dart';
import '../../data/db/app_database.dart';
import '../privacy/cloud_egress_gate.dart';
import '../privacy/consent_authority.dart';
import '../../data/sync/planning_currency_capability_probe.dart';
import '../../data/sync/seq_pull.dart';
import '../../data/sync/revision_cas.dart';
import '../sync/keep_mine_as_new.dart';
import '../../data/sync/server_capabilities.dart';
import '../../data/db/ownership_guard.dart';
import '../../data/db/planning_canonical_invariants.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/repositories/account_deletion_service.dart';
import '../../data/repositories/drift_account_repository.dart';
import '../../data/repositories/drift_card_repository.dart';
import '../../data/repositories/drift_bill_repository.dart';
import '../../data/repositories/drift_plan_repository.dart';
import '../../data/repositories/drift_budget_repository.dart';
import '../../data/repositories/drift_category_repository.dart';
import '../../data/repositories/drift_dedup_store.dart';
import '../../data/repositories/drift_gamification_repository.dart';
import '../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_merchant_category_repository.dart';
import '../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../data/repositories/drift_smart_inbox_repository.dart';
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../../data/sync/exact_transport_capability.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/finance/planning_mutation_guard.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/card_repository.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../domain/repositories/plan_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/gamification_repository.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../../domain/repositories/sender_bank_mapping_repository.dart';
import '../../domain/repositories/suspected_duplicate_repository.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../domain/services/bank_discovery_service.dart';
import '../../data/capture/proof_shadow_dao.dart';
import '../../domain/capture/proof_commit_gate.dart';
import '../../domain/usecases/add_transaction_usecase.dart';
import '../../domain/usecases/budget_progress_usecase.dart';
import '../../domain/usecases/confirm_transaction_usecase.dart';
import '../../domain/usecases/correct_category_usecase.dart';
import '../../domain/usecases/engagement_usecase.dart';
import '../../domain/usecases/goal_details_usecase.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../domain/usecases/resolve_bank_for_sender_usecase.dart';
import '../../domain/usecases/save_budget_usecase.dart';
import '../../domain/usecases/save_goal_usecase.dart';
import '../../domain/usecases/user_settings_usecases.dart';
import '../../features/app/celebration_runtime.dart';
import '../../features/ads/banner_ads_providers.dart';
import '../../features/report_ads/report_ads_providers.dart';
import '../../features/capture/services/local_notification_service.dart';
import '../../features/capture/services/notification_journey_service.dart';
import '../../features/capture/services/capture_backend_client.dart';
import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/capture_sync_service.dart';
import '../../features/capture/services/capture_import_ports.dart';
import '../../features/capture/services/capture_import_service.dart';
import '../../features/capture/services/capture_receipts.dart';
import '../../features/capture/services/capture_server_port.dart';
import '../../features/capture/services/legacy_capture_resolver.dart';
import '../../features/capture/services/unbound_capture_prompt_service.dart';
import '../../features/capture/services/native_capture_bridge.dart';
import '../../features/capture/services/notification_log_service.dart';
import '../../features/capture/services/notification_log_ownership.dart';
import '../../features/capture/services/notification_log_sync_service.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/capture/services/ledger_push_service.dart';
import '../../features/capture/services/ledger_sync_engine.dart';
import '../../features/capture/services/ledger_sync_service.dart';
import '../../features/capture/services/smart_inbox_sync_service.dart';
import '../../features/planning_sync/services/accounts_pull_service.dart';
import '../../features/planning_sync/services/accounts_push_service.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../../features/planning_sync/services/planning_child_sync_service.dart';
import '../../features/planning_sync/services/planning_pull_service.dart';
import '../../features/planning_sync/services/planning_push_service.dart';
import '../../features/planning_sync/services/planning_startup_registration_service.dart';
import '../../features/planning_sync/services/planning_sync_engine.dart';
import '../../features/planning_sync/services/startup_sync_reconcile_service.dart';
import '../../domain/services/notification_planner.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('AppDatabase must be provided from main().');
});

/// MALI-026 (B8-3 §1) — the ACTIVATED planning money-authority seam. The DB-marker
/// coordinator resolves the real cutover state from user_settings.planning_cutover_state
/// + a canonical-invariant recount. It starts at [PlanningCutoverState.canonical]
/// (a fresh v30 DB is canonical) and MUST be refreshed at bootstrap
/// (`refreshFromDatabase()` in main) to reflect an upgraded-with-data (unresolved)
/// database. Tests inject a fixed state via override for P1/P3 scenarios.
final planningCutoverCoordinatorProvider =
    Provider<PlanningCutoverCoordinator>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DbBackedPlanningCutoverCoordinator(
    initialState: PlanningCutoverState.canonical,
    readUserVersion: () async =>
        (await db.customSelect('PRAGMA user_version;').getSingle())
            .read<int>('user_version'),
    readMarker: () async => (await db
            .customSelect(
                'SELECT planning_cutover_state AS s FROM user_settings;')
            .getSingle())
        .read<int>('s'),
    countCanonicalViolations: () async =>
        (await planningCanonicalViolations(db)).length,
  );
});

/// Central P1 mutation/delete guard. It is intentionally not called by current
/// v29 repositories yet, so registering it cannot alter live behavior.
final planningMutationGuardProvider = Provider<PlanningMutationGuard>((ref) {
  return PlanningMutationGuard(ref.watch(planningCutoverCoordinatorProvider));
});

/// Whether any local data existed at the moment bootstrap finished.
/// Overridden from main(). Home uses it to show the full-page skeleton only
/// on the very first, truly-empty launch — never on a normal cold start
/// where real data is about to appear. Defaults to `true` (no skeleton) so
/// an unwired test scope can never regress into skeleton-on-every-open.
final startupHasLocalDataProvider = Provider<bool>((ref) => true);

/// A monotonically-increasing counter that ticks on **every** database write
/// (any table). Read-providers `ref.watch` this so the whole app reflects new
/// data live — a captured/added transaction, a new account, a changed setting
/// — without a hot restart or a manual `invalidate`.
final dbRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  var revision = 0;
  final controller = StreamController<int>();
  // Writes arrive in bursts (startup seeding, sync bookkeeping, notification
  // logs). Emitting per-write invalidated slow watchers like
  // dashboardDataProvider faster than they could complete — the Home screen
  // sat in loading forever. Coalesce: one tick after a short quiet gap, with
  // a max wait so a long steady burst still surfaces data periodically.
  Timer? quiet;
  Timer? maxWait;
  void emit() {
    quiet?.cancel();
    quiet = null;
    maxWait?.cancel();
    maxWait = null;
    if (!controller.isClosed) controller.add(++revision);
  }

  void tick() {
    if (controller.isClosed) return;
    quiet?.cancel();
    quiet = Timer(const Duration(milliseconds: 300), emit);
    maxWait ??= Timer(const Duration(seconds: 2), emit);
  }

  final tableSub = db.tableUpdates().listen((_) => tick());
  final manualSub = db.manualRevisionStream.listen((_) => tick());
  ref.onDispose(() async {
    quiet?.cancel();
    maxWait?.cancel();
    await tableSub.cancel();
    await manualSub.cancel();
    await controller.close();
  });
  return controller.stream;
});

/// MALI-029 — coalescing shared by every revision provider so a write burst
/// (startup seed, batch import, sync) collapses to ONE rebuild, matching
/// [dbRevisionProvider]'s 300ms-quiet / 2s-max-wait behavior.
StreamController<int> _coalescedRevision(
  Ref ref,
  Stream<String> source,
  bool Function(String table) accept,
) {
  var revision = 0;
  final controller = StreamController<int>();
  Timer? quiet;
  Timer? maxWait;
  void emit() {
    quiet?.cancel();
    quiet = null;
    maxWait?.cancel();
    maxWait = null;
    if (!controller.isClosed) controller.add(++revision);
  }

  void tick() {
    if (controller.isClosed) return;
    quiet?.cancel();
    quiet = Timer(const Duration(milliseconds: 300), emit);
    maxWait ??= Timer(const Duration(seconds: 2), emit);
  }

  final sub = source.where(accept).listen((_) => tick());
  ref.onDispose(() async {
    quiet?.cancel();
    maxWait?.cancel();
    await sub.cancel();
    await controller.close();
  });
  return controller;
}

/// MALI-029 — a revision that ticks ONLY when a data write targets one of the
/// comma-joined [tablesKey] tables. Financial screens watch their own domain
/// instead of the global [dbRevisionProvider], so an unrelated-table write never
/// rebuilds them. The key MUST be a sorted, comma-joined table list (a stable
/// family key); use the `k*RevisionTables` constants below. Display dependencies
/// (e.g. `categories` for transaction rows) are included in each domain so a
/// dependent write still refreshes — providers never go stale.
final scopedRevisionProvider =
    StreamProvider.family<int, String>((ref, tablesKey) {
  final tables = tablesKey.split(',').toSet();
  final db = ref.watch(appDatabaseProvider);
  return _coalescedRevision(ref, db.tableWriteStream, tables.contains).stream;
});

/// Tables whose writes are pure bookkeeping / background operations and must NOT
/// rebuild financial screens — the documented sync/notification "flicker" source.
/// EXCLUSION (not enumeration) is deliberate: a new financial table is included in
/// [financialRevisionProvider] automatically; only writes we are certain are
/// non-display are filtered out. Gamification DISPLAY aggregates (achievements,
/// streaks, xp_levels) are intentionally NOT here — only the engagement OUTBOX is.
const kOperationalOnlyTables = <String>{
  'notification_log_events',
  'ledger_sync_outbox',
  'planning_sync_outbox',
  'parked_child_rows',
  'sync_conflicts',
  'sync_cursors',
  'engagement_events',
  'dedup_hashes',
  'restore_operations',
  'financial_cache_health',
  'financial_import_runs',
  'catalog_metadata',
  'pending_merchant_feedback',
  'sender_bank_mappings',
  'smart_inbox_items',
  'suspected_duplicates',
  'remote_banks',
  'remote_parsers',
  'remote_currencies',
  'remote_countries',
  'remote_categories',
  'remote_merchant_keywords',
  'remote_feature_flags',
  'remote_announcements',
  'remote_growth_campaigns',
  'remote_coupons',
};

/// Domain table sets (sorted, comma-joined → stable family keys).
const kReportsRevisionTables = 'categories,transactions';
const kBudgetsRevisionTables = 'budgets,categories,transactions';
const kTransactionsRevisionTables = 'accounts,categories,transactions';

/// A revision for broad financial screens (the dashboard) that ticks on ANY write
/// except the purely-operational tables — so a notification-log / sync-cursor /
/// catalog write no longer rebuilds the whole financial UI, while every financial
/// write (including a brand-new financial table) still refreshes it.
final financialRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return _coalescedRevision(
    ref,
    db.tableWriteStream,
    (table) => !kOperationalOnlyTables.contains(table),
  ).stream;
});

final metricsClientProvider = writerProvider<MetricsClient>((ref) {
  return MetricsClient();
});

final rulesClientProvider = writerProvider<RulesClient>((ref) {
  return RulesClient(database: ref.watch(appDatabaseProvider));
});

final announcementServiceProvider = writerProvider<AnnouncementService>((ref) {
  return AnnouncementService(
    dao: RemoteAnnouncementsDao(ref.watch(appDatabaseProvider)),
  );
});

final activeAnnouncementsProvider =
    FutureProvider<List<RemoteAnnouncement>>((ref) {
  return ref.watch(announcementServiceProvider).getActiveAnnouncements();
});

final growthCampaignServiceProvider = writerProvider<GrowthCampaignService>((ref) {
  return GrowthCampaignService(
    database: ref.watch(appDatabaseProvider),
    dao: RemoteGrowthCampaignsDao(ref.watch(appDatabaseProvider)),
    loadPreferences: ref.watch(loadNotificationPreferencesUseCaseProvider),
    savePreferences: ref.watch(saveNotificationPreferencesUseCaseProvider),
  );
});

final activeDashboardCampaignsProvider =
    FutureProvider<List<RemoteGrowthCampaign>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(growthCampaignServiceProvider).visibleDashboardBanners();
});

final hasForceUpdateProvider = FutureProvider<bool>((ref) async {
  final announcements = await ref.watch(activeAnnouncementsProvider.future);
  return announcements.any((a) => a.isForceUpdate);
});

FeatureFlagService? _featureFlagInstance;

/// Initialises the authoritative runtime FeatureFlagService and loads flags
/// from Drift. Call at startup and after catalog flag sync completes.
Future<FeatureFlagService> initFeatureFlagService(
  AppDatabase db, {
  String? installIdOverride,
  // B2-C startup: the LOCAL init (cached flags) is what makes `featureFlags`
  // usable and MUST stay on the critical path (the getter throws otherwise). The
  // remote [applyUserOverrides] is a NETWORK refresh — bootstrap passes false so
  // it does not gate the first financial frame; the post-frame `syncCatalog`
  // already re-runs this with overrides applied. A fresh install renders with
  // safe default/cached flags for the first frame, then the post-frame refresh
  // lands the server values.
  bool applyRemoteOverrides = true,
  bool Function()? isCurrent,
}) async {
  final id = installIdOverride ?? await InstallId.get();
  final service = FeatureFlagService(
    dao: RemoteFeatureFlagsDao(db),
    installId: id,
  );
  await service.init();
  // Astra H2.4: a failed (re)load must never regress to the bare defaults. A new
  // service starts from `_defaults`, so replacing a good instance with it would
  // revert every cached disabled flag whose default is true. Keep the last good
  // instance instead (a first load that fails still falls back to the defaults).
  if (!service.isInitialised && _featureFlagInstance != null) {
    return _featureFlagInstance!;
  }
  if (applyRemoteOverrides &&
      SupabaseConfig.isConfigured &&
      await CloudEgressGate.instance.permits()) {
    final client = supabase.Supabase.instance.client;
    await service.applyUserOverrides(client, client.auth.currentUser?.id,
        isCurrent: isCurrent);
  }
  if (isCurrent != null && !isCurrent()) return service;
  _featureFlagInstance = service;
  return service;
}

Future<void> _refreshFeatureOverrides(bool Function() current) async {
  if (!current() || !SupabaseConfig.isConfigured) return;
  if (!await CloudEgressGate.instance.permits() || !current()) return;
  final service = _featureFlagInstance;
  if (service == null) return;
  final client = supabase.Supabase.instance.client;
  await service.applyUserOverrides(client, client.auth.currentUser?.id,
      isCurrent: () => current() && identical(_featureFlagInstance, service));
}

FeatureFlagService get featureFlags {
  if (_featureFlagInstance != null) return _featureFlagInstance!;
  throw StateError(
      'FeatureFlagService not initialised. Call syncCatalog first.');
}

// MALI-063n — RETIRED. Dashboard/report/budget summaries were once read
// straight from Supabase RPCs (migration 0030), which carry PRE-canonical
// financial semantics (no refund netting, no half-open windows, no unified
// exclusion). That UI→Supabase path is gone: every financial surface computes
// from the canonical Drift aggregates. The gating flags and the
// `SupabaseFinancialSummaryService` provider were removed so the switch can no
// longer be flipped back on. The RPCs remain in 0030 marked historical; the
// service class survives only for the credential-gated contract tests. Do NOT
// re-wire it for reads without canonicalizing the RPCs first.

final accountDeletionServiceProvider = writerProvider<AccountDeletionService>((ref) {
  return AccountDeletionService();
});

/// LEGACY: the scheduled (30-day) deletion backend, reported truthfully (never
/// as completed). The Delete account screen no longer uses it; it remains only
/// for the status/cancel of requests scheduled before immediate deletion.
final accountDeletionGatewayProvider = writerProvider<AccountDeletionGateway>((ref) {
  return ScheduledAccountDeletionGateway(
      ref.watch(accountDeletionServiceProvider));
});

/// The account scope host, supplied by the root `ProviderScope` (main.dart).
/// Null where none exists (tests, bootstrap): deletion then fails closed.
final accountScopeHostProvider =
    writerProvider<AccountScopeHost?>((ref) => null);

final appleDeletionReauthProvider = writerProvider<AppleDeletionReauth>(
    (ref) => const PlatformAppleDeletionReauth());

/// Immediate, permanent deletion: operation-bound (prepare/challenge/Apple
/// re-auth/request/recover) with original-owner local removal. A writer provider,
/// so it is never built under an offline local-read scope.
final immediateDeletionFlowProvider = writerProvider<ImmediateDeletionFlow>((ref) {
  final host = ref.watch(accountScopeHostProvider);
  final base = Uri.tryParse(SupabaseConfig.url);
  if (host == null || !SupabaseConfig.isConfigured || base == null) {
    return const UnavailableDeletionFlow();
  }
  final supabase.SupabaseClient client;
  try {
    client = supabase.Supabase.instance.client;
  } catch (_) {
    return const UnavailableDeletionFlow();
  }
  final transport = http.Client();
  ref.onDispose(transport.close);
  return GatewayDeletionFlow(
    gateway: PreparedImmediateDeletionGateway(
      session: AppSession.instance,
      host: host,
      client: client,
      store: ImmediateDeletionReceiptStore(),
      transport: transport,
      functionUrl: base.replace(path: '/functions/v1/delete-account-immediate'),
      apiKey: SupabaseConfig.anonKey,
      retainReceiptUntilLocalRemoval: true,
    ),
    apple: ref.watch(appleDeletionReauthProvider),
    emailOnly: !Platform.isIOS,
    googleProof: (nonce) async {
      try {
        final credential = await authorizeIosGoogle(nonce);
        if (credential == null) return const AppleReauthCancelled();
        final token = credential['idToken'];
        if (token == null || token.isEmpty) return const AppleReauthFailed();
        return AppleReauthGranted(jsonEncode({'proof': 'google', 'identity_token': token}));
      } catch (_) {
        return const AppleReauthFailed();
      }
    },
  );
});

final accountDeletionStatusProvider =
    FutureProvider<AccountDeletionStatus>((ref) {
  return ref.watch(accountDeletionServiceProvider).getStatus();
});

final catalogSyncServiceProvider = writerProvider<CatalogSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CatalogSyncService(
    database: db,
    client: supabase.Supabase.instance.client,
    metadataDao: CatalogMetadataDao(db),
    announcementService: ref.watch(announcementServiceProvider),
  );
});

/// Captured scope identity; each local unit drains before removal closes its DB.
class AdmittedLocalWork implements CatalogLocalWork {
  AdmittedLocalWork._(this.ref, this.database, this.authority);
  final WidgetRef ref;
  final AppDatabase database;
  final AdmissionAuthority authority;
  static AdmittedLocalWork? capture(WidgetRef ref) {
    if (!ref.context.mounted) return null;
    final authority = AppSession.instance.captureLocalWorkAuthority();
    if (authority == null) return null;
    return AdmittedLocalWork._(ref, ref.read(appDatabaseProvider), authority);
  }

  @override
  bool get current =>
      ref.context.mounted &&
      authority.isCurrent &&
      identical(ref.read(appDatabaseProvider), database) &&
      AppSession.instance.status == SessionStatus.authenticated;
  @override
  Future<T> local<T>(Future<T> Function() action) {
    if (!current) throw const StaleAdmissionException();
    return AppSession.instance.runAdmittedLocalOperation(authority, action);
  }
}

Future<void> syncCatalog(
  WidgetRef ref, {
  String? countryCode,
  bool force = false,
  AdmittedLocalWork? work,
}) async {
  work ??= AdmittedLocalWork.capture(ref);
  if (work == null || !work.current) return;
  final captured = work;
  try {
    // Entry is already a disposal window: this is awaited from _onResume after
    // other awaits, so the shell can be gone before the first line runs.
    if (!ref.context.mounted) return;
    final database = ref.read(appDatabaseProvider);
    await captured.local(() => const SeedLoader().seedIfEmpty(database));
    if (!captured.current) return;

    // PARSER AUTHORITY EPOCH — before every early return below.
    //
    // This is a purely LOCAL reconcile: if a previous release left bundled rules
    // active, they are deactivated here. It must not sit behind the staleness or
    // Supabase-configured guards, because both of them are reasons a launch does
    // NO sync at all — and an upgraded install would then keep serving money
    // authority the current release does not trust, until the staleness window
    // happened to expire. The forced re-fetch half still lives in syncAll; this
    // half only ever removes authority, so running it early is always safe.
    await captured.local(() => ParserAuthority(
          RemoteParsersDao(database),
          CatalogMetadataDao(database),
          database,
        ).reconcile());
    if (!captured.current) return;

    // Init feature flags from seed data before first frame.
    await captured.local(() => initFeatureFlagService(database,
        applyRemoteOverrides: false, isCurrent: () => captured.current));
    if (!captured.current) return;
    await _refreshFeatureOverrides(() => captured.current);
    if (!captured.current) return;
    if (!SupabaseConfig.isConfigured) return;
    // Astra G (P1): no catalog fetch while Cloud is OFF (no automatic exception).
    if (!await CloudEgressGate.instance.permits()) return;
    if (!captured.current) return;
    if (!force && !await captured.local(() => _catalogSyncIsStale(database))) {
      return;
    }
    if (!captured.current) return;
    // The caller is AppShell — a route. Opening a top-level page disposes it
    // while the awaits above are in flight, and every `ref` use after that
    // throws (observed on a physical iPhone: ref.invalidate from here aborted a
    // post-auth run). Disposed means stop; the next resume repeats the sync.
    if (!ref.context.mounted) return;
    await ref
        .read(catalogSyncServiceProvider)
        .syncAll(countryCode: countryCode, localWork: captured);
    if (!captured.current) return;
    // Catalog sync replaces remote_feature_flags in Drift; refresh the same
    // runtime singleton used by sync gates before any outbox/pull work runs.
    await captured.local(() => initFeatureFlagService(database,
        applyRemoteOverrides: false, isCurrent: () => captured.current));
    if (!captured.current) return;
    await _refreshFeatureOverrides(() => captured.current);
    if (!captured.current) return;
    // Invalidate announcement providers so UI rebuilds with fresh data.
    if (!ref.context.mounted) return;
    ref.invalidate(activeAnnouncementsProvider);
    ref.invalidate(hasForceUpdateProvider);
    // Same-session flag reactivity (R4 §9): the report-ads placement gate must
    // re-evaluate after a live catalog sync (cold-start / resume) so it can act
    // as a production kill switch without an app restart.
    ref.invalidate(reportAdsEnabledProvider);
    // Banner flags ride the same re-sync. Without this a remote flip of
    // `enable_banner_ads` would need an app restart, which is not a kill switch.
    ref.invalidate(bannerAdsEnabledProvider);
    ref.invalidate(bannerPlacementEnabledProvider);
  } on StaleAdmissionException {
    // Scope revoked: the already-started local unit drained; no next unit starts.
  }
}

Future<bool> _catalogSyncIsStale(AppDatabase database) async {
  final metadata = CatalogMetadataDao(database);
  final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 15));
  for (final category in CatalogCategories.syncable) {
    final version = await metadata.getVersion(category);
    final syncedAt = version?.lastSyncedAt;
    if (syncedAt == null || syncedAt.isBefore(cutoff)) return true;
  }
  return false;
}

final activeCurrenciesProvider = FutureProvider<List<RemoteCurrency>>((ref) {
  return RemoteCurrenciesDao(ref.watch(appDatabaseProvider))
      .getActiveCurrencies();
});

final supportedCountriesProvider = FutureProvider<List<RemoteCountry>>((ref) {
  return RemoteCountriesDao(ref.watch(appDatabaseProvider))
      .getSupportedCountries();
});

final ledgerOutboxQueueProvider = writerProvider<LedgerOutboxQueue>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerOutboxQueue(
    db: db,
    isPushEnabled: () => true,
    onQueued: SyncWakeup.notify,
    getOwnerUid: localDataOwnerUid,
    getAuthUserId: () async {
      if (!SupabaseConfig.isConfigured) return null;
      try {
        return supabase.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    },
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

// S5: sync is a signed-in capability, not a UI routing experiment. Auth gates
// inside the queue/services keep guests local-only.
bool _planningAccountsSyncEnabled() => true;

bool _planningEntitySyncEnabled(String entityType) {
  return const {
    PlanningOutboxQueue.accountsEntityType,
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.subscriptionsEntityType,
    PlanningOutboxQueue.goalsEntityType,
    PlanningOutboxQueue.plansEntityType,
    PlanningOutboxQueue.cardsEntityType,
    PlanningOutboxQueue.settingsEntityType,
    PlanningOutboxQueue.categoriesEntityType,
    PlanningOutboxQueue.billPaymentsEntityType,
    PlanningOutboxQueue.goalContributionsEntityType,
    PlanningOutboxQueue.planLinksEntityType,
  }.contains(entityType);
}

Future<String?> _currentSupabaseUserId() async {
  if (!SupabaseConfig.isConfigured) return null;
  try {
    return supabase.Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

final planningOutboxQueueProvider = writerProvider<PlanningOutboxQueue>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: _planningEntitySyncEnabled,
    getAuthUserId: _currentSupabaseUserId,
    getOwnerUid: localDataOwnerUid,
    onQueued: SyncWakeup.notify,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

/// C-3 — one fresh-per-call consent read for an egress class. Settings are read
/// on every call (never cached) so a revocation is observed by the next drain.
Future<bool> Function() _consentGate(Ref ref, EgressClass egressClass) =>
    () => ConsentAuthority(
          () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
              .getSettings(),
        ).allows(egressClass);

final accountsPushServiceProvider = writerProvider<AccountsPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AccountsPushService(
    db: db,
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningAccountsSyncEnabled,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    casGate: ref.watch(revisionCasGateProvider),
    // C-3 — money must not leave the device without cloud consent. Read fresh
    // per push so a revocation is observed by the next drain, not the next boot.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
  );
});

/// Audit H-4: accounts PULL carries money (`initial_balance::text`,
/// `current_balance::text`, …), so it must consult the exact PULL transport
/// capability. It previously shared `_planningAccountsSyncEnabled` — a bare
/// `() => true` — with the push side, so an explicitly `unsupported` transport
/// could not disable it: every row would throw and wedge the cursor instead of
/// the pull simply not running. `exactPullAllowed` requires the same positive
/// proof as push; `unknown` and `unsupported` both block.
final accountsPullServiceProvider = writerProvider<AccountsPullService>((ref) {
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return AccountsPullService(
    db: ref.watch(appDatabaseProvider),
    isEnabled: () =>
        _planningAccountsSyncEnabled() && exactPullAllowed(pullCap),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

final planningPushServiceProvider = writerProvider<PlanningPushService>((ref) {
  return PlanningPushService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningEntitySyncEnabled,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    planningCurrencyCapability: () =>
        ref.read(planningServerCurrencyCapabilityProvider),
    casGate: ref.watch(revisionCasGateProvider),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    mayEgressProfile: _consentGate(ref, EgressClass.profileAndSettings),
    health: ref.watch(syncHealthProvider),
  );
});

/// MALI-026 (B8-3 §29/§30) — budgets/goals/goal_contributions carry per-row
/// planning currency that the SERVER only supports once 0077 is deployed AND the
/// capability is externally verified. Until then their cloud sync is DEFERRED
/// (never accept a legacy / missing-currency remote payload; never reconstruct a
/// currency from the base). Every other entity is unaffected. The gate depends
/// ONLY on the explicit capabilities — never on local schema/P3 state.
const _planningCurrencyGatedEntities = {
  PlanningOutboxQueue.budgetsEntityType,
  PlanningOutboxQueue.goalsEntityType,
  PlanningOutboxQueue.goalContributionsEntityType,
};

/// Direction-aware gate: a planning money entity syncs only when the SERVER
/// planning-currency capability AND that direction's exact decimal transport are
/// BOTH verified. [transportCap] is the exact PULL transport for pulls and the
/// exact PUSH transport for pushes. Non-planning entities keep their normal gate.
bool _planningEntitySyncEnabledWithCurrency(
  String entityType,
  ExactTransportCapability planningCurrencyCap,
  ExactTransportCapability transportCap,
) {
  if (!_planningEntitySyncEnabled(entityType)) return false;
  return planningMoneyEntitySyncEnabled(
    isPlanningCurrencyGatedEntity:
        _planningCurrencyGatedEntities.contains(entityType),
    planningCurrencyCapability: planningCurrencyCap,
    transportCapability: transportCap,
  );
}

final planningPullServiceProvider = writerProvider<PlanningPullService>((ref) {
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return PlanningPullService(
    db: ref.watch(appDatabaseProvider),
    // Audit H-4: the per-entity planning-currency gate only constrains the
    // three planning-currency entities — every OTHER money-bearing entity
    // (subscriptions, plans, bill_payments) short-circuited to `true` and so
    // never consulted the pull transport at all. The capability now applies to
    // the whole pull, with the planning gate layered on top of it.
    //
    // The planning-currency capability is a RUNTIME probe result, so it is read
    // at call time (never captured at provider build): every probe update is
    // seen by the next pull without rebuilding the service mid-sync.
    isEnabled: (entityType) =>
        exactPullAllowed(pullCap) &&
        _planningEntitySyncEnabledWithCurrency(entityType,
            ref.read(planningServerCurrencyCapabilityProvider), pullCap),
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    mayEgressProfile: _consentGate(ref, EgressClass.profileAndSettings),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

final planningChildSyncServiceProvider =
    writerProvider<PlanningChildSyncService>((ref) {
  final pushCap = ref.watch(exactPushTransportCapabilityProvider);
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  // Planning currency is a runtime probe result: read at call time below.
  ExactTransportCapability planningCap() =>
      ref.read(planningServerCurrencyCapabilityProvider);
  return PlanningChildSyncService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    // §29/§30 — goal_contributions inherit the parent goal's server currency,
    // so they are deferred until the planning-currency + exact PUSH transport
    // capabilities are both verified (this is a push-direction service).
    isEnabled: (entityType) => _planningEntitySyncEnabledWithCurrency(
        entityType, planningCap(), pushCap),
    // Pull authority is independent from push authority. The exact pull gate
    // covers every child family; the planning-currency gate is layered on top
    // for goal contributions, using the pull-direction transport capability.
    isPullEnabled: (entityType) =>
        exactPullAllowed(pullCap) &&
        _planningEntitySyncEnabledWithCurrency(
            entityType, planningCap(), pullCap),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    pullCapability: () => ref.read(exactPullTransportCapabilityProvider),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
    casGate: ref.watch(revisionCasGateProvider),
  );
});

final planningStartupRegistrationServiceProvider =
    writerProvider<PlanningStartupRegistrationService>((ref) {
  return PlanningStartupRegistrationService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningEntitySyncEnabled,
  );
});

/// Runtime probe for the SERVER planning-currency capability (migration 0077).
/// Publishes its result to [planningServerCurrencyCapabilityProvider] and to
/// [SyncHealth]; consent-gated (financialSync, fresh per probe) and signed-in only.
final planningCurrencyCapabilityProbeProvider =
    writerProvider<PlanningCurrencyCapabilityProbe>((ref) {
  return PlanningCurrencyCapabilityProbe(
    getAuthUserId: () async {
      try {
        return supabase.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    },
    probeCurrencyColumn: PlanningCurrencyCapabilityProbe.clientProbe(
        () => supabase.Supabase.instance.client),
    onChanged: (cap) =>
        ref.read(planningServerCurrencyCapabilityProvider.notifier).set(cap),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
  );
});

final planningSyncEngineProvider = writerProvider<PlanningSyncEngine>((ref) {
  return PlanningSyncEngine(
    ensureCapabilities: () =>
        ref.read(planningCurrencyCapabilityProbeProvider).ensure(),
    accountsPushService: ref.watch(accountsPushServiceProvider),
    accountsPullService: ref.watch(accountsPullServiceProvider),
    planningPushService: ref.watch(planningPushServiceProvider),
    planningPullService: ref.watch(planningPullServiceProvider),
    planningChildSyncService: ref.watch(planningChildSyncServiceProvider),
    startupRegistrationService:
        ref.watch(planningStartupRegistrationServiceProvider),
    conflictResolver: ref.watch(conflictResolverProvider),
    health: ref.watch(syncHealthProvider),
  );
});

/// A-6: server capability probe (awaiting-FX transactions), consent-gated.
final serverCapabilitiesServiceProvider =
    writerProvider<ServerCapabilitiesService>((ref) {
  return ServerCapabilitiesService(
    getAuthUserId: () async {
      if (!SupabaseConfig.isConfigured) return null;
      try {
        return supabase.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    },
    getClient: () => supabase.Supabase.instance.client,
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
  );
});

/// WP-4: one gate for every pull service (single capability answer, single head
/// read per sync cycle). The `sync_seq` capability is false in production, so
/// every service keeps its legacy timestamp pull.
final seqPullGateProvider = writerProvider<SeqPullGate>((ref) {
  return SeqPullGate(
    db: ref.watch(appDatabaseProvider),
    capability: () => ref.read(serverCapabilitiesServiceProvider).syncSeq(),
  );
});

/// WP-5: one decision per push cycle for every push service. While
/// `revision_cas` is false (production until G4) the plan is `legacy` and every
/// push service runs its legacy guarded path unchanged.
final revisionCasGateProvider = writerProvider<RevisionCasGate>((ref) {
  return RevisionCasGate(
    db: ref.watch(appDatabaseProvider),
    capability: () => ref.read(serverCapabilitiesServiceProvider).revisionCas(),
  );
});

final ledgerPushServiceProvider = writerProvider<LedgerPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerPushService(
    db: db,
    queue: ref.watch(ledgerOutboxQueueProvider),
    isPushEnabled: () => true,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    capabilities: ref.watch(serverCapabilitiesServiceProvider),
    casGate: ref.watch(revisionCasGateProvider),
    // C-3 — money must not leave the device without cloud consent. Read fresh
    // per push so a revocation is observed by the next drain, not the next boot.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
  );
});

/// الواجهة تقرأ/تكتب من Drift دائمًا؛ المزامنة خلفية عبر outbox/push/pull.
final transactionRepositoryProvider = writerProvider<TransactionRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftTransactionRepository(
    db,
    outboxQueue: ref.watch(ledgerOutboxQueueProvider),
  );
});

final suspectedDuplicateRepositoryProvider =
    writerProvider<SuspectedDuplicateRepository>((ref) {
  return DriftSuspectedDuplicateRepository(ref.watch(appDatabaseProvider));
});

final suspectedDuplicatesProvider =
    FutureProvider<List<SuspectedDuplicateEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(suspectedDuplicateRepositoryProvider).getAll();
});

final smartInboxRepositoryProvider = writerProvider<SmartInboxRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftSmartInboxRepository(db);
});

final smartInboxItemsProvider =
    FutureProvider<List<SmartInboxItemEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(smartInboxRepositoryProvider).getOpen();
});

/// S5: الواجهة تقرأ/تكتب من Drift دائمًا؛ المزامنة خلفية عبر outbox/push/pull.
final accountRepositoryProvider = writerProvider<AccountRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftAccountRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    ledgerOutboxQueue: ref.watch(ledgerOutboxQueueProvider),
  );
});

/// مستودع البطاقات الحقيقية (محلي في A1؛ مزامنة Supabase تُضاف في A1b).
final cardRepositoryProvider = writerProvider<CardRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftCardRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

/// MALI-053n/011: pre-sign-out inventory of locally-pending user artifacts.
final unsyncedInventoryServiceProvider =
    writerProvider<UnsyncedInventoryService>((ref) {
  return UnsyncedInventoryService(
    ref.watch(appDatabaseProvider),
    localOnlyCardCount:
        ref.watch(cardRepositoryProvider).countCapabilityGatedUnsyncedCards,
  );
});

/// قائمة الحسابات (تتحدّث عند الإضافة/التعديل عبر invalidate).
final accountsProvider = FutureProvider<List<AccountEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(accountRepositoryProvider).getAll();
});

/// Makes authenticated data providers account-aware. The root ProviderScope
/// survives sign-out/sign-in, so without this dependency a FutureProvider can
/// keep the previous user's successful value in memory.
final appSessionRevisionProvider = StateProvider<int>((ref) {
  void onSessionChanged() => ref.controller.state += 1;

  AppSession.instance.addListener(onSessionChanged);
  ref.onDispose(
    () => AppSession.instance.removeListener(onSessionChanged),
  );
  return 0;
});

/// الحساب النشط عبر الشاشات الرئيسية. null يعني الحساب الافتراضي الحالي.
final activeAccountIdProvider = StateProvider<String?>((ref) {
  void resetSelectedAccount() => ref.controller.state = null;

  AppSession.instance.addListener(resetSelectedAccount);
  ref.onDispose(
    () => AppSession.instance.removeListener(resetSelectedAccount),
  );
  return null;
});

/// عملة الأساس للعرض في الشاشات العامة — من الحساب النشط، ثم الافتراضي، ثم
/// إعدادات المستخدم.
final baseCurrencyProvider = FutureProvider<String>((ref) async {
  ref.watch(dbRevisionProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final activeAccountId = ref.watch(activeAccountIdProvider);
  final activeAccount = activeAccountId == null
      ? null
      : await accountRepo.getById(activeAccountId);
  if (activeAccount != null) return activeAccount.currency;
  final account = await accountRepo.getDefault();
  if (account != null) return account.currency;
  final settings =
      await ref.watch(userSettingsRepositoryProvider).getSettings();
  return settings.currency;
});

/// Admin-managed brand logos keyed by uppercase merchant keyword. Empty until
/// the synced catalog carries `logo_url` values. UI resolves a merchant name
/// against these to show a real logo.
final merchantLogosProvider = FutureProvider<Map<String, String>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final keywords = await RemoteMerchantKeywordsDao(db).getAll();
  return {
    for (final kw in keywords)
      if (kw.logoUrl != null && kw.logoUrl!.isNotEmpty)
        kw.keyword.toUpperCase(): kw.logoUrl!,
  };
});

final billRepositoryProvider = writerProvider<BillRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftBillRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final planRepositoryProvider = writerProvider<PlanRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftPlanRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final merchantCategoryRepositoryProvider =
    writerProvider<MerchantCategoryRepository>((ref) {
  return DriftMerchantCategoryRepository(ref.watch(appDatabaseProvider));
});

final budgetRepositoryProvider = writerProvider<BudgetRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftBudgetRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

final goalRepositoryProvider = writerProvider<GoalRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftGoalRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

/// MALI-022 / MALI-057n — the universal, policy-driven conflict resolver
/// (replaces the planning-only resolver). Covers all twelve synced entities;
/// the keep-local re-enqueue is wired per interactive entity via its typed
/// repository + outbox queue, so resolving carries the current local state.
final conflictResolverProvider = writerProvider<UniversalConflictResolver>((ref) {
  final ledgerQueue = ref.watch(ledgerOutboxQueueProvider);
  final planningQueue = ref.watch(planningOutboxQueueProvider);
  final transactions = ref.watch(transactionRepositoryProvider);
  final accounts = ref.watch(accountRepositoryProvider);
  final budgets = ref.watch(budgetRepositoryProvider);
  final goals = ref.watch(goalRepositoryProvider);
  final bills = ref.watch(billRepositoryProvider);
  final plans = ref.watch(planRepositoryProvider);
  // Keep-remote refetches the current server row and applies it through the
  // SAME pull services (consent / capability / owner gated like any pull).
  final ledgerPull = ref.watch(ledgerSyncServiceProvider);
  final accountsPull = ref.watch(accountsPullServiceProvider);
  final planningPull = ref.watch(planningPullServiceProvider);
  ConflictRemoteSync planningSync(String entityType) => ConflictRemoteSync(
        fetch: (serverId) => planningPull.fetchServerRow(entityType, serverId),
        apply: (row) => planningPull.applyServerRow(entityType, row),
      );

  return UniversalConflictResolver(
    db: ref.watch(appDatabaseProvider),
    remoteSync: {
      ConflictEntities.transaction: ConflictRemoteSync(
        fetch: ledgerPull.fetchServerRow,
        apply: ledgerPull.applyServerRow,
      ),
      ConflictEntities.account: ConflictRemoteSync(
        fetch: accountsPull.fetchServerRow,
        apply: accountsPull.applyServerRow,
      ),
      ConflictEntities.budget:
          planningSync(PlanningOutboxQueue.budgetsEntityType),
      ConflictEntities.goal: planningSync(PlanningOutboxQueue.goalsEntityType),
      ConflictEntities.subscription:
          planningSync(PlanningOutboxQueue.subscriptionsEntityType),
      ConflictEntities.plan: planningSync(PlanningOutboxQueue.plansEntityType),
      ConflictEntities.card: planningSync(PlanningOutboxQueue.cardsEntityType),
      ConflictEntities.category:
          planningSync(PlanningOutboxQueue.categoriesEntityType),
    },
    // WP-5: keep-mine against a cloud tombstone re-creates the transaction as
    // a NEW one (a tombstone is never un-deleted).
    retireChildren: {
      ConflictEntities.goal: (id) =>
          retireUnsyncedGoalChildren(ref.read(appDatabaseProvider), id),
      ConflictEntities.plan: (id) =>
          retireUnsyncedPlanChildren(ref.read(appDatabaseProvider), id),
    },
    restoreAsNew: {
      // D1: goals and plans too (new identity; unsynced children copied).
      ConflictEntities.goal: (id) => restoreGoalAsNew(
          db: ref.read(appDatabaseProvider), goals: goals, localId: id),
      ConflictEntities.plan: (id) => restorePlanAsNew(
          db: ref.read(appDatabaseProvider), plans: plans, localId: id),
      ConflictEntities.transaction: (id) async {
        final e = await transactions.getById(id);
        if (e == null) return;
        // WP-7: a recovered create that lost to a tombstone is stored ignored;
        // its original status is in the conflict's `mine`.
        var status = e.status;
        if (status == TransactionStatus.ignored) {
          final mine = (await SyncConflictStore(ref.read(appDatabaseProvider))
                  .openFor(ConflictEntities.transaction, id))
              ?.mine?['status'];
          for (final v in TransactionStatus.values) {
            if (v.name == mine && v != TransactionStatus.ignored) status = v;
          }
        }
        await transactions.saveTransaction(
          transaction: e.copyWith(id: IdGenerator.next(), status: status),
          categoryKey: null,
          resolvedCategoryId: e.categoryId,
        );
      },
    },
    reEnqueue: {
      ConflictEntities.transaction: (id) async {
        final e = await transactions.getById(id);
        if (e != null) await ledgerQueue.enqueue(OutboxOperation.update, e);
      },
      ConflictEntities.account: (id) async {
        final e = await accounts.getById(id);
        if (e != null) {
          await planningQueue.enqueueAccount(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.budget: (id) async {
        final e = await budgets.getById(id);
        if (e != null) {
          await planningQueue.enqueueBudget(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.goal: (id) async {
        final e = await goals.getById(id);
        if (e != null) {
          await planningQueue.enqueueGoal(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.subscription: (id) async {
        final e = await bills.getById(id);
        if (e != null) {
          await planningQueue.enqueueSubscription(
              PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.plan: (id) async {
        final e = await plans.getById(id);
        if (e != null) {
          await planningQueue.enqueuePlan(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.card: (id) async {
        final e = await ref.read(cardRepositoryProvider).getById(id);
        if (e != null) {
          await planningQueue.enqueueCard(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.category: (id) async {
        final all = await ref.read(categoryRepositoryProvider).getAll();
        for (final e in all) {
          if (e.id == id) {
            await planningQueue.enqueueCategory(
                PlanningSyncOperation.update, e);
          }
        }
      },
    },
    baseFetcher: SupabaseConfig.isConfigured
        ? (remoteTable, serverId) async {
            try {
              final row = await supabase.Supabase.instance.client
                  .from(remoteTable)
                  .select('updated_at, revision')
                  .eq('id', serverId)
                  .maybeSingle();
              if (row == null) return null;
              return ConflictBase(
                updatedAt: row['updated_at'] as String?,
                revision: (row['revision'] as num?)?.toInt(),
              );
            } catch (_) {
              return null;
            }
          }
        : null,
  );
});

/// The current unresolved conflicts across all interactive entities (drives the
/// resolution UI + badge).
final conflictsProvider = FutureProvider<List<SyncConflict>>((ref) {
  ref.watch(dbRevisionProvider); // refresh when any DB write lands
  return ref.watch(conflictResolverProvider).listConflicts();
});

/// MALI-016 — the authoritative, dependency-aware account-deletion path
/// (detach transactions; archive cards/budgets; reassign-or-archive goals &
/// subscriptions with currency checks; atomic; structured result).
final financialAccountDeletionServiceProvider =
    writerProvider<FinancialAccountDeletionService>((ref) {
  return FinancialAccountDeletionService(
    db: ref.watch(appDatabaseProvider),
    accounts: ref.watch(accountRepositoryProvider),
    cards: ref.watch(cardRepositoryProvider),
    budgets: ref.watch(budgetRepositoryProvider),
    goals: ref.watch(goalRepositoryProvider),
    bills: ref.watch(billRepositoryProvider),
  );
});

/// Fail-closed account-currency edit guard. Loading/error states remain locked
/// in the form; a successful `false` is the only state that permits an empty
/// existing account to change currency.
final accountHasTransactionsProvider =
    FutureProvider.family<bool, String>((ref, accountId) {
  return ref
      .watch(financialAccountDeletionServiceProvider)
      .hasTransactions(accountId);
});

final gamificationRepositoryProvider = writerProvider<GamificationRepository>((ref) {
  return DriftGamificationRepository(ref.watch(appDatabaseProvider));
});

final userSettingsRepositoryProvider = writerProvider<UserSettingsRepository>((ref) {
  return DriftUserSettingsRepository(
    ref.watch(appDatabaseProvider),
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

/// The typed consent writer of the live scope's database (same database and the
/// same atomic local outbox as [userSettingsRepositoryProvider]). Every consent
/// decision goes through it; the generic settings save stays for the settings
/// that are not consent.
final consentSettingsWriterProvider = writerProvider<ConsentSettingsWriter>((ref) {
  return DriftUserSettingsRepository(
    ref.watch(appDatabaseProvider),
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

/// Local-only, field-scoped writer: deliberately has no settings outbox.
final merchantPreferenceWriterProvider =
    writerProvider<MerchantPreferenceWriter>((ref) {
  return DriftUserSettingsRepository(ref.watch(appDatabaseProvider));
});

final categoryRepositoryProvider = writerProvider<CategoryRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  // S0: القراءة من Drift دائمًا. S3: الكتابات تُدرَج في الـ outbox وتُزامَن خلفيًا.
  return DriftCategoryRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    ledgerOutboxQueue: ref.watch(ledgerOutboxQueueProvider),
  );
});

final dataPortabilityServiceProvider = writerProvider<DataPortabilityService>((ref) {
  return AppDataPortabilityService(
    db: ref.watch(appDatabaseProvider),
    accounts: ref.watch(accountRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    transactions: ref.watch(transactionRepositoryProvider),
    settings: ref.watch(userSettingsRepositoryProvider),
    ledgerOutbox: ref.watch(ledgerOutboxQueueProvider),
    planningOutbox: ref.watch(planningOutboxQueueProvider),
    isCloudOwned: () async =>
        await localDataOwnerUid() != null ||
        await _currentSupabaseUserId() != null,
  );
});

final recordEngagementUseCaseProvider =
    writerProvider<RecordEngagementUseCase>((ref) {
  return RecordEngagementUseCase(
    gamificationRepository: ref.watch(gamificationRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    userSettingsRepository: ref.watch(userSettingsRepositoryProvider),
    onUpdate: (update) =>
        CelebrationRuntime.instance.pushAll(update.celebrations),
  );
});

final senderBankMappingRepositoryProvider =
    writerProvider<SenderBankMappingRepository>((ref) {
  return DriftSenderBankMappingRepository(ref.watch(appDatabaseProvider));
});

final resolveBankForSenderUseCaseProvider =
    writerProvider<ResolveBankForSenderUseCase>((ref) {
  return ResolveBankForSenderUseCase(
    mappingRepository: ref.watch(senderBankMappingRepositoryProvider),
  );
});

final bankDiscoveryClientProvider = writerProvider<BankDiscoveryClient?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return GeminiBankDiscoveryClient(
    edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/bank-discovery',
    getAnonJwt: () async =>
        supabase.Supabase.instance.client.auth.currentSession?.accessToken ??
        SupabaseConfig.anonKey,
    loadDeviceSecret:
        ref.read(captureDeviceRegistrationServiceProvider).readDeviceSecret,
  );
});

final bankDiscoveryServiceProvider = writerProvider<BankDiscoveryService?>((ref) {
  final client = ref.watch(bankDiscoveryClientProvider);
  if (client == null) return null;
  return BankDiscoveryService(
    mappingRepository: ref.watch(senderBankMappingRepositoryProvider),
    client: client,
    loadAiConsent: () async {
      final settings = await DriftUserSettingsRepository(
        ref.read(appDatabaseProvider),
      ).getSettings();
      // OD-07 / C-3 — AI needs BOTH consents, matching
      // `ConsentAuthority.decide(EgressClass.aiProcessing)`: "restrictive state
      // wins". This used to read `aiConsentGranted` alone, so a user with cloud
      // processing OFF and AI ON still had sanitized SMS text transmitted —
      // contradicting the LIVE privacy policy, which promises that with cloud
      // off "no financial data leaves your device — this is enforced at every
      // network call, not only in the settings UI".
      return ConsentAuthority.decide(EgressClass.aiProcessing, settings);
    },
    loadInstallId: InstallId.get,
  );
});

final senderBankMappingSyncServiceProvider =
    writerProvider<SenderBankMappingSyncService?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return SenderBankMappingSyncService(
    db: ref.watch(appDatabaseProvider),
    remoteStore: SupabaseSenderBankMappingRemoteStore(
      supabase.Supabase.instance.client,
    ),
    currentUserId: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    // C-3 — which banks the user holds is a direct read on their financial
    // life. Consulted fresh on every sync so a revocation is observed.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.senderBankMappings),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

/// D6: `InstallId.get()` CREATES and persists an id when none exists (a
/// secure-storage write), so it is never built under a local-read scope.
final installIdProvider = FutureProvider<String>((ref) {
  if (ref.watch(accountAccessModeProvider) == AccountAccessMode.localRead) {
    throw const LocalReadWriterDenied();
  }
  return InstallId.get();
});

final captureBackendClientProvider = writerProvider<CaptureBackendClient?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return CaptureBackendClient(
    supabaseUrl: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );
});

final captureDeviceRegistrationServiceProvider =
    writerProvider<CaptureDeviceRegistrationService>((ref) {
  final database = ref.watch(appDatabaseProvider);
  var disposed = false;
  final service = CaptureDeviceRegistrationService(
    settingsRepository: DriftUserSettingsRepository(database),
    client: ref.watch(captureBackendClientProvider),
    isCurrentScope: () =>
        !disposed && identical(ref.read(appDatabaseProvider), database),
  );
  ref.onDispose(() {
    disposed = true;
    service.dispose();
  });
  return service;
});

/// Live device-registration status, mirrored from the service's ValueListenable.
final captureRegistrationStatusProvider = NotifierProvider<
    _CaptureRegistrationStatusNotifier,
    CaptureRegistrationStatus>(_CaptureRegistrationStatusNotifier.new);

class _CaptureRegistrationStatusNotifier
    extends Notifier<CaptureRegistrationStatus> {
  @override
  CaptureRegistrationStatus build() {
    final source = ref.watch(captureDeviceRegistrationServiceProvider).status;
    void onChange() => state = source.value;
    source.addListener(onChange);
    ref.onDispose(() => source.removeListener(onChange));
    return source.value;
  }
}

/// Phase 1 notification tracking (docs/NOTIFICATION_PIPELINE_AUDIT.md).
final notificationLogServiceProvider = writerProvider<NotificationLogService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  return NotificationLogService(db,
      isCurrentScope: () =>
          !disposed && identical(ref.read(appDatabaseProvider), db),
      readOrigin: () => readNotificationLogOrigin(db,
          isCurrentScope: () =>
              !disposed && identical(ref.read(appDatabaseProvider), db)));
});

final notificationLogSyncServiceProvider =
    writerProvider<NotificationLogSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  return NotificationLogSyncService(
    db: db,
    readOrigin: () => readNotificationLogOrigin(db,
        isCurrentScope: () =>
            !disposed && identical(ref.read(appDatabaseProvider), db)),
    // C-3 — telemetry about the user's notifications.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.telemetry),
  );
});

final captureSyncServiceProvider = writerProvider<CaptureSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final ingest = ref.watch(ingestCapturedMessageUseCaseProvider);
  return CaptureSyncService(
    settingsRepository: DriftUserSettingsRepository(db),
    // Relay captures land in Drift AND enqueue on the ledger outbox, so the
    // background push publishes them to Supabase exactly like a manual add.
    transactionRepository: DriftTransactionRepository(
      db,
      outboxQueue: ref.watch(ledgerOutboxQueueProvider),
    ),
    dedupStore: DriftDedupStore(db),
    smartInboxRepository: DriftSmartInboxRepository(db),
    suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
    registrationService: ref.watch(captureDeviceRegistrationServiceProvider),
    ownershipGuard: OwnershipGuard(),
    currentUserId: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    accountRepository: ref.watch(accountRepositoryProvider),
    client: ref.watch(captureBackendClientProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    isLocalAutoConfirmV2: () => featureFlags.getBool('local_auto_confirm_v2'),
    // Strictly on-device retry of a backend-rejected capture (no AI, bank
    // discovery or merchant enrichment).
    recoverLocally: (message) =>
        ingest.fromCapturedMessage(message, onDeviceOnly: true),
    // Native raw text for the same payloadId (iOS only; no match => null).
    lookupNativeCapture: (payloadId) async {
      if (!Platform.isIOS) return null;
      final pending = await NativeCaptureBridge.peekPendingSharedMessages();
      for (final m in pending) {
        if (m.id?.trim() == payloadId) return m;
      }
      return null;
    },
  );
});

/// CAP-5: the iOS capture import, bound to the account scope. Built per scope
/// (the root `ProviderScope` is keyed by the scope generation), so it can only
/// ever touch the active replica. Used only behind `capture_import_v3`.
final captureImportServiceProvider = writerProvider<CaptureImportService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final sync = ref.watch(captureSyncServiceProvider);
  return CaptureImportService(
    aiPrimarySelected: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      return settings.cloudProcessingEnabled && settings.aiConsentGranted;
    },
    queue: const NativeCaptureImportQueue(),
    server: ref.watch(captureServerPortProvider),
    captureSyncService: sync,
    receipts: CaptureReceipts(db),
    // On device only, by construction: the import path makes no AI call.
    ingestLocal: CaptureImportService.localIngest(
        ref.watch(ingestCapturedMessageUseCaseProvider)),
    sessionUid: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    replicaOwnerUid: () => replicaOwnerUid(db),
    ownershipGuard: OwnershipGuard(),
  );
});

final captureServerPortProvider = writerProvider<CaptureServerPort>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return BackendCaptureServerPort(
    settingsRepository: DriftUserSettingsRepository(db),
    registrationService: ref.watch(captureDeviceRegistrationServiceProvider),
    captureSyncService: ref.watch(captureSyncServiceProvider),
    client: ref.watch(captureBackendClientProvider),
    useContractV2: () async =>
        await ref.read(serverCapabilitiesServiceProvider).captureContractV2() ==
        ServerCapabilityState.verified,
    accessToken: () async =>
        supabase.Supabase.instance.client.auth.currentSession?.accessToken,
  );
});

/// BL-2: the "bank messages received while you were signed out" prompt logic.
final unboundCapturePromptServiceProvider =
    writerProvider<UnboundCapturePromptService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return UnboundCapturePromptService(
    queue: const NativeCaptureImportQueue(),
    sessionUid: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    replicaOwnerUid: () => replicaOwnerUid(db),
    isEnabled: () => featureFlags.getBool('capture_import_v3'),
  );
});

/// §4.7: removes legacy v2 queue items the adopted replica proves consumed.
final legacyCaptureResolverProvider = writerProvider<LegacyCaptureResolver>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LegacyCaptureResolver(
    queue: const NativeCaptureImportQueue(),
    db: db,
    sessionUid: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    replicaOwnerUid: () => replicaOwnerUid(db),
    // A6: the native read-only listing feeds the fingerprint review annotation.
    legacyItems: () async => [
      for (final item in await NativeCaptureBridge.peekLegacyCaptureItems())
        LegacyCaptureItem(
          id: item.id,
          text: item.text,
          receivedAt: item.receivedAt,
        ),
    ],
  );
});

/// Audit H-4: the ledger pull carries money (`amount::text`,
/// `balance_after::text`, `foreign_amount::text`) and must consult the exact
/// PULL transport capability — `isPullEnabled: () => true` gave it no way to be
/// switched off. `exactPullAllowed` requires positive transport proof.
final ledgerSyncServiceProvider = writerProvider<LedgerSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return LedgerSyncService(
    db: db,
    transactionRepository: DriftTransactionRepository(db),
    dedupStore: DriftDedupStore(db),
    isPullEnabled: () => exactPullAllowed(pullCap),
    mayEgress: _consentGate(ref, EgressClass.financialSync),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

/// Outbox depth for the sync-health surface (counts only).
final syncQueueCountsProvider = FutureProvider.autoDispose<SyncQueueCounts>(
  (ref) => SyncHealth.queueCounts(ref.watch(appDatabaseProvider)),
);

/// A-5: Retry / auth-recovery for stuck sync work. The capability re-probe is
/// forced (bypasses the per-session cache); it is consent-gated inside.
final syncRecoveryServiceProvider = writerProvider<SyncRecoveryService>((ref) {
  return SyncRecoveryService(
    db: ref.watch(appDatabaseProvider),
    ledgerQueue: ref.watch(ledgerOutboxQueueProvider),
    planningQueue: ref.watch(planningOutboxQueueProvider),
    reprobeCapabilities: () async {
      await ref
          .read(serverCapabilitiesServiceProvider)
          .awaitingFxTransactions(force: true);
      await ref
          .read(planningCurrencyCapabilityProbeProvider)
          .ensure(force: true);
    },
    wakeup: SyncWakeup.notify,
  );
});

final ledgerSyncEngineProvider = writerProvider<LedgerSyncEngine>((ref) {
  return LedgerSyncEngine(
    pushService: ref.watch(ledgerPushServiceProvider),
    pullService: ref.watch(ledgerSyncServiceProvider),
    health: ref.watch(syncHealthProvider),
  );
});

final smartInboxSyncServiceProvider = writerProvider<SmartInboxSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return SmartInboxSyncService(
    db: db,
    isPullEnabled: () => true,
    // C-3 — Smart Inbox items are user data. `isPullEnabled` above is a FEATURE
    // gate hardcoded open; consent is a separate question and must be asked.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.smartInbox),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

/// One idempotent reconcile of local accounts/transactions that never reached
/// Supabase (pre-outbox data, the migration-seeded default account, or a
/// background capture that had no session at write time). See
/// [StartupSyncReconcileService].
/// A-4b: records sync intent for server-backed rows a raw-SQL bypass writer left
/// `pending` with no outbox row. Run at the start of each sync cycle.
final pendingSyncReconcilerProvider = writerProvider<PendingSyncReconciler>((ref) {
  return PendingSyncReconciler(
    db: ref.watch(appDatabaseProvider),
    ledgerQueue: ref.watch(ledgerOutboxQueueProvider),
    planningQueue: ref.watch(planningOutboxQueueProvider),
    getOwnerUid: localDataOwnerUid,
    getAuthUserId: _currentSupabaseUserId,
    health: ref.watch(syncHealthProvider),
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.financialSync),
  );
});

final startupSyncReconcileServiceProvider =
    writerProvider<StartupSyncReconcileService>((ref) {
  return StartupSyncReconcileService(
    db: ref.watch(appDatabaseProvider),
    planningCurrencyFor: (table) =>
        ref.read(planningCurrencyCapabilityProbeProvider).ensureTable(table),
    health: ref.watch(syncHealthProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    // Audit H-4: the backfills are a push path and obey the same transport
    // authority as the outbox push services.
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    // C-3 — ...and the same CONSENT authority. Transport capability answers
    // "can we send this safely"; it never answered "may we". This path was an
    // OPEN egress finding for exactly that reason while every sibling service
    // in the pipeline already asked.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.financialSync),
  );
});

/// OD-13 — the process-wide on-device merchant model.
///
/// One instance for the whole app. Capture used to build one per `Categorizer`,
/// i.e. twice per transaction, refitting ~330 exemplars each time and throwing
/// away anything learned. Sharing it here is what makes a user correction able
/// to outlive the call that produced it.
///
/// It is seeded lazily from the user's persisted merchant confirmations, so the
/// learned map stays the single source of truth and no second store exists.
final merchantIntelligenceProvider = writerProvider<MerchantIntelligenceStore>((ref) {
  final store = MerchantIntelligenceStore();
  // Fire-and-forget rehydrate: the model is an optional suggestion source, so
  // capture must never wait on it. Until it resolves the model simply behaves
  // as a freshly-seeded one, which is exactly the pre-fix behaviour.
  ref
      .watch(merchantCategoryRepositoryProvider)
      .getLearnedCategoryMap()
      .then(store.seedFromLearnedMap)
      .catchError((_) {});
  return store;
});

final addTransactionUseCaseProvider = writerProvider<AddTransactionUseCase>((ref) {
  // Capture the DB once at build time. The async callbacks below run later
  // (during a slow AI call); reading `ref` inside them would throw if this
  // provider rebuilt in the meantime (e.g. installId resolving).
  final db = ref.watch(appDatabaseProvider);
  return AddTransactionUseCase(
    // PHASE 11 — Proof gate config, read at CALL TIME so a remote flag flip
    // takes effect on the next capture without rebuilding the use case. This is
    // the kill switch's propagation path.
    // `local_auto_confirm_v2`, read at call time (remote kill switch).
    isLocalAutoConfirmV2: () => featureFlags.getBool('local_auto_confirm_v2'),
    proofGateMode: () => featureFlags.getBool('enable_proof_autocommit')
        ? ProofGateMode.armed
        : ProofGateMode.shadow,
    // PHASE 11 — the DURABLE shadow recorder. Previously null, which meant the
    // gate computed findings and dropped them, so Tier 2 could count nothing.
    // Fire-and-forget: the DAO swallows its own failures, and this is not
    // awaited, so a diagnostic write can neither fail nor slow a commit.
    recordProofShadow: (record) {
      // Uses the captured `db`, not ref.read: this provider explicitly captures
      // it because reading `ref` inside a closure throws if the provider
      // rebuilds — which would silently stop recording.
      unawaited(ProofShadowDao(db).record(record));
    },
    proofParserConfidenceMinPermille: () {
      final v = featureFlags.getInt('proof_parser_confidence_min');
      // TUNE-UPWARD-ONLY. A range check would have accepted any value in 1..989
      // and silently LOWERED the floor — a remote `99` (the plausible
      // percent-for-permille typo) would have dropped it from 990‰ to ~10%.
      // Remote config may make this gate stricter; it may never make it looser
      // than what shipped.
      return (v > ProofCommitGate.defaultParserConfidenceMinPermille &&
              v <= 1000)
          ? v
          : ProofCommitGate.defaultParserConfidenceMinPermille;
    },
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    merchantIntelligence: ref.watch(merchantIntelligenceProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    logMetric: ref.watch(metricsClientProvider).logEvent,
    loadBankProfiles: ref.watch(rulesClientProvider).localBankProfiles,
    // F-016: raw catalog rules — the engine's first parsing authority.
    loadCatalogRules: ref.watch(rulesClientProvider).catalogRulesForSender,
    loadRemoteKeywords: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      final country = settings.country;
      return country.isEmpty
          ? RemoteMerchantKeywordsDao(db).getAll()
          : RemoteMerchantKeywordsDao(db).getActiveForCountry(country);
    },
    noteMerchantFeedback: (keyword) =>
        PendingMerchantFeedbackDao(db).record(keyword),
    // Real-time category assist for unknown merchants: when neither rules nor
    // AI know the merchant, the enrich-merchant Edge Function looks it up via
    // Google Places, returns a category, and writes it to merchant_keywords for
    // every device. Only available when the backend is configured.
    resolveMerchantCategory: SupabaseConfig.isConfigured
        ? (keyword) async {
            try {
              final settings =
                  await DriftUserSettingsRepository(db).getSettings();
              final deviceSecret = await ref
                  .read(captureDeviceRegistrationServiceProvider)
                  .readDeviceSecret();
              final res = await supabase.Supabase.instance.client.functions
                  .invoke('enrich-merchant', body: {
                'merchant_name': keyword,
                'country_code': settings.country,
                'write': true,
                'install_id': await InstallId.get(),
                if (deviceSecret != null && deviceSecret.isNotEmpty)
                  'device_secret': deviceSecret,
                'request_id': IdGenerator.uuidV4(),
                'schema_version': 1,
              });
              final data = res.data;
              if (data is Map && data['matched'] == true) {
                return data['category'] as String?;
              }
            } catch (_) {
              // Network/auth failure — fall back to the feedback queue.
            }
            return null;
          }
        : null,
    // C-3 — the merchant name comes from a financial message; enrichment needs
    // fresh cloud consent, read at call time.
    mayEnrichMerchant: () => ConsentAuthority(
      () => DriftUserSettingsRepository(db).getSettings(),
    ).allows(EgressClass.financialSync),
    accountRepository: ref.watch(accountRepositoryProvider),
    dedupStore: DriftDedupStore(db),
    aiClient: SupabaseConfig.isConfigured
        ? SupabaseAiParserClient(
            edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/parse-sms',
            getAnonJwt: () async =>
                supabase.Supabase.instance.client.auth.currentSession
                    ?.accessToken ??
                SupabaseConfig.anonKey,
            loadDeviceSecret: ref
                .read(captureDeviceRegistrationServiceProvider)
                .readDeviceSecret,
          )
        : null,
    aiPrimarySelected: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      return settings.cloudProcessingEnabled && settings.aiConsentGranted;
    },
    loadAiConsent: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      // OD-07 / C-3 — AI needs BOTH consents, matching
      // `ConsentAuthority.decide(EgressClass.aiProcessing)`: "restrictive state
      // wins". This used to read `aiConsentGranted` alone, so a user with cloud
      // processing OFF and AI ON still had sanitized SMS text transmitted —
      // contradicting the LIVE privacy policy, which promises that with cloud
      // off "no financial data leaves your device — this is enforced at every
      // network call, not only in the settings UI".
      return ConsentAuthority.decide(EgressClass.aiProcessing, settings);
    },
    loadInstallId: InstallId.get,
    resolveBankForSenderUseCase: ref.watch(resolveBankForSenderUseCaseProvider),
    bankDiscoveryService: ref.watch(bankDiscoveryServiceProvider),
    senderBankMappingRepository: ref.watch(senderBankMappingRepositoryProvider),
    isAiSenderMappingAuto: () => featureFlags.getBool('ai_sender_mapping_auto'),
    suspectedDuplicateRepository:
        ref.watch(suspectedDuplicateRepositoryProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

final saveManualTransactionUseCaseProvider =
    writerProvider<SaveManualTransactionUseCase>((ref) {
  return SaveManualTransactionUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    logMetric: ref.watch(metricsClientProvider).logEvent,
    accountRepository: ref.watch(accountRepositoryProvider),
    suspectedDuplicateRepository:
        ref.watch(suspectedDuplicateRepositoryProvider),
  );
});

final ingestCapturedMessageUseCaseProvider =
    writerProvider<IngestCapturedMessageUseCase>((ref) {
  return IngestCapturedMessageUseCase(
    ref.watch(addTransactionUseCaseProvider),
  );
});

final confirmTransactionUseCaseProvider =
    writerProvider<ConfirmTransactionUseCase>((ref) {
  return ConfirmTransactionUseCase(
    ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final correctCategoryUseCaseProvider = writerProvider<CorrectCategoryUseCase>((ref) {
  return CorrectCategoryUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    merchantIntelligence: ref.watch(merchantIntelligenceProvider),
  );
});

final saveBudgetUseCaseProvider = writerProvider<SaveBudgetUseCase>((ref) {
  return SaveBudgetUseCase(
    ref.watch(budgetRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteBudgetUseCaseProvider = writerProvider<DeleteBudgetUseCase>((ref) {
  return DeleteBudgetUseCase(ref.watch(budgetRepositoryProvider));
});

final saveGoalUseCaseProvider = writerProvider<SaveGoalUseCase>((ref) {
  return SaveGoalUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteGoalUseCaseProvider = writerProvider<DeleteGoalUseCase>((ref) {
  return DeleteGoalUseCase(ref.watch(goalRepositoryProvider));
});

final addGoalContributionUseCaseProvider =
    writerProvider<AddGoalContributionUseCase>((ref) {
  return AddGoalContributionUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    notifyGoalMilestone: (goal, beforeProgress, afterProgress) async {
      final loadPrefs = ref.read(loadNotificationPreferencesUseCaseProvider);
      final savePrefs = ref.read(saveNotificationPreferencesUseCaseProvider);
      final preferences = await loadPrefs();
      final notification = const NotificationPlanner().planGoalMilestone(
        preferences: preferences,
        goal: goal,
        beforeProgress: beforeProgress,
        afterProgress: afterProgress,
        lang: LocalNotificationService.instance.notificationLanguage,
      );
      if (notification == null) return;
      await LocalNotificationService.instance.showGoalMilestoneNotification(
        notification: notification,
        preferences: preferences,
      );
      await savePrefs(
        preferences.copyWith(
          notifiedGoalMilestones: {
            ...preferences.notifiedGoalMilestones,
            goal.id: notification.milestone,
          },
        ),
      );
    },
  );
});

final budgetProgressUseCaseProvider = writerProvider<BudgetProgressUseCase>((ref) {
  // MALI-063n: the dormant Supabase budget-summary batch-fetch (pre-canonical
  // semantics) is retired — budget consumption is always the canonical Drift
  // path.
  final db = ref.watch(appDatabaseProvider);
  return BudgetProgressUseCase(
    budgetRepository: ref.watch(budgetRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    onMonthUnderBudget: (at) => recordMonthUnderBudget(db, at),
  );
});

final goalDetailsUseCaseProvider = writerProvider<GoalDetailsUseCase>((ref) {
  return GoalDetailsUseCase(ref.watch(goalRepositoryProvider));
});

final loadNotificationPreferencesUseCaseProvider =
    writerProvider<LoadNotificationPreferencesUseCase>((ref) {
  return LoadNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final saveNotificationPreferencesUseCaseProvider =
    writerProvider<SaveNotificationPreferencesUseCase>((ref) {
  return SaveNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final notificationJourneyServiceProvider =
    writerProvider<NotificationJourneyService>((ref) {
  return NotificationJourneyService(
    database: ref.watch(appDatabaseProvider),
    loadPreferences: ref.watch(loadNotificationPreferencesUseCaseProvider),
    savePreferences: ref.watch(saveNotificationPreferencesUseCaseProvider),
    campaignsDao: RemoteGrowthCampaignsDao(ref.watch(appDatabaseProvider)),
  );
});

final loadUserSettingsUseCaseProvider =
    writerProvider<LoadUserSettingsUseCase>((ref) {
  return LoadUserSettingsUseCase(ref.watch(userSettingsRepositoryProvider));
});

final saveCountryCurrencyUseCaseProvider =
    writerProvider<SaveCountryCurrencyUseCase>((ref) {
  return SaveCountryCurrencyUseCase(
    ref.watch(userSettingsRepositoryProvider),
    ref.watch(accountRepositoryProvider),
    ref.watch(transactionRepositoryProvider),
  );
});

final saveLanguageUseCaseProvider = writerProvider<SaveLanguageUseCase>((ref) {
  return SaveLanguageUseCase(ref.watch(userSettingsRepositoryProvider));
});
