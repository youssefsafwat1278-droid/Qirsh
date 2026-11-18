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

/// [source] without the bodies of `#if DEBUG` branches (keeps `#else`).
String releaseOnly(String source) {
  final out = StringBuffer();
  // Per open #if: is it `#if DEBUG`, and has its `#else` been reached?
  final stack = <({bool debug, bool inElse})>[];
  bool excluded() => stack.any((e) => e.debug && !e.inElse);
  for (final line in source.split('\n')) {
    final t = line.trim();
    if (t.startsWith('#if ')) {
      stack.add((debug: t == '#if DEBUG', inElse: false));
      continue;
    }
    if (t == '#else' && stack.isNotEmpty) {
      stack[stack.length - 1] = (debug: stack.last.debug, inElse: true);
      continue;
    }
    if (t == '#endif' && stack.isNotEmpty) {
      stack.removeLast();
      continue;
    }
    if (!excluded()) out.writeln(line);
  }
  return out.toString();
}

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

    // Release-shipped code only: a `#if DEBUG` branch is not compiled into
    // the archive App Store Connect checks (B16: the disk-space probe).
    String sources(List<String> dirs) => [
          for (final d in dirs)
            for (final f in Directory(d).listSync())
              if (f.path.endsWith('.swift'))
                releaseOnly(File(f.path).readAsStringSync()),
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
    // list, NSPrivacyAccessedAPIType, read 2026-11-17): C617.1 timestamps of
    // files in the App Group container; CA92.1 app-only UserDefaults.standard
    // (Runner only); 1C8F.1 App Group UserDefaults(suiteName:) shared app <->
    // extension. No DiskSpace: B16 compiles the probe out of release builds.
    test('Runner reasons match its use', () {
      expect(declared('ios/Runner/PrivacyInfo.xcprivacy'), {
        'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1'},
        'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1', '1C8F.1'},
      });
    });

    test('ShareBankMessage reasons match its use', () {
      expect(declared('ios/ShareBankMessage/PrivacyInfo.xcprivacy'), {
        'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1'},
        'NSPrivacyAccessedAPICategoryUserDefaults': {'1C8F.1'},
      });
    });

    test('B16: the disk-space probe exists only in DEBUG builds', () {
      for (final path in const [
        'ios/Runner/SharedCaptureStore.swift',
        'ios/ShareBankMessage/SharedCaptureStore.swift',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src, contains('volumeAvailableCapacityForImportantUsageKey'),
            reason: 'the debug diagnostics row keeps its probe');
        expect(
            RegExp(detectors['NSPrivacyAccessedAPICategoryDiskSpace']!)
                .hasMatch(releaseOnly(src)),
            isFalse,
            reason: '$path: the DiskSpace API must not be in release code');
      }
    });
  });

  // V1-003 / decision 3.2: the data the app actually sends off the device.
  group('Runner manifest declares the data the app collects', () {
    final xml = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
    final types = RegExp(
            r'<key>NSPrivacyCollectedDataType</key>\s*<string>(\w+)</string>')
        .allMatches(xml)
        .map((m) => m.group(1)!)
        .toSet();

    test('every type Qirsh sends is declared', () {
      expect(
          types,
          containsAll(const [
            'NSPrivacyCollectedDataTypeEmailsOrTextMessages', // sanitized SMS
            'NSPrivacyCollectedDataTypePhotosorVideos', // profile photo
            'NSPrivacyCollectedDataTypeUserID', // account id
            'NSPrivacyCollectedDataTypeProductInteraction', // notification log
            'NSPrivacyCollectedDataTypeOtherFinancialInfo',
            'NSPrivacyCollectedDataTypeEmailAddress',
            'NSPrivacyCollectedDataTypeName',
            'NSPrivacyCollectedDataTypePhoneNumber',
            'NSPrivacyCollectedDataTypeDeviceID',
            'NSPrivacyCollectedDataTypeCrashData',
            'NSPrivacyCollectedDataTypeOtherDataTypes', // date of birth
          ]));
    });

    test('Qirsh uses what it collects only for app functionality', () {
      final purposes = RegExp(r'<string>(NSPrivacyCollectedDataTypePurpose\w+)</string>')
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toSet();
      expect(purposes, {'NSPrivacyCollectedDataTypePurposeAppFunctionality'},
          reason: 'notification logs serve delivery retries, engagement '
              'events serve streaks; no analytics use exists in V1');
    });

    test('no advertising data and no tracking (ads compiled out, 3.2)', () {
      expect(types, isNot(contains('NSPrivacyCollectedDataTypeAdvertisingData')));
      expect(xml, contains('<key>NSPrivacyTracking</key>\n\t<false/>'));
      expect(xml, isNot(contains('NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising')));
    });
  });

  // Decision 3.1 (V1-014): iPhone only, portrait.
  group('iPhone-only target configuration', () {
    final pbx =
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

    test('every build configuration targets device family 1 (iPhone)', () {
      final families = RegExp(r'TARGETED_DEVICE_FAMILY = ([^;]+);')
          .allMatches(pbx)
          .map((m) => m.group(1)!.replaceAll('"', ''))
          .toList();
      expect(families, hasLength(6),
          reason: 'project Debug/Release/Profile + share extension x3');
      expect(families.toSet(), {'1'});
    });

    test('portrait only, no iPad orientation key', () {
      final orientations = RegExp(
              r'<key>UISupportedInterfaceOrientations</key>\s*<array>(.*?)</array>',
              dotAll: true)
          .firstMatch(plist)!
          .group(1)!;
      expect(
          RegExp(r'<string>(\w+)</string>')
              .allMatches(orientations)
              .map((m) => m.group(1))
              .toList(),
          ['UIInterfaceOrientationPortrait']);
      expect(plist, isNot(contains('UISupportedInterfaceOrientations~ipad')));
      expect(plist, contains('<key>LSRequiresIPhoneOS</key>'));
    });
  });
}
