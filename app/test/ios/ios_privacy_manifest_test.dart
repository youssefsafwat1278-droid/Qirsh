import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-043 / MALI-031 — STATIC iOS privacy-manifest contract (source-level, not
// the built .app bundle; freshly-built archive evidence is external and lives in
// tools/verify_ios_packaging.sh). A permission usage-description string in
// Info.plist is a privacy/App-Store surface: declaring one the app cannot
// justify (no code / package / capability) is a store-review risk and a false
// privacy signal. This is a PRECISE structural guard for the known location keys
// plus a JUSTIFIED-usage inventory (an allowlist), not a fragile
// "every key maps to code" heuristic.

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  RegExp key(String k) => RegExp('<key>$k</key>');

  group('iOS Info.plist permission usage descriptions', () {
    // The app has no location package and no location code (MALI-043): a
    // location usage-description must never reappear.
    const locationKeys = [
      'NSLocationWhenInUseUsageDescription',
      'NSLocationAlwaysAndWhenInUseUsageDescription',
      'NSLocationAlwaysUsageDescription',
      'NSLocationUsageDescription',
    ];
    for (final k in locationKeys) {
      test('$k is absent (no location feature exists)', () {
        expect(key(k).hasMatch(plist), isFalse,
            reason:
                'the app declares no location capability — $k is an unjustified '
                'permission and an App-Store-review risk');
      });
    }

    // Inventory guard: every NS*UsageDescription present must be one the app
    // actually justifies. A NEW unjustified permission (contacts, mic, calendar,
    // location, …) added later fails here until it is either justified and
    // allowlisted or removed.
    test('only justified usage-description keys are declared', () {
      const justified = {
        'NSCameraUsageDescription', // profile photo capture
        'NSFaceIDUsageDescription', // biometric app lock
        'NSPhotoLibraryUsageDescription', // profile photo selection
      };
      final present = RegExp(r'<key>(NS\w*UsageDescription)</key>')
          .allMatches(plist)
          .map((m) => m.group(1)!)
          .toSet();
      final unjustified = present.difference(justified);
      expect(unjustified, isEmpty,
          reason: 'unjustified permission usage-description(s) declared: '
              '$unjustified — justify + allowlist them here, or remove them');
    });
  });

  // IOS-01 — required-reason API declarations. Each target's manifest must
  // declare every required-reason API category its compiled Swift sources use
  // (target membership per Runner.xcodeproj: BankMessageShortcuts.swift is
  // compiled into Runner; SharedCaptureStore/SharedOfferIntentStore are
  // compiled into BOTH Runner and ShareBankMessage).
  group('iOS privacy manifests declare required-reason APIs', () {
    const detectors = {
      'NSPrivacyAccessedAPICategoryDiskSpace':
          r'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|statfs|statvfs',
      'NSPrivacyAccessedAPICategoryFileTimestamp':
          r'modificationDate|creationDate|ModificationDate|CreationDate|getattrlist|\bf?stat\(',
      'NSPrivacyAccessedAPICategoryUserDefaults': r'\bUserDefaults\b',
      'NSPrivacyAccessedAPICategorySystemBootTime':
          r'systemUptime|mach_absolute_time',
      'NSPrivacyAccessedAPICategoryActiveKeyboards': r'activeInputModes',
    };

    Map<String, Set<String>> declared(String path) {
      final xml = File(path).readAsStringSync();
      final entry = RegExp(
          r'<key>NSPrivacyAccessedAPIType</key>\s*<string>(\w+)</string>\s*'
          r'<key>NSPrivacyAccessedAPITypeReasons</key>\s*<array>(.*?)</array>',
          dotAll: true);
      return {
        for (final m in entry.allMatches(xml))
          m.group(1)!: RegExp(r'<string>([^<]+)</string>')
              .allMatches(m.group(2)!)
              .map((r) => r.group(1)!)
              .toSet(),
      };
    }

    String sources(List<String> dirs) => [
          for (final d in dirs)
            for (final f in Directory(d).listSync())
              if (f.path.endsWith('.swift')) File(f.path).readAsStringSync(),
        ].join('\n');

    final targets = {
      'ios/Runner/PrivacyInfo.xcprivacy':
          sources(['ios/Runner', 'ios/BankMessageShortcuts']),
      'ios/ShareBankMessage/PrivacyInfo.xcprivacy':
          sources(['ios/ShareBankMessage']),
    };

    targets.forEach((manifest, code) {
      test('$manifest declares every category its target uses', () {
        final used = {
          for (final e in detectors.entries)
            if (RegExp(e.value).hasMatch(code)) e.key,
        };
        final missing = used.difference(declared(manifest).keys.toSet());
        expect(missing, isEmpty,
            reason: 'required-reason API used but undeclared: $missing');
      });
    });

    // Reasons pinned to the actual use (codes from Apple's required-reason
    // list): C617.1 timestamps of files in the App Group container;
    // 85F4.1 disk-space state shown in the Sync diagnostics screen;
    // CA92.1 app-only UserDefaults.standard (Runner only);
    // 1C8F.1 App Group UserDefaults(suiteName:) shared app <-> extension.
    test('Runner reasons match its use', () {
      expect(declared('ios/Runner/PrivacyInfo.xcprivacy'), {
        'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1'},
        'NSPrivacyAccessedAPICategoryDiskSpace': {'85F4.1'},
        'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1', '1C8F.1'},
      });
    });

    test('ShareBankMessage reasons match its use', () {
      expect(declared('ios/ShareBankMessage/PrivacyInfo.xcprivacy'), {
        'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1'},
        'NSPrivacyAccessedAPICategoryDiskSpace': {'85F4.1'},
        'NSPrivacyAccessedAPICategoryUserDefaults': {'1C8F.1'},
      });
    });
  });
}
