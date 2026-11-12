import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'session_files.dart';
import 'session_keychain.dart';
import 'session_record.dart';

/// ASR design v7.2 §6 — the coordinator-owned session store.
///
/// One Keychain item per backend namespace holds the whole record (§6.2). Only
/// coordinator operations write it (I4); SDK storage callbacks never do. The
/// store keeps the last confirmed record ([committed]) and an [indeterminate]
/// flag: a write whose outcome is unknown is resolved by a reload queued on the
/// native serial queue behind it (§6.3), and while unresolved nothing may act on
/// the session.

/// §6.8 load classes.
enum LoadClass {
  verifiedEmpty,
  valid,
  validFinalizing,
  validRequiresAdoption,
  validDead,
  validBarred,
  unknownProvenance,

  /// A required read was temporarily unavailable: `Supabase.initialize` must
  /// not run, nothing restrictive is published, and the load is retried (§6.7).
  deferred,
}

@immutable
class LoadResult {
  const LoadResult(this.loadClass,
      {this.record, this.untrustedThisLaunch = false, this.reason});

  final LoadClass loadClass;

  /// The committed record for every class except [LoadClass.deferred] and
  /// [LoadClass.unknownProvenance] (null when verified empty).
  final SessionRecord? record;

  /// §6.6-5: a migration-marker repair could not be confirmed; the record is
  /// not trusted for any automatic admission this launch.
  final bool untrustedThisLaunch;

  /// Diagnostic only (never contains an id, token or value).
  final String? reason;

  /// What the one-shot SDK storage may serve (§4.7 init case, §6.8): only a
  /// valid ordinary record (with or without a finalizing adoption).
  SessionRecord? get served => !untrustedThisLaunch &&
          (loadClass == LoadClass.valid ||
              loadClass == LoadClass.validFinalizing)
      ? record
      : null;
}

/// Outcome of one store write.
enum WriteOutcome {
  /// The OS reported success; [SessionStore.committed] is the new record.
  committed,

  /// Confirmed not written (an error status); the committed record is unchanged.
  failed,

  /// Unknown, and the reload could not resolve it: the store is
  /// [SessionStore.indeterminate].
  indeterminate,
}

/// The legacy SDK session (SharedPreferences, `sb-<first host label>-auth-token`,
/// supabase.dart:125-131). Values are read only while legacy cleanup is pending.
abstract class LegacySessionSource {
  /// Null value = no value. Throws when the store cannot be read.
  Future<String?> readValue();

  /// Blind remove, then `containsKey`; true only when verified gone.
  Future<bool> removeVerified();
}

class SessionStore {
  SessionStore({
    required this.keychain,
    required this.files,
    required this.origin,
    required this.legacy,
    required this.localInstallDataPresent,
    Random? random,
  })  : ns = namespaceHash(origin),
        _random = random ?? Random.secure();

  final SessionKeychainApi keychain;
  final SessionFiles files;
  final Uri origin;
  final LegacySessionSource legacy;

  /// §6.5: whether this install already has local app data (the encrypted
  /// database). Null = cannot tell → deferred.
  final Future<bool?> Function() localInstallDataPresent;
  final Random _random;

  final String ns;
  String get itemKey => sessionItemKey(ns);

  String? _installId;
  String? get installId => _installId;

  SessionRecord? _committed;
  bool _indeterminate = false;
  int _floorSeq = 0;
  int _floorLifecycle = 0;

  /// The last confirmed record (null = verified empty: absent, tombstone or void).
  SessionRecord? get committed => _committed;
  bool get indeterminate => _indeterminate;

  /// The seq/lifecycle the next record must exceed when [committed] is null
  /// (after a tombstone or a void record).
  int get nextSeqFloor => _committed?.seq ?? _floorSeq;
  int get lifecycleFloor => _committed?.lifecycle ?? _floorLifecycle;

  String _newId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  // ------------------------------------------------------------------- load

  Future<LoadResult> load() async {
    if (await keychain.protectedDataAvailable() != true) {
      return const LoadResult(LoadClass.deferred, reason: 'protected_data');
    }
    final marker = await files.readInstallMarker();
    final fence = await files.readFence();
    final migration = await files.readMigration();
    final item = await keychain.read(itemKey);
    for (final s in [marker.status, fence.status, migration.status]) {
      if (s == FileStatus.unavailable) {
        return const LoadResult(LoadClass.deferred, reason: 'file_unavailable');
      }
    }
    // Android: the item exists but can never be read again (its Keystore key
    // is gone or invalidated, or its bytes are damaged). Retrying cannot help,
    // so it is not deferred: nothing is served or admitted from it, it is never
    // reported absent to the migration (no legacy import), and the next
    // explicit sign-in replaces it.
    final unrecoverable = item.isUnrecoverable;
    if (item.status != KeychainStatus.found &&
        item.status != KeychainStatus.absent &&
        !unrecoverable) {
      return const LoadResult(LoadClass.deferred, reason: 'item_unavailable');
    }
    if (marker.status == FileStatus.malformed) {
      // No regeneration this launch.
      return const LoadResult(LoadClass.unknownProvenance,
          reason: 'install_marker_malformed');
    }
    if (fence.status == FileStatus.malformed ||
        migration.status == FileStatus.malformed) {
      return const LoadResult(LoadClass.unknownProvenance,
          reason: 'marker_malformed');
    }

    SessionRecord? record;
    if (item.isFound) {
      try {
        record = SessionRecord.decode(item.value!);
      } on FormatException {
        return const LoadResult(LoadClass.unknownProvenance,
            reason: 'record_malformed');
      }
      if (record.ns != ns) {
        return const LoadResult(LoadClass.unknownProvenance,
            reason: 'record_ns');
      }
    }

    // §6.5 install marker.
    final fenceMap = fence.value ?? const <String, FenceEntry>{};
    var migrationMap = migration.value ?? const <String, MigrationEntry>{};
    if (marker.isFound) {
      _installId = marker.value;
      if (record != null && record.installId != _installId) {
        record = await _voidRecord(record);
      }
    } else {
      final id = _newId();
      if (record != null) {
        final hasLocal = await localInstallDataPresent();
        if (hasLocal == null) {
          return const LoadResult(LoadClass.deferred, reason: 'local_data');
        }
        if (!hasLocal) {
          // Reinstall: the Keychain outlived the app. Delete the orphan item.
          final del = await keychain.delete(itemKey);
          if (!del.isOk || !(await keychain.read(itemKey)).isAbsent) {
            return const LoadResult(LoadClass.deferred,
                reason: 'orphan_delete_failed');
          }
          record = null;
        }
      }
      if (!await files.writeInstallMarker(id)) {
        return const LoadResult(LoadClass.deferred, reason: 'marker_write');
      }
      _installId = id;
      if (record != null) {
        // Marker lost while local data survived: void the record.
        record = await _voidRecord(record);
      }
    }

    // §6.6 migration.
    // A Keychain item that existed at load (even if voided above) forbids an
    // import: only repair is allowed.
    final migrationResult = await _migrate(record, fenceMap,
        Map.of(migrationMap),
        itemPresent: item.isFound || unrecoverable);
    if (migrationResult.deferred) {
      return const LoadResult(LoadClass.deferred, reason: 'migration');
    }
    if (migrationResult.unknownProvenance) {
      return const LoadResult(LoadClass.unknownProvenance,
          reason: 'legacy_corrupt');
    }
    record = migrationResult.record;
    migrationMap = migrationResult.map;

    // §6.4-4 fence (same install only).
    final f = fenceMap[ns];
    if (record != null && f != null && f.installId == record.installId &&
        (record.seq <= f.removedThroughSeq ||
            record.lifecycle < f.lifecycleFloor)) {
      _floorSeq = max(record.seq, f.removedThroughSeq);
      _floorLifecycle = max(record.lifecycle, f.lifecycleFloor);
      record = null;
    } else if (f != null && f.installId == _installId) {
      _floorSeq = f.removedThroughSeq;
      _floorLifecycle = f.lifecycleFloor;
    }

    if (record != null && record.isTombstone) {
      _floorSeq = record.seq;
      _floorLifecycle = record.lifecycle;
      _committed = null;
      return const LoadResult(LoadClass.verifiedEmpty);
    }
    _committed = record;
    if (record == null) {
      return LoadResult(LoadClass.verifiedEmpty,
          reason: unrecoverable ? 'record_unrecoverable' : null);
    }
    return LoadResult(classify(record),
        record: record, untrustedThisLaunch: migrationResult.untrusted);
  }

  /// §6.8 for a non-tombstone record.
  static LoadClass classify(SessionRecord r) {
    final a = r.adoption;
    if (a != null && a.state != AdoptionState.finalizing) {
      return LoadClass.validBarred;
    }
    if (r.autoAdmissionBlocked == r.lifecycle) return LoadClass.validBarred;
    if (r.credential == CredentialState.dead) return LoadClass.validDead;
    if (r.admission == AdmissionDisposition.requiresAdoption) {
      return LoadClass.validRequiresAdoption;
    }
    return a == null ? LoadClass.valid : LoadClass.validFinalizing;
  }

  /// Voids [record] by writing a tombstone under the current install id. Returns
  /// null (verified empty) on success; on failure the record stays voided for
  /// this launch only in memory (the next launch repeats the marker check).
  Future<SessionRecord?> _voidRecord(SessionRecord record) async {
    final tomb = SessionRecord(
      ns: ns,
      installId: _installId!,
      seq: record.seq + 1,
      lifecycle: record.lifecycle + 1,
      kind: RecordKind.tombstone,
    );
    await keychain.write(itemKey, tomb.encode());
    _floorSeq = tomb.seq;
    _floorLifecycle = tomb.lifecycle;
    return null;
  }

  Future<_Migration> _migrate(SessionRecord? record,
      Map<String, FenceEntry> fence, Map<String, MigrationEntry> map,
      {required bool itemPresent}) async {
    final entry = map[ns];

    Future<_Migration> cleanup(MigrationEntry e, SessionRecord? r,
        {bool untrusted = false}) async {
      // §6.6-3(iv)/(v) and §6.6-6: blind remove + containsKey; never a value read.
      if (await legacy.removeVerified() &&
          e.legacyCleanup == LegacyCleanup.pending) {
        const done = MigrationEntry(
            state: MigrationState.done, legacyCleanup: LegacyCleanup.done);
        if (await files.writeMigrationEntry(map, ns, done)) map[ns] = done;
      }
      return _Migration(record: r, map: map, untrusted: untrusted);
    }

    if (entry != null) {
      if (entry.state == MigrationState.importing) {
        // Crash inside the import: with a record → repair to done; without →
        // done (sign in once). Either way the legacy value is never read again.
        const done = MigrationEntry(
            state: MigrationState.done, legacyCleanup: LegacyCleanup.pending);
        final ok = await files.writeMigrationEntry(map, ns, done);
        if (ok) map[ns] = done;
        return cleanup(done, record, untrusted: record != null && !ok);
      }
      return cleanup(entry, record);
    }

    // No entry for ns.
    if (itemPresent || fence.containsKey(ns)) {
      // §6.6-5 repair first: write `done` before the record is trusted.
      const done = MigrationEntry(
          state: MigrationState.done, legacyCleanup: LegacyCleanup.pending);
      final ok = await files.writeMigrationEntry(map, ns, done);
      if (ok) map[ns] = done;
      return cleanup(done, record, untrusted: record != null && !ok);
    }

    final String? raw;
    try {
      raw = await legacy.readValue();
    } catch (_) {
      return _Migration.deferred();
    }
    if (raw == null) {
      const done = MigrationEntry(
          state: MigrationState.done, legacyCleanup: LegacyCleanup.done);
      if (await files.writeMigrationEntry(map, ns, done)) map[ns] = done;
      return _Migration(record: null, map: map);
    }

    // (i) marker `importing`, durable and read back.
    const importing = MigrationEntry(
        state: MigrationState.importing, legacyCleanup: LegacyCleanup.pending);
    if (!await files.writeMigrationEntry(map, ns, importing)) {
      return _Migration.deferred();
    }
    map[ns] = importing;

    final imported = _legacyRecord(raw);
    if (imported == _LegacyParse.corrupt) {
      // Unknown provenance; the marker forbids any later import.
      return _Migration(record: null, map: map, unknownProvenance: true);
    }
    SessionRecord? newRecord;
    if (imported is SessionRecord) {
      // (ii) the v2 record.
      final w = await keychain.write(itemKey, imported.encode());
      if (w.isOk) {
        newRecord = imported;
      } else {
        // Not imported (or unknown): reload decides; never retried.
        final back = await keychain.read(itemKey);
        if (back.isFound) {
          try {
            final r = SessionRecord.decode(back.value!);
            if (r.encode() == imported.encode()) newRecord = r;
          } on FormatException {
            return _Migration(record: null, map: map, unknownProvenance: true);
          }
        }
      }
    }
    // (iii) done, cleanup pending → (iv)/(v).
    const done = MigrationEntry(
        state: MigrationState.done, legacyCleanup: LegacyCleanup.pending);
    final ok = await files.writeMigrationEntry(map, ns, done);
    if (ok) map[ns] = done;
    return cleanup(done, newRecord, untrusted: newRecord != null && !ok);
  }

  /// Parses the legacy SDK value. Mismatched issuer/subject → not imported
  /// ([_LegacyParse.notImported]); corrupt → [_LegacyParse.corrupt].
  Object _legacyRecord(String raw) {
    final Map<String, dynamic> json;
    final String canonical;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return _LegacyParse.corrupt;
      json = decoded;
      canonical = canonicalSession(json);
    } catch (_) {
      return _LegacyParse.corrupt;
    }
    final session = jsonDecode(canonical) as Map<String, dynamic>;
    final uid = (session['user'] as Map)['id'];
    final claims = jwtClaims(session['access_token'] as String);
    final base = origin.toString().endsWith('/')
        ? origin.toString().substring(0, origin.toString().length - 1)
        : origin.toString();
    if (claims == null || claims['iss'] != '$base/auth/v1' ||
        claims['sub'] != uid || uid is! String) {
      return _LegacyParse.notImported;
    }
    return SessionRecord(
      ns: ns,
      installId: _installId!,
      seq: max(nextSeqFloor, 0) + 1,
      lifecycle: max(lifecycleFloor, 0) + 1,
      kind: RecordKind.session,
      owner: uid,
      session: canonical,
      // The previous build admitted this session ordinarily; importing it as
      // requiresAdoption would sign every Cloud-OFF user out on update.
      admission: AdmissionDisposition.ordinary,
    );
  }

  // ------------------------------------------------------------------ write

  /// Writes [next] (which must be `committed.seq + 1`). Callers hold the
  /// coordinator's `AuthMutationSection`.
  Future<WriteOutcome> write(SessionRecord next) async {
    if (_indeterminate) return WriteOutcome.indeterminate;
    final expected = nextSeqFloor + 1;
    if (next.seq != expected || next.ns != ns || next.installId != _installId) {
      throw StateError('session_store_sequence');
    }
    final w = await keychain.write(itemKey, next.encode());
    switch (w.status) {
      case KeychainStatus.ok:
        _committed = next;
        return WriteOutcome.committed;
      case KeychainStatus.error:
      case KeychainStatus.unavailable:
        // The OS reported a definite failure: the item is unchanged.
        return WriteOutcome.failed;
      case KeychainStatus.unknown:
      case KeychainStatus.found:
      case KeychainStatus.absent:
        _indeterminate = true;
        return await _reconcile(next);
    }
  }

  /// §6.3: the reload runs on the native serial queue behind the outstanding
  /// write, so it observes that write's outcome. Adopt what is found.
  Future<WriteOutcome> _reconcile(SessionRecord attempted) async {
    final back = await keychain.read(itemKey);
    if (back.isAbsent) {
      _indeterminate = false;
      // Nothing there: the write did not land (the previous record cannot have
      // been absent unless committed was null).
      return _committed == null ? WriteOutcome.failed : _unexpected();
    }
    if (!back.isFound) return WriteOutcome.indeterminate;
    final SessionRecord found;
    try {
      found = SessionRecord.decode(back.value!);
    } on FormatException {
      return WriteOutcome.indeterminate;
    }
    _indeterminate = false;
    if (found.encode() == attempted.encode()) {
      _committed = attempted;
      return WriteOutcome.committed;
    }
    if (_committed != null && found.encode() == _committed!.encode()) {
      return WriteOutcome.failed;
    }
    return _unexpected();
  }

  /// The item holds neither the previous nor the attempted record: someone else
  /// wrote it. Restrictive: stay indeterminate.
  WriteOutcome _unexpected() {
    _indeterminate = true;
    return WriteOutcome.indeterminate;
  }

  /// Re-reads the item to resolve [indeterminate] (e.g. on the next trigger).
  Future<bool> resolve() async {
    if (!_indeterminate) return true;
    final back = await keychain.read(itemKey);
    if (back.isAbsent && _committed == null) {
      _indeterminate = false;
      return true;
    }
    if (!back.isFound) return false;
    try {
      final r = SessionRecord.decode(back.value!);
      if (r.ns != ns || r.installId != _installId) return false;
      if (r.seq < nextSeqFloor) return false;
      _committed = r.isTombstone ? null : r;
      if (r.isTombstone) {
        _floorSeq = r.seq;
        _floorLifecycle = r.lifecycle;
      }
      _indeterminate = false;
      return true;
    } on FormatException {
      return false;
    }
  }

  // ---------------------------------------------------------------- removal

  /// §6.4 steps 2, 3 and 5 (the synchronous intent, step 1, is the
  /// coordinator's). Returns true when the removal is durable.
  Future<bool> remove() async {
    final c = _committed;
    final seq = nextSeqFloor;
    final lifecycle = lifecycleFloor;
    final fence = await files.readFence();
    var fenced = false;
    if (fence.isFound || fence.isAbsent) {
      fenced = await files.writeFenceEntry(
        fence.value ?? const {},
        ns,
        FenceEntry(
            installId: _installId!,
            removedThroughSeq: seq,
            lifecycleFloor: lifecycle + 1),
      );
    }
    final tomb = SessionRecord(
      ns: ns,
      installId: _installId!,
      seq: seq + 1,
      lifecycle: lifecycle + 1,
      kind: RecordKind.tombstone,
    );
    final w = await keychain.write(itemKey, tomb.encode());
    var tombstoned = w.isOk;
    if (!tombstoned && w.status == KeychainStatus.unknown) {
      final back = await keychain.read(itemKey);
      tombstoned = back.isFound && back.value == tomb.encode();
    }
    if (tombstoned || fenced) {
      _committed = null;
      _indeterminate = false;
      _floorSeq = seq + 1;
      _floorLifecycle = lifecycle + 1;
    }
    if (tombstoned) return true;
    if (fenced) return true;
    // Step 5: delete; success = verified empty.
    final del = await keychain.delete(itemKey);
    if (del.isOk && (await keychain.read(itemKey)).isAbsent) {
      _committed = null;
      _indeterminate = false;
      _floorSeq = seq + 1;
      _floorLifecycle = lifecycle + 1;
      return true;
    }
    // Step 6: not durable. The caller keeps the process restricted.
    if (c != null) _committed = c;
    return false;
  }
}

enum _LegacyParse { corrupt, notImported }

class _Migration {
  _Migration({
    required this.record,
    required this.map,
    this.untrusted = false,
    this.unknownProvenance = false,
  }) : deferred = false;

  _Migration.deferred()
      : record = null,
        map = const {},
        untrusted = false,
        unknownProvenance = false,
        deferred = true;

  final SessionRecord? record;
  final Map<String, MigrationEntry> map;
  final bool untrusted;
  final bool unknownProvenance;
  final bool deferred;
}

/// The unverified claims of a JWT-shaped token (a namespace check on app-owned
/// local data, not signature verification). Null when not decodable.
Map<String, dynamic>? jwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
