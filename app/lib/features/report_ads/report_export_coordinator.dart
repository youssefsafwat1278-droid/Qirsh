import '../../core/observability/app_diagnostics.dart';
import 'dart:async';

import '../ads/report_banner_suppression.dart';
import 'ad_consent_service.dart';
import 'report_ads_analytics.dart';
import 'report_export_ad_gateway.dart';
import 'report_entitlement.dart';

/// The report-export attempt lifecycle (§19). The coordinator owns
/// idle→resolvingEntitlement→preparingAd→presentingAd→generating→completed;
/// `sharing` happens downstream in the preview screen.
enum ReportExportPhase {
  idle,
  resolvingEntitlement,
  preparingAd,
  confirmingAd,
  presentingAd,
  generating,
  sharing,
  completed,
}

enum _AdOpportunityResult { proceed, cancelled, superseded }

/// Wraps the existing report-export choke point with a narrow state machine
/// (R4). It owns NO report logic — `generate` (the caller's closure around the
/// report-export choke point) is invoked EXACTLY ONCE per accepted attempt.
///
/// Invariants:
///  * FAIL-OPEN — every terminal ad outcome proceeds to generation (§4).
///  * SINGLE-FLIGHT — one accepted tap ⇒ ≤ one ad opportunity and ≤ one
///    generation; repeated taps while active are ignored (§5).
///  * exportAttemptId — each attempt is tagged; stale continuations bail (§5/§20).
///  * NEVER HANGS — the gateway/consent futures always complete (§20).
class ReportExportCoordinator {
  ReportExportCoordinator({
    required bool Function() reportAdsEnabled,
    required bool Function() adConfigAvailable,
    required ReportEntitlementResolver entitlement,
    required AdConsentService consent,
    required ReportExportAdGateway gateway,
    required ReportAdsAnalytics analytics,
    String Function()? mintAttemptId,
    Duration adOpportunityDeadline = const Duration(minutes: 6),
  })  : _reportAdsEnabled = reportAdsEnabled,
        _adConfigAvailable = adConfigAvailable,
        _entitlement = entitlement,
        _consent = consent,
        _gateway = gateway,
        _analytics = analytics,
        _mintAttemptId = mintAttemptId ?? _defaultMintAttemptId,
        _adOpportunityDeadline = adOpportunityDeadline;

  final bool Function() _reportAdsEnabled;
  final bool Function() _adConfigAvailable;
  final ReportEntitlementResolver _entitlement;
  final AdConsentService _consent;
  final ReportExportAdGateway _gateway;
  final ReportAdsAnalytics _analytics;
  final String Function() _mintAttemptId;
  final Duration _adOpportunityDeadline;

  static int _seq = 0;
  static String _defaultMintAttemptId() => 'export-${_seq++}';

  ReportExportPhase _phase = ReportExportPhase.idle;
  ReportExportPhase get phase => _phase;

  String? _currentAttemptId;
  bool _inFlight = false;

  /// Run one accepted export attempt. [generate] performs the actual report
  /// generation (the caller's context-guarded wrapper around the choke point)
  /// and is invoked at most once.
  ///
  /// [confirmAdNotice], when supplied, is awaited ONLY after every real gate has
  /// passed AND an interstitial is actually loaded and ready to present — so an
  /// ad-free, offline, flag-off, UMP-blocked or no-fill attempt never shows an
  /// ad warning. Returning false is an explicit user cancellation of THIS
  /// attempt: no ad, no report, straight back to idle. Because it is awaited
  /// inside the attempt, it inherits single-flight: repeated Export taps while
  /// the notice is open are ignored.
  Future<void> run(
    Future<void> Function() generate, {
    Future<bool> Function()? confirmAdNotice,
  }) async {
    return AppDiagnostics.run(AppOperation.reportExport, () async {
      if (_inFlight) return; // single-flight: ignore repeated taps
      _inFlight = true;
      // The Reports banner stays down for the WHOLE journey from here: resolving
      // entitlement, UMP, preloading, the notice, the native presentation and the
      // generation after it. The route gate covers only the Flutter routes in
      // that sequence, and a native interstitial is not one — it pushes no route
      // at all, so nothing else would suppress the banner underneath it.
      ReportBannerSuppression.beginJourney();
      final attempt = _mintAttemptId();
      _currentAttemptId = attempt;
      _analytics.exportRequested();

      var advanced = false;
      Future<void> advanceOnce() async {
        // The ONE continuation: generate exactly once, and never for a superseded
        // attempt (stale callback protection).
        if (advanced || _currentAttemptId != attempt) return;
        advanced = true;
        _phase = ReportExportPhase.generating;
        await generate();
        _phase = ReportExportPhase.completed;
        _analytics.exportCompleted();
      }

      try {
        // One deadline owns the complete ad opportunity: entitlement, UMP,
        // preload, notice, the ad.show() trigger and the terminal show callback.
        // Future.microtask ensures the timer is attached before any stage starts.
        // Report generation deliberately sits outside this deadline.
        var opportunityOpen = true;
        bool isCurrentOpportunity() =>
            opportunityOpen && _currentAttemptId == attempt;
        void closeOpportunity() {
          opportunityOpen = false;
          if (_phase != ReportExportPhase.preparingAd &&
              _phase != ReportExportPhase.confirmingAd &&
              _phase != ReportExportPhase.presentingAd) {
            return;
          }
          try {
            // The concrete gateway's disposal is reusable: it also invalidates
            // late load callbacks and clears any active presentation.
            _gateway.dispose();
          } catch (_) {
            // Cleanup is best-effort; report generation remains fail-open.
          }
        }

        _AdOpportunityResult result;
        try {
          final opportunity = Future<_AdOpportunityResult>.microtask(
            () => _runAdOpportunity(
              isCurrentOpportunity,
              confirmAdNotice: confirmAdNotice,
            ),
          );
          result = await opportunity.timeout(
            _adOpportunityDeadline,
            onTimeout: () {
              // Future.timeout cannot cancel its source. Close this attempt's ad
              // token so a late consent/load/show continuation cannot create a
              // second opportunity after the report has already advanced.
              closeOpportunity();
              return _AdOpportunityResult.proceed;
            },
          );
        } catch (_) {
          // Audit H-6: an exception anywhere in the ad stage must never cost the
          // user their accepted report-export attempt.
          closeOpportunity();
          result = _AdOpportunityResult.proceed;
        }
        if (_currentAttemptId != attempt) return; // superseded
        opportunityOpen = false;
        if (result == _AdOpportunityResult.cancelled) {
          // Explicit cancellation of this attempt. Deliberately NOT fail-open:
          // the user asked to stop, so do not quietly generate the report.
          return;
        }
        if (result == _AdOpportunityResult.superseded) return;
        // Fail-open: every path (ad shown / skipped / failed / interrupted) lands
        // here and generates exactly once.
        await advanceOnce();
      } finally {
        // Always paired, on every exit: an early return, a cancellation, a
        // supersession or a throw. A journey left open is a banner that never
        // comes back.
        ReportBannerSuppression.endJourney();
        if (_currentAttemptId == attempt) {
          _inFlight = false;
          _currentAttemptId = null;
          _phase = ReportExportPhase.idle;
        }
      }
    });
  }

  Future<_AdOpportunityResult> _runAdOpportunity(
    bool Function() isCurrent, {
    Future<bool> Function()? confirmAdNotice,
  }) async {
    final showAd = await _shouldShowAd(isCurrent);
    if (!isCurrent()) return _AdOpportunityResult.superseded;
    if (!showAd) return _AdOpportunityResult.proceed;

    if (confirmAdNotice != null) {
      _phase = ReportExportPhase.confirmingAd;
      final proceed = await confirmAdNotice();
      if (!isCurrent()) return _AdOpportunityResult.superseded;
      if (!proceed) return _AdOpportunityResult.cancelled;
    }

    _phase = ReportExportPhase.presentingAd;
    // Same contract as the gate: a presentation failure is an ad outcome,
    // never a reason to withhold the report.
    try {
      final outcome = await _gateway.showIfAvailable();
      if (!isCurrent()) return _AdOpportunityResult.superseded;
      _recordOutcome(outcome);
    } catch (_) {
      if (!isCurrent()) return _AdOpportunityResult.superseded;
      _analytics.adShowFailed();
    }
    return _AdOpportunityResult.proceed;
  }

  /// Evaluate the full ad gate (§8). ANY false term ⇒ no ad.
  Future<bool> _shouldShowAd(bool Function() isCurrent) async {
    if (!_reportAdsEnabled()) return false;
    if (!_adConfigAvailable()) return false;

    _phase = ReportExportPhase.resolvingEntitlement;
    final state = await _entitlement.resolve();
    if (!isCurrent()) return false;
    // Only VERIFIED_INACTIVE is eligible; ACTIVE and UNKNOWN both skip the ad.
    if (state != ReportEntitlementState.verifiedInactive) return false;

    final canRequestAds = await _consent.canRequestAds();
    if (!isCurrent()) return false;
    if (!canRequestAds) return false;

    _phase = ReportExportPhase.preparingAd;
    _analytics.adLoadRequested();
    if (!_gateway.isAvailable) await _gateway.preload();
    if (!isCurrent()) return false;
    if (!_gateway.isAvailable) {
      _analytics.adLoadFailed();
      return false;
    }
    return true;
  }

  void _recordOutcome(ReportAdOutcome outcome) {
    switch (outcome) {
      case ReportAdOutcome.dismissed:
        // The ONLY outcome that means a human actually saw a full-screen ad.
        // The Reports banner stays quiet for a while after it, so the two
        // formats D-19 approved on that one surface cannot read as a single ad
        // break with two ads in it.
        ReportBannerSuppression.markAdShown();
        _analytics.adImpression();
        _analytics.adDismissed();
      case ReportAdOutcome.failedToShow:
        _analytics.adShowFailed();
      case ReportAdOutcome.failedToLoad:
        _analytics.adLoadFailed();
      case ReportAdOutcome.unavailable:
      case ReportAdOutcome.lifecycleInterrupted:
        break;
    }
  }

  /// Opportunistic preload (§21): only when every applicable gate allows it —
  /// flag on, config present, VERIFIED_INACTIVE, and UMP permits requests.
  /// Never preloads for VERIFIED_ACTIVE / UNKNOWN, flag off, or missing config.
  Future<void> maybePreload() async {
    if (!_reportAdsEnabled() || !_adConfigAvailable()) return;
    final state = await _entitlement.resolve();
    if (state != ReportEntitlementState.verifiedInactive) return;
    if (!await _consent.canRequestAds()) return;
    await _gateway.preload();
  }
}
