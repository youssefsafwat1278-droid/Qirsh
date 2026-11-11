// Offline presentation/negative-only review, never imported by lib/.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

const visualParityCountryFailureKeys = ['countrySaveFailure', 'profileSaveFailure', 'notificationSaveFailure'];
final _events = <String, int>{};
Map<String, int> visualParityCountryFailureEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
FailureOnlyCountrySettings? _active;
void releaseVisualParityCountryFailure() => _active?.release();

class FailureOnlyCountrySettings extends DriftUserSettingsRepository {
  FailureOnlyCountrySettings(super.db, {this.profile = false, this.notification = false});
  final bool profile;
  final bool notification;
  final gate = Completer<void>();
  int calls = 0;
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
    if (!notification && (profile ? settings.displayName != 'QA retained name' : (settings.country != 'EG' || settings.currency != 'EGP'))) {
      throw StateError('country_preview_only_allows_EG_EGP');
    }
    calls++;
    _event(notification ? 'notificationSaveFailureAdmitted' : profile ? 'profileSaveFailureAdmitted' : 'countrySaveFailureAdmitted');
    await gate.future;
    throw StateError('private_synthetic_country_failure_before_write');
  }
}

Future<bool> openVisualParityCountryFailure(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityCountryFailureKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('onboarding_review_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('onboarding_review_requires_memory');
  }
  // The actual use case can relabel an existing empty account. Require a
  // real EGP default and history, so even an accidental other choice cannot
  // perform that preceding account operation. Only EG/EGP reaches held Save.
  final account = await ref.read(accountRepositoryProvider).getDefault();
  final recent =
      await ref.read(transactionRepositoryProvider).getRecent(limit: 1);
  if (key == 'countrySaveFailure' && (account?.currency != 'EGP' || recent.isEmpty)) {
    throw StateError('country_review_requires_EGP_history');
  }
  if (!context.mounted) return false;
  final service = FailureOnlyCountrySettings(db, profile: key == 'profileSaveFailure', notification: key == 'notificationSaveFailure');
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    localeProvider.overrideWithValue(Localizations.localeOf(context)),
    userSettingsRepositoryProvider.overrideWithValue(service),
    saveCountryCurrencyUseCaseProvider.overrideWithValue(
        SaveCountryCurrencyUseCase(service, ref.read(accountRepositoryProvider),
            ref.read(transactionRepositoryProvider))),
  ]);
  _active = service;
  _event('${key}Opened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => UncontrolledProviderScope(
                container: container,
                child: key == 'countrySaveFailure' ? const OnboardingSetupScreen() : const SettingsScreen(page: SettingsPage.account),
              )))
      .whenComplete(() {
    service.release();
    if (identical(_active, service)) _active = null;
    container.dispose();
    _event('${key}Closed');
  }));
  return true;
}
