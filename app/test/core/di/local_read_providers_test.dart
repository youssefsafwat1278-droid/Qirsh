import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/account_deletion_gateway.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/core/auth/immediate_deletion_flow.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';

import '../session/recording_secure_storage.dart';

// O-H2 — no writer, outbox, sync, capture, cloud or notification service is ever
// built under a local-read scope.

/// Providers of app_providers.dart that build nothing writable and nothing that
/// reaches the cloud: the database handle itself and pure policy/state seeds.
const _notWriterBearing = {
  'appDatabaseProvider',
  'planningCutoverCoordinatorProvider',
  'planningMutationGuardProvider',
  'startupHasLocalDataProvider',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every Provider<T> in app_providers.dart is a writerProvider unless it '
      'is explicitly known to build nothing writable', () {
    final source = File('lib/core/di/app_providers.dart').readAsStringSync();
    final raw = RegExp(r'final\s+(\w+)\s*=\s*Provider<')
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
    expect(raw.difference(_notWriterBearing), isEmpty,
        reason: 'wrap these in writerProvider (or allowlist with a reason)');
    final wrapped = RegExp(r'final\s+(\w+)\s*=\s*writerProvider<')
        .allMatches(source)
        .length;
    expect(wrapped, greaterThan(70));
  });

  group('under a local-read scope', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = await AppDatabase.open(executor: NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        accountAccessModeProvider.overrideWithValue(AccountAccessMode.localRead),
      ]);
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    final writers = <String, ProviderListenable<Object?>>{
      'transactionRepository': transactionRepositoryProvider,
      'accountRepository': accountRepositoryProvider,
      'cardRepository': cardRepositoryProvider,
      'budgetRepository': budgetRepositoryProvider,
      'goalRepository': goalRepositoryProvider,
      'userSettingsRepository': userSettingsRepositoryProvider,
      'ledgerOutboxQueue': ledgerOutboxQueueProvider,
      'planningOutboxQueue': planningOutboxQueueProvider,
      'ledgerPushService': ledgerPushServiceProvider,
      'ledgerSyncEngine': ledgerSyncEngineProvider,
      'planningSyncEngine': planningSyncEngineProvider,
      'profilePhotoSyncService': profilePhotoSyncServiceProvider,
      'captureSyncService': captureSyncServiceProvider,
      'captureImportService': captureImportServiceProvider,
      'dataPortabilityService': dataPortabilityServiceProvider,
      'addTransactionUseCase': addTransactionUseCaseProvider,
      'saveManualTransactionUseCase': saveManualTransactionUseCaseProvider,
      'saveBudgetUseCase': saveBudgetUseCaseProvider,
      'saveGoalUseCase': saveGoalUseCaseProvider,
      'notificationJourneyService': notificationJourneyServiceProvider,
      'metricsClient': metricsClientProvider,
      'accountDeletionService': accountDeletionServiceProvider,
      'accountDeletionGateway': accountDeletionGatewayProvider,
    };

    for (final entry in writers.entries) {
      test('${entry.key} is never built', () {
        expect(() => container.read(entry.value),
            throwsA(isA<LocalReadWriterDenied>()));
      });
    }
  });

  test('the deletion gateway denies at its own boundary before building its service', () {
    var serviceBuilds = 0;
    final container = ProviderContainer(overrides: [
      accountAccessModeProvider.overrideWithValue(AccountAccessMode.localRead),
      accountDeletionServiceProvider.overrideWith((ref) {
        serviceBuilds++;
        throw StateError('deletion service must not be constructed');
      }),
    ]);
    addTearDown(container.dispose);
    Object? failure;
    try {
      container.read(accountDeletionGatewayProvider);
    } catch (error) {
      failure = error;
    }
    expect(serviceBuilds, 0, reason: 'the gateway itself owns the local-read denial');
    expect(failure, isA<LocalReadWriterDenied>());
  });

  test('a writable deletion gateway remains scheduled-only without calling its backend', () {
    var serviceBuilds = 0;
    var clientReads = 0;
    final container = ProviderContainer(overrides: [
      accountDeletionServiceProvider.overrideWith((ref) {
        serviceBuilds++;
        return AccountDeletionService(getClient: () {
          clientReads++;
          throw StateError('gateway construction must not obtain an SDK client');
        });
      }),
    ]);
    addTearDown(container.dispose);
    expect(container.read(accountAccessModeProvider), AccountAccessMode.writable);
    final gateway = container.read(accountDeletionGatewayProvider);
    expect(gateway, isA<ScheduledAccountDeletionGateway>());
    expect(gateway.deletesImmediately, isFalse);
    expect(serviceBuilds, 1);
    expect(clientReads, 0);
  });

  test('immediate deletion flow: denied under local read, fail-closed without a scope host', () async {
    final local = ProviderContainer(overrides: [
      accountAccessModeProvider.overrideWithValue(AccountAccessMode.localRead),
    ]);
    addTearDown(local.dispose);
    expect(() => local.read(immediateDeletionFlowProvider),
        throwsA(isA<LocalReadWriterDenied>()));
    expect(() => local.read(appleDeletionReauthProvider),
        throwsA(isA<LocalReadWriterDenied>()));

    final writable = ProviderContainer();
    addTearDown(writable.dispose);
    final flow = writable.read(immediateDeletionFlowProvider);
    expect(flow, isA<UnavailableDeletionFlow>());
    expect(await flow.begin(), isNull);
    expect(await flow.resume(), isNull);
  });

  test('under a writable scope the same providers build as before', () async {
    final db = await AppDatabase.open(executor: NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    expect(container.read(accountAccessModeProvider),
        AccountAccessMode.writable);
    expect(container.read(transactionRepositoryProvider), isNotNull);
    expect(container.read(accountRepositoryProvider), isNotNull);
  });

  // Astra D6 — `installIdProvider` is an unwrapped FutureProvider whose read
  // CREATES and persists the install id when none exists (a secure-storage
  // write). Under a local-read scope it must never be built.
  group('D6: installIdProvider', () {
    late RecordingSecureStorage storage;
    late AppDatabase db;
    setUp(() async {
      storage = RecordingSecureStorage().install();
      db = await AppDatabase.open(executor: NativeDatabase.memory());
    });
    tearDown(() async => db.close());

    test('under local read: never built, nothing created or written', () async {
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        accountAccessModeProvider.overrideWithValue(AccountAccessMode.localRead),
      ]);
      addTearDown(container.dispose);
      await expectLater(container.read(installIdProvider.future),
          throwsA(isA<LocalReadWriterDenied>()));
      expect(storage.attempts.where((a) => a.contains('mali_install_id')),
          isEmpty);
    });

    test('control: a writable scope still creates and persists it', () async {
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
      ]);
      addTearDown(container.dispose);
      final id = await container.read(installIdProvider.future);
      expect(id, isNotEmpty);
      expect(storage.attempts.where((a) => a.contains('mali_install_id')),
          isNotEmpty);
    });
  });
}
