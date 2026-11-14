// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';

import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';

// O-H2 — the host half of the offline local-read unit: grant issuance, auth-origin
// classification, the local-read scope and its two-phase restoration, writer
// denial and reconnect, over the REAL session singleton, a real encrypted replica
// store/scope host and a recording secure storage. Every side effect is observed
// as an ATTEMPT (storage attempts, opener calls, file tree), not as final state.

const _uid = 'uid-read-a';
const _grantKey = SecureLocalReadStore.storageKey;

String _jwt(String uid, int exp) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': exp})}.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;
  late int writableOpens;

  Future<SupabaseClient> liveSdk([String uid = _uid]) async {
    final c = await f.clientFor(uid);
    clients.add(c);
    return c;
  }

  /// A client whose stored session is EXPIRED (same uid), which cannot refresh.
  Future<SupabaseClient> expiredSdk([String uid = _uid]) async {
    var calls = 0;
    final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              // The first answer is already expired; a later refresh is live.
              'access_token': _jwt(
                  uid,
                  ++calls == 1
                      ? 1
                      : DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600),
              'token_type': 'bearer',
              'refresh_token': 'synthetic-refresh',
              'user': {'id': uid, 'email': '$uid@example.com'},
            }),
            200)));
    await c.auth
        .signInWithPassword(email: '$uid@example.com', password: 'synthetic');
    expect(c.auth.currentSession!.isExpired, isTrue);
    clients.add(c);
    return c;
  }

  /// A client with NO session at all (cold start, nothing recovered).
  SupabaseClient absentSdk() {
    final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async => http.Response('{}', 200)));
    clients.add(c);
    return c;
  }

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    writableOpens = 0;
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: ({location, runMigrations = true, creation = const CreationPolicy.unrestricted()}) {
        writableOpens++;
        return AppDatabase.open(
            location: location, runMigrations: runMigrations, creation: creation);
      },
    );
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
  });

  tearDown(() async {
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
  });

  // ------------------------------------------------------------------ helpers

  Future<void> signInFirstAccount(SupabaseClient sdk, [String uid = _uid]) async {
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$uid@example.com', userId: uid);
    await f.session.finishOnboarding(client: sdk);
  }

  Future<LocalReadGrantRecord?> record() => authority.peekRecord();

  Future<void> seedRows(AppDatabase db) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, raw_merchant, direction) VALUES "
        "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
        "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
  }

  Future<String> replicaIdOf(AppDatabase db) async => (await db
          .customSelect('SELECT replica_id FROM replica_meta;')
          .getSingle())
      .read<String>('replica_id');

  Future<int> txCount(AppDatabase db) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM transactions;')
          .getSingle())
      .read<int>('c');

  List<String> tree() => [
        for (final e in Directory(f.support.path).listSync(recursive: true))
          p.relative(e.path, from: f.support.path),
      ]..sort();

  List<String> grantAttempts(int from) => [
        for (final a in f.storage.attempts.skip(from))
          if (a.contains(_grantKey)) a,
      ];

  /// Signed in as [_uid] (first account, grant issued), one known row, the
  /// replica id; then the process "dies" and a new one starts, replica `active`.
  Future<String> seededAndRestarted() async {
    final sdk = await liveSdk();
    await signInFirstAccount(sdk);
    await seedRows(f.host.current!.database);
    final id = await replicaIdOf(f.host.current!.database);
    await f.restartWithoutLock();
    f.session.configureAccountScope(f.host);
    f.session.configureLocalRead(authority);
    return id;
  }

  Future<SupabaseClient> returningLoginSdk({
    Future<void> Function()? beforeProfile,
  }) async {
      SharedPreferences.setMockInitialValues({});
      final initialized = await Supabase.initialize(
          url: 'https://example.supabase.co', anonKey: 'synthetic-anon',
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false, localStorage: EmptyLocalStorage(),
              detectSessionInUri: false),
          httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/profiles')) {
          await beforeProfile?.call();
          return http.Response(
              jsonEncode([{'onboarding_completed_at': '2026-10-01T00:00:00Z'}]),
              200, headers: {'content-type': 'application/json'}, request: request);
        }
        return http.Response('{}', 200, request: request);
      }));
      addTearDown(() => Supabase.instance.dispose());
      final sdk = initialized.client;
      await F2Fixture.recoverSession_(sdk, _uid);
      return sdk;
  }

  // ------------------------------------------------------------ 1. issuance

  test('startup denial diagnostic contains only a constant reason', () async {
    AuthDiagnostics.debugReset();
    expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    expect(AuthDiagnostics.entries.value.last,
        contains('local_read_restore grant_absent_or_uncommitted'));
    for (final line in AuthDiagnostics.entries.value) {
      expect(line, isNot(contains(_uid)));
      expect(line, isNot(contains('@')));
    }
  });

  group('grant issuance', () {
    test(
        'a first account gets its receipt only after finishOnboarding, with '
        'the real replica id', () async {
      final sdk = await liveSdk();
      await f.session.bindSupabaseAuth(sdk);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      expect(f.session.hasCompletedOnboarding, isFalse);
      expect(await record(), isNull,
          reason: 'unfinished onboarding is not an offline route');
      await f.session.finishOnboarding(client: sdk);
      final r = await record();
      expect(r, isNotNull);
      expect(r!.state, LocalReadGrantState.committed);
      expect(r.uid, _uid);
      expect(r.replicaId, await replicaIdOf(f.host.current!.database));
    });

    test('a returning completed account is receipted at the identity commit',
        () async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      final first = (await record())!.operationId;
      await f.session.signOut();
      expect((await record())!.state, LocalReadGrantState.blocked);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      final again = (await record())!;
      expect(again.state, LocalReadGrantState.committed);
      expect(again.operationId, isNot(first),
          reason: 'a fresh admission is a fresh grant transaction');
    });

    test('explicit returning login gets its grant when remote onboarding completes',
        () async {
      final sdk = await returningLoginSdk();
      await f.session.bindSupabaseAuth(sdk);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      expect(f.session.hasCompletedOnboarding, isFalse);
      expect(await record(), isNull);

      expect(await f.session.reconcileAccountOnboarding(sdk), isTrue);

      final grant = await record();
      expect(grant, isNotNull,
          reason: 'the actual auth screen skips finishOnboarding for returning users');
      expect(grant!.state, LocalReadGrantState.committed);
      expect(grant.uid, _uid);
      expect(grant.replicaId, await replicaIdOf(f.host.current!.database));
      final originalOp = grant.operationId;
      await f.session.reconcileAccountOnboarding(sdk);
      expect((await record())!.operationId, originalOp,
          reason: 'ordinary automatic reconciliation never renews the grant');

      await seedRows(f.host.current!.database);
      final originalReplica = grant.replicaId;
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      final afterRestart = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(afterRestart);
      await f.session.debugResetAuthBinding();
      await f.session.bindSupabaseAuth(await expiredSdk());
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(f.session.asrLocalReadOwner, _uid);
      expect(f.host.current!.isLocalRead, isTrue);
      expect(await replicaIdOf(f.host.current!.database), originalReplica);
      expect(await txCount(f.host.current!.database), 1);
    }, skip: !SupabaseConfig.isConfigured
        ? 'Run with synthetic SUPABASE_URL and SUPABASE_ANON_KEY to exercise remote completion.'
        : false);

    for (final loss in ['expiry', 'signout']) {
      test('returning reconciliation issues no grant after $loss', () async {
        final arrived = Completer<void>();
        final release = Completer<void>();
        final sdk = await returningLoginSdk(beforeProfile: () async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
        });
        await f.session.bindSupabaseAuth(sdk);
        await f.session.setIdentity(
            method: 'google', email: '$_uid@example.com', userId: _uid);
        final reconciliation = f.session.reconcileAccountOnboarding(sdk)
            .then<void>((_) {}, onError: (Object error) {
          expect(error, isA<StaleAdmissionException>());
        });
        await arrived.future;
        if (loss == 'expiry') {
          sdk.auth.currentSession!.expiresAt = 1;
        } else {
          await f.session.signOut();
        }
        release.complete();
        await reconciliation;
        expect((await record())?.state,
            isNot(LocalReadGrantState.committed));
      }, skip: !SupabaseConfig.isConfigured ? 'Requires synthetic config.' : false);
    }

    test('stale reconciliation leaves its successor explicit proof untouched',
        () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      var profiles = 0;
      final sdk = await returningLoginSdk(beforeProfile: () async {
        if (++profiles == 1) {
          arrived.complete();
          await release.future;
        }
      });
      await f.session.bindSupabaseAuth(sdk);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      final old = f.session.reconcileAccountOnboarding(sdk)
          .then<void>((_) {}, onError: (Object error) {
        expect(error, isA<StaleAdmissionException>());
      });
      await arrived.future;
      // A new explicit admission of the same user supersedes the old proof.
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      // An ordinary event learns completion while the old lookup is pending.
      // It must not itself issue an offline grant.
      await f.session.revalidateSupabaseSessionOnResume(sdk);
      expect(f.session.hasCompletedOnboarding, isTrue);
      expect(await record(), isNull);
      release.complete();
      await old;
      expect(await record(), isNull,
          reason: 'the old callback cannot consume the successor proof');
      await f.session.reconcileAccountOnboarding(sdk);
      expect((await record())!.state, LocalReadGrantState.committed,
          reason: 'the successor still owns its own explicit proof');
    }, skip: !SupabaseConfig.isConfigured ? 'Requires synthetic config.' : false);

    test('automatic reconcile of a saved identity never mints a receipt',
        () async {
      // A legacy install: completed account, marker and replica, no receipt.
      f.session.configureLocalRead(null);
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      expect(await record(), isNull);
      f.session.configureLocalRead(authority);
      final from = f.storage.attempts.length;
      await f.session.reconcileAccountOnboarding(sdk);
      await f.session.bindSupabaseAuth(await liveSdk());
      expect(await record(), isNull);
      expect(grantAttempts(from), isEmpty);
    });

    test('guest, expired SDK, mismatched SDK and failed publication issue none',
        () async {
      await f.session.setIdentity(method: 'guest');
      expect(await record(), isNull, reason: 'guest');

      final expired = await expiredSdk();
      await f.session.bindSupabaseAuth(expired);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      await f.session.finishOnboarding(client: expired);
      expect(await record(), isNull, reason: 'expired SDK');
    });

    test('an SDK of another uid and a failed identity commit issue none',
        () async {
      final other = await liveSdk('someone-else');
      await f.session.bindSupabaseAuth(other);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      await f.session.finishOnboarding(client: other);
      expect(await record(), isNull, reason: 'SDK uid mismatch');

      f.storage.gate = (op, key) async {
        if (op == 'write' && key == 'auth_method') {
          throw StateError('commit refused');
        }
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      f.storage.gate = null;
      expect(await record(), isNull, reason: 'failed publication');
    });

    test('freshness lost before the first account finishes onboarding: none',
        () async {
      final sdk = await liveSdk();
      await f.session.bindSupabaseAuth(sdk);
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      f.session.markSessionInvalid();
      await f.session.finishOnboarding(client: sdk);
      expect(await record(), isNull);
    });
  });

  // ------------------------------------------------- 2. restore, in process

  group('expired or absent SDK with a valid grant', () {
    Future<void> signedInWithRow() async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      await seedRows(f.host.current!.database);
    }

    test('expired same-uid SDK swaps to the read-only scope of the same replica',
        () async {
      await signedInWithRow();
      final writable = f.host.current!;
      final id = await replicaIdOf(writable.database);
      await f.session.bindSupabaseAuth(await expiredSdk());
      await f.session.debugLocalReadIdle;
      final scope = f.host.current!;
      expect(f.session.localReadActive, isTrue);
      expect(scope.isLocalRead, isTrue);
      expect(scope.accessMode, AccountAccessMode.localRead);
      expect(scope.database.isReadOnly, isTrue);
      expect(scope.generation, greaterThan(writable.generation));
      expect(identical(scope.database, writable.database), isFalse);
      expect(writable.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(await replicaIdOf(scope.database), id);
      expect(await txCount(scope.database), 1);
      expect(f.session.status, isNot(SessionStatus.authenticated),
          reason: 'an expired token is never promoted to authenticated');
    });

    test('warm expiry never exposes sign-in while local read is restoring',
        () async {
      await signedInWithRow();
      final signInPresentations = <SessionStatus>[];
      void observePresentation() {
        if (f.session.status == SessionStatus.sessionExpired &&
            !f.session.localReadPresentationRestricted) {
          signInPresentations.add(f.session.status);
        }
      }
      f.session.addListener(observePresentation);
      try {
        await f.session.bindSupabaseAuth(await expiredSdk());
        await f.session.debugLocalReadIdle;
        expect(f.session.localReadActive, isTrue);
        expect(signInPresentations, isEmpty,
            reason: 'the router must stay on the recovery shell throughout '
                'the writable-to-read-only handoff');
      } finally {
        f.session.removeListener(observePresentation);
      }
    });

    test('absent SDK session swaps to the read-only scope too', () async {
      await signedInWithRow();
      await f.session.bindSupabaseAuth(absentSdk());
      await f.session.debugLocalReadIdle;
      expect(f.session.localReadActive, isTrue);
      expect(f.host.current!.database.isReadOnly, isTrue);
      expect(await txCount(f.host.current!.database), 1);
    });

    test('without a receipt nothing changes: the writable scope stays',
        () async {
      f.session.configureLocalRead(null);
      await signedInWithRow();
      f.session.configureLocalRead(authority);
      final writable = f.host.current!;
      await f.session.bindSupabaseAuth(await expiredSdk());
      await f.session.debugLocalReadIdle;
      expect(f.session.localReadActive, isFalse);
      expect(identical(f.host.current, writable), isTrue);
    });
  });

  // ------------------------------------------------------- 3. cold start

  group('cold start restoration', () {
    test('restores the exact same replica read-only with no side effects',
        () async {
      final id = await seededAndRestarted();
      final opensBefore = writableOpens;
      final from = f.storage.attempts.length;
      final before = tree();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(f.session.localReadActive, isTrue);
      final scope = f.host.current!;
      expect(scope.isLocalRead, isTrue);
      expect(scope.uid, _uid);
      expect(await replicaIdOf(scope.database), id);
      expect(await txCount(scope.database), 1);
      expect(f.storage.attempts.skip(from), isEmpty,
          reason: 'no write or delete of any kind on the read path');
      expect(writableOpens, opensBefore, reason: 'no writable open');
      expect(tree(), before,
          reason: 'no lease, .instance, key, salt or directory was created');
    });

    group('denial with zero attempted side effects', () {
      Future<void> expectDenied(Future<void> Function() corrupt) async {
        await seededAndRestarted();
        await corrupt();
        final opensBefore = writableOpens;
        final from = f.storage.attempts.length;
        final before = tree();
        expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
        expect(f.session.localReadActive, isFalse);
        expect(f.host.current, isNull, reason: 'nothing was published');
        expect(f.storage.attempts.skip(from), isEmpty);
        expect(writableOpens, opensBefore);
        expect(tree(), before);
        expect(coordinator.pendingOpens, 0,
            reason: 'a refusal before any connection releases its reservation');
      }

      test('no grant record', () async {
        await expectDenied(() async => f.storage.data.remove(_grantKey));
      });
      test('malformed grant record', () async {
        await expectDenied(() async => f.storage.data[_grantKey] = '{nope');
      });
      test('a preparing record denies', () async {
        await expectDenied(() async {
          final r = jsonDecode(f.storage.data[_grantKey]!) as Map;
          f.storage.data[_grantKey] = jsonEncode({...r, 'state': 'preparing'});
        });
      });
      test('a locked registry entry denies', () async {
        await expectDenied(() async {
          // Written straight into the registry JSON: the lock call itself
          // would be an attempted write the assertion must not see.
          final reg = jsonDecode(f.storage.data[ReplicaStore.registryKey]!)
              as Map<String, dynamic>;
          for (final e in reg.values) {
            (e as Map<String, dynamic>)['state'] = 'locked';
          }
          f.storage.data[ReplicaStore.registryKey] = jsonEncode(reg);
        });
      });
      test('a removal in progress denies', () async {
        await expectDenied(() async =>
            f.storage.data[ReplicaStore.removalBarrierKey] = '{"uid":"x"}');
      });
      test('a revoked uid denies', () async {
        await expectDenied(() async =>
            f.storage.data[ReplicaStore.removalRevokedKey] =
                jsonEncode([_uid]));
      });
      test('a legacy-only install (no registry) denies', () async {
        await expectDenied(
            () async => f.storage.data.remove(ReplicaStore.registryKey));
      });
      test('an owner marker of another uid denies', () async {
        await expectDenied(() async =>
            f.storage.data[ReplicaStore.ownerMarkerKey] = 'someone-else');
      });
    });
  });

  // ------------------------------- O-H3 item 2: honest incomplete logout

  group('incomplete durable deny on logout', () {
    /// Fails every grant-record write, and the FIRST registry read after that
    /// (the verified registry lock the deny falls back to), so no durable denial
    /// can be established while the scope lock itself still works.
    var failingDeny = false;
    var registryReadsToFail = 0;
    void breakDurableDeny() {
      failingDeny = true;
      f.storage.gate = (op, key) async {
        if (!failingDeny) return;
        if (op == 'write' && key == _grantKey) {
          registryReadsToFail = 1;
          throw StateError('secure storage unavailable');
        }
        if (op == 'read' &&
            key == ReplicaStore.registryKey &&
            registryReadsToFail > 0) {
          registryReadsToFail--;
          throw StateError('registry unreadable');
        }
      };
    }

    Future<void> inLocalRead() async {
      await seededAndRestarted();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
    }

    test('signOut reports incomplete, stays locked, deletes nothing', () async {
      await inLocalRead();
      final deletesBefore = f.storage.deletes.length;
      breakDurableDeny();
      final outcome = await f.session.signOut();
      expect(outcome, SignOutOutcome.durableDenyIncomplete);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect(f.session.localReadActive, isFalse);
      expect(f.host.current!.uid, isNull, reason: 'signed-out scope');
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse,
          reason: 'the process stays locked');
      expect((await record())!.state, LocalReadGrantState.committed,
          reason: 'nothing durable landed: said honestly, not invented');
      // No key deletion or data wipe "repairs" it.
      expect(
          f.storage.deletes.skip(deletesBefore).where(
              (k) => k.startsWith('qirsh.') || k == _grantKey),
          isEmpty);
      expect(
          Directory(f.support.path)
              .listSync(recursive: true)
              .whereType<File>()
              .isNotEmpty,
          isTrue);
    });

    test('a complete logout still reports complete', () async {
      await inLocalRead();
      expect(await f.session.signOut(), SignOutOutcome.complete);
      expect(f.session.localReadCleanupIncomplete, isFalse);
    });

    test('retry re-runs only the durable deny: failure, then success', () async {
      await inLocalRead();
      breakDurableDeny();
      expect(await f.session.signOut(), SignOutOutcome.durableDenyIncomplete);
      final keyDeletes = f.storage.deletes.length;
      final identityWrites = f.storage.attempts.length;

      // Still failing: stays incomplete and honest.
      expect(await f.session.retryLocalReadDeny(), isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect((await record())!.state, LocalReadGrantState.committed);

      // Storage recovers: the deny lands; nothing else is touched.
      failingDeny = false;
      f.storage.gate = null;
      final from = f.storage.attempts.length;
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      expect((await record())!.state, LocalReadGrantState.blocked);
      expect(f.storage.deletes.length, keyDeletes);
      expect(identityWrites, lessThanOrEqualTo(from));
      expect(
          f.storage.attempts
              .skip(from)
              .where((a) => a.startsWith('write:') && !a.contains(_grantKey)),
          isEmpty,
          reason: 'only the grant record is written');
      // A restart cannot bring it back.
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    });
  });

  // ------------------------------- Astra D4: incomplete deny on remove-data

  group('D4: remove data with an incomplete durable deny', () {
    var secureDenyFails = false;
    var registryFallbackFails = false;
    void breakDeny({required bool registryToo}) {
      secureDenyFails = true;
      registryFallbackFails = registryToo;
      f.storage.gate = (op, key) async {
        if (secureDenyFails && op == 'write' && key == _grantKey) {
          throw StateError('secure storage unavailable');
        }
        if (registryFallbackFails &&
            op == 'read' &&
            key == ReplicaStore.registryKey &&
            StackTrace.current.toString().contains('lockVerified')) {
          throw StateError('registry unreadable');
        }
      };
    }

    void repairDeny() {
      secureDenyFails = false;
      registryFallbackFails = false;
      f.storage.gate = null;
    }

    Future<String> admitted() async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      await seedRows(f.host.current!.database);
      expect((await record())!.state, LocalReadGrantState.committed);
      f.session.removalNoticePending.value = false;
      f.session.denyIncompleteNoticePending.value = false;
      return f.host.current!.location!.directory;
    }

    tearDown(() {
      repairDeny();
      f.session.removalNoticePending.value = false;
      f.session.denyIncompleteNoticePending.value = false;
    });

    test('secure deny failure + registry fallback failure: returns incomplete, '
        'data IS removed, process locked, root notice pending', () async {
      final dir = await admitted();
      breakDeny(registryToo: true);
      var remoteCalls = 0;
      final outcome =
          await f.session.removeDataFromDeviceWithOutcome(signOutRemote: () async {
        remoteCalls++;
      });
      expect(outcome, RemoveDataOutcome.durableDenyIncomplete);
      expect(Directory(dir).existsSync(), isFalse, reason: 'data removed');
      expect(remoteCalls, 1);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect(f.session.denyIncompleteNoticePending.value, isTrue,
          reason: 'the root shows it; no initiating widget is involved');
      expect(f.session.localReadActive, isFalse);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse,
          reason: 'the process stays locked');
      expect(f.session.status, isNot(SessionStatus.authenticated));
    });

    test('secure deny failure but registry fallback SUCCEEDS: complete, '
        'no incomplete notice', () async {
      await admitted();
      breakDeny(registryToo: false);
      final outcome = await f.session.removeDataFromDeviceWithOutcome();
      expect(outcome, RemoveDataOutcome.complete);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      expect(f.session.denyIncompleteNoticePending.value, isFalse);
    });

    test('a clean removal returns complete and raises no incomplete notice',
        () async {
      await admitted();
      expect(await f.session.removeDataFromDeviceWithOutcome(), RemoveDataOutcome.complete);
      expect(f.session.denyIncompleteNoticePending.value, isFalse);
      expect(f.session.removalNoticePending.value, isTrue);
    });

    test('the incomplete notice is raised even when the removal itself throws',
        () async {
      await admitted();
      breakDeny(registryToo: true);
      // A removal that cannot be confirmed (flow unavailable) still reports the
      // unfinished denial through the root, not only the thrown exception.
      f.session.configureRemoveData(null);
      await expectLater(f.session.removeDataFromDevice(),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(f.session.denyIncompleteNoticePending.value, isTrue);
      expect(f.session.removalNoticePending.value, isFalse,
          reason: 'no false completion notice');
    });

    // Astra R10.3 — the outcome speaks only to the durable denial. A request
    // with NO target removes nothing, so it raises no data-removed notice.
    test('no target: nothing is removed and no data-removed notice is raised',
        () async {
      expect(f.host.current?.uid, isNull);
      f.session.removalNoticePending.value = false;
      final deletes = f.storage.deletes.length;
      var remoteCalls = 0;
      final outcome =
          await f.session.removeDataFromDeviceWithOutcome(signOutRemote: () async {
        remoteCalls++;
      });
      expect(outcome, RemoveDataOutcome.complete,
          reason: 'only the denial step is described; it needed nothing');
      expect(f.storage.deletes.skip(deletes).where((k) => k.contains('db_key')),
          isEmpty,
          reason: 'no replica key was deleted: nothing was removed');
      expect(f.session.removalNoticePending.value, isFalse,
          reason: 'nothing was removed, so no "data removed" claim');
      expect(remoteCalls, 1, reason: 'the provider sign-out still runs');
    });

    test('a throwing removal plus a failed denial raises only the denial '
        'notice, which claims no removal', () async {
      await admitted();
      breakDeny(registryToo: true);
      f.session.configureRemoveData(null);
      await expectLater(f.session.removeDataFromDevice(),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(f.session.denyIncompleteNoticePending.value, isTrue);
      expect(f.session.removalNoticePending.value, isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
    });

    test('retry re-runs ONLY the durable deny: no removal, no remote effect',
        () async {
      final dir = await admitted();
      breakDeny(registryToo: true);
      var remoteCalls = 0;
      expect(
          await f.session.removeDataFromDeviceWithOutcome(signOutRemote: () async {
            remoteCalls++;
          }),
          RemoveDataOutcome.durableDenyIncomplete);
      final deletes = f.storage.deletes.length;
      final attempts = f.storage.attempts.length;

      // Still failing: stays incomplete, honestly.
      expect(await f.session.retryLocalReadDeny(), isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);

      repairDeny();
      final from = f.storage.attempts.length;
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      expect((await record())!.state, LocalReadGrantState.blocked);
      expect(remoteCalls, 1, reason: 'no remote effect repeated');
      expect(f.storage.deletes.length, deletes,
          reason: 'no key deletion or second removal');
      expect(Directory(dir).existsSync(), isFalse);
      expect(
          f.storage.attempts
              .skip(from)
              .where((a) => a.startsWith('write:') && !a.contains(_grantKey)),
          isEmpty,
          reason: 'only the grant record is written');
      expect(attempts, lessThanOrEqualTo(from));
    });

    test('restart: with the registry fallback working nothing returns; the '
        'replica is gone either way', () async {
      await admitted();
      breakDeny(registryToo: false);
      expect(await f.session.removeDataFromDeviceWithOutcome(), RemoveDataOutcome.complete);
      repairDeny();
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      f.session.configureLocalRead(authority);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    });

    test('restart after an UNFINISHED denial still cannot restore: the removed '
        'replica no longer exists', () async {
      await admitted();
      breakDeny(registryToo: true);
      expect(await f.session.removeDataFromDeviceWithOutcome(),
          RemoveDataOutcome.durableDenyIncomplete);
      repairDeny();
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      f.session.configureLocalRead(authority);
      expect((await record())!.state, LocalReadGrantState.committed,
          reason: 'the denial truly did not land (said honestly)');
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    });
  });

  // ------------------------------------------------ Astra D6: egress guard

  group('D6: the egress gate follows the local-read scope', () {
    test('Cloud ON saved, restored read-only: the gate admits nothing '
        'automatic; leaving local read gives it back', () async {
      final egress = TestEgress(seedOn: true)
        ..owner = _uid
        ..install();
      addTearDown(() => CloudEgressGate.instance = CloudEgressGate());
      // ON record is for 'uid-a' in the harness: re-seed it for this uid.
      final body = jsonEncode({
        'v': 1,
        'records': {
          _uid: const CloudEgressRecord(
                  state: EgressState.on,
                  ownerUid: _uid,
                  transitionGeneration: 1,
                  reservedVersion: 1)
              .toJson()
        }
      });
      egress.secure.value = body;
      egress.file.value = body;
      egress.gate.localReadActive = () => f.session.localReadEgressDenied;
      expect(await egress.gate.permits(), isTrue, reason: 'control');

      await seededAndRestarted();
      final epochBefore = egress.gate.epoch;
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(f.session.localReadEgressDenied, isTrue);
      expect(await egress.gate.permits(), isFalse);
      await expectLater(
          egress.gate.admit(
              request: AdmissionRequest(
                  'POST', Uri.parse('https://example.supabase.co/auth/v1/token'))),
          throwsA(isA<EgressDeniedException>()));
      expect(egress.gate.epoch, greaterThan(epochBefore),
          reason: 'responses of anything admitted before are discarded');

      await f.session.signOut();
      expect(f.session.localReadEgressDenied, isFalse);
    });

    test('a failed restore does not leave the egress gate closed', () async {
      await seededAndRestarted();
      f.storage.data.remove(_grantKey);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.session.localReadEgressDenied, isFalse);
    });
  });

  // -------------------- Astra D6: logout from local read has no remote effect

  group('D6: logging out of local read performs no remote effect', () {
    Future<(int Function(), int Function())> spies() async {
      var flushes = 0;
      var unlinks = 0;
      f.session.configureSignOutFlush(() async => flushes++);
      // P3: sign-out sends the pre-taken unlink ticket, never the gated hook.
      f.session.configureCaptureDeviceUnlink(() async => unlinks += 100);
      f.session.configureCaptureUnlinkTicket(() => () async => unlinks++);
      return (() => flushes, () => unlinks);
    }

    tearDown(() {
      f.session.configureSignOutFlush(null);
      f.session.configureCaptureDeviceUnlink(null);
      f.session.configureCaptureUnlinkTicket(null);
    });

    test('control: an ordinary (writable) sign-out still unlinks',
        () async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      final (flushes, unlinks) = await spies();
      await f.session.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // W4: signOut no longer flushes (the UI flushes before it, while
      // admission is still open).
      expect(flushes(), 0);
      expect(unlinks(), 1);
    });

    test('from local read: no outbox flush, no device unlink', () async {
      await seededAndRestarted();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      final (flushes, unlinks) = await spies();
      await f.session.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(flushes(), 0, reason: 'the flush is a network push');
      expect(unlinks(), 0, reason: 'the unlink is a backend call');
      expect(f.session.localReadActive, isFalse);
    });
  });

  // ------------------------------------------------ 4. locking and revocation

  group('lock and durable denial', () {
    Future<void> inLocalRead() async {
      await seededAndRestarted();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
    }

    test('explicit logout locks the scope and denies durably', () async {
      await inLocalRead();
      await f.session.signOut();
      expect(f.session.localReadActive, isFalse);
      expect(f.host.current!.uid, isNull, reason: 'signed-out scope');
      expect((await record())!.state, LocalReadGrantState.blocked);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      // A restart cannot bring it back.
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    });

    test('runtime signedOut with an unknown cause denies a writable grant',
        () async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      final done = Completer<void>();
      f.session.debugAuthEventCompleted = (e) {
        if (e == AuthChangeEvent.signedOut && !done.isCompleted) done.complete();
      };
      await sdk.auth.signOut(scope: SignOutScope.local);
      await done.future.timeout(const Duration(seconds: 5));
      f.session.debugAuthEventCompleted = null;
      expect((await record())!.state, LocalReadGrantState.blocked);
      await f.restartWithoutLock();
      f.session.configureAccountScope(f.host);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
    });

    test('userDeleted and auth_required lock as well', () async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      final done = Completer<void>();
      f.session.debugAuthEventCompleted = (e) {
        if (e == AuthChangeEvent.userDeleted && !done.isCompleted) {
          done.complete();
        }
      };
      sdk.auth.notifyAllSubscribers(AuthChangeEvent.userDeleted);
      // userDeleted carries no live-session guard bypass: the SDK session is
      // still live here, so the event is stale and changes nothing.
      await done.future.timeout(const Duration(seconds: 5));
      f.session.debugAuthEventCompleted = null;
      expect((await record())!.state, LocalReadGrantState.committed,
          reason: 'a loss event while a LIVE sdk session exists is stale');

      await f.session.handleAuthRequiredFailure();
      expect((await record())!.state, LocalReadGrantState.blocked,
          reason: 'auth_required with an unknown cause locks');
    });

    test('an unattributed stream error neither locks nor unlocks', () async {
      await inLocalRead();
      final from = f.storage.attempts.length;
      final sdk = absentSdk();
      await f.session.bindSupabaseAuth(sdk);
      sdk.auth.notifyException(const AuthException('synthetic transport'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(f.session.localReadActive, isTrue);
      expect((await record())!.state, LocalReadGrantState.committed);
      expect(grantAttempts(from), isEmpty);
    });

    test('a stale loss event for a previous owner does not lock a newer one',
        () async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      final done = Completer<void>();
      f.session.debugAuthEventCompleted = (e) {
        if (e == AuthChangeEvent.signedOut && !done.isCompleted) done.complete();
      };
      sdk.auth.notifyAllSubscribers(AuthChangeEvent.signedOut);
      await done.future.timeout(const Duration(seconds: 5));
      f.session.debugAuthEventCompleted = null;
      expect((await record())!.state, LocalReadGrantState.committed);
    });
  });

  // ----------------------------------------- 5. writer denial in local read

  group('writers are denied while local-read', () {
    test('no writable secondary, no admitted local work, no broker client',
        () async {
      await seededAndRestarted();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      final db = f.host.current!.database;
      expect(db.admitsSecondary, isFalse);
      await expectLater(
          AppDatabase.openSecondary(owner: db),
          throwsA(isA<DatabaseLifecycleException>().having((e) => e.reason,
              'reason', DatabaseLifecycleFailure.readOnlyOwner)));
      expect(f.session.captureLocalWorkAuthority(), isNull,
          reason: 'AdmittedLocalWork never accepts a local-read proof');
      expect(coordinator.client.isHostIssued, isFalse);
      await expectLater(
          coordinator.client.open<int>(open: () async => 1, close: (_) async {}),
          throwsA(isA<DatabaseAccessUnavailable>()));
      await expectLater(db.customStatement('CREATE TABLE x(a);'), throwsA(anything));
    });

    test('the candidate open was reserved, tracked and is released on close',
        () async {
      await seededAndRestarted();
      final holdersBefore = coordinator.openHolders;
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      final readOnly = f.host.current!.database;
      expect(coordinator.pendingOpens, 0);
      expect(coordinator.openHolders, holdersBefore + 1);
      await f.session.signOut();
      expect(readOnly.lifecycleState, DatabaseLifecycleState.closed);
      expect(coordinator.pendingOpens, 0);
    });
  });

  // ------------------------------------------------------------ 6. reconnect

  group('reconnect', () {
    test('an explicit fresh admission replaces the database and generation',
        () async {
      final sdk = await expiredSdk();
      await signInFirstAccount(await liveSdk());
      await seedRows(f.host.current!.database);
      final firstOp = (await record())!.operationId;
      await f.session.bindSupabaseAuth(sdk);
      await f.session.debugLocalReadIdle;
      final readOnly = f.host.current!;
      expect(readOnly.isLocalRead, isTrue);
      final capability = readOnly.localReadCapability!;

      // The sign-in made the bound SDK live again; the user reconnects.
      await sdk.auth.refreshSession();
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      final scope = f.host.current!;
      expect(scope.isLocalRead, isFalse);
      expect(scope.generation, greaterThan(readOnly.generation));
      expect(identical(scope.database, readOnly.database), isFalse);
      expect(readOnly.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(scope.database.isReadOnly, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(capability.isCurrent, isFalse,
          reason: 'the old grant was superseded by the fresh one');
      final r = (await record())!;
      expect(r.state, LocalReadGrantState.committed);
      expect(r.operationId, isNot(firstOp));
      expect(await txCount(scope.database), 1);
    });

    // O-H3 item 1 — strict reconnect: the outgoing proof is never reinstated.
    // The only way back into local read is a fresh two-phase restore.
    Future<(LocalReadCapability, AccountScope, SupabaseClient)>
        inExpiredLocalRead() async {
      final sdk = await expiredSdk();
      await signInFirstAccount(await liveSdk());
      await seedRows(f.host.current!.database);
      await f.session.bindSupabaseAuth(sdk);
      await f.session.debugLocalReadIdle;
      final scope = f.host.current!;
      expect(scope.isLocalRead, isTrue);
      return (scope.localReadCapability!, scope, sdk);
    }

    test(
        'a reconnect that fails AFTER the writable swap re-enters local read '
        'only through a fresh restore (new scope, new capability)', () async {
      final (old, oldScope, sdk) = await inExpiredLocalRead();
      final opId = (await record())!.operationId;
      await sdk.auth.refreshSession();
      f.storage.gate = (op, key) async {
        if (op == 'write' && key == 'auth_method') {
          throw StateError('commit refused');
        }
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      f.storage.gate = null;
      // Synchronously invalidated and never reinstated.
      expect(old.isCurrent, isFalse);
      expect(f.session.localReadActive, isFalse);
      await f.session.debugLocalReadIdle;
      // A fresh restore from the durable grant: new scope, new capability.
      expect(f.session.localReadActive, isTrue);
      final fresh = f.host.current!;
      expect(fresh.isLocalRead, isTrue);
      expect(identical(fresh, oldScope), isFalse);
      expect(fresh.generation, greaterThan(oldScope.generation));
      expect(identical(fresh.database, oldScope.database), isFalse);
      expect(identical(fresh.localReadCapability, old), isFalse);
      expect(fresh.localReadCapability!.isCurrent, isTrue);
      // The stale callback holding the OLD proof is still refused.
      expect(old.isCurrent, isFalse);
      expect(old.requireCurrent, throwsA(isA<StaleLocalReadException>()));
      expect((await record())!.operationId, opId,
          reason: 'restoration reads the durable grant; it writes nothing');
      expect(await txCount(fresh.database), 1);
    });

    test(
        'a reconnect that fails while the read-only scope is still published '
        'does not reinstate it: the scope is replaced by a fresh restore',
        () async {
      final (old, oldScope, _) = await inExpiredLocalRead();
      f.storage.gate = (op, key) async {
        if (op == 'read' && key == kMarkerKey) {
          throw StateError('marker unreadable');
        }
      };
      Object? error;
      try {
        await f.session.setIdentity(
            method: 'google', email: '$_uid@example.com', userId: _uid);
      } catch (e) {
        error = e;
      }
      f.storage.gate = null;
      expect(error, isNotNull);
      expect(old.isCurrent, isFalse);
      expect(f.session.localReadActive, isFalse);
      await f.session.debugLocalReadIdle;
      expect(f.session.localReadActive, isTrue);
      final fresh = f.host.current!;
      expect(identical(fresh, oldScope), isFalse);
      expect(identical(fresh.database, oldScope.database), isFalse);
      expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(fresh.localReadCapability!.isCurrent, isTrue);
      expect(old.isCurrent, isFalse);
    });

    test('when the fresh restore fails after a failed reconnect: signed out',
        () async {
      final (old, _, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      f.storage.gate = (op, key) async {
        if (op == 'write' && key == 'auth_method') {
          // The durable evidence turns restrictive before the restore runs.
          f.storage.data[ReplicaStore.removalBarrierKey] = '{"uid":"x"}';
          throw StateError('commit refused');
        }
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      f.storage.gate = null;
      await f.session.debugLocalReadIdle;
      expect(old.isCurrent, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.host.current, isNotNull);
      expect(f.host.current!.uid, isNull, reason: 'signed-out scope');
      expect(f.host.current!.isLocalRead, isFalse);
    });

    // Astra D3 — a queued failure recovery is bound to the FAILED attempt. A
    // delayed recovery must never downgrade a newer independently admitted
    // scope; the same uid alone is never proof of current write authority.
    //
    // Attempt #1 (which had retired the local-read proof) fails after its
    // writable swap; its failure recovery is queued but starts LATE (the gate
    // models a busy serial lane), after a newer admission completed.
    Future<void> failFirstThenAdmit(String secondUid) async {
      final release = Completer<void>();
      f.session.debugFailureRecoveryGate = () => release.future;
      var first = true;
      f.storage.gate = (op, key) async {
        if (first && op == 'write' && key == 'auth_method') {
          first = false;
          throw StateError('commit refused');
        }
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      await f.session.setIdentity(
          method: 'google',
          email: '$secondUid@example.com',
          userId: secondUid);
      f.storage.gate = null;
      release.complete();
      await f.session.debugLocalReadIdle;
      f.session.debugFailureRecoveryGate = null;
    }

    test(
        'D3: a newer same-uid writable admission that completes before the '
        'queued failure recovery runs is NOT downgraded to read-only', () async {
      final (old, oldScope, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      await failFirstThenAdmit(_uid);
      final newer = f.host.current!;
      expect(newer.uid, _uid);
      expect(newer.isLocalRead, isFalse,
          reason: 'the queued recovery of the failed attempt must not '
              'downgrade the newer writable scope');
      expect(newer.database.isReadOnly, isFalse);
      expect(newer.database.lifecycleState, DatabaseLifecycleState.open);
      expect(f.session.localReadActive, isFalse);
      expect(f.session.status, SessionStatus.authenticated);
      expect(old.isCurrent, isFalse, reason: 'old proof never revives');
      expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
    });

    test(
        'D3: a different-uid successor admitted before the queued failure '
        'recovery runs is not replaced by the old uid\'s read-only scope',
        () async {
      final (old, _, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      await failFirstThenAdmit('uid-b');
      final successor = f.host.current!;
      expect(successor.uid, 'uid-b');
      expect(successor.isLocalRead, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(old.isCurrent, isFalse);
    });
    // Astra R10.2 — the recovery is bound to the ORIGINATING attempt's identity,
    // not to whatever state exists when the failure is caught. A successor that
    // arrives BEFORE the failure is captured (the gap between the throw and the
    // capture) already superseded the attempt, so no recovery is queued at all.
    Future<void> failThenAdmitBeforeCapture(String secondUid) async {
      var first = true;
      f.storage.gate = (op, key) async {
        if (first && op == 'write' && key == 'auth_method') {
          first = false;
          throw StateError('commit refused');
        }
      };
      f.session.debugBeforeFailureCapture = () async {
        f.session.debugBeforeFailureCapture = null;
        f.storage.gate = null;
        await f.session.setIdentity(
            method: 'google',
            email: '$secondUid@example.com',
            userId: secondUid);
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      f.session.debugBeforeFailureCapture = null;
      f.storage.gate = null;
      await f.session.debugLocalReadIdle;
    }

    test(
        'R10.2: a same-uid writable admission that arrives BEFORE the failure '
        'is captured is not downgraded to read-only', () async {
      final (old, oldScope, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      await failThenAdmitBeforeCapture(_uid);
      final newer = f.host.current!;
      expect(newer.uid, _uid);
      expect(newer.isLocalRead, isFalse,
          reason: 'a recovery bound at capture would adopt the successor');
      expect(newer.database.isReadOnly, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.session.status, SessionStatus.authenticated);
      expect(old.isCurrent, isFalse);
      expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
    });

    test(
        'R10.2: a different-uid successor that arrives before the failure is '
        'captured is not replaced by the old uid\'s read-only scope', () async {
      final (old, _, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      await failThenAdmitBeforeCapture('uid-b');
      final successor = f.host.current!;
      expect(successor.uid, 'uid-b');
      expect(successor.isLocalRead, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(old.isCurrent, isFalse);
    });

    test(
        'R10.2 control: with no successor the failed attempt still recovers '
        'through the fresh restore', () async {
      final (old, oldScope, sdk) = await inExpiredLocalRead();
      await sdk.auth.refreshSession();
      var first = true;
      f.storage.gate = (op, key) async {
        if (first && op == 'write' && key == 'auth_method') {
          first = false;
          throw StateError('commit refused');
        }
      };
      await expectLater(
          f.session.setIdentity(
              method: 'google', email: '$_uid@example.com', userId: _uid),
          throwsStateError);
      f.storage.gate = null;
      await f.session.debugLocalReadIdle;
      expect(f.session.localReadActive, isTrue);
      expect(identical(f.host.current, oldScope), isFalse);
      expect(old.isCurrent, isFalse);
    });
  });
}
