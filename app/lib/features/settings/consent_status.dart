import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../../core/privacy/cloud_egress_gate.dart';
import '../../core/privacy/consent_authority.dart';
import '../../domain/entities/supporting_entities.dart';

/// What the Privacy screen says about Cloud sync and Smart Analysis.
enum ConsentStatus {
  /// Both are on AND the live gate confirms it.
  active,

  /// Only part of the permission is on (cloud without AI, or a legacy AI-only
  /// row). Never normalised silently.
  partial,

  /// Nothing is on.
  off,

  /// The stored choice says on but the live state cannot be confirmed.
  unknown,

  /// An explicit enable has not finished (or could not be confirmed).
  turningOn,

  /// A disable is in progress; egress is already stopped.
  turningOff,
}

/// Read-only facts about the live egress gate for the active owner. Reading them
/// never creates authority and never touches the network.
class ConsentLiveFacts {
  const ConsentLiveFacts({
    this.egressState,
    this.uncertain = false,
    this.enablePending = false,
    this.pendingResumable = false,
    this.pendingUnresolved = false,
    this.frozen = false,
    this.resolved = true,
    this.nativeVerified = true,
  });

  /// The durable egress record's state for the active owner (null = absent).
  final EgressState? egressState;

  /// A durable store was unreadable or corrupt.
  final bool uncertain;

  /// An explicit enable is pending (in this process or durably).
  final bool enablePending;

  /// R17: the pending enable is EXACTLY resumable (one consistent operation at
  /// the version the stored row implies). False for every unresolved or
  /// conflicting pending, where the only way out is the verified withdrawal.
  final bool pendingResumable;

  /// N-CR-4: the pending evidence cannot be attributed to one operation
  /// (corrupt, unreadable, conflicting or mismatched layers), so the verified
  /// withdrawal would refuse to clear it. Independent of whether any pending
  /// record is readable and of the stored choice. There is no Turn on and no
  /// withdrawal to offer; the evidence is never erased automatically.
  final bool pendingUnresolved;

  /// Egress is frozen (a disable is in flight).
  final bool frozen;

  /// The gate finished its start-up reconciliation.
  final bool resolved;

  /// The service verified the live ON in every layer: the Dart records and,
  /// where a native barrier exists, the same ON read back from the native
  /// layers. False when it cannot (native unset, OFF, unreadable, disagreeing).
  final bool nativeVerified;

  /// A clean, resolved, durable ON.
  static const confirmedOn = ConsentLiveFacts(egressState: EgressState.on);

  /// Nothing could be read.
  static const unreadable = ConsentLiveFacts(uncertain: true);
}

/// Combines the stored choices with the live facts. A stored "accepted" alone is
/// never reported as active: only a confirmed, resolved, durable ON is.
ConsentStatus deriveConsentStatus(
    UserSettingsEntity settings, ConsentLiveFacts? facts) {
  if (facts == null) return ConsentStatus.unknown;
  if (facts.pendingUnresolved) return ConsentStatus.unknown;
  if (facts.enablePending) return ConsentStatus.turningOn;
  if (facts.frozen || facts.egressState == EgressState.disabling) {
    return ConsentStatus.turningOff;
  }
  final cloud = settings.cloudProcessingEnabled;
  final ai = settings.aiConsentGranted;
  if (!cloud && !ai) return ConsentStatus.off;
  if (facts.uncertain || !facts.resolved) return ConsentStatus.unknown;
  // Cloud OFF sends nothing, whatever the stored AI choice says (iOS keeps the
  // AI choice when sign-out pauses Cloud). Reporting that as "partially on"
  // made a paused account look active; it is OFF.
  if (!cloud) return ConsentStatus.off;
  // A stored ON is never reported as active unless the live ON is verified in
  // every layer (the Dart records AND, where it exists, the native ones).
  if (cloud && (facts.egressState != EgressState.on || !facts.nativeVerified)) {
    return ConsentStatus.unknown;
  }
  return cloud && ai ? ConsentStatus.active : ConsentStatus.partial;
}

/// The live facts, read from the egress gate (local stores only). Any failure
/// is reported as uncertain, never as on.
final consentLiveFactsProvider =
    FutureProvider.autoDispose<ConsentLiveFacts>((ref) async {
  final gate = CloudEgressGate.instance;
  try {
    final view = await gate.view();
    // An unreadable pending layer is uncertainty, not a claim that an enable is
    // in flight.
    final unreadable = (await gate.readPending()).unreadable;
    final pending =
        !unreadable && await gate.pendingBlocks(owner: view.owner);
    final service = ref.read(captureDeviceRegistrationServiceProvider);
    final verified = view.record?.state == EgressState.on &&
        await service.liveOnVerified(owner: view.owner);
    // N-PV: pending provenance is inspected independently of whether the Dart
    // pending is present, readable or absent: a native barrier can survive on
    // its own (a partial persistence or a crash). The inspection covers the
    // native runtime whenever one exists, classifies anything it cannot
    // attribute as unresolved, and only reads: nothing is fabricated for the
    // Dart side and no native operation is abandoned.
    var unresolved = false;
    if (view.owner.isNotEmpty) {
      unresolved =
          await service.pendingProvenanceUnresolved(ownerUid: view.owner);
    }
    var resumable = false;
    if (pending && !unresolved) {
      try {
        final stored = await ref.read(userSettingsRepositoryProvider).getSettings();
        resumable = await service.pendingEnableState(stored,
                ownerUid: view.owner) ==
            PendingEnableState.resumable;
      } catch (_) {}
    }
    return ConsentLiveFacts(
      egressState: view.record?.state,
      uncertain: view.uncertain || unreadable,
      enablePending: pending,
      pendingResumable: resumable,
      pendingUnresolved: unresolved,
      frozen: ConsentAuthority.egressFrozen,
      resolved: gate.isResolved,
      nativeVerified: verified,
    );
  } catch (_) {
    return ConsentLiveFacts.unreadable;
  }
});
