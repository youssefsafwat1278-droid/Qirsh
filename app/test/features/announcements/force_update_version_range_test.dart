import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/app_version.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';

// V1 audit PROD-11 — a force-update row cached before the user updated must not
// keep blocking the updated app. The block applies only when the running
// version is inside the row's min/max range (same rule as the banner).

final _from = DateTime.utc(2026, 1, 1);

RemoteAnnouncement _force({String? min, String? max}) => RemoteAnnouncement(
      id: 'force',
      titleAr: 'حدّث التطبيق',
      titleEn: 'Update the app',
      bodyAr: null,
      bodyEn: null,
      severity: 'force_update',
      minAppVersion: min,
      maxAppVersion: max,
      actionLabelAr: null,
      actionLabelEn: null,
      actionUrl: null,
      validFrom: _from,
      validUntil: null,
      isDismissible: false,
      priority: 0,
      isDismissed: false,
      dismissedAt: null,
      syncedAt: _from,
    );

Future<bool> _blocks(RemoteAnnouncement row) async {
  final container = ProviderContainer(overrides: [
    activeAnnouncementsProvider.overrideWith((ref) async => [row]),
  ]);
  addTearDown(container.dispose);
  return container.read(hasForceUpdateProvider.future);
}

void main() {
  test('a cached force row whose max is below the running version does not block',
      () async {
    // Running version is kAppVersion (1.0.0 in tests); the row targets < 1.0.0.
    expect(compareAppVersions(kAppVersion, '0.9.9'), greaterThan(0));
    expect(await _blocks(_force(max: '0.9.9')), isFalse);
  });

  test('a force row whose min is above the running version does not block',
      () async {
    expect(await _blocks(_force(min: '99.0.0')), isFalse);
  });

  test('a force row that includes the running version still blocks', () async {
    expect(await _blocks(_force(max: kAppVersion)), isTrue);
    expect(await _blocks(_force(min: kAppVersion)), isTrue);
  });

  test('a force row with no range still blocks every version', () async {
    expect(await _blocks(_force()), isTrue);
  });
}
