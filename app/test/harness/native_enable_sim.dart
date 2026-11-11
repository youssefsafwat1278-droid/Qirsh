import 'dart:async';

import 'package:flutter/services.dart';

/// N-E harness: a scripted stand-in for the NATIVE side of the pending-enable
/// protocol, reached through the real [MethodChannel] the bridge uses. It models
/// only the contract the Dart side relies on (one barrier per owner, bound to a
/// live owner lifecycle; ON only under a matching barrier; complete clears the
/// barrier; abandon needs no ON). It is NOT native execution: nothing here
/// proves the Swift behaviour.

/// How the next reply of a method is faulted.
enum SimFault {
  none,
  nullReply,
  platformError,
  malformed,
  conflict,
  ownerMismatch,
  uncertain,
  incomplete,
  noBarrier,
  stale,
  pending,
  badLayers, // "done" with layers that do not verify
}

const kSimOperationId = 'abcdefabcdefabcdefabcdefabcdefab';

class NativeEnableSim {
  NativeEnableSim({this.uid = 'uid-x'});

  final String uid;
  int ownerGeneration = 7;
  int ownerEpoch = 2;

  /// Egress-state generation the restrictive publication wrote.
  int publishedTransitionGeneration = 3;
  int publishedVersion = 0;

  // The simulated native state.
  Map<String, Object?>? pending; // the barrier (same in both layers)
  String? egressState; // 'ON' | 'OFF' | null
  int egressGeneration = 0;
  int egressVersion = 0;

  /// The owner lifetime the egress ON entry is bound to (native stores the
  /// lifetime owner generation/epoch of the operation that wrote it).
  int? egressOwnerGeneration;
  int? egressOwnerEpoch;

  /// A lifetime fence's retirement on the stored entry (operationId,
  /// transitionGeneration, reservedVersion, ownerGeneration, ownerEpoch). The
  /// inspection then reports ITS fields in place of the entry's own, and names
  /// the true stored version maximum as `egressVersionFrontier`.
  Map<String, Object?>? retirement;

  /// With [retirement]: the App Group file copy is gone (a reinstall).
  bool retiredFileAbsent = false;

  /// With [retirement]: the file copy is an OFF WITHOUT the retirement.
  bool retiredFilePlain = false;

  /// Native creates the owner HMAC key lazily. Successful restrictive owner
  /// publication or a fresh `begin` establishes it; before either, inspection
  /// reports two physically absent egress layers (see `cloudEgressPending`).
  bool hashKeyExists = false;

  /// Inspection knobs: the pending entry exists in ONE layer only (status
  /// `incomplete`), or the layers disagree (status `conflict`).
  String? pendingOnlyInLayer;
  bool pendingLayersConflict = false;

  /// Every `setCloudEgressState` write fails (native storage unavailable).
  bool failEgressWrites = false;

  /// Every `getCloudEgressState` read fails (native readback unavailable).
  bool failEgressReads = false;

  /// Every `setCaptureConsentMirror` write fails.
  bool failMirror = false;

  /// `setCaptureBackendConfig` knobs (N-R8): the method is absent natively
  /// (the channel answers "not implemented"), or the native side refuses it.
  bool backendConfigMissing = false;
  bool backendConfigRefused = false;

  /// The last backend config the native side accepted (its arguments).
  Map<String, Object?>? backendConfig;

  /// The last restrictive/other consent mirror the native side accepted
  /// (`{uid, cloud, ai, version, transitionGeneration}`).
  Map<String, Object?>? mirror;
  bool ownerAlive = true;

  final List<MethodCall> calls = [];
  final Map<String, List<SimFault>> faults = {};
  final Map<String, Completer<void>> holds = {};
  final Map<String, Completer<void>> reached = {};

  /// Called with the method name at the START of every call (before any hold).
  void Function(String method)? onCall;

  /// Called right after a state-changing call applied, before the reply returns.
  void Function(String method)? afterApply;

  /// Fault the next call(s) of [method].
  void fault(String method, SimFault f) => (faults[method] ??= []).add(f);

  /// Holds the next [method] call until the returned completer completes.
  Completer<void> hold(String method) {
    reached[method] = Completer<void>();
    return holds[method] = Completer<void>();
  }

  final List<Completer<void>> _released = [];

  /// Lets every held call go (a failing test must not strand an in-flight
  /// native call that later tests would wait behind).
  void releaseAll() {
    for (final h in [...holds.values, ..._released]) {
      if (!h.isCompleted) h.complete();
    }
  }

  List<MethodCall> of(String method) =>
      calls.where((c) => c.method == method).toList();

  List<String> get methods => [for (final c in calls) c.method];

  Map<String, Object?> _binding() => {
        for (final k in [
          'operationId',
          'transitionGeneration',
          'reservedVersion',
          'ownerGeneration',
          'ownerEpoch'
        ])
          k: pending![k],
      };

  List<Map<String, Object?>> _barrierLayers(String outcome,
          {Map<String, Object?>? binding}) =>
      [
        for (final layer in ['file', 'keychain'])
          {'layer': layer, 'outcome': outcome, ...?binding}
      ];

  List<Map<String, Object?>> _egressLayers(String outcome,
          {String? state,
          int? generation,
          int? version,
          int? ownerGeneration,
          int? ownerEpoch}) =>
      [
        for (final layer in ['file', 'keychain'])
          {
            'layer': layer,
            'outcome': outcome,
            if (state != null) 'state': state,
            if (generation != null) 'transitionGeneration': generation,
            if (version != null) 'reservedVersion': version,
            if (ownerGeneration != null) 'ownerGeneration': ownerGeneration,
            if (ownerEpoch != null) 'ownerEpoch': ownerEpoch,
          }
      ];

  Map<String, Object?> _reply(
    String operation,
    String status, {
    Map<String, Object?>? binding,
    List<Map<String, Object?>>? barrier,
    List<Map<String, Object?>> egress = const [],
  }) =>
      {
        'contractVersion': 1,
        'operation': operation,
        'status': status,
        ...?binding,
        'barrier': barrier ?? _barrierLayers('absent'),
        'egress': egress,
      };

  Map<String, Object?> _args(MethodCall c) =>
      Map<String, Object?>.from(c.arguments as Map);

  bool _matches(Map<String, Object?> a) =>
      pending != null &&
      [
        'operationId',
        'transitionGeneration',
        'reservedVersion',
        'ownerGeneration',
        'ownerEpoch'
      ].every((k) => pending![k] == a[k]);

  Map<String, Object?> _binded() => _binding();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    onCall?.call(call.method);
    final r = reached[call.method];
    if (r != null && !r.isCompleted) r.complete();
    final h = holds[call.method];
    if (h != null) {
      holds.remove(call.method);
      _released.add(h);
      await h.future;
    }
    final queue = faults[call.method];
    final fault =
        queue != null && queue.isNotEmpty ? queue.removeAt(0) : SimFault.none;
    switch (call.method) {
      case 'captureOwnerEpoch':
        return ownerEpoch;
      case 'getCaptureOwner':
        return ownerAlive
            ? {
                'uid': uid,
                'uidHash': List.filled(64, 'a').join(),
                'generation': ownerGeneration,
              }
            : null;
      case 'publishRestrictiveCaptureOwner':
        final pubFault = _faulted('publishRestrictive', fault);
        if (pubFault is! _NoFault) return pubFault;
        final a = _args(call);
        final requested = a['version'] as int;
        // Native never accepts a version below the stored frontier.
        if (egressState != null && egressVersion > requested) {
          return _reply('publishRestrictive', 'stale');
        }
        // Recovery mode: both layers must still hold exactly the inspected OFF.
        final expectedGeneration = a['expectedTransitionGeneration'];
        if (expectedGeneration != null &&
            (egressState != 'OFF' ||
                pending != null ||
                egressGeneration != expectedGeneration ||
                egressVersion != a['expectedReservedVersion'] ||
                egressOwnerGeneration != a['expectedLifetimeOwnerGeneration'] ||
                egressOwnerEpoch != a['expectedLifetimeOwnerEpoch'] ||
                requested <= egressVersion)) {
          return _reply('publishRestrictive', 'conflict');
        }
        final retiredCopies = a['expectedRetiredCopies'] as List?;
        if (retiredCopies != null) {
          // Both layers must still hold exactly the inspected retired OFF, and
          // the version must be above every stored and retired version.
          final now = _egressNow();
          bool same(Object? copy, Map<String, Object?> layer) {
            final c = Map<String, Object?>.from(copy as Map);
            if (layer['outcome'] == 'absent') return c.length == 1;
            return c.length == 6 &&
                [
                  'operationId',
                  'transitionGeneration',
                  'reservedVersion',
                  'ownerGeneration',
                  'ownerEpoch'
                ].every((k) => c[k] == layer[k]);
          }

          final r = retirement;
          if (r == null ||
              retiredFilePlain ||
              egressState != 'OFF' ||
              pending != null ||
              a.containsKey('expectedOffCopies') ||
              a.containsKey('expectedTransitionGeneration') ||
              retiredCopies.length != 2 ||
              !same(retiredCopies[0], now[0]) ||
              !same(retiredCopies[1], now[1]) ||
              requested <= egressVersion ||
              requested <= (r['reservedVersion'] as int)) {
            return _reply('publishRestrictive', 'conflict');
          }
        }
        if (retirement != null) {
          // A retired lifetime is never reused: strictly above it.
          final g = retirement!['ownerGeneration'] as int;
          if (g > ownerGeneration) ownerGeneration = g;
          ownerGeneration++;
        }
        final offCopies = a['expectedOffCopies'] as List?;
        if (offCopies != null) {
          if (offCopies.length != 2 || egressState != 'OFF' || pending != null ||
              offCopies.any((r) => requested <= ((r as Map)['reservedVersion'] as int))) {
            return _reply('publishRestrictive', 'conflict');
          }
          for (final r in offCopies) {
            final generation = (r as Map)['ownerGeneration'] as int?;
            if (generation != null && generation > ownerGeneration) {
              ownerGeneration = generation;
            }
          }
          ownerGeneration++;
        }
        publishedVersion = requested;
        // The fresh restrictive lifetime replaces the retired entry in both layers.
        retirement = null;
        retiredFileAbsent = false;
        retiredFilePlain = false;
        ownerAlive = true; // a restrictive publication creates the owner
        // A successful receipt reports the physical OFF records it persisted.
        hashKeyExists = true;
        egressState = 'OFF';
        // Native never lowers a transition generation.
        if (egressGeneration < publishedTransitionGeneration) {
          egressGeneration = publishedTransitionGeneration;
        }
        egressVersion = publishedVersion;
        egressOwnerGeneration = ownerGeneration;
        egressOwnerEpoch = a['expectedEpoch'] as int;
        return {
          'contractVersion': 1,
          'operation': 'publishRestrictive',
          'status': 'done',
          'owner': {
            'uid': a['uid'],
            'uidHash': List.filled(64, 'a').join(),
            'generation': ownerGeneration,
          },
          'ownerGeneration': ownerGeneration,
          'ownerEpoch': a['expectedEpoch'],
          'barrier': _barrierLayers('absent'),
          'egress': [
            for (final layer in ['file', 'keychain'])
              {
                'layer': layer,
                'outcome': 'verified',
                'state': 'OFF',
                'transitionGeneration': egressGeneration,
                'reservedVersion': a['version'],
                'ownerGeneration': ownerGeneration,
                'ownerEpoch': a['expectedEpoch'],
              }
          ],
        };
      case 'revokeCaptureAuthorizationLifetime':
        final revokeFault = _faulted('revoke', fault);
        if (revokeFault is! _NoFault) return revokeFault;
        final a = _args(call);
        return {
          'contractVersion': 1,
          'operation': 'revoke',
          'status': 'done',
          for (final k in [
            'operationId',
            'transitionGeneration',
            'reservedVersion',
            'ownerGeneration',
            'ownerEpoch'
          ])
            k: a[k],
          'barrier': _barrierLayers('absent'),
          'egress': [
            for (final layer in ['file', 'keychain'])
              {
                'layer': layer,
                'outcome': 'verified',
                'state': 'OFF',
                for (final k in [
                  'operationId',
                  'transitionGeneration',
                  'reservedVersion',
                  'ownerGeneration',
                  'ownerEpoch'
                ])
                  k: a[k],
              }
          ],
        };
      case 'setCaptureConsentMirror':
        if (failMirror) throw PlatformException(code: 'storage_write_failed');
        mirror = _args(call);
        return null;
      case 'setCaptureBackendConfig':
        if (backendConfigMissing) throw MissingPluginException();
        if (backendConfigRefused) {
          throw PlatformException(code: 'storage_write_failed');
        }
        backendConfig = _args(call);
        return null;
      case 'getCloudEgressState':
        if (failEgressReads) throw PlatformException(code: 'queue_unavailable');
        // AppDelegate's snapshot shape: unset, or one reconciled record.
        if (egressState == null) return {'status': 'unset'};
        return {
          'status': 'record',
          'state': egressState,
          'ownerUid': uid,
          'transitionGeneration': egressGeneration,
          'reservedVersion': egressVersion,
        };
      case 'setCloudEgressState':
        return _setEgress(_args(call));
      case 'beginCloudEgressEnable':
        return _begin(_args(call), fault);
      case 'writeCloudEgressEnableOn':
        return _writeOn(_args(call), fault);
      case 'restrictCloudEgressEnable':
        return _restrict(_args(call), fault);
      case 'finishCloudEgressEnable':
        return _finish(_args(call), fault);
      case 'getCloudEgressPending':
        return _inspect(fault);
      default:
        throw StateError('unexpected native operation ${call.method}');
    }
  }

  /// The egress layers as the inspection reports them now.
  List<Map<String, Object?>> _egressNow() {
    if (egressState == null) return _egressLayers('absent');
    final plain = _egressLayers('verified',
        state: egressState,
        generation: egressGeneration,
        version: egressVersion,
        ownerGeneration: egressOwnerGeneration,
        ownerEpoch: egressOwnerEpoch);
    final r = retirement;
    if (r == null) return plain;
    return [
      for (final layer in ['file', 'keychain'])
        if (layer == 'file' && retiredFileAbsent)
          {'layer': layer, 'outcome': 'absent'}
        else if (layer == 'file' && retiredFilePlain)
          plain[0]
        else
          {'layer': layer, 'outcome': 'verified', 'state': egressState, ...r},
    ];
  }

  /// The true stored maximum (entry and retirement), when an entry exists.
  int? _versionFrontier() {
    if (egressState == null) return null;
    final retired = retirement?['reservedVersion'] as int? ?? 0;
    return retired > egressVersion ? retired : egressVersion;
  }

  static const _rank = {'ON': 0, 'DISABLING': 1, 'OFF': 2};

  /// `SharedCaptureStore.setCloudEgressState`: a non-restrictive write is
  /// refused while a pending barrier of the owner exists; nothing older than the
  /// stored (generation, rank) is accepted; the lifetime evidence is kept.
  Object? _setEgress(Map<String, Object?> a) {
    if (failEgressWrites) throw PlatformException(code: 'storage_write_failed');
    final state = a['state'] as String;
    final rank = _rank[state]!;
    final generation = a['transitionGeneration'] as int;
    if (rank == 0 && pending != null) {
      throw PlatformException(code: 'egress_denied');
    }
    final held = egressState;
    if (held != null &&
        (generation < egressGeneration ||
            (generation == egressGeneration && rank < _rank[held]!))) {
      throw PlatformException(code: 'stale_generation');
    }
    final requestedVersion = a['reservedVersion'] as int;
    if (rank == 0 && requestedVersion < egressVersion) {
      throw PlatformException(code: 'stale_generation');
    }
    egressState = state;
    egressGeneration = generation;
    egressVersion = rank > 0 && egressVersion > requestedVersion
        ? egressVersion : requestedVersion;
    hashKeyExists = true;
    return null;
  }

  Object? _faulted(String operation, SimFault fault) {
    switch (fault) {
      case SimFault.nullReply:
        return null;
      case SimFault.platformError:
        throw PlatformException(code: 'queue_unavailable');
      case SimFault.malformed:
        return {'contractVersion': 1, 'operation': operation};
      case SimFault.conflict:
        return _reply(operation, 'conflict');
      case SimFault.ownerMismatch:
        return _reply(operation, 'ownerMismatch');
      case SimFault.uncertain:
        return _reply(operation, 'uncertain');
      case SimFault.incomplete:
        return _reply(operation, 'incomplete');
      case SimFault.noBarrier:
        return _reply(operation, 'noBarrier');
      case SimFault.stale:
        return _reply(operation, 'stale');
      case SimFault.pending:
        return _reply(operation, 'pending');
      case SimFault.badLayers:
      case SimFault.none:
        return const _NoFault();
    }
  }

  Object? _begin(Map<String, Object?> a, SimFault fault) {
    final f = _faulted('begin', fault);
    if (f is! _NoFault) return f;
    if (!ownerAlive) return _reply('begin', 'ownerMismatch');
    final resumeId = a['resumeOperationId'];
    if (pending != null) {
      final same = resumeId != null &&
          pending!['operationId'] == resumeId &&
          a['resumeOwnerEpoch'] == pending!['ownerEpoch'] &&
          a['transitionGeneration'] == pending!['transitionGeneration'] &&
          a['reservedVersion'] == pending!['reservedVersion'] &&
          pending!['ownerEpoch'] == ownerEpoch &&
          pending!['ownerGeneration'] == ownerGeneration;
      if (!same) {
        return _reply('begin', 'conflict',
            binding: _binded(),
            barrier: _barrierLayers('verified', binding: _binded()));
      }
    } else {
      hashKeyExists = true;
      pending = {
        'operationId': kSimOperationId,
        'transitionGeneration': a['transitionGeneration'],
        'reservedVersion': a['reservedVersion'],
        'ownerGeneration': ownerGeneration,
        'ownerEpoch': ownerEpoch,
      };
    }
    afterApply?.call('beginCloudEgressEnable');
    return _reply('begin', 'done',
        binding: _binded(),
        barrier: _barrierLayers(
            fault == SimFault.badLayers ? 'writeFailed' : 'verified',
            binding: _binded()));
  }

  Object? _writeOn(Map<String, Object?> a, SimFault fault) {
    final f = _faulted('writeOn', fault);
    if (f is! _NoFault) return f;
    if (!ownerAlive ||
        a['ownerGeneration'] != ownerGeneration ||
        a['ownerEpoch'] != ownerEpoch) {
      return _reply('writeOn', 'ownerMismatch');
    }
    if (!_matches(a)) return _reply('writeOn', 'conflict');
    egressState = 'ON';
    egressGeneration = a['transitionGeneration'] as int;
    egressVersion = a['reservedVersion'] as int;
    egressOwnerGeneration = a['ownerGeneration'] as int;
    egressOwnerEpoch = a['ownerEpoch'] as int;
    afterApply?.call('writeCloudEgressEnableOn');
    return _reply('writeOn', 'done',
        binding: _binded(),
        barrier: _barrierLayers('verified', binding: _binded()),
        egress: _egressLayers(
            fault == SimFault.badLayers ? 'writeFailed' : 'verified',
            state: 'ON',
            generation: egressGeneration,
            version: egressVersion));
  }

  Object? _restrict(Map<String, Object?> a, SimFault fault) {
    final f = _faulted('restrict', fault);
    if (f is! _NoFault) return f;
    if (!_matches(a)) return _reply('restrict', 'noBarrier');
    if (egressState == 'ON' && egressGeneration == a['transitionGeneration']) {
      egressState = 'OFF';
    }
    afterApply?.call('restrictCloudEgressEnable');
    return _reply('restrict', 'done',
        binding: _binded(),
        barrier: _barrierLayers('verified', binding: _binded()),
        egress: _egressLayers(
            fault == SimFault.badLayers ? 'writeFailed' : 'alreadyRestrictive',
            state: egressState));
  }

  Object? _finish(Map<String, Object?> a, SimFault fault) {
    final abandon = a['abandon'] == true;
    final op = abandon ? 'abandon' : 'complete';
    final f = _faulted(op, fault);
    if (f is! _NoFault) return f;
    if (!ownerAlive ||
        a['ownerGeneration'] != ownerGeneration ||
        a['ownerEpoch'] != ownerEpoch) {
      return _reply(op, 'ownerMismatch');
    }
    if (!_matches(a)) return _reply(op, 'noBarrier');
    final binding = _binded();
    if (abandon) {
      if (egressState == 'ON') {
        return _reply(op, 'conflict',
            binding: binding,
            barrier: _barrierLayers('verified', binding: binding),
            egress: _egressLayers('verified', state: 'ON'));
      }
      pending = null;
      afterApply?.call('abandon');
      return _reply(op, 'done',
          binding: binding,
          barrier: _barrierLayers('cleared'),
          egress: _egressLayers('absent'));
    }
    if (egressState != 'ON') {
      return _reply(op, 'conflict', binding: binding);
    }
    pending = null;
    afterApply?.call('complete');
    return _reply(op, 'done',
        binding: binding,
        barrier: _barrierLayers(
            fault == SimFault.badLayers ? 'verified' : 'cleared'),
        egress: _egressLayers('verified',
            state: 'ON', generation: egressGeneration, version: egressVersion));
  }

  /// The REAL native inspection (`SharedCaptureStore.cloudEgressPending`):
  /// status `noBarrier` when nothing is pending (whatever the egress holds),
  /// `pending` when both barrier layers hold the same entry, `incomplete` when
  /// one does, `conflict` when they disagree; never `done`. The egress layers
  /// are empty only while no owner hash key exists, otherwise one report per
  /// layer (`absent`, or `verified` with state, generation, version and the
  /// lifetime owner generation/epoch).
  Object? _inspect(SimFault fault) {
    final f = _faulted('inspect', fault);
    if (f is! _NoFault) return f;
    List<Map<String, Object?>> egress() => _egressNow();
    final frontier = _versionFrontier();
    Map<String, Object?> withFrontier(Map<String, Object?> reply) =>
        {...reply, if (frontier != null) 'egressVersionFrontier': frontier};
    if (pending == null) {
      return withFrontier(_reply('inspect', 'noBarrier', egress: egress()));
    }
    final binding = _binded();
    final layers = <Map<String, Object?>>[
      for (final layer in ['file', 'keychain'])
        if (pendingOnlyInLayer != null && pendingOnlyInLayer != layer)
          {'layer': layer, 'outcome': 'absent'}
        else if (pendingLayersConflict && layer == 'keychain')
          {
            'layer': layer,
            'outcome': 'verified',
            ...binding,
            'operationId': 'f' * 32,
          }
        else
          {'layer': layer, 'outcome': 'verified', ...binding},
    ];
    final status = pendingLayersConflict
        ? 'conflict'
        : pendingOnlyInLayer != null
            ? 'incomplete'
            : 'pending';
    return withFrontier(_reply('inspect', status,
        binding: binding, barrier: layers, egress: egress()));
  }
}

class _NoFault {
  const _NoFault();
}
