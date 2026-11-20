import '../../domain/entities/supporting_entities.dart';
import 'cloud_egress_gate.dart';

/// Every distinct class of data that can leave the device.
///
/// The taxonomy exists so consent is answered ONCE per class at the egress
/// boundary, instead of each service inventing its own check — which is how
/// F-025/C-3 happened: `cloudProcessingEnabled` gated capture upload and two
/// analytics call sites, and nothing else, while the privacy screen promised it
/// disabled synchronisation.
enum EgressClass {
  /// Money and the records that describe it: accounts, transactions, budgets,
  /// goals, subscriptions, plans, cards, bill payments, goal contributions.
  financialSync,

  /// `user_settings` — carries `display_name`, `phone_number`, `date_of_birth`.
  /// Separate from [financialSync] because it is PII rather than money.
  profileAndSettings,

  /// The encrypted backup blob and its metadata row.
  backup,

  /// Captured message content sent for cloud parsing (`parse-sms`), bank
  /// discovery, and merchant enrichment. The most sensitive class: raw bank SMS.
  aiProcessing,

  /// Gemini-first phase 3 (owner decision 2026-11-20): smart analysis — a
  /// captured bank message, sanitised on the device (names, phone and account
  /// numbers hidden), sent to Qirsh's server for Google Gemini to read the
  /// amount, type and merchant, and the result fetched back. Needs the
  /// smart-analysis (AI) consent ONLY, not Cloud: it travels in its own lane
  /// (`CloudEgressGate.runSmartAnalysis`), which admits the analysis endpoints
  /// and nothing else. Bank discovery, merchant enrichment and shared learning
  /// stay [aiProcessing] (Cloud AND AI).
  smartAnalysis,

  /// Which banks the user holds — inferred from sender→bank mappings. Not money,
  /// but a direct read on the user's financial life.
  senderBankMappings,

  /// Smart Inbox items.
  smartInbox,

  /// XP, levels, achievements, streaks, engagement events.
  gamification,

  /// Product analytics, metrics, notification delivery logs, the activity ping.
  telemetry,

  /// Crash/error reporting (Sentry). Called out separately from [telemetry]
  /// because OD-05 gives it its own explicit contract.
  diagnostics,

  /// Remote catalog: banks, parsers, flags, announcements, coupons, campaigns.
  /// Contains no user data, but Astra G (P1) removed its Cloud-OFF exception:
  /// while Cloud is OFF or unset NO automatic catalog fetch happens.
  catalog,

  /// Authentication with the identity provider. Astra G (P1) removed the
  /// automatic exception: background token refresh is denied while Cloud is OFF.
  /// Astra H2: the only network operations allowed while OFF are explicit
  /// user-initiated sign-in, re-authentication, delete-account and cancel-delete
  /// (with their strictly necessary auth exchanges). They run through
  /// `CloudEgressGate.runAccountControl(op, body)`, an operation-scoped,
  /// time-boxed, endpoint-allowlisted grant that never enables Cloud and never
  /// widens consent. That is an ESCALATED product decision, never a
  /// ConsentAuthority decision.
  auth,
}

/// The single authority deciding whether a class of data may leave this device.
///
/// ## Why this exists
/// Enforcement used to be per-service opt-in, so every new service shipped
/// ungated by default — and several did. Two independent examples found in
/// review: `RemoteBackupController` defaults its consent callback to
/// `() => true` and the provider never passes one, and the Smart Inbox pull gate
/// is a hardcoded `() => true`. A toggle that services may forget to read is not
/// enforcement.
///
/// ## Semantics
/// * **Fail closed.** `unset` and `declined` both deny. Only an explicit
///   `accepted` permits, matching [UserSettingsEntity.cloudProcessingEnabled].
/// * **Cloud is the master gate (OD-07 restrictive-wins).** AI processing
///   requires cloud consent AND AI consent. Granting AI alone must never open an
///   egress path, because the AI path transmits the same content the cloud path
///   does. The sync payload and the iOS bridge already enforced this; the in-app
///   parse path did not.
/// * **Diagnostics fail closed (OD-05).** Crash reporting can carry device,
///   user and context information, so it follows cloud consent. A future
///   genuinely-anonymous essential channel needs its own documented contract —
///   it is not assumed here.
/// * **Catalog and auth are gated like everything else** (Astra G, P1). There is
///   no automatic exception while Cloud is OFF: no catalog fetch. [decide]
///   answers false for [EgressClass.auth]; only an explicit user action may
///   authenticate (see [EgressClass.auth]). The one exception, an owner
///   decision (2026-10-29): the AuthCoordinator's session-only token refresh
///   (routine and automatic session recovery) runs while Cloud is OFF under
///   `CloudEgressGate.permitsSessionRefresh`. It carries the refresh token
///   only: no financial data, SMS, AI or sync.
///
/// ## What this class deliberately does NOT do
/// It does not cache. Callers must consult it at the moment of egress, because
/// consent can be revoked between a decision and a retry — and a queued or
/// retried request must observe the revocation, not the state at enqueue time.
class ConsentAuthority {
  const ConsentAuthority(this._settings);

  /// E1: set (synchronously) the moment the user starts switching Cloud OFF and
  /// cleared only once durable OFF is committed. While true every class is
  /// denied, so no new egress can start during the ON->OFF transition even
  /// though the stored consent still reads ON. Process-wide on purpose: the
  /// startup and the UI own different service instances. This is the
  /// synchronous in-process mirror; the DURABLE denial is the
  /// `CloudEgressGate` record, which outlives this flag (persistent OFF gate).
  static bool egressFrozen = false;

  /// Diagnostic only: a short constant naming the site that last froze egress
  /// (never a uid or a secret). Shown by the sign-in failure code.
  static String egressFreezeTag = '';

  /// Phase 4c: advanced by every [freeze]. A holder that records the value
  /// right after its own freeze owns only that contribution: [releaseFreeze]
  /// restores the earlier state only while no freeze has happened since, so a
  /// later (foreign) freeze is never erased.
  static int freezeGeneration = 0;

  /// Freezes egress and records [tag] (a constant) as the cause. With
  /// [retainTag] a freeze already in force keeps its tag; the generation still
  /// advances, so this holder's freeze outlives an earlier holder's release.
  static void freeze(String tag, {bool retainTag = false}) {
    if (!(retainTag && egressFrozen)) egressFreezeTag = tag;
    egressFrozen = true;
    freezeGeneration++;
  }

  /// Releases the freeze taken at [generation]: restores [wasFrozen] when no
  /// freeze happened since, else leaves egress frozen for the newer holder.
  static void releaseFreeze(int generation, {required bool wasFrozen}) {
    if (freezeGeneration == generation) egressFrozen = wasFrozen;
  }

  /// Reads settings FRESH on every call. See the no-caching note above.
  final Future<UserSettingsEntity> Function() _settings;

  /// Whether [egressClass] may transmit right now.
  Future<bool> allows(EgressClass egressClass) async {
    if (!decide(egressClass, await _settings())) return false;
    // Phase 3: smart analysis does not depend on the Cloud record; its lane is
    // admitted by the gate on its own scope (EgressGrant.smartAnalysis).
    if (egressClass == EgressClass.smartAnalysis) return true;
    // The durable gate: DISABLING / OFF / unreadable / corrupt / conflicting /
    // ABSENT state denies for the active owner, whatever the settings read. The
    // effective cloud consent is the persisted consent AND a durable ON record
    // (Astra H2.2).
    return CloudEgressGate.instance.permits();
  }

  /// Pure decision function — the whole policy in one readable place, so it can
  /// be exhaustively tested without a database.
  static bool decide(EgressClass egressClass, UserSettingsEntity settings) {
    final cloud = settings.cloudProcessingEnabled && !egressFrozen;
    switch (egressClass) {
      // Never automatic: an explicit account-control action goes through
      // CloudEgressGate.runAccountControl instead.
      case EgressClass.auth:
        return false;

      // Cloud consent is the master gate for everything carrying user data.
      case EgressClass.financialSync:
      case EgressClass.profileAndSettings:
      case EgressClass.backup:
      case EgressClass.senderBankMappings:
      case EgressClass.smartInbox:
      case EgressClass.gamification:
      case EgressClass.telemetry:
      case EgressClass.diagnostics:
      case EgressClass.catalog:
        return cloud;

      // OD-07: restrictive state wins. AI needs BOTH.
      case EgressClass.aiProcessing:
        return cloud && settings.aiConsentGranted;

      // Phase 3: smart analysis needs its own consent only (still never while
      // a Cloud transition froze egress).
      case EgressClass.smartAnalysis:
        return settings.aiConsentGranted && !egressFrozen;
    }
  }

  /// Human-readable reason for a denial — for diagnostics and tests, never for
  /// user-facing copy.
  static String denialReason(EgressClass egressClass, UserSettingsEntity s) {
    if (decide(egressClass, s)) return 'allowed';
    if (egressClass == EgressClass.auth) return 'auth_explicit_user_action_only';
    if (egressClass == EgressClass.aiProcessing && !s.cloudProcessingEnabled) {
      return 'ai_requires_cloud_consent';
    }
    if (egressClass == EgressClass.aiProcessing) return 'ai_consent_off';
    if (egressClass == EgressClass.smartAnalysis) {
      return egressFrozen ? 'egress_frozen' : 'ai_consent_off';
    }
    return 'cloud_consent_off';
  }
}
