import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_resume_reminder.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:shared_preferences/shared_preferences.dart';

const off = UserSettingsEntity(id: 'settings', country: 'EG', currency: 'EGP',
    language: 'en', theme: 'dark', inputMethod: 'manual', notificationsJson: '{}',
    privacyModeEnabled: false, cloudConsentState: ConsentState.declined,
    cloudConsentVersion: 2);

void main() {
  final store = CloudResumeReminder();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('never-enabled and deliberately OFF users get no reminder', () async {
    expect(await store.shouldShow('a', off), isFalse);
    expect(await store.shouldShow('a', off.copyWith(
        cloudConsentState: ConsentState.unset, cloudConsentVersion: 0)), isFalse);
  });
  test('a paused choice is retained only for the same account', () async {
    await store.rememberPaused('a', off);
    expect(await store.shouldShow('a', off), isTrue);
    expect(await store.shouldShow('b', off), isFalse);
    expect(await CloudResumeReminder().shouldShow('a', off), isTrue);
  });
  test('a later decision clears the reminder, including a deliberate OFF', () async {
    await store.rememberPaused('a', off);
    expect(await store.shouldShow('a', off.copyWith(cloudConsentVersion: 3)), isFalse);
    expect(await store.shouldShow('a', off), isFalse);
  });
  test('explicit re-enable clears the reminder without changing any consent', () async {
    await store.rememberPaused('a', off);
    final on = off.copyWith(cloudConsentState: ConsentState.accepted,
        cloudConsentVersion: 3);
    expect(await store.shouldShow('a', on), isFalse);
    expect(await store.shouldShow('a', off), isFalse);
    expect(on.cloudProcessingEnabled, isTrue);
    expect(off.cloudProcessingEnabled, isFalse);
  });
  test('fresh replica or uninstall cannot inherit a previous choice reminder', () async {
    await store.rememberPaused('a', off);
    expect(await store.shouldShow('a', off.copyWith(cloudConsentVersion: 0)), isFalse);
    expect(await store.shouldShow('a', off), isFalse);
    await store.rememberPaused('a', off);
    SharedPreferences.setMockInitialValues({});
    expect(await store.shouldShow('a', off), isFalse);
  });
  test('dismissal persists across views', () async {
    await store.rememberPaused('a', off);
    await store.dismiss('a');
    expect(await CloudResumeReminder().shouldShow('a', off), isFalse);
  });
  test('the AI choice before the pause is remembered with the reminder',
      () async {
    await store.rememberPaused('a', off, aiWasOn: true);
    expect(await store.shouldShow('a', off), isTrue);
    expect(await store.aiWasOn('a'), isTrue);
    await store.rememberPaused('b', off);
    expect(await store.aiWasOn('b'), isFalse);
    expect(await store.aiWasOn('c'), isFalse);
  });
}
