import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

/// C-3 / F-025 — the consent switch must enforce what the privacy screen
/// promises («إيقافها يعطّل … والمزامنة»).
///
/// Review found `cloudProcessingEnabled` gated capture upload plus two analytics
/// call sites and NOTHING else. With consent OFF and a signed-in user, all of
/// this still left the device: financial push AND pull, `user_settings` carrying
/// display_name / phone_number / date_of_birth, sender→bank mappings (i.e. which
/// banks the user holds), Smart Inbox, gamification, notification logs, the
/// activity ping, metrics, and the encrypted backup upload.
///
/// These tests pin the POLICY exhaustively. Wiring each call site to consult it
/// is separate work, guarded by its own architecture test — a policy nobody
/// calls would be exactly the failure this replaces.
UserSettingsEntity _settings({
  required ConsentState cloud,
  required ConsentState ai,
}) =>
    UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud,
      aiConsentState: ai,
    );

void main() {
  const allClasses = EgressClass.values;

  group('fail closed', () {
    test('every user-data class is denied when cloud consent is UNSET', () {
      final s = _settings(cloud: ConsentState.unset, ai: ConsentState.unset);
      for (final c in allClasses) {
        expect(ConsentAuthority.decide(c, s), isFalse,
            reason: '$c must not egress before an explicit opt-in');
      }
    });

    test('every user-data class is denied when cloud consent is DECLINED', () {
      final s = _settings(cloud: ConsentState.declined, ai: ConsentState.accepted);
      // Phase 3: Smart Analysis alone is decided by its own consent (below).
      for (final c in allClasses.where((c) => c != EgressClass.smartAnalysis)) {
        expect(ConsentAuthority.decide(c, s), isFalse, reason: '$c');
      }
    });

    test('with BOTH declined, smart analysis is denied too', () {
      final s = _settings(cloud: ConsentState.declined, ai: ConsentState.declined);
      for (final c in allClasses) {
        expect(ConsentAuthority.decide(c, s), isFalse, reason: '$c');
      }
    });

    test('unset is treated exactly like declined — never like accepted', () {
      final unset = _settings(cloud: ConsentState.unset, ai: ConsentState.unset);
      final declined =
          _settings(cloud: ConsentState.declined, ai: ConsentState.declined);
      for (final c in allClasses) {
        expect(ConsentAuthority.decide(c, unset),
            ConsentAuthority.decide(c, declined),
            reason: '$c must not distinguish "not yet asked" from "said no"');
      }
    });
  });

  group('OD-07 — restrictive state wins', () {
    test('AI consent alone does NOT open the AI path', () {
      // The AI path transmits the same message content the cloud path does, so
      // granting AI while cloud is off must not create an egress route. The sync
      // payload and the iOS bridge already enforced this; the in-app parse path
      // read aiConsentGranted alone.
      final s = _settings(cloud: ConsentState.declined, ai: ConsentState.accepted);
      expect(ConsentAuthority.decide(EgressClass.aiProcessing, s), isFalse);
      expect(ConsentAuthority.denialReason(EgressClass.aiProcessing, s),
          'ai_requires_cloud_consent');
    });

    test('cloud consent alone does NOT open the AI path', () {
      final s = _settings(cloud: ConsentState.accepted, ai: ConsentState.unset);
      expect(ConsentAuthority.decide(EgressClass.aiProcessing, s), isFalse);
      expect(ConsentAuthority.denialReason(EgressClass.aiProcessing, s),
          'ai_consent_off');
    });

    test('AI requires BOTH', () {
      final s = _settings(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      expect(ConsentAuthority.decide(EgressClass.aiProcessing, s), isTrue);
    });
  });

  // Gemini-first phase 3 (owner decision 2026-11-20): smart analysis is
  // separated from Cloud. It needs its own consent and nothing else; every
  // other class keeps its rule, aiProcessing (bank discovery, enrichment,
  // shared learning) included.
  group('phase 3 — smart analysis needs its own consent only', () {
    test('AI consent with Cloud OFF allows smart analysis and nothing else', () {
      final s = _settings(cloud: ConsentState.declined, ai: ConsentState.accepted);
      expect(ConsentAuthority.decide(EgressClass.smartAnalysis, s), isTrue);
      for (final c in allClasses.where((c) => c != EgressClass.smartAnalysis)) {
        expect(ConsentAuthority.decide(c, s), isFalse, reason: '$c');
      }
    });

    test('Cloud consent alone never allows smart analysis', () {
      for (final ai in [ConsentState.unset, ConsentState.declined]) {
        final s = _settings(cloud: ConsentState.accepted, ai: ai);
        expect(ConsentAuthority.decide(EgressClass.smartAnalysis, s), isFalse);
        expect(ConsentAuthority.denialReason(EgressClass.smartAnalysis, s),
            'ai_consent_off');
      }
    });

    test('a Cloud transition freeze denies smart analysis too', () {
      final s = _settings(cloud: ConsentState.declined, ai: ConsentState.accepted);
      ConsentAuthority.egressFrozen = true;
      addTearDown(() => ConsentAuthority.egressFrozen = false);
      expect(ConsentAuthority.decide(EgressClass.smartAnalysis, s), isFalse);
      expect(ConsentAuthority.denialReason(EgressClass.smartAnalysis, s),
          'egress_frozen');
    });

    test('allows() for smart analysis needs no Cloud record, and observes a '
        'withdrawal at once', () async {
      var ai = ConsentState.accepted;
      final authority = ConsentAuthority(
          () async => _settings(cloud: ConsentState.declined, ai: ai));
      expect(await authority.allows(EgressClass.smartAnalysis), isTrue);
      ai = ConsentState.declined;
      expect(await authority.allows(EgressClass.smartAnalysis), isFalse);
      expect(await authority.allows(EgressClass.aiProcessing), isFalse);
    });
  });

  group('OD-05 — diagnostics fail closed', () {
    test('crash reporting follows cloud consent, with no exemption', () {
      // Sentry currently initialises on DSN presence alone (main.dart), which is
      // what this policy is written to correct: crash payloads can carry device,
      // user and context information.
      final off = _settings(cloud: ConsentState.declined, ai: ConsentState.unset);
      expect(ConsentAuthority.decide(EgressClass.diagnostics, off), isFalse);
      final on = _settings(cloud: ConsentState.accepted, ai: ConsentState.unset);
      expect(ConsentAuthority.decide(EgressClass.diagnostics, on), isTrue);
    });
  });

  // Astra G (P1), updated truthfully: the former "never gated" exceptions are
  // gone. Catalog follows cloud consent like everything else; auth is never an
  // automatic decision (an explicit user action goes through
  // CloudEgressGate.runAccountControl).
  group('no automatic catalog/auth exception', () {
    test('catalog is denied with consent OFF and allowed only with consent ON',
        () {
      final off =
          _settings(cloud: ConsentState.declined, ai: ConsentState.declined);
      final on = _settings(cloud: ConsentState.accepted, ai: ConsentState.unset);
      expect(ConsentAuthority.decide(EgressClass.catalog, off), isFalse);
      expect(ConsentAuthority.decide(EgressClass.catalog, on), isTrue);
    });

    test('auth is never decided automatically, even with consent ON', () {
      final on = _settings(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      expect(ConsentAuthority.decide(EgressClass.auth, on), isFalse);
    });
  });

  group('the authority is consulted fresh, never cached', () {
    test('a revocation between two calls is observed by the second', () async {
      var cloud = ConsentState.accepted;
      final authority = ConsentAuthority(
        () async => _settings(cloud: cloud, ai: ConsentState.accepted),
      );

      expect(await authority.allows(EgressClass.financialSync), isTrue);
      cloud = ConsentState.declined; // user revokes mid-session
      expect(await authority.allows(EgressClass.financialSync), isFalse,
          reason: 'a queued or retried request must observe the revocation, '
              'not the state captured when it was enqueued');
    });
  });

  test('every EgressClass has an explicit decision — no default-allow', () {
    // A new class added without a decision would fall through. Dart exhaustive
    // switch already prevents that at compile time; this asserts intent too.
    final on = _settings(cloud: ConsentState.accepted, ai: ConsentState.accepted);
    final off = _settings(cloud: ConsentState.unset, ai: ConsentState.unset);
    for (final c in allClasses) {
      expect(() => ConsentAuthority.decide(c, on), returnsNormally, reason: '$c');
      expect(() => ConsentAuthority.decide(c, off), returnsNormally, reason: '$c');
    }
    // And the sensitive classes must actually differ between the two states.
    for (final c in [
      EgressClass.financialSync,
      EgressClass.profileAndSettings,
      EgressClass.backup,
      EgressClass.aiProcessing,
      EgressClass.senderBankMappings,
      EgressClass.smartInbox,
      EgressClass.gamification,
      EgressClass.telemetry,
      EgressClass.diagnostics,
    ]) {
      expect(ConsentAuthority.decide(c, on), isTrue, reason: '$c with consent');
      expect(ConsentAuthority.decide(c, off), isFalse, reason: '$c without');
    }
  });
}
