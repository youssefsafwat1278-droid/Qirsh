import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/privacy/cloud_egress_gate.dart';
import '../ads/admob_build_config.dart';
import '../ads/mobile_ads_initializer.dart';
import 'report_ads_debug_config.dart';

/// Google UMP is the SOLE ad-consent authority (docs REFERRAL_ADS_ADMIN_SYSTEM.md
/// §3). Qirsh keeps NO duplicate advertising-consent boolean; `canRequestAds` is
/// read from UMP, never persisted independently. This is entirely separate from
/// `cloudProcessingEnabled`, which governs Qirsh product analytics only (§12).
abstract class AdConsentService {
  /// At a suitable app-start point: request a consent-info update and load/show
  /// the required form. Never throws — a failure simply leaves ads not requestable.
  Future<void> gatherConsent();

  /// Whether ads may be requested per UMP right now.
  Future<bool> canRequestAds();

  /// Whether Settings should offer a "privacy options" entry.
  Future<bool> isPrivacyOptionsRequired();

  /// Present the UMP privacy options form (invoked from the Settings entry).
  Future<void> showPrivacyOptions();
}

/// google_mobile_ads UMP implementation. All calls are wrapped so a form error
/// never propagates; on any uncertainty `canRequestAds` stays false, which the
/// gate treats as "no ad → export proceeds" (fail-open).
class UmpAdConsentService implements AdConsentService {
  const UmpAdConsentService();

  ConsentInformation get _info => ConsentInformation.instance;

  @override
  Future<void> gatherConsent() async {
    // Astra H2.5: the UMP consent-info update and form are network calls to
    // Google. Not while the egress gate does not permit.
    final gate = CloudEgressGate.instance;
    final epoch = gate.epoch;
    bool isCurrent() =>
        identical(CloudEgressGate.instance, gate) && gate.epoch == epoch;
    if (!await MobileAdsInitializer.mayServe() || !isCurrent()) return;
    try {
      // Debug/profile-only: force EEA geography (+ optional test device) so a
      // human R6 test can exercise the consent form / privacy-options path.
      // Structurally inert in release (see ReportAdsDebugConfig); production
      // requests carry no debug settings.
      final debugSettings = ReportAdsDebugConfig.forceEeaGeography
          ? ConsentDebugSettings(
              debugGeography: DebugGeography.debugGeographyEea,
              testIdentifiers: ReportAdsDebugConfig.testDeviceIds,
            )
          : null;
      final params =
          ConsentRequestParameters(consentDebugSettings: debugSettings);
      final updated = Completer<void>();
      _info.requestConsentInfoUpdate(
        params,
        () => updated.complete(),
        (error) => updated.complete(), // treat as "no consent gathered"
      );
      await updated.future;
      // Consent callbacks cannot retain permission across an OFF transition.
      if (!await MobileAdsInitializer.mayServe() || !isCurrent()) return;

      final formDismissed = Completer<void>();
      ConsentForm.loadAndShowConsentFormIfRequired((error) {
        formDismissed.complete();
      });
      await formDismissed.future;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[UMP] gatherConsent failed: ${e.runtimeType}');
      }
    }
  }

  @override
  Future<bool> canRequestAds() async {
    // Decision 3.2: no UMP call at all in a build without ads compiled in.
    if (!AdMobBuildConfig.adsCompiledIn) return false;
    try {
      return await _info.canRequestAds();
    } catch (_) {
      return false; // uncertainty → no ad
    }
  }

  @override
  Future<bool> isPrivacyOptionsRequired() async {
    // Hidden while Cloud is OFF: its form is a Google network call (H2.5).
    if (!await MobileAdsInitializer.mayServe()) return false;
    try {
      final status = await _info.getPrivacyOptionsRequirementStatus();
      return status == PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> showPrivacyOptions() async {
    if (!await MobileAdsInitializer.mayServe()) return;
    final done = Completer<void>();
    ConsentForm.showPrivacyOptionsForm((error) => done.complete());
    await done.future;
  }
}
