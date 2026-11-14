import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AUDIT 1 — EVERY PATH THAT CAN DESTROY USER DATA, ENUMERATED.
///
/// The first pass at this used a scanner that looked for a dangerous statement
/// and a nearby transaction, which is not an audit: it cannot tell a scoped
/// single-row delete from a table wipe, and it says nothing about what REACHES
/// the statement. The P0 that prompted all of this (ac622970) was not a missing
/// transaction — the wipe was already atomic. It was a correct wipe called in
/// the wrong ORDER, which no proximity check can see.
///
/// So this is an inventory instead. Every destructive site in `lib/` is listed
/// below with the reason it is safe, and the test fails when a site appears that
/// is not on the list. That forces the classification to happen at review time,
/// when the author still knows why.
///
/// The full inventory, as audited:
///
///  1. data_wipe_service.dart — `DELETE FROM $table` over wipedTables.
///     Reached from sign-out, the ownership transition, Privacy "delete all my
///     data" and Settings. One transaction, so all-or-nothing; the table list is
///     proven exhaustive against the live schema by data_wipe_service_test, and
///     the ownership path is proven by cross_account_local_isolation_test and
///     ownership_transition_order_test (purge BEFORE wipe, fail closed).
///
///  2. restore_backup_usecase.dart — `DELETE FROM $table` before reinserting.
///     Inside _db.transaction() with fault hooks at every boundary that
///     restore_recovery_test drives, plus `PRAGMA foreign_key_check` INSIDE the
///     transaction so any residual violation rolls the whole restore back. FK
///     enforcement is restored in a `finally`. Only tables the backup actually
///     carries are emptied, so a v2 backup cannot wipe a v3 catalog.
///
///  3. local_notification_service.dart — deletes ONE transaction by id, and
///     only while status = 'pending'. A notification action rejecting a capture
///     that was never confirmed. Scoped by primary key; not a bulk path.
///
///  4. app_database.dart — `DROP TABLE cards` in the NOT NULL -> NULLable
///     rebuild. Pre-drops the temp, copies every column, renames, all inside a
///     transaction, so an interruption leaves the original table untouched.
///
///  5. capture_work_item_repository / capture_review_label_repository —
///     `deleteAll()` on capture-derived operational tables. Model output and
///     review labels, both regenerable; neither holds money.
///
///  6. database_lease.dart — `deleteSync()` on `.lease` and intent FILES only,
///     and only when the record belongs to an ENDED instance (a dead pid or
///     unparseable content). Never touches the database file. Failures are
///     swallowed because a stale lock file must not block startup.
///
/// Deliberately NOT here, and asserted absent below: secure-storage
/// `deleteAll()`, which would take the SQLCipher key with it and make the
/// database unopenable, and any delete/recreate of the database as recovery.
void main() {
  final root = Directory.current.path;

  /// Every permitted destructive site: path -> how many destructive statements
  /// it may contain. Exact counts, so a NEW statement inside an
  /// already-audited file fails too — that is where an unreviewed one hides.
  ///
  /// GROUP A — bulk wipes of user data. The only two, both audited above.
  ///   data_wipe_service (2)        the loop + the custom-categories delete
  ///   restore_backup_usecase (7)   the table loop + journal/staging cleanup
  ///
  /// GROUP B — schema rebuild, atomic and self-contained.
  ///   app_database (4)             cards_new pre-drop, DROP cards, + 2 repairs
  ///
  /// GROUP C — ONE row, by primary key. Cannot be a bulk loss.
  ///   local_notification_service   one pending transaction, rejected by action
  ///   drift_suspected_duplicate    one duplicate candidate, by id
  ///   drift_category_repository    merchant map rows for one deleted category
  ///
  /// GROUP D — server-replaceable CATALOG caches. Re-synced on next launch;
  /// hold no money and nothing the user authored.
  ///   catalog_daos (5)             flags, announcements, campaigns, coupons,
  ///                                pending merchant feedback
  ///
  /// GROUP E — queue / staging / journal bookkeeping. Operational state, scoped
  /// to a resolved or superseded item, never the financial row itself.
  ///   conflict_resolver (2)        outbox rows for a resolved conflict
  ///   keep_mine_as_new (2)         D1: the queued CREATE rows of ONE tombstoned
  ///                                goal's / plan's own UNSYNCED children, by
  ///                                exact entity id, inside the resolver's local
  ///                                transaction, right after those children were
  ///                                re-created under the new record. Their parent
  ///                                is tombstoned in the cloud, so they could only
  ///                                dead-letter; a crash halfway rolls back with
  ///                                the copy and the conflict stays open.
  ///   ledger_outbox_queue (2)      coalesced + acknowledged rows
  ///   outbox_receipt (1)           WP-5 lost-ACK receipt: deletes the ONE outbox
  ///                                row whose operation_id the cloud row carries
  ///                                as `last_op_id` (our own write landed), in one
  ///                                local transaction with the entity settle; a
  ///                                crash halfway rolls both back and the same
  ///                                receipt is recognised on the next pull
  ///   planning_outbox_queue (3)    same, planning side, plus (A-2) the parked
  ///                                dependency_wait row of a never-synced,
  ///                                accountless card that is then deleted
  ///                                (a parked row is never in flight)
  ///   planning_child_sync (1)      parked child rows for one table
  ///   ledger_sync_service (1)      B12: quarantined pull rows (parked_child_rows,
  ///                                table_name='transactions') cleared by server id
  ///                                once the row applies cleanly or is retried OK
  ///   planning_pull_service (1)    parked rows superseded by a fresh pull
  ///   planning_server_currency_repair (1)  parked rows after repair
  ///   restore_journal (1)          journal rows by operation_id
  ///   capture_work_item_repo (2)   regenerable model output
  ///   drift_smart_inbox_repo (1)   deletes only the exact, locally created
  ///                                manual analysis draft after durable ingest
  ///                                or intentional ignore in the same account.
  ///                                One atomic statement. If it fails or the
  ///                                process dies after ingest, the review copy
  ///                                remains and re-ingestion can deduplicate.
  ///   capture_review_label_repo (3) regenerable review labels
  ///   affiliate_click_gateway (1)  EXPIRED click receipts (TTL sweep)
  ///
  /// GROUP F — files, never the database.
  ///   database_lease (2)           .lease + intent files of ENDED instances
  ///
  /// GROUP G — WP-3a per-UID replica directories (whole replica, by design).
  ///   replica_store (3)            `remove(uid)`: the ONE user-initiated
  ///                                "Remove data from this device" for a single
  ///                                uid's replica dir, reached only from the
  ///                                explicit removal flow (WP-3b); sign-out
  ///                                never calls it (SYNC-Q2/Q4). It first
  ///                                renames the dir to `_removing.<hash>`
  ///                                (atomic), so a crash leaves either the
  ///                                intact replica or a tombstone that
  ///                                recoverPendingRemovals finishes; it never
  ///                                touches another uid's dir. The third is
  ///                                legacy adoption discarding its OWN
  ///                                half-built copy (state `migrating`,
  ///                                never opened, source legacy file untouched
  ///                                until the copy is verified).
  ///
  /// GROUP H — WP-7 rebootstrap (§4.10).
  ///   replica_recovery (1)         deletes exactly ONE row of the FRESH replica
  ///                                (the pulled copy of an entity the user's own
  ///                                unsynced version replaces, by id), inside the
  ///                                merge's local transaction on a database the
  ///                                old replica never shares; the old replica is
  ///                                only read, and is kept 14 days after the swap.
  ///   replica_store (+4, total 7)         discarding the half-built `.rb` replica of an
  ///                                abandoned rebootstrap, purging a `.old`
  ///                                replica after the 14-day retention, and the
  ///                                swap superseding an older `.old`; plus the
  ///                                `.rb`/`.old` tombstones of `remove(uid)`.
  ///
  /// GROUP I — per-account profile photo (adversarial 32b, 2026-11-14).
  ///   profile_image_store (1)      `deleteProfileImagesOf(uid)` deletes ONE
  ///                                directory `profile/<sha256 key of uid>/`
  ///                                holding only that account's avatar copy.
  ///                                Reached only from RemoveDataFlow AFTER the
  ///                                uid's replica removal succeeded; best
  ///                                effort (a failure leaves only a photo, no
  ///                                ledger data); never touches another uid.
  const inventory = <String, int>{
    // A
    'lib/core/privacy/data_wipe_service.dart': 2,
    'lib/core/backup/restore_backup_usecase.dart': 7,
    // B
    'lib/data/db/app_database.dart': 4,
    // C
    'lib/features/capture/services/local_notification_service.dart': 2,
    'lib/data/repositories/drift_suspected_duplicate_repository.dart': 1,
    'lib/data/repositories/drift_category_repository.dart': 1,
    // D
    'lib/data/catalog/catalog_daos.dart': 5,
    // E
    'lib/core/sync/conflict_resolver.dart': 2,
    'lib/core/sync/keep_mine_as_new.dart': 2,
    'lib/features/capture/services/ledger_outbox_queue.dart': 2,
    'lib/core/sync/outbox_receipt.dart': 1,
    'lib/features/planning_sync/services/planning_outbox_queue.dart': 3,
    'lib/features/planning_sync/services/planning_child_sync_service.dart': 1,
    'lib/features/capture/services/ledger_sync_service.dart': 1,
    'lib/features/planning_sync/services/planning_pull_service.dart': 1,
    'lib/features/planning_sync/services/planning_server_currency_repair.dart': 1,
    'lib/core/backup/restore_journal.dart': 1,
    'lib/data/repositories/capture_work_item_repository.dart': 2,
    'lib/data/repositories/drift_smart_inbox_repository.dart': 1,
    'lib/data/repositories/capture_review_label_repository.dart': 3,
    'lib/features/coupons/affiliate_click_gateway.dart': 1,
    // F
    'lib/data/db/database_lease.dart': 2,
    // G
    'lib/data/db/replica_store.dart': 7,
    // H
    'lib/core/session/replica_recovery.dart': 1,
    // I
    'lib/features/settings/profile_image_store.dart': 1,
  };

  /// Statements that can destroy more than one row, or a file.
  final destructive = RegExp(
    r'DROP TABLE|DELETE FROM|deleteAll\(\)|deleteSync\(|'
    r'\.delete\(recursive:\s*true\)',
  );

  List<File> dartSources() => Directory('$root/lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('no destructive site exists outside the audited inventory', () {
    final found = <String, int>{};
    for (final file in dartSources()) {
      final rel = file.path.substring(root.length + 1);
      final hits = destructive
          .allMatches(file.readAsStringSync())
          // A comment describing a REMOVED dangerous pattern is not a call site.
          .where((m) => !_isInComment(file.readAsStringSync(), m.start))
          .length;
      if (hits > 0) found[rel] = hits;
    }

    final unlisted = found.keys.where((f) => !inventory.containsKey(f)).toList()
      ..sort();
    expect(unlisted, isEmpty,
        reason: 'these files destroy data but are not in the audited '
            'inventory. Add each one WITH the reason it is safe — what reaches '
            'it, what transaction contains it, and what happens if it fails '
            'halfway. Do not just append the path.');

    // A count that GREW means a new statement inside an already-audited file,
    // which is exactly where an unreviewed one would hide.
    for (final entry in found.entries) {
      final expected = inventory[entry.key];
      if (expected == null) continue;
      expect(entry.value, lessThanOrEqualTo(expected),
          reason: '${entry.key} gained a destructive statement '
              '(${entry.value} > $expected) — audit and re-classify it');
    }
  });

  test('the two destructive bulk wipes are the only interpolated table deletes',
      () {
    // `DELETE FROM $table` is the shape that can empty ANY table, so it must
    // stay confined to the wipe and the restore, both of which are audited above.
    final sites = <String>[];
    for (final file in dartSources()) {
      if (file.readAsStringSync().contains(r'DELETE FROM $table')) {
        sites.add(file.path.substring(root.length + 1));
      }
    }
    expect(sites.toSet(), {
      'lib/core/privacy/data_wipe_service.dart',
      'lib/core/backup/restore_backup_usecase.dart',
      // WP-7: one pulled row by id (see GROUP H).
      'lib/core/session/replica_recovery.dart',
    });
  });

  test('both bulk wipes are wrapped in a transaction', () {
    for (final path in const [
      'lib/core/privacy/data_wipe_service.dart',
      'lib/core/backup/restore_backup_usecase.dart',
    ]) {
      final src = File('$root/$path').readAsStringSync();
      final deleteAt = src.indexOf(r'DELETE FROM $table');
      final txnAt = src.lastIndexOf('transaction(() async {', deleteAt);
      expect(txnAt, greaterThan(-1),
          reason: '$path empties tables outside a transaction — a crash '
              'halfway would leave a partially destroyed database');
    }
  });

  test('the database is never deleted or recreated as error recovery', () {
    // The invariant from the key-store audit, enforced across the whole tree:
    // "could not open" must never be answered by discarding the file. A new key
    // over an existing encrypted database is unrecoverable, and so is this.
    for (final file in dartSources()) {
      final src = file.readAsStringSync();
      for (final pattern in const [
        'databaseFile.deleteSync',
        'databaseFile.delete(',
        'dbFile.deleteSync',
        'dbFile.delete(',
      ]) {
        expect(src.contains(pattern), isFalse,
            reason: '${file.path} deletes the database file — recovery must '
                'never discard data it cannot prove is worthless');
      }
    }
  });

  test('secure storage deleteAll() never appears in production code', () {
    // It would take the SQLCipher key with it and leave the database
    // permanently unopenable. The key-preserving sweep is what wipeAndReset
    // uses; secure_storage_wipe_atomicity_test covers its behaviour.
    for (final file in dartSources()) {
      final src = file.readAsStringSync();
      final at = src.indexOf('_storage.deleteAll(');
      expect(at, -1, reason: '${file.path} calls secure-storage deleteAll()');
      expect(src.contains('storage.deleteAll('), isFalse,
          reason: '${file.path} calls secure-storage deleteAll()');
    }
  });
}

/// Whether [offset] sits on a `//` comment line — a comment documenting a
/// pattern that was REMOVED is not a live call site.
bool _isInComment(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset) + 1;
  final line = source.substring(lineStart, offset);
  return line.trimLeft().startsWith('//') || line.contains('/// ');
}
