import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/ownership_guard.dart'
    show StaleOwnershipException;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';
import 'recording_secure_storage.dart';

const _owner = 'prepared-local-owner';
const _bound = Duration(seconds: 5);
Future<T> _bounded<T>(Future<T> work) => work.timeout(_bound);

/// Real published host, strict replica store and SDK session. Only local
/// persistence, platform replies and synthetic SDK transport are controlled.
class _World {
  final session = AppSession.instance;
  final oldGate = CloudEgressGate.instance;
  final egress = TestEgress();
  final holds = <Hold>[];
  final producers = <Future<void>>[];
  final unexpectedSdk = <http.Request>[];
  var reminderClears = 0;
  late F2Fixture fixture;
  late SupabaseClient sdk;
  late void Function() restoreFence;

  static Future<_World> open() async {
    final w = _World();
    await w.session.debugResetAuthBinding();
    w.session.debugResetAdmissionState();
    w.restoreFence = AccountFenceAuthority.replacePersistenceForTest();
    w.fixture = await F2Fixture.create(afterWithdraw: () async {});
    w.session.configureAccountScope(w.fixture.host);
    w.sdk = SupabaseClient('https://example.supabase.co', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        // Production wraps the SDK transport in the same gate: with Cloud OFF a
        // local sign-out's logout request is denied before it can reach a socket.
        httpClient: GatedHttpClient(MockClient((request) async {
          w.unexpectedSdk.add(request);
          throw StateError('unexpected SDK request');
        })));
    await F2Fixture.recoverSession_(w.sdk, _owner);
    w.session.configureLocalReminderClear(() async {
      w.reminderClears++;
    });
    w.egress.owner = _owner;
    w.egress.install();
    await w.admit(_owner);
    final event = Completer<void>();
    w.session.debugAuthEventCompleted = (type) {
      if (type == AuthChangeEvent.tokenRefreshed && !event.isCompleted) {
        event.complete();
      }
    };
    try {
      await w.session.bindSupabaseAuth(w.sdk);
      await _bounded(event.future);
    } finally {
      w.session.debugAuthEventCompleted = null;
    }
    expect(w.admission.isCurrent, isTrue);
    return w;
  }

  DatabaseHostAdmission get admission =>
      session.captureDatabaseHostAdmission()!;
  AdmissionAuthority get origin => session.captureCallbackOrigin()!;

  Future<void> admit(String uid) async {
    if (sdk.auth.currentSession?.user.id != uid) {
      await F2Fixture.recoverSession_(sdk, uid);
    }
    final actual = sdk.auth.currentSession!;
    await session.setIdentity(
        method: 'google',
        userId: uid,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken);
    await session.finishOnboarding(client: sdk);
  }

  Future<T> track<T>(Future<T> work) {
    producers
        .add(work.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return work;
  }

  Future<PreparedOriginalLocalRemovalOutcome> remove() =>
      track(session.removePreparedOriginalLocalReplica(
          originalAdmission: admission, originalOrigin: origin));

  Hold hold() {
    final result = Hold();
    holds.add(result);
    return result;
  }

  Hold storageHold(bool Function(String, String) match) {
    final result = fixture.storage.holdOnce(match);
    holds.add(result);
    return result;
  }

  Future<void> finish() async {
    for (final hold in holds) {
      if (!hold.release.isCompleted) hold.release.complete();
    }
    await _bounded(Future.wait(producers));
    fixture.storage.gate = null;
    fixture.barrier.onCall = null;
    session.configureCaptureDeviceUnlink(null);
    session.configureLocalReminderClear(null);
    session.debugAuthEventCompleted = null;
    await _bounded(session.debugResetAuthBinding());
    await _bounded(session.drainAdmissions());
    await _bounded(fixture.dispose());
    await sdk.dispose();
    CloudEgressGate.instance = oldGate;
    restoreFence();
    expect(unexpectedSdk, isEmpty);
  }
}

Future<void> _world(Future<void> Function(_World) body) async {
  final w = await _World.open();
  try {
    await body(w);
  } finally {
    await w.finish();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'real local work drains, and exclusion spans final sweep and strict cleanup',
      () => _world((w) async {
            final db = w.fixture.host.current!.database;
            final admission = w.admission;
            final origin = w.origin;
            final events = <String>[];
            final local = w.hold();
            final sweep = w.hold();
            final cleanup = w.storageHold(
                (op, key) => op == 'delete' && key == 'auth_method');
            final work =
                w.track(w.session.runAdmittedLocalOperation(origin, () async {
              await db.customSelect('SELECT 1;').get();
              local.reached.complete();
              await local.release.future;
              events.add('local-terminal');
            }));
            await _bounded(local.reached.future);
            w.fixture.barrier.onCall = (call) async {
              if (call == 'begin:$_owner') {
                expect(events, contains('local-terminal'));
              }
              if (call == 'finish:$_owner') {
                sweep.reached.complete();
                await sweep.release.future;
              }
            };
            final removal = w.track(w.session
                .removePreparedOriginalLocalReplica(
                    originalAdmission: admission, originalOrigin: origin));
            expect(w.fixture.flow.isRunning, isTrue);
            expect(admission.isCurrent, isFalse);
            expect(origin.isCurrent, isFalse);
            expect(db.lifecycleState, DatabaseLifecycleState.open);
            expect(
                () => w.session.runAdmittedLocalOperation(origin, () async {}),
                throwsA(isA<StaleAdmissionException>()));
            final during = w.session.beginAuthAttempt();
            await expectLater(
                w.session.setIdentity(
                    method: 'google', userId: 'successor', attempt: during),
                throwsA(isA<StaleAdmissionException>()));
            expect(w.fixture.scope.calls, isNot(contains('detach')));
            local.release.complete();
            await _bounded(work);
            await _bounded(sweep.reached.future);
            expect(db.lifecycleState, DatabaseLifecycleState.closed);
            expect(w.fixture.flow.isRunning, isTrue);
            sweep.release.complete();
            await _bounded(cleanup.reached.future);
            expect(w.fixture.flow.isRunning, isTrue);
            expect(
                (jsonDecode(w.fixture.storage.data[RemoveDataFlow.barrierKey]!)
                    as Map)['localOnly'],
                isTrue);
            await expectLater(
                w.session.setIdentity(method: 'google', userId: 'successor'),
                throwsA(isA<StaleAdmissionException>()));
            cleanup.release.complete();
            expect(
                await _bounded(removal),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
            expect(w.fixture.flow.isRunning, isFalse);
            expect(w.fixture.storage.data[RemoveDataFlow.barrierKey], isNull);
            expect(w.session.removalNoticePending.value, isFalse);
            await expectLater(
                w.session.setIdentity(
                    method: 'google', userId: 'successor', attempt: during),
                throwsA(isA<StaleAdmissionException>()));
          }));

  test(
      'nested local reservation refuses before mutation; external original control works',
      () => _world((w) async {
            final admission = w.admission;
            final origin = w.origin;
            final before = List<String>.of(w.fixture.storage.attempts);
            final result = await w.session.runAdmittedLocalOperation(
                origin,
                () => w.session.runAdmittedLocalOperation(
                    origin,
                    () => w.session.removePreparedOriginalLocalReplica(
                        originalAdmission: admission, originalOrigin: origin)));
            expect(result,
                PreparedOriginalLocalRemovalOutcome.operationUnavailable);
            expect(w.fixture.storage.attempts, before);
            expect(admission.isCurrent, isTrue);
            expect(
                await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
          }));

  test(
      'reservation abandonment is nondestructive and queued work takes its released turn',
      () => _world((w) async {
            final before = List<String>.of(w.fixture.storage.attempts);
            final reservation =
                w.fixture.flow.reservePreparedRemoval(w.admission, w.origin)!;
            expect(w.fixture.flow.isRunning, isTrue);
            w.fixture.flow.abandonPreparedRemoval(reservation);
            w.fixture.flow.abandonPreparedRemoval(reservation);
            expect(w.fixture.flow.isRunning, isFalse);
            expect(w.fixture.storage.attempts, before);
            expect(w.fixture.order, isEmpty);
            expect(await _bounded(w.fixture.flow.resumePending()), isTrue);
          }));

  test(
      'duplicate run is one execution and ordinary join waits for held settlement',
      () => _world((w) async {
            var remote = 0;
            final flow = RemoveDataFlow(
                store: w.fixture.store,
                scope: w.fixture.scope,
                barrier: w.fixture.barrier,
                clearOwnerMarker: w.session.clearLocalDataOwnerMarker,
                quiesce: w.session.drainAdmissions,
                invalidateAdmissionGeneration:
                    w.session.invalidateRemovalGeneration,
                serverCleanupBestEffort: () async {
                  remote++;
                });
            w.session.configureRemoveData(flow);
            final reservation =
                flow.reservePreparedRemoval(w.admission, w.origin)!;
            final one = w.track(flow.runPreparedRemoval(reservation));
            expect(
                identical(one, flow.runPreparedRemoval(reservation)), isTrue);
            var joinedSettled = false;
            final joined =
                w.track(flow.remove(_owner).then((_) => joinedSettled = true));
            await _bounded(one);
            expect(joinedSettled, isFalse);
            expect(flow.isRunning, isTrue);
            expect(remote, 0);
            final settle = flow.settlePreparedRemoval(reservation,
                localCleanupConfirmed: true);
            expect(
                identical(
                    settle,
                    flow.settlePreparedRemoval(reservation,
                        localCleanupConfirmed: true)),
                isTrue);
            await _bounded(settle);
            await _bounded(joined);
            expect(w.fixture.order.where((value) => value == 'begin:$_owner'),
                hasLength(1));
            expect(remote, 0);
          }));

  test(
      'abandoned reservation reports incomplete to joiners and releases queue',
      () => _world((w) async {
            final reservation =
                w.fixture.flow.reservePreparedRemoval(w.admission, w.origin)!;
            final joined = w.track(w.fixture.flow.remove(_owner));
            final observed = joined.then<Object?>((_) => null,
                onError: (Object error) => error);
            w.fixture.flow.abandonPreparedRemoval(reservation);
            expect(
                await _bounded(observed), isA<RemoveDataIncompleteException>());
            expect(await _bounded(w.fixture.flow.resumePending()), isTrue);
            expect(w.fixture.order, isEmpty);
          }));

  test(
      'unconfirmed cleanup cannot turn a joined prepared execution into success',
      () => _world((w) async {
            final reached = Completer<void>();
            final release = w.hold();
            w.fixture.barrier.onCall = (call) async {
              if (call == 'begin:$_owner') {
                reached.complete();
                await release.release.future;
              }
            };
            final reservation =
                w.fixture.flow.reservePreparedRemoval(w.admission, w.origin)!;
            final execution =
                w.track(w.fixture.flow.runPreparedRemoval(reservation));
            await _bounded(reached.future);
            final joined = w.track(w.fixture.flow.remove(_owner));
            final observed = joined.then<Object?>((_) => null,
                onError: (Object error) => error);
            release.release.complete();
            await _bounded(execution);
            await _bounded(w.fixture.flow.settlePreparedRemoval(reservation,
                localCleanupConfirmed: false));
            expect(
                await _bounded(observed), isA<RemoveDataIncompleteException>());
            expect(
                w.fixture.storage.data[RemoveDataFlow.barrierKey], isNotNull);
          }));

  test(
      'prepared exclusion refuses new maintenance after its real drain',
      () => _world((w) async {
            var entered = 0;
            await w.session.runMaintenanceParticipant(() async {
              entered++;
            });
            expect(entered, 1,
                reason: 'matched ordinary maintenance is executable');
            final reached = Completer<void>();
            final release = w.hold();
            w.fixture.barrier.onCall = (call) async {
              if (call == 'begin:$_owner') {
                reached.complete();
                await release.release.future;
              }
            };
            final removal = w.remove();
            await _bounded(reached.future);
            final maintenance =
                w.track(w.session.runMaintenanceParticipant(() async {
              entered++;
            }));
            final observed = maintenance.then<Object?>((_) => null,
                onError: (Object error) => error);
            final refusal = await _bounded(observed);
            release.release.complete();
            expect(
                await _bounded(removal),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
            expect(refusal, isA<StaleOwnershipException>());
            expect(entered, 1,
                reason: 'no new maintenance body after removal drain');
          }));

  test(
      'prepared failure propagates incomplete to its ordinary same-owner join',
      () => _world((w) async {
            final reached = Completer<void>();
            final release = w.hold();
            w.fixture.barrier.onCall = (call) async {
              if (call == 'begin:$_owner') {
                reached.complete();
                await release.release.future;
                throw const RemoveDataIncompleteException();
              }
            };
            final reservation =
                w.fixture.flow.reservePreparedRemoval(w.admission, w.origin)!;
            final execution =
                w.track(w.fixture.flow.runPreparedRemoval(reservation));
            final executionObserved = execution.then<Object?>((_) => null,
                onError: (Object error) => error);
            await _bounded(reached.future);
            final joined = w.track(w.fixture.flow.remove(_owner));
            final joinedObserved = joined.then<Object?>((_) => null,
                onError: (Object error) => error);
            release.release.complete();
            expect(await _bounded(executionObserved),
                isA<RemoveDataIncompleteException>());
            await _bounded(w.fixture.flow.settlePreparedRemoval(reservation,
                localCleanupConfirmed: false));
            expect(await _bounded(joinedObserved),
                isA<RemoveDataIncompleteException>());
            expect(w.fixture.flow.isRunning, isFalse);
            expect(
                w.fixture.storage.data[RemoveDataFlow.barrierKey], isNotNull);
          }));

  test(
      'pending actual flow cannot be joined by prepared acceptance',
      () => _world((w) async {
            final admission = w.admission;
            final origin = w.origin;
            final held = w.storageHold(
                (op, key) => op == 'read' && key == RemoveDataFlow.barrierKey);
            final prior = w.track(w.fixture.flow.resumePending());
            await _bounded(held.reached.future);
            final before = List<String>.of(w.fixture.storage.attempts);
            expect(
                await _bounded(w.session.removePreparedOriginalLocalReplica(
                    originalAdmission: admission, originalOrigin: origin)),
                PreparedOriginalLocalRemovalOutcome.operationUnavailable);
            expect(w.fixture.storage.attempts, before);
            held.release.complete();
            expect(await _bounded(prior), isTrue);
          }));

  for (final marker in [
    'foreign-owner',
    'owner-transition-pending:synthetic'
  ]) {
    test(
        '$marker preflight preserves every domain artifact',
        () => _world((w) async {
              w.fixture.storage.data[kMarkerKey] = marker;
              final before = Map<String, String>.of(w.fixture.storage.data);
              final attempts = List<String>.of(w.fixture.storage.attempts);
              final db = w.fixture.host.current!.database;
              expect(await _bounded(w.remove()),
                  PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete);
              expect(w.fixture.storage.data, before);
              expect(w.fixture.storage.attempts, attempts);
              expect(w.fixture.order, isEmpty);
              expect(db.lifecycleState, DatabaseLifecycleState.open);
              expect(await w.fixture.artifactsOf(_owner),
                  containsAll(['dir', 'key', 'registry']));
              expect(w.session.captureDatabaseHostAdmission(), isNull);
              expect(w.session.captureLocalWorkAuthority(), isNull);
            }));
  }

  test(
      'foreign durable leftover is incomplete, preserved, and never executed',
      () => _world((w) async {
            final raw = jsonEncode({
              'uid': 'foreign-record-owner',
              'uidHash': 'foreign-hash',
              'revoke': true,
              'localOnly': false
            });
            w.fixture.storage.data[RemoveDataFlow.barrierKey] = raw;
            final before = Map<String, String>.of(w.fixture.storage.data);
            final attempts = List<String>.of(w.fixture.storage.attempts);
            expect(await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete);
            expect(w.fixture.storage.data, before);
            expect(w.fixture.storage.attempts, attempts);
            expect(w.fixture.order, isEmpty);
            expect(w.session.captureDatabaseHostAdmission(), isNull);
          }));

  test(
      'absent original owner marker is a matched positive, not recaptured authority',
      () => _world((w) async {
            w.fixture.storage.data.remove(kMarkerKey);
            expect(
                await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
            expect(await w.fixture.artifactsOf(_owner), isEmpty);
          }));

  test(
      'confirmed removal clears reminders once and the SDK session locally, with no remote effects',
      () => _world((w) async {
            var unlink = 0;
            var purge = 0;
            w.session.configureCaptureDeviceUnlink(() async {
              unlink++;
            });
            w.session.configureCaptureOwnerClear(() async {
              purge++;
              return true;
            });
            expect(w.sdk.auth.currentSession?.user.id, _owner);
            expect(
                await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
            expect(w.reminderClears, 1);
            expect(w.sdk.auth.currentSession, isNull);
            expect(unlink, 0);
            expect(purge, 0);
            expect(w.unexpectedSdk, isEmpty);
            // The local sign-out's signedOut event reaches every auth listener;
            // none may reprocess the removed owner (owner clear, unlink, network).
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await _bounded(w.session.drainAdmissions());
            expect(w.session.status, SessionStatus.needsOnboarding);
            expect(w.reminderClears, 1);
            expect(unlink, 0);
            expect(purge, 0);
            expect(w.unexpectedSdk, isEmpty);
          }));

  test(
      'a reminder clear that never completes cannot stall the confirmed removal',
      () => _world((w) async {
            var unlink = 0;
            var purge = 0;
            w.session.configureCaptureDeviceUnlink(() async {
              unlink++;
            });
            w.session.configureCaptureOwnerClear(() async {
              purge++;
              return true;
            });
            w.session.configureLocalReminderClear(() {
              w.reminderClears++;
              return Completer<void>().future;
            });
            // The clear is bounded at 4s, so allow more than the usual bound.
            expect(
                await w.remove().timeout(const Duration(seconds: 10)),
                PreparedOriginalLocalRemovalOutcome
                    .originalLocalRemovalConfirmed);
            expect(w.reminderClears, 1);
            expect(w.session.status, SessionStatus.needsOnboarding);
            expect(w.sdk.auth.currentSession, isNull);
            expect(unlink, 0);
            expect(purge, 0);
          }));

  test(
      'launch strict cleanup skips the SDK sign-out once a successor took the epoch during the reminder clear',
      () => _world((w) async {
            w.fixture.storage.data[RemoveDataFlow.barrierKey] = jsonEncode({
              'uid': _owner,
              'uidHash': await w.fixture.hash(_owner),
              'revoke': true,
              'localOnly': true,
            });
            final held = w.hold();
            w.session.configureLocalReminderClear(() async {
              w.reminderClears++;
              held.reached.complete();
              await held.release.future;
            });
            final launch = w.track(w.session.prepareLaunchAdmission());
            await _bounded(held.reached.future);
            final successor = w
                .track(w.session.setIdentity(method: 'google', userId: _owner));
            held.release.complete();
            expect((await _bounded(launch)).blocked, isTrue);
            await _bounded(successor);
            expect(w.reminderClears, 1);
            expect(w.sdk.auth.currentSession?.user.id, _owner,
                reason: 'the successor keeps its SDK session');
          }));

  test(
      'strict cleanup failure retains true barrier and denies local work',
      () => _world((w) async {
            var unlink = 0;
            w.session.configureCaptureDeviceUnlink(() async {
              unlink++;
            });
            w.fixture.storage.gate = (op, key) async {
              if (op == 'delete' && key == 'auth_method') {
                throw StateError('synthetic cleanup failure');
              }
            };
            expect(await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete);
            expect(
                (jsonDecode(w.fixture.storage.data[RemoveDataFlow.barrierKey]!)
                    as Map)['localOnly'],
                isTrue);
            expect(w.session.captureLocalWorkAuthority(), isNull);
            expect(w.sdk.auth.currentSession?.user.id, _owner);
            expect(w.reminderClears, 0);
            expect(unlink, 0);
            w.fixture.storage.gate = null;
            expect(await _bounded(w.fixture.flow.resumePending()), isTrue);
            expect(w.session.removalNoticePending.value, isFalse);
          }));

  test(
      'failed final native sweep cannot confirm and true mode survives restart',
      () => _world((w) async {
            w.fixture.barrier.failFinish = true;
            expect(await _bounded(w.remove()),
                PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete);
            expect(
                w.fixture.storage.data[RemoveDataFlow.barrierKey], isNotNull);
            w.fixture.barrier.failFinish = false;
            var remote = 0;
            final reconstructed = RemoveDataFlow(
                store: w.fixture.store,
                scope: w.fixture.scope,
                barrier: w.fixture.barrier,
                clearOwnerMarker: w.session.clearLocalDataOwnerMarker,
                serverCleanupBestEffort: () async {
                  remote++;
                });
            final recovered =
                await _bounded(reconstructed.resumePendingWithOutcome());
            expect(recovered.completed, isTrue);
            expect(recovered.localOnly, isTrue);
            expect(remote, 0);
            expect(w.session.removalNoticePending.value, isFalse);
          }));

  test(
      'settlement never clears a foreign barrier replacement',
      () => _world((w) async {
            final held = w.storageHold(
                (op, key) => op == 'delete' && key == 'auth_method');
            final removal = w.remove();
            await _bounded(held.reached.future);
            final replacement = jsonEncode({
              'uid': 'foreign-record-owner',
              'uidHash': 'foreign-hash',
              'revoke': true,
              'localOnly': true
            });
            w.fixture.storage.data[RemoveDataFlow.barrierKey] = replacement;
            held.release.complete();
            expect(await _bounded(removal),
                PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete);
            expect(
                w.fixture.storage.data[RemoveDataFlow.barrierKey], replacement);
          }));

  test('completed removal own stale marker is cleared on actual restart launch',
      () => _world((w) async {
        await _bounded(w.fixture.flow.remove(_owner));
        expect(await w.fixture.flow.revokedUids(), contains(_owner));
        expect(await w.fixture.artifactsOf(_owner), isEmpty);
        w.fixture.storage.data[kMarkerKey] = _owner;
        await _bounded(w.fixture.restart());
        var purge = 0;
        var unlink = 0;
        w.session.configureCaptureOwnerClear(() async { purge++; return true; });
        w.session.configureCaptureDeviceUnlink(() async { unlink++; });
        final launch = await _bounded(w.session.prepareLaunchAdmission());
        expect(launch.blocked, isFalse);
        expect(w.fixture.storage.data[kMarkerKey], isNull);
        expect(w.fixture.storage.data[kGenerationKey], isNull);
        expect(w.fixture.storage.data['auth_method'], isNull);
        expect(w.fixture.storage.data['onboarding_current_account_v1'], isNull);
        expect(await w.fixture.artifactsOf(_owner), isEmpty);
        expect(await w.fixture.flow.revokedUids(), contains(_owner));
        // No record means the mode is unknown: it finishes through the ordinary
        // sign-out (owner clear runs) but never sends the remote unlink.
        expect(purge, 1);
        expect(unlink, 0);
      }));

  for (final replacement in ['foreign-launch-owner', 'owner-transition-pending:launch']) {
    test('restart stale-marker reread preserves $replacement and refuses cleanup',
        () => _world((w) async {
          await _bounded(w.fixture.flow.remove(_owner));
          w.fixture.storage.data[RemoveDataFlow.barrierKey] = jsonEncode({
            'uid': _owner,
            'uidHash': await w.fixture.hash(_owner),
            'revoke': true,
            'localOnly': true,
          });
          w.fixture.storage.data[kMarkerKey] = _owner;
          await _bounded(w.fixture.restart());
          final identity = w.fixture.storage.data['onboarding_current_account_v1'];
          final revoked = w.fixture.storage.data[RemoveDataFlow.revokedKey];
          var reads = 0;
          var reached = false;
          // The record's own resume works first; only what follows the race
          // (the strict stage) must stay clean.
          var before = 0;
          w.fixture.storage.gate = (op, key) async {
            if (op == 'read' && key == kMarkerKey && ++reads == 5) {
              reached = true;
              before = w.fixture.storage.attempts.length;
              w.fixture.storage.data[kMarkerKey] = replacement;
            }
          };
          expect((await _bounded(w.session.prepareLaunchAdmission())).blocked, isTrue);
          expect(reached, isTrue, reason: 'actual strict marker reread was reached');
          expect(w.fixture.storage.data[kMarkerKey], replacement);
          expect(w.fixture.storage.data['onboarding_current_account_v1'], identity);
          expect(w.fixture.storage.data[RemoveDataFlow.revokedKey], revoked);
          expect(w.fixture.storage.attempts.skip(before), isEmpty);
          expect(await w.fixture.artifactsOf(_owner), isEmpty);
        }));
  }

  test('restart stale-marker clear loses its epoch before any successor cleanup',
      () => _world((w) async {
        await _bounded(w.fixture.flow.remove(_owner));
        w.fixture.storage.data[RemoveDataFlow.barrierKey] = jsonEncode({
          'uid': _owner,
          'uidHash': await w.fixture.hash(_owner),
          'revoke': true,
          'localOnly': true,
        });
        w.fixture.storage.data[kMarkerKey] = _owner;
        await _bounded(w.fixture.restart());
        var reads = 0;
        final held = w.hold();
        w.fixture.storage.gate = (op, key) async {
          if (op == 'read' && key == kMarkerKey && ++reads == 5) {
            held.reached.complete();
            await held.release.future;
          }
        };
        final launch = w.track(w.session.prepareLaunchAdmission());
        await _bounded(held.reached.future);
        w.fixture.storage.gate = null;
        final before = w.fixture.storage.attempts.length;
        final successor = w.track(w.session.setIdentity(method: 'google', userId: _owner));
        held.release.complete();
        expect((await _bounded(launch)).blocked, isTrue);
        await _bounded(successor);
        expect(w.fixture.host.current?.uid, _owner);
        expect(w.fixture.storage.data[kMarkerKey], _owner);
        expect(w.fixture.storage.attempts.skip(before),
            isNot(anyOf(contains('delete:auth_method'), contains('delete:auth_email'),
                contains('delete:onboarding_current_account_v1'))));
      }));

  for (final withRecord in [true, false]) {
    test(
        'launch ${withRecord ? 'true record' : 'unknown completed mode'} cleanup suppresses remote effects',
        () => _world((w) async {
              var unlink = 0;
              var purge = 0;
              w.session.configureCaptureDeviceUnlink(() async {
                unlink++;
              });
              w.session.configureCaptureOwnerClear(() async {
                purge++;
                return true;
              });
              if (withRecord) {
                w.fixture.storage.data[RemoveDataFlow.barrierKey] = jsonEncode({
                  'uid': _owner,
                  'uidHash': await w.fixture.hash(_owner),
                  'revoke': true,
                  'localOnly': true,
                });
              } else {
                w.fixture.storage.data[RemoveDataFlow.revokedKey] =
                    jsonEncode([_owner]);
                await w.fixture.host.detach();
                await w.session.clearLocalDataOwnerMarker(_owner);
              }
              final result = await _bounded(w.session.prepareLaunchAdmission());
              expect(result.blocked, isFalse);
              expect(unlink, 0);
              expect(w.fixture.storage.data['auth_method'], isNull);
              if (withRecord) {
                // The strict path: no owner clear, but the deleted owner's
                // reminders are cleared locally once and the SDK session is gone.
                expect(purge, 0);
                expect(w.reminderClears, 1);
                expect(w.sdk.auth.currentSession, isNull);
              } else {
                // Unknown mode finishes through the ordinary sign-out.
                expect(purge, 1);
                expect(w.reminderClears, 0);
                expect(w.sdk.auth.currentSession?.user.id, _owner);
              }
            }));
  }

  test(
      'launch ordinary interrupted Remove data finishes the normal path with unlink and owner clear',
      () => _world((w) async {
            var unlink = 0;
            var purge = 0;
            w.session.configureCaptureDeviceUnlink(() async {
              unlink++;
            });
            w.session.configureCaptureOwnerClear(() async {
              purge++;
              return true;
            });
            w.fixture.storage.data[RemoveDataFlow.barrierKey] = jsonEncode({
              'uid': _owner,
              'uidHash': await w.fixture.hash(_owner),
              'revoke': true,
              'localOnly': false,
            });
            final result = await _bounded(w.session.prepareLaunchAdmission());
            expect(result.blocked, isFalse);
            expect(unlink, 1);
            expect(purge, 1);
            expect(w.reminderClears, 0);
            expect(w.fixture.storage.data['auth_method'], isNull);
          }));

  test(
      'launch helper stopped inside a read cannot clear a successor after epoch loss',
      () => _world((w) async {
            w.fixture.storage.data[RemoveDataFlow.revokedKey] =
                jsonEncode([_owner]);
            await w.fixture.host.detach();
            await w.session.clearLocalDataOwnerMarker(_owner);
            var markerReads = 0;
            final held = w.hold();
            w.fixture.storage.gate = (op, key) async {
              if (op == 'read' && key == kMarkerKey && ++markerReads == 3) {
                held.reached.complete();
                await held.release.future;
              }
            };
            final launch = w.track(w.session.prepareLaunchAdmission());
            await _bounded(held.reached.future);
            // The explicit entrance advances its epoch before waiting behind the
            // held ownership lane. Release that lane before awaiting the successor.
            w.fixture.storage.gate = null;
            final before = w.fixture.storage.attempts.length;
            final successor = w
                .track(w.session.setIdentity(method: 'google', userId: _owner));
            held.release.complete();
            expect((await _bounded(launch)).blocked, isTrue);
            await _bounded(successor);
            await w.session.finishOnboarding(client: w.sdk);
            expect(
                w.fixture.storage.attempts.skip(before),
                isNot(anyOf(
                    contains('delete:auth_method'),
                    contains('delete:auth_email'),
                    contains('delete:onboarding_current_account_v1'))));
            expect(w.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
          }));

  group('P4: server-completed deletion killed before local removal', () {
    const secret = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ0123';
    Future<void> seed(_World w, ImmediateDeletionPhase phase) async {
      await ImmediateDeletionReceiptStore().writeVerified(
          ImmediateDeletionReceipt(
              owner: _owner,
              operationId: 'op-p4',
              receiptSecret: secret,
              phase: phase));
      expect(await w.fixture.artifactsOf(_owner),
          containsAll(['dir', 'key', 'registry']));
      expect(w.fixture.storage.data[kMarkerKey], _owner);
      // The process dies: no SDK session survives (the server deleted the
      // user), nothing local was removed.
      await _bounded(w.session.debugResetAuthBinding());
      await _bounded(w.fixture.restart());
    }

    test('a COMPLETED receipt removes the replica and clears the marker at launch',
        () => _world((w) async {
              await seed(w, ImmediateDeletionPhase.completed);
              final launch = await _bounded(w.session.prepareLaunchAdmission());
              expect(launch.blocked, isFalse);
              expect(launch.uid, isNull);
              expect(await w.fixture.artifactsOf(_owner), isEmpty);
              expect(w.fixture.storage.data[kMarkerKey], isNull);
              expect(w.fixture.storage.data['auth_method'], isNull);
              expect(w.fixture.storage.data['onboarding_current_account_v1'],
                  isNull);
              expect(w.fixture.storage.data[RemoveDataFlow.barrierKey], isNull);
              expect(await w.fixture.flow.revokedUids(), contains(_owner));
              expect(w.session.status, isNot(SessionStatus.authenticated));
              final retired = await ImmediateDeletionReceiptStore().load(_owner);
              expect(retired?.phase, ImmediateDeletionPhase.completed);
              expect(retired?.receiptSecret, isNull);
              // Idempotent: the next launch has nothing left to do.
              final again =
                  await _bounded(w.session.prepareLaunchAdmission());
              expect(again.blocked, isFalse);
              expect(again.uid, isNull);
            }));

    test('an unconfirmed removal blocks the launch and keeps the barrier',
        () => _world((w) async {
              await seed(w, ImmediateDeletionPhase.completed);
              w.fixture.barrier.failFinish = true;
              final launch = await _bounded(w.session.prepareLaunchAdmission());
              expect(launch.blocked, isTrue);
              expect(w.fixture.storage.data[RemoveDataFlow.barrierKey],
                  isNotNull);
              expect((await ImmediateDeletionReceiptStore().load(_owner))
                  ?.receiptSecret, secret);
              w.fixture.barrier.failFinish = false;
            }));

    test('a receipt NOT in the completed phase triggers no removal',
        () => _world((w) async {
              await seed(w, ImmediateDeletionPhase.mayHaveBeenSent);
              final launch = await _bounded(w.session.prepareLaunchAdmission());
              expect(launch.blocked, isFalse);
              expect(launch.uid, _owner);
              expect(await w.fixture.artifactsOf(_owner),
                  containsAll(['dir', 'key', 'registry']));
              expect(w.fixture.storage.data[kMarkerKey], _owner);
              final kept = await ImmediateDeletionReceiptStore().load(_owner);
              expect(kept?.phase, ImmediateDeletionPhase.mayHaveBeenSent);
              expect(kept?.receiptSecret, secret);
            }));
  });
}
