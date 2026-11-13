import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/consent_status.dart';

// The consent status shown to the person is derived from the stored choices AND
// the live egress facts. A stored "accepted" alone is never enough to say
// "active": a pending/uncertain/frozen state must not be reported as on.

UserSettingsEntity _settings(ConsentState cloud, ConsentState ai) =>
    const UserSettingsEntity(
      id: 's',
      country: 'SA',
      currency: 'SAR',
      language: 'en',
      theme: 'light',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
    ).copyWith(cloudConsentState: cloud, aiConsentState: ai);

const _on = ConsentLiveFacts(egressState: EgressState.on);

void main() {
  const a = ConsentState.accepted;
  const d = ConsentState.declined;
  const u = ConsentState.unset;

  group('settled states with a confirmed live gate', () {
    test('both accepted + gate ON is active', () {
      expect(deriveConsentStatus(_settings(a, a), _on), ConsentStatus.active);
    });
    test('cloud only is partial', () {
      expect(deriveConsentStatus(_settings(a, d), _on), ConsentStatus.partial);
      expect(deriveConsentStatus(_settings(a, u), _on), ConsentStatus.partial);
    });
    test('Cloud OFF with a kept AI choice is off, never "partially on"', () {
      // The state iOS is left in after sign-out pauses Cloud: nothing is sent.
      expect(deriveConsentStatus(_settings(d, a), _on), ConsentStatus.off);
      expect(deriveConsentStatus(_settings(u, a), _on), ConsentStatus.off);
    });
    test('nothing accepted is off', () {
      expect(deriveConsentStatus(_settings(d, d), _on), ConsentStatus.off);
      expect(deriveConsentStatus(_settings(u, u), _on), ConsentStatus.off);
    });
  });

  group('never active from settings alone', () {
    test('no live facts yet (loading/failed) is unknown', () {
      expect(deriveConsentStatus(_settings(a, a), null), ConsentStatus.unknown);
    });
    test('uncertain durable state is unknown', () {
      expect(
          deriveConsentStatus(_settings(a, a),
              const ConsentLiveFacts(egressState: EgressState.on, uncertain: true)),
          ConsentStatus.unknown);
    });
    test('unresolved gate is unknown', () {
      expect(
          deriveConsentStatus(_settings(a, a),
              const ConsentLiveFacts(egressState: EgressState.on, resolved: false)),
          ConsentStatus.unknown);
    });
    test('accepted but no durable ON record is unknown', () {
      expect(deriveConsentStatus(_settings(a, a), const ConsentLiveFacts()),
          ConsentStatus.unknown);
      expect(
          deriveConsentStatus(
              _settings(a, a), const ConsentLiveFacts(egressState: EgressState.off)),
          ConsentStatus.unknown);
    });
    test('a pending enable is turning on even with accepted settings', () {
      expect(
          deriveConsentStatus(_settings(a, a),
              const ConsentLiveFacts(egressState: EgressState.on, enablePending: true)),
          ConsentStatus.turningOn);
      expect(
          deriveConsentStatus(_settings(d, d),
              const ConsentLiveFacts(enablePending: true)),
          ConsentStatus.turningOn);
    });
    test('a disabling record or frozen egress is turning off', () {
      expect(
          deriveConsentStatus(_settings(a, a),
              const ConsentLiveFacts(egressState: EgressState.disabling)),
          ConsentStatus.turningOff);
      expect(
          deriveConsentStatus(_settings(a, a),
              const ConsentLiveFacts(egressState: EgressState.on, frozen: true)),
          ConsentStatus.turningOff);
    });
    test('a Dart ON the native layers do not confirm is unknown, never active',
        () {
      const unverified =
          ConsentLiveFacts(egressState: EgressState.on, nativeVerified: false);
      expect(deriveConsentStatus(_settings(a, a), unverified),
          ConsentStatus.unknown);
      expect(deriveConsentStatus(_settings(a, d), unverified),
          ConsentStatus.unknown);
      expect(deriveConsentStatus(_settings(a, u), unverified),
          ConsentStatus.unknown);
    });
    test('unverified native facts never turn an OFF or a pending state into '
        'something else', () {
      const unverified =
          ConsentLiveFacts(egressState: EgressState.on, nativeVerified: false);
      expect(deriveConsentStatus(_settings(d, d), unverified), ConsentStatus.off);
      expect(
          deriveConsentStatus(
              _settings(a, a),
              const ConsentLiveFacts(
                  enablePending: true, nativeVerified: false)),
          ConsentStatus.turningOn);
    });
    test('off stays off even when the durable record is uncertain', () {
      expect(
          deriveConsentStatus(_settings(d, d),
              const ConsentLiveFacts(uncertain: true)),
          ConsentStatus.off);
    });
  });
}
