import 'budget_alert_commits.dart';
import '../../../core/privacy/consent_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../../core/backend/supabase_config.dart';
import '../../../core/backend/rules_client.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/install_id.dart';
import 'capture_device_registration_service.dart';
import '../../../data/catalog/catalog_daos.dart';
import 'dart:async';
import '../../../data/capture/proof_shadow_dao.dart';
import '../../../domain/capture/proof_commit_gate.dart';
import '../../../core/di/app_providers.dart' show featureFlags;
import '../../../data/db/app_database.dart';
import '../../../data/db/database_access_broker.dart';
import '../../../data/db/ownership_guard.dart';
import '../../../data/db/replica_store.dart';
import '../../../data/repositories/drift_budget_repository.dart';
import '../../../data/repositories/drift_card_repository.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_account_repository.dart';
import '../../../data/repositories/drift_gamification_repository.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../planning_sync/services/outbox_queue_factory.dart';
import '../../gamification/services/achievement_unlocks.dart';
import 'package:drift/drift.dart' show Variable;

import '../../../domain/entities/captured_message.dart';
import '../../../domain/entities/card_entity.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../engine/parser/card_network.dart';
import '../../../domain/services/bank_discovery_service.dart';
import '../../../domain/services/budget_alert_planner.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/budget_progress_usecase.dart';
import '../../../domain/usecases/engagement_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../domain/usecases/resolve_bank_for_sender_usecase.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../../engine/ai/ai_parser_client.dart';
import '../../../engine/ai/bank_discovery_client.dart';
import '../../../engine/categorization/category.dart';
import 'capture_notification_content.dart';
import 'local_notification_service.dart';

/// WHAT IN HERE IS LIVE, AND WHAT IS NOT.
///
/// [checkBudgetAlert] IS live — `app_shell.dart` and `manual_transaction_sheet
/// .dart` both call it, and the comment at the app-shell call site records why:
/// the relay import and the foreground shared-message ingest add transactions
/// "without going through CapturedMessageProcessor, so its budget check never
/// ran for them".
///
/// [process] / [processCapturedMessage] are NOT reachable. They were the
/// background-isolate capture pipeline; every capture now arrives through the
/// native durable queue and is ingested by `AppShell._consumeSharedInput`,
/// which owns the per-item lease/ack boundary, the Smart Inbox persistence for
/// unprocessable captures (via `SharedCaptureHandoffService`), and the same
/// five-disposition notification switch reproduced here. Nothing dispatches a
/// Dart background entry point for capture on either platform: the only capture
/// channel is `money_companion/native_capture`, and no native code creates a
/// background `FlutterEngine` or a `DartCallback` — pinned by
/// `test/architecture/capture_entry_points_test.dart`.
///
/// They are kept rather than deleted because they are not merely unused: they
/// are the only implementation of `_autoDetectCard`, which the live drain does
/// NOT do. Deleting them would quietly convert a known gap into a lost one.
/// Do not add callers; the live path is the drain.
class CapturedMessageProcessor {
  const CapturedMessageProcessor._();

  static Future<CapturedMessageResult> process({
    required String rawMessage,
    String? senderId,
    CapturedMessageSource source = CapturedMessageSource.unknown,
    bool showNotifications = true,
    AppDatabase? database,
    DatabaseBrokerClient? job,
  }) async {
    return processCapturedMessage(
      CapturedMessage(
        text: rawMessage,
        senderId: senderId,
        source: source,
        receivedAt: DateTime.now().toUtc(),
      ),
      showNotifications: showNotifications,
      database: database,
      job: job,
    );
  }

  static Future<CapturedMessageResult> processCapturedMessage(
    CapturedMessage message, {
    bool showNotifications = true,
    AppDatabase? database,
    DatabaseBrokerClient? job,
  }) async {
    // O: an ownerless entry (no shared database supplied) is default-deny. It
    // needs a genuine host-issued job, and is refused BEFORE it captures the
    // stored ownership, resolves a location, touches a key or lease, or opens.
    if (database == null && (job == null || !job.isHostIssued)) {
      throw const DatabaseAccessUnavailable('host_job_required');
    }
    // MALI-069n §6/§Blocker-1 — when no shared database is supplied this is a
    // bounded SECONDARY connection to the same encrypted file: same key + PRAGMA
    // contract, no concurrent migrations, and it holds a CROSS-ISOLATE shared
    // lease (refused while file-exclusive maintenance is in progress). Always
    // closed in the finally below (which releases the lease).
    final shouldCloseDatabase = database == null;
    // MALI-069n §Blocker-1 — this background isolate does not share the owner
    // object in memory, so it binds to the current ADMISSION GENERATION and
    // re-validates at every boundary (points 1/2 in openSecondary, points 3/4/5
    // below). A previous session's capture never commits or notifies under a new
    // admission (sign-out / wipe / ownership change / same-UID re-login).
    final ownershipGuard = shouldCloseDatabase ? OwnershipGuard() : null;
    final admissionToken =
        ownershipGuard != null ? await ownershipGuard.capture() : null;
    final AppDatabase db;
    DatabaseBrokerHandle<AppDatabase>? jobHandle;
    if (database != null) {
      db = database;
    } else {
      // WP-3b — the account's own replica (owner marker + registry), never a
      // shared file. No admitted account, or a locked one (signed out), is a
      // refusal: the capture stays queued for its owner.
      final location = await ReplicaStore().activeLocation();
      if (location == null) throw const StaleOwnershipException();
      final leaseManager =
          await AppDatabase.appSupportLeaseManager(location: location);
      Future<AppDatabase> openSecondary() => AppDatabase.openSecondary(
            location: location,
            leaseManager: leaseManager,
            ownershipGuard: ownershipGuard,
            admissionToken: admissionToken,
          );
      // Reserved with the coordinator BEFORE the opener runs.
      jobHandle = await job!.open<AppDatabase>(
          open: openSecondary, close: (opened) => opened.close());
      db = jobHandle.value;
    }
    try {
      final settingsRepository = DriftUserSettingsRepository(db);
      // MALI-060n — the AI/enrichment endpoints authenticate on the server-
      // verified device secret. Read it once here and hand it to each client.
      final deviceRegistration = CaptureDeviceRegistrationService(
          settingsRepository: settingsRepository);
      Future<String?> loadDeviceSecret() =>
          deviceRegistration.readDeviceSecret();
      // Background/native captures must enter the sync pipeline like every
      // other write. The queues are auth-gated internally (guest → local-only).
      // A-2 (G14): same cutover authority as the foreground, so a background-
      // enqueued money row is serialized exactly like a foreground one.
      final cutover = await resolveCutoverCoordinator(db);
      final ledgerOutbox = buildLedgerOutboxQueue(db, coordinator: cutover);
      final planningOutbox = buildPlanningOutboxQueue(db, coordinator: cutover);
      final engagementUseCase = RecordEngagementUseCase(
        gamificationRepository: DriftGamificationRepository(db),
        transactionRepository: DriftTransactionRepository(db),
        userSettingsRepository: settingsRepository,
      );
      final notificationPreferences =
          await LoadNotificationPreferencesUseCase(settingsRepository).call();
      // Background isolate: no providers, so the language comes straight from
      // the settings row `localeProvider` reads in the UI.
      final notificationLanguage =
          (await settingsRepository.getSettings()).language;
      Future<void> storeHistory(NotificationHistoryEntry entry) async {
        if (ownershipGuard != null && admissionToken != null &&
            !await ownershipGuard.isCurrent(admissionToken)) {
          return;
        }
        await settingsRepository.appendNotificationHistory(entry,
            isCurrent: () => settingsRepository.isDatabaseOpen);
      }
      // CAP-7: the background isolate has no shell to wire the generic-text flag.
      LocalNotificationService.instance.captureNotifyV2 = () {
        try {
          return featureFlags.getBool('capture_notify_v2');
        } catch (_) {
          return false;
        }
      };
      final senderBankMappingRepository = DriftSenderBankMappingRepository(db);
      final aiParserClient = SupabaseConfig.isConfigured
          ? SupabaseAiParserClient(
              edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/parse-sms',
              getAnonJwt: () async =>
                  supabase.Supabase.instance.client.auth.currentSession
                      ?.accessToken ??
                  SupabaseConfig.anonKey,
              loadDeviceSecret: loadDeviceSecret,
            )
          : null;
      final bankDiscoveryClient = SupabaseConfig.isConfigured
          ? GeminiBankDiscoveryClient(
              edgeFunctionUrl:
                  '${SupabaseConfig.url}/functions/v1/bank-discovery',
              getAnonJwt: () async => supabase
                  .Supabase.instance.client.auth.currentSession?.accessToken,
              loadDeviceSecret: loadDeviceSecret,
            )
          : null;
      final ingestUseCase = IngestCapturedMessageUseCase(
        AddTransactionUseCase(
          // PHASE 11 — the background capture path MUST carry the same Proof
          // wiring as the foreground one. This is where automatic bank SMS
          // actually flows, so a use case constructed without it would default
          // to shadow (safe) but record NOTHING — and Tier 2 would count zero
          // from the only path that matters at volume.
          // `local_auto_confirm_v2`, read at call time (remote kill switch).
          isLocalAutoConfirmV2: () => featureFlags.getBool('local_auto_confirm_v2'),
          proofGateMode: () => featureFlags.getBool('enable_proof_autocommit')
              ? ProofGateMode.armed
              : ProofGateMode.shadow,
          proofParserConfidenceMinPermille: () {
            final v = featureFlags.getInt('proof_parser_confidence_min');
            // Tune-upward-only, identical to the foreground clamp.
            return (v > ProofCommitGate.defaultParserConfidenceMinPermille &&
                    v <= 1000)
                ? v
                : ProofCommitGate.defaultParserConfidenceMinPermille;
          },
          recordProofShadow: (record) {
            unawaited(ProofShadowDao(db).record(record));
          },
          transactionRepository:
              DriftTransactionRepository(db, outboxQueue: ledgerOutbox),
          merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          recordEngagementUseCase: engagementUseCase,
          loadBankProfiles: RulesClient(database: db).localBankProfiles,
          // F-016: raw catalog rules — the engine's first parsing authority.
          loadCatalogRules: RulesClient(database: db).catalogRulesForSender,
          loadRemoteKeywords: () async {
            final settings = await settingsRepository.getSettings();
            final country = settings.country;
            return country.isEmpty
                ? RemoteMerchantKeywordsDao(db).getAll()
                : RemoteMerchantKeywordsDao(db).getActiveForCountry(country);
          },
          noteMerchantFeedback: (keyword) =>
              PendingMerchantFeedbackDao(db).record(keyword),
          resolveMerchantCategory: SupabaseConfig.isConfigured
              ? (keyword) async {
                  try {
                    final settings = await settingsRepository.getSettings();
                    final deviceSecret = await loadDeviceSecret();
                    final res = await supabase
                        .Supabase.instance.client.functions
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
          // C-3 — the merchant name comes from a financial message; enrichment
          // needs fresh cloud consent, read at call time.
          mayEnrichMerchant: () => ConsentAuthority(
                () => settingsRepository.getSettings(),
              ).allows(EgressClass.financialSync),
          aiClient: aiParserClient,
          aiPrimarySelected: () async {
            final settings = await settingsRepository.getSettings();
            return settings.cloudProcessingEnabled && settings.aiConsentGranted;
          },
          loadAiConsent: () async =>
              ConsentAuthority.decide(EgressClass.aiProcessing,
                          await settingsRepository.getSettings()),
          loadInstallId: InstallId.get,
          accountRepository:
              DriftAccountRepository(db, outboxQueue: planningOutbox),
          dedupStore: DriftDedupStore(db),
          suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
          resolveBankForSenderUseCase: ResolveBankForSenderUseCase(
            mappingRepository: senderBankMappingRepository,
          ),
          senderBankMappingRepository: senderBankMappingRepository,
          isAiSenderMappingAuto: () =>
              featureFlags.getBool('ai_sender_mapping_auto'),
          bankDiscoveryService: bankDiscoveryClient == null
              ? null
              : BankDiscoveryService(
                  mappingRepository: senderBankMappingRepository,
                  client: bankDiscoveryClient,
                  loadAiConsent: () async =>
                      ConsentAuthority.decide(EgressClass.aiProcessing,
                          await settingsRepository.getSettings()),
                  loadInstallId: InstallId.get,
                ),
        ),
      );

      // Point 3 — re-validate immediately before the Drift commit. If the
      // admission changed while we were preparing, abort WITHOUT writing: the
      // capture belongs to a session that no longer owns this database.
      if (ownershipGuard != null &&
          admissionToken != null &&
          !await ownershipGuard.isCurrent(admissionToken)) {
        throw const StaleOwnershipException();
      }

      final result = await ingestUseCase.fromCapturedMessage(message);

      if (result.addTransactionResult.outcome == AddTransactionOutcome.added) {
        await _autoDetectCard(db, result.addTransactionResult.transaction);
      }

      if (showNotifications) {
        await checkBudgetAlert(db, notificationPreferences,
            lang: notificationLanguage,
            storeHistory: storeHistory,
            committedTransactions:
                newlyAddedTransactions(result.addTransactionResult));
      }

      // Points 4/5 — re-validate before the native acknowledgement / any
      // notification side effect. A superseded session must never surface a
      // banner to whoever owns the device now.
      final ownershipStillValid = ownershipGuard == null ||
          admissionToken == null ||
          await ownershipGuard.isCurrent(admissionToken);
      if (showNotifications && ownershipStillValid) {
        switch (result.disposition) {
          case CapturedMessageDisposition.ignored:
            break;
          case CapturedMessageDisposition.notifyOnly:
            final content = buildConfirmedCaptureContent(
                result.addTransactionResult.transaction,
                lang: notificationLanguage);
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: content.title,
              body: content.body,
              preferences: notificationPreferences,
              storeHistory: storeHistory,
              stableId: result.notificationStableId,
            );
          case CapturedMessageDisposition.requestConfirmation:
            final transaction = result.addTransactionResult.transaction;
            if (transaction != null) {
              final content = buildReviewCaptureContent(
                  result.addTransactionResult.transaction,
                  lang: notificationLanguage);
              await LocalNotificationService.instance.showReviewNotification(
                transactionId: transaction.id,
                title: content.title,
                body: content.body,
                preferences: notificationPreferences,
                storeHistory: storeHistory,
              );
            }
          case CapturedMessageDisposition.suspiciousDuplicate:
            final content = buildDuplicateCaptureContent(
                result.addTransactionResult.transaction,
                lang: notificationLanguage);
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: content.title,
              body: content.body,
              preferences: notificationPreferences,
              storeHistory: storeHistory,
              stableId: result.notificationStableId,
            );
          case CapturedMessageDisposition.unprocessable:
            final unsupported =
                buildUnsupportedCaptureContent(lang: notificationLanguage);
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: unsupported.title,
              body: unsupported.body,
              preferences: notificationPreferences,
              storeHistory: storeHistory,
              stableId: result.notificationStableId,
            );
        }
      }

      return result;
    } finally {
      if (shouldCloseDatabase) {
        await (jobHandle?.close() ?? db.close());
      }
    }
  }

  /// Checks every active budget (any category, any period) against current
  /// spend and fires a local alert for each one crossing the 75%/90%/100%
  /// thresholds. Public so both the capture pipeline (below) and manual
  /// transaction entry (manual_transaction_sheet.dart) can call it after
  /// adding a transaction — a budget can be blown by either path.
  /// يربط عملية مُلتقَطة ببطاقة حقيقية: لو الحساب معروف وفيه آخر 4 أرقام ولا
  /// توجد بطاقة مطابقة، يُنشئ بطاقة تلقائية (source=auto). لو الحساب غير معروف
  /// أو لا يوجد رقم بطاقة، تُترك للتجميع المُشتَقّ («غير مخصّصة»). أفضل جهد —
  /// لا يكسر خط الالتقاط.
  static Future<void> _autoDetectCard(
    AppDatabase db,
    TransactionEntity? transaction,
  ) async {
    if (transaction == null) return;
    final accountId = transaction.accountId;
    final last4 = normalizeLast4(transaction.cardLast4);
    if (accountId == null || last4 == null) return;
    try {
      final cardRepo =
          DriftCardRepository(db, outboxQueue: buildPlanningOutboxQueue(db));
      if (await cardRepo.findByAccountAndLast4(accountId, last4) != null) {
        return;
      }
      await cardRepo.create(CardEntity(
        id: '',
        accountId: accountId,
        last4: last4,
        network: CardNetworkDetector.detect(transaction.rawMessage),
        source: CardSource.auto,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ));
    } catch (_) {
      // فشل ربط البطاقة يجب ألا يوقف الالتقاط.
    }
  }

  /// [lang] is the reader's language. Defaulting it keeps the three existing
  /// call sites compiling, and each one passes the settings row's value.
  static Future<void> checkBudgetAlert(
    AppDatabase db,
    NotificationPreferences prefs, {
    String lang = 'ar',
    required Iterable<TransactionEntity> committedTransactions,
    DateTime? now,
    Future<void> Function(BudgetAlertContent content)? emit,
    Future<void> Function(NotificationHistoryEntry)? storeHistory,
  }) async {
    final transactions = committedTransactions.toList();
    if (transactions.isEmpty) return;
    final current = now ?? DateTime.now().toUtc();
    final budgetRepository = DriftBudgetRepository(db);
    final progress = await BudgetProgressUseCase(
      budgetRepository: budgetRepository,
      transactionRepository: DriftTransactionRepository(db),
      onMonthUnderBudget: (at) => recordMonthUnderBudget(db, at),
    )(now: current);
    if (progress.entries.isEmpty) return;

    final accountRepo = DriftAccountRepository(db);
    final excludedAccounts = {
      for (final account in await accountRepo.getAll())
        if (account.excludeFromTotals) account.id,
    };
    const planner = BudgetAlertPlanner();
    for (final entry in progress.entries) {
      if (!transactions.any((transaction) => budgetAlertAffectedBy(
            entry,
            transaction,
            excludedAccountIds: excludedAccounts,
          ))) {
        continue;
      }
      final budgetAccountId = entry.budget.accountId;
      final account = budgetAccountId == null
          ? null
          : await accountRepo.getById(budgetAccountId);
      final currencyLabel = Currency.labelFor(
        entry.budget.currency,
        lang,
      );
      final categoryLabel = entry.budget.isAllExpenses
          ? (lang == 'en' ? 'your overall' : 'ميزانيتك الكلية')
          : await _categoryName(db, entry.budget.categoryId, lang) ??
              (lang == 'en' ? 'the category' : 'ميزانية الفئة');

      final content = planner.plan(
        entry: entry,
        now: current,
        currencyLabel: currencyLabel,
        categoryLabel: categoryLabel,
        // UX-037 — the account was already resolved right here and never
        // reached the notification text.
        accountLabel: account?.name,
        lang: lang,
      );
      if (content == null) continue;

      if (emit != null) {
        await emit(content);
      } else if (!await LocalNotificationService.instance.showBudgetAlert(
        title: content.title,
        body: content.body,
        type: content.type,
        preferences: prefs,
        notifId: content.notifId,
        storeHistory: storeHistory,
      )) {
        continue;
      }
      await budgetRepository.save(entry.budget.copyWith(
        lastNotifiedSpentMoney: entry.spent,
        lastNotifiedPeriodStart: entry.periodStart,
      ));
    }
  }

  /// The category's name in [lang].
  ///
  /// The local `categories` table has no `name_en` column — English names live
  /// only in the seeded [Categories] catalog, keyed by the stable `key`. This
  /// is the same resolution `CategoryView.name` does for the UI; a user-created
  /// category has one name, the one they typed, and keeps it.
  static Future<String?> _categoryName(
    AppDatabase db,
    String categoryId,
    String lang,
  ) async {
    final rows = await db.customSelect(
      'SELECT key, name_ar FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(categoryId)],
    ).get();
    final row = rows.firstOrNull;
    if (row == null) return null;
    final nameAr = row.read<String>('name_ar');
    if (lang != 'en') return nameAr;
    final key = row.read<String>('key');
    final known = Categories.all.where((c) => c.key == key);
    return known.isEmpty ? nameAr : known.first.enName;
  }
}
