import '../../harness/egress_test_support.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'dart:io';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:drift/native.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/features/capture/services/notification_journey_service.dart';
import '../capture/ledger_admission_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/backend/auth_client_provider.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/di/rebootstrap_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/rebootstrap_service.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/core/sync/sync_wakeup.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/legacy_financial_cache_reconciler.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_engine.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';
import 'package:money_companion/features/gamification/services/engagement_event_service.dart';
import 'package:money_companion/features/gamification/services/gamification_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_sync_engine.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../core/session/f2_fixture.dart';

class _SdkStorage extends GotrueAsyncStorage {
  const _SdkStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key,required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}
class _Planning implements PlanningSyncEngine {
  _Planning(this.events,{this.firstRelease,this.firstReached});final List<String> events;
  final Completer<void>? firstRelease,firstReached;
  @override
  Future<SyncParentsOutcome> syncParents({LegacyFinancialCacheReconciler? reconciler}) async {
    if(firstReached!=null&&!firstReached!.isCompleted){firstReached!.complete();await firstRelease!.future;}
    events.add('parents');return const SyncParentsOutcome(accounts:ReconcileDomainResult.noDirtyState,planning:ReconcileDomainResult.noDirtyState);
  }
  @override
  Future<void> syncChildren() async {events.add('children');}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Ledger implements LedgerSyncEngine {
  _Ledger(this.events);final List<String> events;
  @override
  Future<ReconcileDomainResult> sync({LegacyFinancialCacheReconciler? reconciler}) async {
    events.add('ledger');return ReconcileDomainResult.noDirtyState;
  }
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Startup implements StartupSyncReconcileService {
  @override
  Future<ReconcileOutcome> run({Duration? timeBudget,SyncPhaseBinding? phase}) async=>ReconcileOutcome.skippedNothingPending;
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Pending implements PendingSyncReconciler {
  @override
  Future<int> run() async=>0;
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Accounts implements AccountsPushService {
  @override
  Future<AccountsPushResult> push() async=>const AccountsPushResult();
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _ParentPush implements PlanningPushService {
  @override
  Future<PlanningPushResult> push() async=>const PlanningPushResult();
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _LedgerPush implements LedgerPushService {
  @override
  Future<LedgerPushResult> push() async=>const LedgerPushResult();
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Child implements PlanningChildSyncService {
  @override
  Future<void> sync() async {}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Notifications implements NotificationLogSyncService {
  _Notifications(this.events,this.service);final List<String> events;final NotificationLogSyncService service;
  final List<Future<Object?>> owned=[];final List<Object?> outcomes=[];
  @override
  Future<NotificationUploadOutcome> syncWithPhase(SyncPhaseBinding phase) {
    final actual=service.syncWithPhase(phase);
    owned.add(actual.then<Object?>((value){outcomes.add(value);return value;},onError:(Object error){outcomes.add(error);return error;}));
    return actual.then((value){events.add('notification');return value;});
  }
  Future<void> settle() async {await Future.wait(owned);}
  @override
  Future<void> sync() async {await syncWithPhase(SyncPhaseBinding());}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Journey implements NotificationJourneyService {
  _Journey(this.events);final List<String> events;
  @override
  Future<void> evaluate()async{events.add('journey');}
  @override
  Future<void> evaluateAfterCapture()async{events.add('journey-capture');}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Sender implements SenderBankMappingSyncService {
  _Sender(this.events);final List<String> events;
  @override
  Future<SenderMappingSyncResult> sync() async {events.add('sender');return const SenderMappingSyncResult();}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Engagement implements EngagementEventService {
  _Engagement(this.events,this.db);final List<String> events;final AppDatabase db;
  @override
  Future<int> pushWithPhase(SyncPhaseBinding phase) async {
    await EngagementEventService(db:db,isSyncEnabled:()=>true,
        getAuthUserId:()async=>'smart-cycle-owner',mayEgress:()async=>true).pushWithPhase(phase);
    events.add('engagement');return 0;
  }
  @override
  Future<int> push() => pushWithPhase(SyncPhaseBinding());
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Gamification implements GamificationSyncService {
  _Gamification(this.events);final List<String> events;
  @override
  Future<void> performSync() async {events.add('gamification');}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
// Default-account reconcile stop controls: these record what the ACTUAL AppShell
// does after the startup reconcile ends with a typed stop or loses its lifetime.
class _RecAccounts implements AccountsPushService {
  _RecAccounts(this.events);final List<String> events;
  @override
  Future<AccountsPushResult> push() async {events.add('accounts-push');return const AccountsPushResult();}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _RecParentPush implements PlanningPushService {
  _RecParentPush(this.events);final List<String> events;
  @override
  Future<PlanningPushResult> push() async {events.add('parent-push');return const PlanningPushResult();}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _RecLedgerPush implements LedgerPushService {
  _RecLedgerPush(this.events);final List<String> events;
  @override
  Future<LedgerPushResult> push() async {events.add('ledger-push');return const LedgerPushResult();}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _RecChild implements PlanningChildSyncService {
  _RecChild(this.events);final List<String> events;
  @override
  Future<void> sync() async {events.add('child-sync');}
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
/// Throws the real typed stop by default; while [release] is set, parks the call
/// until the test releases it and then RETURNS normally (post-return loss).
class _ControlStartup implements StartupSyncReconcileService {
  _ControlStartup(this.db);final AppDatabase db;
  int calls=0;final phaseHeld=<bool>[];
  final firstCall=Completer<void>();
  Completer<void>? reached;Completer<void>? release;
  @override
  Future<ReconcileOutcome> run({Duration? timeBudget,SyncPhaseBinding? phase}) async {
    calls++;
    phaseHeld.add(phase!=null&&phase.isBound&&phase.isCurrent&&identical(phase.database,db));
    if(!firstCall.isCompleted)firstCall.complete();
    final gate=release;
    if(gate!=null) {
      final signal=reached;if(signal!=null&&!signal.isCompleted)signal.complete();
      await gate.future;return ReconcileOutcome.ran;
    }
    throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.denial,accepted:true);
  }
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
/// Parks the body's first await (before any reconcile) while [hold] is set, so a
/// test can change admission between body entry and the reconcile decision.
class _HeldTrigger implements EpochRebootstrapTrigger {
  Completer<void>? hold;Completer<void>? reached;
  @override
  Future<RebootstrapOutcome> check(String uid) async {
    final gate=hold;
    if(gate!=null){
      final signal=reached;if(signal!=null&&!signal.isCompleted)signal.complete();
      await gate.future;
    }
    return RebootstrapOutcome.notNeeded;
  }
  @override
  dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
Future<void> _until(WidgetTester tester,bool Function() complete) async {
  for(var i=0;i<300&&!complete();i++) {
    await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
    await tester.pump(const Duration(milliseconds:10));
  }
  expect(complete(),isTrue);
}
Future<T> _observe<T>(WidgetTester tester,Future<T> work) async {
  var complete=false;T? result;Object? error;StackTrace? stack;
  work.then((value){result=value;complete=true;},onError:(Object e,StackTrace s){error=e;stack=s;complete=true;});
  await _until(tester,()=>complete);
  if(error!=null)Error.throwWithStackTrace(error!,stack!);
  return result as T;
}
Future<T> _background<T>(WidgetTester tester,Future<T> Function() start) async {
  var complete=false;T? result;Object? error;StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(start().then((value){result=value;complete=true;},
        onError:(Object e,StackTrace s){error=e;stack=s;complete=true;}));
  });
  await _until(tester,()=>complete);
  if(error!=null)Error.throwWithStackTrace(error!,stack!);
  return result as T;
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const configured=String.fromEnvironment('SUPABASE_ENV')=='local' &&
      SupabaseConfig.url=='https://example.supabase.co' && SupabaseConfig.anonKey=='anon';
  if(!configured){test('configured mounted caller qualification requires exact synthetic local defines',(){},
      skip:'No caller qualification: requires SUPABASE_ENV=local, SUPABASE_URL=https://example.supabase.co, SUPABASE_ANON_KEY=anon');return;}
  const eventId='550e8400-e29b-41d4-a716-446655440201';
  const uid='smart-cycle-owner';const serverId='00000000-0000-0000-0000-000000000456';
  late Future<http.Response> Function(http.Request) respond;
  setUpAll(() async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    await Supabase.initialize(url:'https://example.supabase.co',anonKey:'anon',
        authOptions:const FlutterAuthClientOptions(autoRefreshToken:false,detectSessionInUri:false,
            localStorage:EmptyLocalStorage(),pkceAsyncStorage:_SdkStorage()),
        httpClient:MockClient((request)=>respond(request)));
  });
  tearDownAll(()async=>Supabase.instance.dispose());
  setUp(()=>rootBundle.clear());
  const scenarios=[
    (notification:false,cut:false,engagement:false,flush:false,denial:false,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:false,flush:false,denial:true,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:false,flush:true,denial:false,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:false,flush:true,denial:true,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:false,flush:false,denial:false,ordinary:true,retire:false),
    (notification:false,cut:false,engagement:false,flush:false,denial:false,ordinary:true,retire:true),
    (notification:false,cut:false,engagement:false,flush:true,denial:false,ordinary:true,retire:false),
    (notification:false,cut:false,engagement:true,flush:false,denial:false,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:true,flush:false,denial:true,ordinary:false,retire:false),
    (notification:false,cut:false,engagement:true,flush:false,denial:false,ordinary:true,retire:false),
    (notification:false,cut:false,engagement:true,flush:false,denial:false,ordinary:true,retire:true),
    (notification:true,cut:false,engagement:false,flush:false,denial:false,ordinary:false,retire:false),
    (notification:true,cut:false,engagement:false,flush:false,denial:true,ordinary:false,retire:false),
    (notification:true,cut:false,engagement:false,flush:true,denial:false,ordinary:false,retire:false),
    (notification:true,cut:false,engagement:false,flush:true,denial:true,ordinary:false,retire:false),
    (notification:true,cut:false,engagement:false,flush:false,denial:false,ordinary:true,retire:false),
    (notification:true,cut:false,engagement:false,flush:false,denial:false,ordinary:true,retire:true),
    (notification:true,cut:true,engagement:false,flush:false,denial:false,ordinary:false,retire:false),
    (notification:true,cut:true,engagement:false,flush:true,denial:false,ordinary:false,retire:false),
  ];
  for(final scenario in scenarios) {
      final flush=scenario.flush;final denial=scenario.denial;
      final ordinary=scenario.ordinary;final retire=scenario.retire;
      final engagement=scenario.engagement;final notification=scenario.notification;final cut=scenario.cut;
      testWidgets('actual mounted ${notification?'notification':engagement?'engagement':'status'} ${flush?'flush':'normal'} denial=$denial ordinary=$ordinary retire=$retire cut=$cut',(tester) async {
        F2Fixture? fixture;void Function()? restore;
        final previousGate=CloudEgressGate.instance;
        final fixtureEgress=TestEgress(seedOn:false);fixtureEgress.owner=uid;
        ProviderContainer? container;SupabaseClient? ownedClient;
        final previousNotifications=FlutterLocalNotificationsPlatform.instance;
        final databases=<AppDatabase>[];
        Future<void>? flushProducer;Object? primaryFailure;StackTrace? primaryStack;
        final authReached=Completer<void>();final authRelease=Completer<void>();
        final restoreReached=Completer<void>();final restoreRelease=Completer<void>();
        final firstPlanning=Completer<void>();final planningRelease=Completer<void>();
        var restoreReturned=false;final probe=LedgerDatabaseProbe();
        _Notifications? observedNotification;
        final unknownRequests=<String>[];final allRequests=<http.Request>[];
        var notificationBefore=<Map<String,Object?>>[];
        bool matchesBody(http.Request r,Object? expected){try{return jsonEncode(jsonDecode(r.body))==jsonEncode(expected);}catch(_){return false;}}
        respond=(r)async {
          allRequests.add(r);
          if(r.method=='POST'&&r.url.path=='/rest/v1/rpc/mark_onboarding_completed'&&r.url.query.isEmpty&&matchesBody(r,null)) {
            return http.Response('null',200,headers:{'content-type':'application/json'},request:r);
          }
          unknownRequests.add('${r.method} ${r.url} ${r.body}');
          return http.Response('{"code":"unexpected_fixture_request","message":"not allowlisted","details":null,"hint":null}',500,
              headers:{'content-type':'application/json'},request:r);
        };
        final events=<String>[];final requests=<http.Request>[];
        final umpMethods=<String>[];final unknownUmpMethods=<String>[];
        var measuring=false;var ended=0;
        void onRun(){if(!SyncRunState.instance.running)ended++;}
        SyncRunState.instance.addListener(onRun);
        try {
          fixture=await _background(tester,()async {
            fixtureEgress.install();
            final off=CloudEgressRecord(state:notification?EgressState.off:EgressState.on,ownerUid:uid,transitionGeneration:1,reservedVersion:1);
            expect((await fixtureEgress.gate.writeRecord(off)).all,isTrue);
            for(final slot in [fixtureEgress.secure,fixtureEgress.file]){
              expect((jsonDecode(slot.value!) as Map)['records'][uid],off.toJson());
            }
            final view=await fixtureEgress.gate.view(owner:uid);
            expect(view.uncertain,isFalse);expect(view.record,off);expect(await fixtureEgress.gate.permits(),!notification);
            restore=AccountFenceAuthority.replacePersistenceForTest();
            final created=await F2Fixture.create(afterWithdraw:()async{},opener:({location,runMigrations=true,
                creation=const CreationPolicy.unrestricted()})async {
              final key=await SecureDatabaseKeyStore(storageKey:location!.keyName,
                  databaseExists:()=>File(location.dbPath).exists(),creation:creation).readOrCreateKey();
              final executor=probe.attached?LedgerDatabaseProbe():probe;executor.attached=true;
              executor.delegate=NativeDatabase(File(location.dbPath),enableMigrations:false,setup:(sqlite){
                sqlite.execute("PRAGMA cipher = 'sqlcipher';");
                if(sqlite.select('PRAGMA cipher;').isEmpty)throw StateError('caller controlled cipher unavailable');
                sqlite.execute('PRAGMA key = ${sqlString(key)};');sqlite.select('SELECT count(*) FROM sqlite_master;');
                sqlite.execute('PRAGMA foreign_keys = ON;');
              });
              return AppDatabase.open(executor:executor,location:location,runMigrations:runMigrations,creation:creation);
            });
            void remember(){final db=created.host.current?.database;if(db!=null&&!databases.contains(db))databases.add(db);}
            created.host.addListener(remember);remember();
            created.session.configureAccountScope(created.host);
            await F2Fixture.recoverSession_(Supabase.instance.client,uid);
            await created.signIn(uid);
            return created;
          });
          final owned=fixture!;final db=owned.host.current!.database;
          expect(owned.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          expect(await _background(tester,()=>AccountFenceAuthority.shared.capture(owned.session,owned.host)),isNotNull);
          final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),(_)async=>owned.support.path);
          messenger.setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'),(call)async {
            if(call.method=='hasPendingSharedMessages')return false;
            if(call.method.startsWith('consume')||call.method=='drainOfferIntents')return '[]';
            if(call.method=='captureCapabilities')return '{}';
            return null;
          });
          messenger.setMockMethodCallHandler(const MethodChannel('mali/device_timezone'),
              (call)async=>call.method=='getLocalTimezone'?'UTC':null);
          AndroidFlutterLocalNotificationsPlugin.registerWith();
          messenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'),(call)async {
            if(call.method=='getNotificationAppLaunchDetails')return {'notificationLaunchedApp':false};
            if(call.method=='initialize')return true;
            if(call.method=='pendingNotificationRequests')return <Object>[];
            return null;
          });
          messenger.setMockMessageHandler('plugins.flutter.io/google_mobile_ads/ump',(data) async {
            final method=const StandardMessageCodec().readValue(ReadBuffer(data!)) as String;
            umpMethods.add(method);
            final Object? result;
            switch(method) {
              case 'ConsentInformation#requestConsentInfoUpdate':
              case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired': result=null;
              case 'ConsentInformation#canRequestAds': result=false;
              case 'ConsentInformation#getPrivacyOptionsRequirementStatus': result=0;
              default:
                unknownUmpMethods.add(method);
                return const StandardMethodCodec().encodeErrorEnvelope(code:'unexpected_mock_method');
            }
            return const StandardMethodCodec().encodeSuccessEnvelope(result);
          });
          await _background(tester,()=>F2Fixture.recoverSession_(Supabase.instance.client,uid));
          await _background(tester,()=>AppSession.instance.markCoachMarkSeen('dashboard.v1'));
          final client=await _background(tester,()=>owned.clientFor(uid));ownedClient=client;
          final health=SyncHealth(db:db);
          await _background(tester,()=>db.customStatement("INSERT INTO transactions(id,amount,currency,type,source,direction,occurred_at,raw_message,parse_confidence,status,created_at,updated_at) VALUES ('restore-oracle',1,'SAR','payment','bank','debit','2026-01-01T00:00:00Z','',1,'confirmed','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"));
          expect(await _background(tester,()=>CloudEgressGate.instance.permits()),!notification);
          final settings=await _background(tester,()=>DriftUserSettingsRepository(db).getSettings());
          expect(settings.cloudConsentState,ConsentState.unset);expect(settings.aiConsentState,ConsentState.unset);
          expect(settings.cloudProcessingEnabled,isFalse);expect(settings.aiConsentGranted,isFalse);
          probe.afterSelect=(sql)async {if(sql=='SELECT EXISTS(SELECT 1 FROM transactions) AS d') {
            restoreReached.complete();await restoreRelease.future;restoreReturned=true;
          }};
          Future<List<Map<String,Object?>>> notificationRows()async=>[
            for(final row in await db.customSelect('SELECT * FROM notification_log_events ORDER BY rowid;').get())row.data,
          ];
          Future<void> seedNotification()async{
            final logs=NotificationLogService(db);
            final id=await logs.recordCreated(channel:'local_ios',notificationType:'caller-notification');
            await logs.recordSent(logId:id,channel:'local_ios',notificationType:'caller-notification');
            notificationBefore=await notificationRows();expect(notificationBefore,hasLength(2));
          }
          respond=(request)async {
            allRequests.add(request);
            final path=request.url.path;final query=request.url.queryParameters;
            final Object? body;final int status;
            if(request.method=='POST'&&path=='/rest/v1/rpc/mark_onboarding_completed'&&query.isEmpty&&matchesBody(request,null)) {
              body=null;status=200;
            }else if(request.method=='POST'&&path=='/rest/v1/rpc/record_engagement_event'&&query.isEmpty&&matchesBody(request,
                {'p_event_id':eventId,'p_event_type':'goal_contribution','p_occurred_at':DateTime.utc(2026,10,1).toIso8601String(),
                  'p_business_key':'caller-goal:one','p_event_version':1})) {
              body=denial?{'code':'QD001','message':'synthetic event refusal','details':null,'hint':null}:
                  ordinary?{'code':'503','message':'synthetic ordinary event error','details':null,'hint':null}:
                  {'xp':15,'level':1,'awarded':15};status=denial?400:ordinary?503:200;
            }else if(request.method=='PATCH'&&path=='/rest/v1/user_smart_inbox'&&
                query.length==2&&query['id']=='eq.$serverId'&&query['select']=='id'&&matchesBody(request,{'status':'dismissed'})) {
              body=denial?{'code':'QD001','message':'synthetic mutation refusal','details':null,'hint':null}:<Object>[{'id':serverId}];status=denial?400:200;
            }else if(request.method=='GET'&&path=='/rest/v1/user_smart_inbox'&&query.length==3&&
                query['select']=='*'&&query['order']=='updated_at.asc.nullslast,id.asc.nullslast'&&query['limit']=='200') {
              body=<Object>[];status=200;
            }else if(!notification&&request.method=='GET'&&path=='/rest/v1/feature_flag_overrides'&&
                query.length==2&&query['select']=='key,enabled'&&query['user_id']=='eq.$uid'&&request.body.isEmpty) {
              body=<Object>[];status=200;
            }else if(!notification&&request.method=='GET'&&path=='/functions/v1/catalog-versions'&&query.isEmpty&&request.body.isEmpty) {
              body={'error':'synthetic catalog unavailable'};status=503;
            }else if(notification&&request.method=='POST'&&path=='/rest/v1/notification_logs'&&
                query.length==1&&query['on_conflict']=='id'&&notificationBefore.any((row)=>matchesBody(request,{
                  'id':row['notification_log_id'],'user_id':uid,'install_id':'caller-install','notification_type':row['notification_type'],
                  'channel':row['channel'],if(Platform.isIOS||Platform.isAndroid)'device_platform':Platform.isIOS?'ios':'android',
                  'status':row['event_type']=='created'?'pending':'sent',
                  if(row['event_type']=='created')'created_at':row['occurred_at'] else 'sent_at':row['occurred_at'],
                }))) {
              body=denial?{'code':'QD001','message':'synthetic notification refusal','details':null,'hint':null}:null;status=denial?400:200;
            }else {
              unknownRequests.add('${request.method} ${request.url} ${request.body}');
              body={'code':'unexpected_fixture_request','message':'not allowlisted','details':null,'hint':null};status=500;
            }
            final lifecycleOnly=request.method=='POST'&&path=='/rest/v1/rpc/mark_onboarding_completed'&&
                query.isEmpty&&matchesBody(request,null)&&status==200;
            if(measuring&&!lifecycleOnly)requests.add(request);
            return http.Response(jsonEncode(body),status,headers:{'content-type':'application/json'},request:request);
          };
          final service=SmartInboxSyncService(db:db,isPullEnabled:()=>true,getAuthUserId:()async {
            if(measuring&&ordinary&&!engagement&&!notification) {
              if(!authReached.isCompleted)authReached.complete();
              await authRelease.future;
              throw StateError('synthetic current status preflight error');
            }
            return uid;
          },mayEgress:()async=>true,health:health);
          final eventService=EngagementEventService(db:db,isSyncEnabled:()=>true,
              getAuthUserId:()async {
                if(measuring&&engagement&&ordinary&&retire) {
                  if(!authReached.isCompleted)authReached.complete();
                  await authRelease.future;
                  throw StateError('synthetic retired engagement preflight error');
                }
                return uid;
              },mayEgress:()async=>true,health:health);
          final notificationService=NotificationLogSyncService(db:db,getClient:()=>Supabase.instance.client,
              getAuthUserId:()async{
                if(notification&&measuring&&(ordinary||cut)) {
                  if(!authReached.isCompleted)authReached.complete();await authRelease.future;
                  if(ordinary)throw StateError('synthetic notification ordinary preflight');
                }
                return Supabase.instance.client.auth.currentUser?.id;
              },getCurrentAuthUserId:()=>Supabase.instance.client.auth.currentUser?.id,
              getInstallId:()async=>'caller-install',mayEgress:()async=>true);
          observedNotification=_Notifications(events,notificationService);
          if(notification&&!flush){await _background(tester,seedNotification);measuring=true;}
          final originalNotificationCap=AppSession.instance.captureLocalWorkAuthority()!;
          container=ProviderContainer(overrides:[
            appDatabaseProvider.overrideWithValue(db),authClientProvider.overrideWithValue(client),syncHealthProvider.overrideWithValue(health),
            smartInboxSyncServiceProvider.overrideWithValue(service),planningSyncEngineProvider.overrideWithValue(_Planning(events,firstRelease:planningRelease,firstReached:firstPlanning)),
            ledgerSyncEngineProvider.overrideWithValue(_Ledger(events)),startupSyncReconcileServiceProvider.overrideWithValue(_Startup()),
            pendingSyncReconcilerProvider.overrideWithValue(_Pending()),accountsPushServiceProvider.overrideWithValue(_Accounts()),
            planningPushServiceProvider.overrideWithValue(_ParentPush()),ledgerPushServiceProvider.overrideWithValue(_LedgerPush()),
            planningChildSyncServiceProvider.overrideWithValue(_Child()),notificationLogSyncServiceProvider.overrideWithValue(observedNotification),
            senderBankMappingSyncServiceProvider.overrideWithValue(_Sender(events)),engagementEventServiceProvider.overrideWithValue(engagement?eventService:_Engagement(events,db)),
            gamificationSyncServiceProvider.overrideWithValue(_Gamification(events)),rebootstrapTriggerProvider.overrideWithValue(null),
            hasForceUpdateProvider.overrideWith((ref)async=>true),
            if(notification)notificationJourneyServiceProvider.overrideWithValue(_Journey(events)),
          ]);
          await _observe(tester,container.read(hasForceUpdateProvider.future));
          await tester.pumpWidget(UncontrolledProviderScope(container:container,
              child:MaterialApp(theme:AppTheme.light,localizationsDelegates:AppL10n.localizationsDelegates,
                  supportedLocales:AppL10n.supportedLocales,home:const AppShell())));
          await _observe(tester,restoreReached.future);
          expect(appDataRestoring.value,isTrue);
          await _observe(tester,firstPlanning.future);
          restoreRelease.complete();
          await _until(tester,()=>restoreReturned&&!appDataRestoring.value);
          expect(SyncRunState.instance.running,isTrue,reason:'normal cycle cannot yet run its finally closer');
          planningRelease.complete();
          final cap=notification&&!flush?originalNotificationCap:AppSession.instance.captureLocalWorkAuthority()!;
          if(notification&&!flush) {
            if(ordinary||cut) {
              await _observe(tester,authReached.future);
              if(retire)await _background(tester,()=>owned.signIn(uid));
              if(cut){await _background(tester,()async {
                var notified=0;void onNotification(){notified++;}
                AppSession.instance.addListener(onNotification);
                try {
                  await AppSession.instance.markCoachMarkSeen('notification-caller-generation-cut-${flush?'flush':'normal'}');
                  expect(notified,1,reason:'actual public notification retires this shell generation');
                }finally{AppSession.instance.removeListener(onNotification);}
              });}
              if(cut)expect(cap.isCurrent,isTrue);
              authRelease.complete();
            }
            await _until(tester,()=>observedNotification!.outcomes.isNotEmpty&&!SyncRunState.instance.running);
            await _background(tester,observedNotification.settle);
            if(!denial&&!retire&&!cut)await _until(tester,()=>events.contains('journey'));
          }else {
          await _until(tester,()=>ended>0&&!SyncRunState.instance.running&&events.contains('notification'));
          await _observe(tester,container.read(sessionAdConsentProvider).ensureGathered());
          await _observe(tester,container.read(notificationJourneyServiceProvider).evaluate());
          // Decided change (owner decision 3.2, Version 1 has no advertising):
          // a build without QIRSH_ADS_ENABLED compiles ads out, so the mounted
          // cycle's ad-consent gathering makes NO UMP call in any scenario
          // (before 3.2 the non-notification scenarios expected the UMP form).
          expect(umpMethods,isEmpty);
          expect(unknownUmpMethods,isEmpty);
          await _background(tester,()=>AppSession.instance.drainAdmissions());
          events.clear();requests.clear();measuring=true;
          if(notification)await _background(tester,seedNotification);
          if(engagement) {
            await _observe(tester,eventService.enqueue(eventId:eventId,eventType:'goal_contribution',
                occurredAt:DateTime.utc(2026,10,1),businessKey:'caller-goal:one'));
          }else if(!notification) { await _observe(tester,()async {
            await db.customStatement("INSERT INTO smart_inbox_items(id,server_id,type,title,status,server_created_at,synced_at,created_at,updated_at,pending_sync) VALUES ('cycle','$serverId','needs_review','Synthetic','open','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',0);");
            await DriftSmartInboxRepository(db).dismiss(serverId);
          }()); }
          if(flush) {
            flushProducer=AppSession.instance.flushPendingForSignOut();
            if(ordinary||cut) {
              await _observe(tester,authReached.future);
              if(cut){await _background(tester,()async {
                var notified=0;void onNotification(){notified++;}
                AppSession.instance.addListener(onNotification);
                try {
                  await AppSession.instance.markCoachMarkSeen('notification-caller-generation-cut-${flush?'flush':'normal'}');
                  expect(notified,1,reason:'actual public notification retires this shell generation');
                }finally{AppSession.instance.removeListener(onNotification);}
              });}
              authRelease.complete();
            }
            await _observe(tester,flushProducer);
          }else {
            final before=ended;SyncWakeup.notify();await tester.pump(const Duration(milliseconds:750));
            if(ordinary&&(!engagement||retire)) {
              await _observe(tester,authReached.future);
              if(retire)await _background(tester,()=>owned.signIn(uid));
              authRelease.complete();
            }
            await _until(tester,()=>ended>before&&!SyncRunState.instance.running);
          }
          }
          if(notification) {
            final posts=requests.where((r)=>r.url.path=='/rest/v1/notification_logs').toList();
            expect(posts,hasLength(ordinary||retire||cut?0:denial?1:2));
            expect(cap.isCurrent,!denial&&!retire);
            if(cut)expect(AppSession.instance.captureLocalWorkAuthority()!.isCurrent,isTrue);
            if(flush){expect(events.contains('sender'),!denial&&!cut);}
            else {expect(events.contains('journey'),!denial&&!retire&&!cut);}
            if(!denial&&!retire) {
              final after=await _background(tester,notificationRows);
              if(ordinary||cut){expect(after,notificationBefore);}
              else {expect(after.every((r)=>r['synced_at']!=null&&r['sync_attempt_count']==0),isTrue);}
            }
          }else if(engagement) {
            final calls=requests.where((r)=>r.url.path=='/rest/v1/rpc/record_engagement_event').toList();
            expect(calls,hasLength(retire?0:1));
            if(!retire) {
              final request=calls.single;expect(request.method,'POST');
              expect(jsonDecode(request.body),{'p_event_id':eventId,'p_event_type':'goal_contribution',
                'p_occurred_at':DateTime.utc(2026,10,1).toIso8601String(),
                'p_business_key':'caller-goal:one','p_event_version':1});
            }
            expect(events.contains('children'),isTrue);
            expect(events.contains('gamification'),!denial&&!retire);
            expect(cap.isCurrent,!denial&&!retire);
            if(retire)expect(AppSession.instance.captureLocalWorkAuthority()!.isCurrent,isTrue);
            if(!denial&&!retire) {
              final event=await _background(tester,()async=>(await db.customSelect(
                  "SELECT * FROM engagement_events WHERE event_id='$eventId';").getSingle()).data);
              expect(event['status'],ordinary?'pending':'synced');expect(event['attempt_count'],ordinary?1:0);
              final xp=await _background(tester,()=>db.customSelect('SELECT total_xp FROM xp_levels LIMIT 1;').getSingle());
              expect(xp.read<int>('total_xp'),ordinary?0:15);
            }
          }else {
          expect(requests.where((r)=>r.url.path=='/rest/v1/rpc/record_engagement_event'),isEmpty);
          if(ordinary) {
            expect(requests,isEmpty);
          }else {
            expect(requests.where((r)=>r.method=='PATCH'),hasLength(1));
            final patch=requests.firstWhere((r)=>r.method=='PATCH');expect(patch.url.path,'/rest/v1/user_smart_inbox');
            expect(patch.url.queryParameters,{'id':'eq.$serverId','select':'id'});expect(jsonDecode(patch.body),{'status':'dismissed'});
          }
          expect(cap.isCurrent,!denial&&!retire);
          if(retire)expect(AppSession.instance.captureLocalWorkAuthority()!.isCurrent,isTrue);
          if(flush) {expect(events.contains('notification'),!denial);expect(events.contains('sender'),!denial);}
          else {expect(requests.where((r)=>r.method=='GET').isNotEmpty,!denial&&!ordinary);
            expect(events.contains('children'),!denial&&!retire);
            expect(events.contains('engagement'),!denial&&!retire);expect(events.contains('gamification'),!denial&&!retire);}
          }
          if(!notification) {
            expect(allRequests.where((r)=>r.url.path=='/rest/v1/notification_logs'),isEmpty);
            expect(allRequests.where((r)=>r.method=='GET'&&r.url.path=='/rest/v1/feature_flag_overrides'),isNotEmpty);
            expect(allRequests.where((r)=>r.method=='GET'&&r.url.path=='/functions/v1/catalog-versions'),isNotEmpty);
          }
          expect(unknownRequests,isEmpty);
          expect(tester.takeException(),isNull);
        }catch(error,stack){
          primaryFailure=error;primaryStack=stack;
          debugPrint('CALLER primary failure: $error\n$stack');
          rethrow;
        }finally {
          try {
          Supabase.instance.client.auth.stopAutoRefresh();
          if(!restoreRelease.isCompleted)restoreRelease.complete();
          if(!planningRelease.isCompleted)planningRelease.complete();
          if(!authRelease.isCompleted)authRelease.complete();
          if(flushProducer!=null)await _observe(tester,flushProducer);
          if(observedNotification!=null)await _background(tester,observedNotification.settle);
          await tester.pumpWidget(const SizedBox.shrink());await tester.pump();
          await _until(tester,()=>!SyncRunState.instance.running);
          SyncRunState.instance.removeListener(onRun);
          if(fixture!=null)await _background(tester,()=>AppSession.instance.drainAdmissions());
          await _background(tester,UserActivityService.waitPendingActivityWork);
          if(ownedClient!=null)await _background(tester,()=>ownedClient!.dispose());
          if(container!=null) {
            await _observe(tester,container.read(sessionAdConsentProvider).ensureGathered());
          }
          expect(unknownUmpMethods,isEmpty);
          if(notification)expect(umpMethods,isEmpty);
          container?.dispose();
          if(fixture!=null) {
            await _background(tester,()=>fixture!.host.lock());
            Supabase.instance.client.auth.stopAutoRefresh();
            await _background(tester,UserActivityService.waitPendingActivityWork);
            final signedOut=fixture.host.current!.database;
            await _background(tester,()=>signedOut.close());
            for(final db in databases) { expect(db.lifecycleState,DatabaseLifecycleState.closed); }
            expect(await _background(tester,()=>AccountFenceAuthority.shared.initialize()),isTrue);
            expect(AccountFenceAuthority.shared.store.ready,isTrue);
            AppSession.instance.configureAccountScope(null);
            await _background(tester,()=>fixture!.dispose());
            for(final db in databases) { expect(db.lifecycleState,DatabaseLifecycleState.closed); }
            expect(await _background(tester,()=>AccountFenceAuthority.shared.initialize()),isTrue);
            expect(AccountFenceAuthority.shared.store.ready,isTrue);
          }
          expect(unknownRequests,isEmpty);
          restore?.call();
          expect(fixtureEgress.gate.inFlightCount,0);CloudEgressGate.instance=previousGate;
          final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          FlutterLocalNotificationsPlatform.instance=previousNotifications;
          messenger.setMockMessageHandler('plugins.flutter.io/google_mobile_ads/ump',null);
          for(final name in ['plugins.flutter.io/path_provider','money_companion/native_capture','dexterous.com/flutter/local_notifications','mali/device_timezone']) {
            messenger.setMockMethodCallHandler(MethodChannel(name),null);
          }
          } catch(error,stack) {
            if(primaryFailure!=null) {
              debugPrint('CALLER cleanup failure after primary: $error\n$stack');
              Error.throwWithStackTrace(primaryFailure,primaryStack!);
            }
            rethrow;
          }
        }
      });
  }

  // ── Default-account reconcile stop controls (actual AppShell) ─────────────
  // The startup reconcile fake throws the REAL typed stop (or loses the original
  // lifetime and then returns normally). Nothing is caught inside a mock: the
  // actual AppShell must end the normal body / the sign-out flush by itself.
  // Completion is observed from the actual run/flush futures, never from a
  // settle duration, and the oracle does not wait for parents (the body is
  // intentionally stopped BEFORE them).
  Future<void> stopControl(WidgetTester tester,{required bool flush,required bool lose,bool late=false}) async {
    F2Fixture? fixture;void Function()? restore;
    final previousGate=CloudEgressGate.instance;
    final fixtureEgress=TestEgress(seedOn:false);fixtureEgress.owner=uid;
    ProviderContainer? container;SupabaseClient? ownedClient;
    final previousNotifications=FlutterLocalNotificationsPlatform.instance;
    final databases=<AppDatabase>[];
    Future<void>? flushProducer;Object? primaryFailure;StackTrace? primaryStack;
    final probe=LedgerDatabaseProbe();
    _Notifications? observedNotification;
    final unknownRequests=<String>[];
    final events=<String>[];final umpMethods=<String>[];final unknownUmpMethods=<String>[];
    var ended=0;
    void onRun(){if(!SyncRunState.instance.running)ended++;}
    SyncRunState.instance.addListener(onRun);
    bool matchesNull(http.Request r){try{return jsonEncode(jsonDecode(r.body))==jsonEncode(null);}catch(_){return false;}}
    respond=(request)async {
      final path=request.url.path;final query=request.url.queryParameters;
      final Object? body;final int status;
      if(request.method=='POST'&&path=='/rest/v1/rpc/mark_onboarding_completed'&&query.isEmpty&&matchesNull(request)) {
        body=null;status=200;
      }else if(request.method=='GET'&&path=='/rest/v1/feature_flag_overrides'&&
          query.length==2&&query['select']=='key,enabled'&&query['user_id']=='eq.$uid'&&request.body.isEmpty) {
        body=<Object>[];status=200;
      }else if(request.method=='GET'&&path=='/functions/v1/catalog-versions'&&query.isEmpty&&request.body.isEmpty) {
        body={'error':'synthetic catalog unavailable'};status=503;
      }else {
        unknownRequests.add('${request.method} ${request.url} ${request.body}');
        body={'code':'unexpected_fixture_request','message':'not allowlisted','details':null,'hint':null};status=500;
      }
      return http.Response(jsonEncode(body),status,headers:{'content-type':'application/json'},request:request);
    };
    try {
      fixture=await _background(tester,()async {
        fixtureEgress.install();
        const on=CloudEgressRecord(state:EgressState.on,ownerUid:uid,transitionGeneration:1,reservedVersion:1);
        expect((await fixtureEgress.gate.writeRecord(on)).all,isTrue);
        expect(await fixtureEgress.gate.permits(),isTrue);
        restore=AccountFenceAuthority.replacePersistenceForTest();
        final created=await F2Fixture.create(afterWithdraw:()async{},opener:({location,runMigrations=true,
            creation=const CreationPolicy.unrestricted()})async {
          final key=await SecureDatabaseKeyStore(storageKey:location!.keyName,
              databaseExists:()=>File(location.dbPath).exists(),creation:creation).readOrCreateKey();
          final executor=probe.attached?LedgerDatabaseProbe():probe;executor.attached=true;
          executor.delegate=NativeDatabase(File(location.dbPath),enableMigrations:false,setup:(sqlite){
            sqlite.execute("PRAGMA cipher = 'sqlcipher';");
            if(sqlite.select('PRAGMA cipher;').isEmpty)throw StateError('caller controlled cipher unavailable');
            sqlite.execute('PRAGMA key = ${sqlString(key)};');sqlite.select('SELECT count(*) FROM sqlite_master;');
            sqlite.execute('PRAGMA foreign_keys = ON;');
          });
          return AppDatabase.open(executor:executor,location:location,runMigrations:runMigrations,creation:creation);
        });
        void remember(){final db=created.host.current?.database;if(db!=null&&!databases.contains(db))databases.add(db);}
        created.host.addListener(remember);remember();
        created.session.configureAccountScope(created.host);
        await F2Fixture.recoverSession_(Supabase.instance.client,uid);
        await created.signIn(uid);
        return created;
      });
      final owned=fixture!;final db=owned.host.current!.database;
      final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),(_)async=>owned.support.path);
      messenger.setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'),(call)async {
        if(call.method=='hasPendingSharedMessages')return false;
        if(call.method.startsWith('consume')||call.method=='drainOfferIntents')return '[]';
        if(call.method=='captureCapabilities')return '{}';
        return null;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('mali/device_timezone'),
          (call)async=>call.method=='getLocalTimezone'?'UTC':null);
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      messenger.setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'),(call)async {
        if(call.method=='getNotificationAppLaunchDetails')return {'notificationLaunchedApp':false};
        if(call.method=='initialize')return true;
        if(call.method=='pendingNotificationRequests')return <Object>[];
        return null;
      });
      messenger.setMockMessageHandler('plugins.flutter.io/google_mobile_ads/ump',(data) async {
        final method=const StandardMessageCodec().readValue(ReadBuffer(data!)) as String;
        umpMethods.add(method);
        final Object? result;
        switch(method) {
          case 'ConsentInformation#requestConsentInfoUpdate':
          case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired': result=null;
          case 'ConsentInformation#canRequestAds': result=false;
          case 'ConsentInformation#getPrivacyOptionsRequirementStatus': result=0;
          default:
            unknownUmpMethods.add(method);
            return const StandardMethodCodec().encodeErrorEnvelope(code:'unexpected_mock_method');
        }
        return const StandardMethodCodec().encodeSuccessEnvelope(result);
      });
      await _background(tester,()=>F2Fixture.recoverSession_(Supabase.instance.client,uid));
      await _background(tester,()=>AppSession.instance.markCoachMarkSeen('dashboard.v1'));
      final client=await _background(tester,()=>owned.clientFor(uid));ownedClient=client;
      final health=SyncHealth(db:db);
      final settings=await _background(tester,()=>DriftUserSettingsRepository(db).getSettings());
      expect(settings.cloudProcessingEnabled,isFalse);
      final service=SmartInboxSyncService(db:db,isPullEnabled:()=>true,getAuthUserId:()async=>uid,
          mayEgress:()async=>true,health:health);
      final notificationService=NotificationLogSyncService(db:db,getClient:()=>Supabase.instance.client,
          getAuthUserId:()async=>Supabase.instance.client.auth.currentUser?.id,
          getCurrentAuthUserId:()=>Supabase.instance.client.auth.currentUser?.id,
          getInstallId:()async=>'caller-install',mayEgress:()async=>true);
      observedNotification=_Notifications(events,notificationService);
      final control=_ControlStartup(db);final trigger=_HeldTrigger();
      container=ProviderContainer(overrides:[
        appDatabaseProvider.overrideWithValue(db),authClientProvider.overrideWithValue(client),syncHealthProvider.overrideWithValue(health),
        smartInboxSyncServiceProvider.overrideWithValue(service),planningSyncEngineProvider.overrideWithValue(_Planning(events)),
        ledgerSyncEngineProvider.overrideWithValue(_Ledger(events)),startupSyncReconcileServiceProvider.overrideWithValue(control),
        pendingSyncReconcilerProvider.overrideWithValue(_Pending()),accountsPushServiceProvider.overrideWithValue(_RecAccounts(events)),
        planningPushServiceProvider.overrideWithValue(_RecParentPush(events)),ledgerPushServiceProvider.overrideWithValue(_RecLedgerPush(events)),
        planningChildSyncServiceProvider.overrideWithValue(_RecChild(events)),notificationLogSyncServiceProvider.overrideWithValue(observedNotification),
        senderBankMappingSyncServiceProvider.overrideWithValue(_Sender(events)),engagementEventServiceProvider.overrideWithValue(_Engagement(events,db)),
        gamificationSyncServiceProvider.overrideWithValue(_Gamification(events)),rebootstrapTriggerProvider.overrideWithValue(late?trigger:null),
        hasForceUpdateProvider.overrideWith((ref)async=>true),
      ]);
      // A parked startup call (post-return loss) is armed BEFORE the normal
      // cold-start body can reach it; the flush variants arm it later.
      if(!flush&&lose){control.reached=Completer<void>();control.release=Completer<void>();}
      await _observe(tester,container.read(hasForceUpdateProvider.future));
      await tester.pumpWidget(UncontrolledProviderScope(container:container,
          child:MaterialApp(theme:AppTheme.light,localizationsDelegates:AppL10n.localizationsDelegates,
              supportedLocales:AppL10n.supportedLocales,home:const AppShell())));
      const bodyEvents=['parents','ledger','children'];
      if(!flush) {
        if(lose) {
          await _observe(tester,control.reached!.future);
          await _background(tester,()=>owned.signIn(uid)); // the original lifetime ends mid-startup
          control.release!.complete();control.release=null;
        }else {
          await _observe(tester,control.firstCall.future);
        }
        await _until(tester,()=>ended>0&&!SyncRunState.instance.running);
        expect(control.phaseHeld.first,isTrue,reason:'startup received a bound, current phase on the original database');
        for(final event in bodyEvents){expect(events,isNot(contains(event)),reason:'$event ran after the startup stop/loss');}
        if(late) {
          // The first cycle stopped at startup (calls==1). The next cycle ENTERS with
          // no admitted work (the host is locked: actual public API, no session
          // status change, so the retained generation stays admitted), parks at its
          // first await, and only then is the account really admitted again. That
          // original run must never reach the reconcile through the later admission.
          final callsAfterFirst=control.calls;final before=ended;
          trigger.hold=Completer<void>();trigger.reached=Completer<void>();
          await _background(tester,()=>owned.host.lock());
          expect(AppSession.instance.captureLocalWorkAuthority(),isNull,reason:'no admitted work when the run is entered');
          SyncWakeup.notify();await tester.pump(const Duration(milliseconds:750));
          await _observe(tester,trigger.reached!.future);
          await _background(tester,()=>owned.host.activate(uid));
          expect(AppSession.instance.captureLocalWorkAuthority()?.isCurrent,isTrue,reason:'a real later admission exists');
          trigger.hold!.complete();trigger.hold=null;
          await _until(tester,()=>ended>before&&!SyncRunState.instance.running);
          expect(control.calls,callsAfterFirst,reason:'the original run used a later admission to reach the reconcile');
          for(final event in bodyEvents){expect(events,isNot(contains(event)));}
        }else if(!lose) {
          // The stop left the one-shot reconcile unlatched: the next cycle asks again.
          final callsAfterFirst=control.calls;final before=ended;
          SyncWakeup.notify();await tester.pump(const Duration(milliseconds:750));
          await _until(tester,()=>ended>before&&!SyncRunState.instance.running);
          expect(control.calls,greaterThan(callsAfterFirst));
          for(final event in bodyEvents){expect(events,isNot(contains(event)));}
        }
      }else {
        // The cold-start cycle stops at startup; wait until it and the engagement
        // chain are complete before the flush window opens.
        await _until(tester,()=>ended>0&&!SyncRunState.instance.running&&events.contains('notification'));
        await _background(tester,()=>AppSession.instance.drainAdmissions());
        events.clear();
        final callsBefore=control.calls;
        if(lose){control.reached=Completer<void>();control.release=Completer<void>();}
        flushProducer=AppSession.instance.flushPendingForSignOut();
        if(lose) {
          await _observe(tester,control.reached!.future);
          await _background(tester,()async {
            var notified=0;void onNotification(){notified++;}
            AppSession.instance.addListener(onNotification);
            try {
              await AppSession.instance.markCoachMarkSeen('default-backfill-flush-generation-cut');
              expect(notified,1,reason:'actual public notification retires this shell generation');
            }finally{AppSession.instance.removeListener(onNotification);}
          });
          control.release!.complete();control.release=null;
        }
        await _observe(tester,flushProducer);
        expect(control.calls,callsBefore+1);
        expect(control.phaseHeld.last,isTrue,reason:'flush startup received a bound, current phase');
        expect(events,isEmpty,reason:'no later push/notification/sender work after the startup stop/loss: $events');
      }
      expect(unknownRequests,isEmpty);
      expect(tester.takeException(),isNull);
    }catch(error,stack){
      primaryFailure=error;primaryStack=stack;
      debugPrint('CALLER primary failure: $error\n$stack');
      rethrow;
    }finally {
      try {
        Supabase.instance.client.auth.stopAutoRefresh();
        if(flushProducer!=null)await _observe(tester,flushProducer);
        if(observedNotification!=null)await _background(tester,observedNotification.settle);
        await tester.pumpWidget(const SizedBox.shrink());await tester.pump();
        await _until(tester,()=>!SyncRunState.instance.running);
        SyncRunState.instance.removeListener(onRun);
        if(fixture!=null)await _background(tester,()=>AppSession.instance.drainAdmissions());
        await _background(tester,UserActivityService.waitPendingActivityWork);
        if(ownedClient!=null)await _background(tester,()=>ownedClient!.dispose());
        if(container!=null) {
          await _observe(tester,container.read(sessionAdConsentProvider).ensureGathered());
        }
        expect(unknownUmpMethods,isEmpty);
        container?.dispose();
        if(fixture!=null) {
          await _background(tester,()=>fixture!.host.lock());
          Supabase.instance.client.auth.stopAutoRefresh();
          await _background(tester,UserActivityService.waitPendingActivityWork);
          final signedOut=fixture.host.current!.database;
          await _background(tester,()=>signedOut.close());
          for(final db in databases) { expect(db.lifecycleState,DatabaseLifecycleState.closed); }
          expect(await _background(tester,()=>AccountFenceAuthority.shared.initialize()),isTrue);
          expect(AccountFenceAuthority.shared.store.ready,isTrue);
          AppSession.instance.configureAccountScope(null);
          await _background(tester,()=>fixture!.dispose());
          for(final db in databases) { expect(db.lifecycleState,DatabaseLifecycleState.closed); }
          expect(await _background(tester,()=>AccountFenceAuthority.shared.initialize()),isTrue);
          expect(AccountFenceAuthority.shared.store.ready,isTrue);
        }
        expect(unknownRequests,isEmpty);
        restore?.call();
        expect(fixtureEgress.gate.inFlightCount,0);CloudEgressGate.instance=previousGate;
        final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        FlutterLocalNotificationsPlatform.instance=previousNotifications;
        messenger.setMockMessageHandler('plugins.flutter.io/google_mobile_ads/ump',null);
        for(final name in ['plugins.flutter.io/path_provider','money_companion/native_capture','dexterous.com/flutter/local_notifications','mali/device_timezone']) {
          messenger.setMockMethodCallHandler(MethodChannel(name),null);
        }
      } catch(error,stack) {
        if(primaryFailure!=null) {
          debugPrint('CALLER cleanup failure after primary: $error\n$stack');
          Error.throwWithStackTrace(primaryFailure,primaryStack!);
        }
        rethrow;
      }
    }
  }
  for(final flush in [false,true]) {
    for(final lose in [false,true]) {
      testWidgets('actual mounted default-account startup ${lose?'post-return lifetime loss':'typed stop'} ${flush?'flush':'normal'}',
          (tester)=>stopControl(tester,flush:flush,lose:lose));
    }
  }
  testWidgets('actual mounted default-account startup entered without admitted work stays restricted after a real later admission',
      (tester)=>stopControl(tester,flush:false,lose:false,late:true));
}
