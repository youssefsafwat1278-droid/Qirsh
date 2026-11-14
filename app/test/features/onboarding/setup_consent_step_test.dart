import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';

import '../consent/consent_test_harness.dart';

/// In-memory account repository that records every create call (the spy).
class SpyAccountRepo implements AccountRepository {
  final List<AccountEntity> accounts = [];
  final List<AccountEntity> createCalls = [];
  bool failNextCreate = false;

  @override
  Future<List<AccountEntity>> getAll() async => List.of(accounts);
  @override
  Future<AccountEntity?> getById(String id) async =>
      accounts.where((a) => a.id == id).firstOrNull;
  @override
  Future<AccountEntity?> getDefault() async => accounts.firstOrNull;
  @override
  Future<AccountEntity> create(AccountEntity account) async {
    createCalls.add(account);
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('disk');
    }
    // Idempotent on id, like the real primary key.
    accounts.removeWhere((a) => a.id == account.id);
    accounts.add(account);
    return account;
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async => account;
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> setDefault(String id) async {}
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  late SpyAccountRepo accountRepo;

  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  Future<void> pumpSetup(
    WidgetTester tester, {
    OnboardingSetupEntry entry = OnboardingSetupEntry.full,
    String country = 'Egypt',
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        saveCountryCurrencyUseCaseProvider.overrideWithValue(_OkSaveCountry()),
        accountRepositoryProvider.overrideWithValue(accountRepo),
        accountsProvider
            .overrideWith((ref) => ref.watch(accountRepositoryProvider).getAll()),
      ],
      home: OnboardingSetupScreen(entry: entry),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    if (entry == OnboardingSetupEntry.full) {
      expect(find.text('Step 1 of 6'), findsOneWidget);
      await tester.tap(find.textContaining(country).first);
      await advance(tester);
    }
  }

  setUp(() => accountRepo = SpyAccountRepo());

  testWidgets('one consent choice precedes readiness and account setup', (tester) async {
    await pumpSetup(tester);
    expect(find.text('Step 2 of 6'), findsOneWidget);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await advance(tester);
    expect(find.text('Step 3 of 6'), findsOneWidget);
    expect(repo.settings.cloudConsentState, ConsentState.declined);
    expect(repo.settings.aiConsentState, ConsentState.declined);
    await tester.tap(find.text('Continue'));
    await advance(tester);
    expect(find.text('Step 4 of 6'), findsOneWidget);
  });

  testWidgets('explicit Accept grants cloud and AI through existing authority', (tester) async {
    await pumpSetup(tester);
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await advance(tester);
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(service.enableCalls, 1);
    expect(service.retryCalls, 1);
    expect(find.text('Step 3 of 6'), findsOneWidget);
  });

  testWidgets('Cloud activation waits for a server receipt during setup',
      (tester) async {
    await pumpSetup(tester);
    service.outcome = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    final accept = find.byKey(const Key('initialConsentAccept'));
    await tester.tap(accept);
    await advance(tester);

    expect(find.text('Step 3 of 6'), findsNothing);
    expect(accept, findsOneWidget);
    expect(find.textContaining("isn't connected"), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    service.outcome =
        const CaptureRegistrationStatus(CaptureRegistrationPhase.connected);
    await tester.tap(accept);
    await advance(tester);
    expect(find.text('Step 3 of 6'), findsOneWidget);
  });

  testWidgets('Account Setup: name is required, currency defaults to the '
      'country currency, no default name', (tester) async {
    await pumpSetup(tester);
    for (var i = 0; i < 1; i++) {
      await tester.tap(find.byKey(const Key('initialConsentDecline')));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    final nameField = tester.widget<TextField>(
        find.byKey(const ValueKey('account-name-field')));
    expect(nameField.controller!.text, isEmpty);
    expect(find.textContaining('EGP'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await tester.pump();
    expect(find.text('Please enter an account name'), findsOneWidget);
    expect(accountRepo.createCalls, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Please enter an account name'), findsNothing);
  });

  testWidgets('Account Setup: create goes through the repository, a failed '
      'save retries with the SAME id, then the step completes',
      (tester) async {
    await pumpSetup(tester);
    for (var i = 0; i < 1; i++) {
      await tester.tap(find.byKey(const Key('initialConsentDecline')));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    await tester.enterText(
        find.byKey(const ValueKey('account-name-field')), 'My bank');
    accountRepo.failNextCreate = true;
    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await tester.pumpAndSettle();
    expect(accountRepo.accounts, isEmpty);
    expect(find.text('Step 4 of 6'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await advance(tester);
    expect(accountRepo.createCalls, hasLength(2));
    expect(accountRepo.createCalls[0].id, accountRepo.createCalls[1].id,
        reason: 'retry must reuse the creation id (no duplicate)');
    expect(accountRepo.accounts, hasLength(1));
    expect(accountRepo.accounts.single.name, 'My bank');
    expect(accountRepo.accounts.single.currency, 'EGP');
    expect(accountRepo.accounts.single.type, AccountType.bank);
    expect(find.text('Step 5 of 6'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('an existing account is shown; user may continue or add another',
      (tester) async {
    final now = DateTime.utc(2026, 1, 1);
    accountRepo.accounts.add(AccountEntity(
      id: 'default_account',
      name: 'Legacy main',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
    await pumpSetup(tester);
    for (var i = 0; i < 1; i++) {
      await tester.tap(find.byKey(const Key('initialConsentDecline')));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    expect(find.text('Legacy main'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-account-add-another')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-name-field')), findsOneWidget);
    expect(accountRepo.createCalls, isEmpty);
  });

  testWidgets('notifications completion advances to the shortcut and leaves '
      'its Installed confirmation required', (tester) async {
    // Exercise the actual six-step UI with the existing fake local repositories.
    // Only the notification platform boundary is stubbed; no session authority
    // or consent decision is manufactured by this test.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const timezoneChannel = MethodChannel('mali/device_timezone');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        timezoneChannel, (_) async => 'Africa/Cairo');
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(timezoneChannel, null));
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async => call.method == 'getNotificationAppLaunchDetails'
          ? <String, dynamic>{'notificationLaunchedApp': false} : true);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpSetup(tester);
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await advance(tester);
    await tester.tap(find.text('Continue'));
    await advance(tester);
    await tester.enterText(
        find.byKey(const ValueKey('account-name-field')), 'Notification test account');
    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await advance(tester);
    expect(find.text('Step 5 of 6'), findsOneWidget);
    await tester.tap(find.text('Enable'));
    await advance(tester);
    await advance(tester);
    expect(find.text('Step 6 of 6'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget,
        reason: 'notification permission must never confirm shortcut installation');
    final finish = tester.widget<FilledButton>(
        find.ancestor(of: find.text('Start'), matching: find.byType(FilledButton)));
    expect(finish.onPressed, isNull,
        reason: 'the separate Installed action remains an explicit user decision');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('finish is blocked without an account', (tester) async {
    await pumpSetup(tester, entry: OnboardingSetupEntry.captureGuide);
    await tester.tap(find.text('Installed'));
    await advance(tester);
    expect(accountRepo.accounts, isEmpty);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Add an account to finish setup.'), findsOneWidget);
    expect(find.text('Step 4 of 6'), findsOneWidget,
        reason: 'sent back to Account Setup');
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

class _OkSaveCountry extends FakeSaveCountry {
  @override
  Future<UserSettingsEntity> call(String country, String currency) async =>
      FakeSettingsRepository().settings;
}
