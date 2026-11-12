import 'capture_import_ports.dart';
import 'native_capture_bridge.dart';

/// What the BL-2 prompt may show: a count and the senders, nothing else. The
/// ids, uid and generation are the CAS snapshot and are never displayed.
class UnboundCaptureOffer {
  const UnboundCaptureOffer({
    required this.uid,
    required this.generation,
    required this.ids,
    required this.senders,
  });

  final String uid;
  final int generation;
  final List<String> ids;
  final List<String> senders;

  int get count => ids.length;
}

enum UnboundCaptureChoice {
  /// The CAS held and the choice was applied.
  applied,

  /// The queue changed since the prompt was built; nothing was mutated.
  changed,

  /// The uid, owner record, replica owner and session no longer agree, or the
  /// native layer refused; nothing was mutated.
  refused,
}

/// BL-2 (§4.3): "N bank messages were received while you were signed out" with
/// "Add them to my account" / "Discard them".
///
/// A hint is never authority. The offer exists only when the active owner
/// record, the replica owner and the session are all the SAME uid and the
/// native layer reports items hinted to that uid. Only an explicit choice
/// mutates, through the native CAS, which re-checks everything under the queue
/// lock and otherwise changes nothing. Added items are bound `localOnly`: the
/// import service parses them on device, never uploads them, never uses AI.
class UnboundCapturePromptService {
  UnboundCapturePromptService({
    required CaptureImportQueue queue,
    required String? Function() sessionUid,
    required Future<String?> Function() replicaOwnerUid,
    required bool Function() isEnabled,
    Future<CaptureOwnerRecord?> Function(String uid)? ownerFor,
  })  : _queue = queue,
        _sessionUid = sessionUid,
        _replicaOwnerUid = replicaOwnerUid,
        _isEnabled = isEnabled,
        _ownerFor = ownerFor;

  final CaptureImportQueue _queue;

  /// The active owner record asked for the session's uid. Android's native
  /// queue holds no uid and answers only "is this uid the active owner";
  /// null uses the queue's own record (iOS).
  final Future<CaptureOwnerRecord?> Function(String uid)? _ownerFor;
  final String? Function() _sessionUid;
  final Future<String?> Function() _replicaOwnerUid;
  final bool Function() _isEnabled;

  /// The offer for the CURRENT user, or null. Never asks the native layer about
  /// any uid other than the session's own.
  Future<UnboundCaptureOffer?> check() async {
    if (!_isEnabled()) return null;
    final session = _sessionUid();
    final replica = await _replicaOwnerUid();
    if (session == null || replica != session) return null;
    try {
      final ownerFor = _ownerFor;
      final owner = ownerFor != null
          ? await ownerFor(session)
          : await _queue.getOwner();
      if (owner == null || owner.uid != session) return null;
      final summary = await _queue.unboundSummary(session);
      if (summary.count == 0) return null;
      return UnboundCaptureOffer(
        uid: session,
        generation: owner.generation,
        ids: summary.ids,
        senders: summary.senders,
      );
    } on CaptureQueueException {
      return null;
    }
  }

  Future<UnboundCaptureChoice> add(UnboundCaptureOffer offer) =>
      _choose(offer, _queue.claim);

  Future<UnboundCaptureChoice> discard(UnboundCaptureOffer offer) =>
      _choose(offer, _queue.discard);

  Future<UnboundCaptureChoice> _choose(
    UnboundCaptureOffer offer,
    Future<CaptureClaimResult> Function({
      required String uid,
      required int generation,
      required String replicaOwnerUid,
      required String sessionUid,
      required List<String> ids,
    }) apply,
  ) async {
    // Fresh values, not the offer's: an account switch since the prompt was
    // built must make the CAS fail, not be papered over.
    final session = _sessionUid();
    final replica = await _replicaOwnerUid();
    if (session == null || replica == null) return UnboundCaptureChoice.refused;
    try {
      final result = await apply(
        uid: offer.uid,
        generation: offer.generation,
        replicaOwnerUid: replica,
        sessionUid: session,
        ids: offer.ids,
      );
      switch (result.status) {
        case CaptureClaimStatus.applied:
          return UnboundCaptureChoice.applied;
        case CaptureClaimStatus.stale:
          return UnboundCaptureChoice.changed;
        case CaptureClaimStatus.ownerMismatch:
          return UnboundCaptureChoice.refused;
      }
    } on CaptureQueueException {
      return UnboundCaptureChoice.refused;
    }
  }
}
