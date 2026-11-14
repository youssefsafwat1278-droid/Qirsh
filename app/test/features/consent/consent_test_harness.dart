import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/settings/consent_status.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class FakeSettingsRepository
    implements UserSettingsRepository, ConsentSettingsWriter {
  UserSettingsEntity settings = const UserSettingsEntity(
    id: 's',
    country: 'SA',
    currency: 'SAR',
    language: 'en',
    theme: 'light',
    inputMethod: 'manual',
    notificationsJson: '{}',
    privacyModeEnabled: false,
  );
  int saveCalls = 0;
  bool failSave = false;

  /// The choices of the most recent typed write (null until one happens).
  ConsentChoices? lastChoices;

  @override
  Future<UserSettingsEntity> getSettings() async => settings;

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity value) async {
    if (failSave) throw StateError('disk');
    saveCalls++;
    return settings = value;
  }

  /// The typed consent write: the capability is checked before AND after, and the
  /// choices are merged into the CURRENT stored settings (UI-wiring double only;
  /// the real transaction is covered by the F2Fixture/Drift tests).
  @override
  Future<UserSettingsEntity> saveConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    capability.requireCurrent();
    if (failSave) throw StateError('disk');
    saveCalls++;
    lastChoices = choices;
    settings = choices.applyTo(settings);
    capability.requireCurrent();
    return settings;
  }
}

/// Registration service double: [retry] moves status to [outcome].
class FakeRegistrationService implements CaptureDeviceRegistrationService {
  FakeRegistrationService(
      {this.outcome = const CaptureRegistrationStatus(
          CaptureRegistrationPhase.connected)});

  CaptureRegistrationStatus outcome;
  int retryCalls = 0;
  @override
  final consentServerRevision = ValueNotifier<int>(0);
  final notifier = ValueNotifier(const CaptureRegistrationStatus(
      CaptureRegistrationPhase.notRequested));

  @override
  ValueListenable<CaptureRegistrationStatus> get status => notifier;

  @override
  Future<bool> deviceConsentMatches(UserSettingsEntity settings) async =>
      outcome.phase == CaptureRegistrationPhase.connected;

  @override
  Future<bool> serverConsentMatches(UserSettingsEntity settings,
      {bool waitForAccount = false}) async =>
      outcome.phase == CaptureRegistrationPhase.connected;

  @override
  Future<void> retry() async {
    retryCalls++;
    notifier.value = outcome;
  }

  int syncCalls = 0;

  /// Astra G: widening Cloud goes through an explicit enable.
  int enableCalls = 0;

  @override
  bool isDisablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      before.cloudProcessingEnabled && !after.cloudProcessingEnabled;

  int disableCalls = 0;

  @override
  Future<void> disableCloud({required Future<void> Function() commitLocalOff}) {
    disableCalls++;
    return commitLocalOff();
  }

  @override
  bool isEnablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      !before.cloudProcessingEnabled && after.cloudProcessingEnabled;

  /// A3(c): the route an explicit choice takes. Tests script it; by default it
  /// mirrors the real split (enable when Cloud widens, otherwise a plain save).
  ExplicitEnableRoute? routeOverride;
  int routeCalls = 0;

  /// Runs during the route's await (a lifecycle can end there).
  void Function()? duringRoute;

  @override
  Future<ExplicitEnableRoute> explicitEnableRoute(
      UserSettingsEntity current, UserSettingsEntity updated,
      {required String ownerUid}) async {
    routeCalls++;
    duringRoute?.call();
    await Future<void>.delayed(Duration.zero);
    return routeOverride ??
        (isEnablingCloud(current, updated)
            ? ExplicitEnableRoute.enable
            : ExplicitEnableRoute.plainSave);
  }

  /// The typed writer a [ConsentWrite] commits through (wired by
  /// [consentOverrides]).
  ConsentSettingsWriter? writer;

  /// N-E: when set, the enable fails with it (nothing is saved), like the real
  /// service on an incomplete native/Dart transition.
  Object? enableError;

  @override
  Future<void> enableCloud({required ConsentWrite write}) async {
    enableCalls++;
    final failure = enableError;
    if (failure != null) throw failure;
    await writer!.saveConsentChoice(write.capability, write.choices);
  }

  /// R17/R18: the state of a pending enable and the withdrawal from it.
  PendingEnableState pendingStateOverride = PendingEnableState.none;
  int withdrawCalls = 0;
  Object? withdrawError;

  @override
  Future<PendingEnableState> pendingEnableState(UserSettingsEntity stored,
          {required String ownerUid}) async =>
      pendingStateOverride;

  @override
  Future<void> withdrawPendingEnable({
    required ConsentCapability capability,
    required Future<void> Function() commitLocalOff,
  }) async {
    withdrawCalls++;
    final failure = withdrawError;
    if (failure != null) throw failure;
    await commitLocalOff();
  }

  @override
  Future<void> syncBackendState() async => syncCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSaveCountry implements SaveCountryCurrencyUseCase {
  @override
  Future<UserSettingsEntity> call(String country, String currency) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Override> consentOverrides(
  FakeSettingsRepository repo,
  FakeRegistrationService service, {
  ConsentLocalWork? work,
  ConsentLocalWork? Function()? workSource,
}) {
  service.writer ??= repo;
  return [
      userSettingsRepositoryProvider.overrideWithValue(repo),
      userSettingsProvider.overrideWith((_) => repo.getSettings()),
      captureDeviceRegistrationServiceProvider.overrideWithValue(service),
      consentSettingsWriterProvider.overrideWithValue(repo),
      // A confirmed, resolved gate by default; tests of uncertain / pending
      // states override this provider after these.
      consentLiveFactsProvider
          .overrideWith((_) async => ConsentLiveFacts.confirmedOn),
      consentLocalWorkProvider.overrideWithValue(() =>
          workSource?.call() ??
          work ??
          fakeConsentWork(isCurrent: () => true)),
    ];
}

Widget consentApp({
  required List<Override> overrides,
  required Widget home,
  String locale = 'en',
}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light,
        locale: Locale(locale),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );


/// A UI-wiring double: a capability with no database whose liveness the test
/// controls, and a runner that just runs. Real lifecycle behaviour is proven with
/// the F2Fixture/AppSession tests, never with this.
ConsentLocalWork fakeConsentWork(
        {required bool Function() isCurrent, String uid = 'uid-fake'}) =>
    ConsentLocalWork(
        ConsentCapability(
            uid: uid, epoch: 1, database: null, isCurrent: isCurrent),
        <T>(action) => action());
