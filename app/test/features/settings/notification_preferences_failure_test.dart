import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
class _Keys implements DatabaseKeyStore {
 @override Future<String> readOrCreateKey() async => 'prefs-memory';
 @override Future<String?> readStoredKey() async => 'prefs-memory';
}
class _FailureSettings extends DriftUserSettingsRepository {
 _FailureSettings(super.db);
 int calls=0;Completer<void> gate=Completer<void>();final inputs=<String>[];
 @override Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
  calls++;inputs.add(settings.notificationsJson);await gate.future;throw StateError('private_preference_failure');
 }
}
Future<Map<String,List<Map<String,Object?>>>> _sql(AppDatabase db) async {
 final names=await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
 return {for(final n in names)n.read<String>('name'):[for(final row in await db.customSelect('SELECT * FROM "${n.read<String>('name')}"').get())row.data]};
}
void main(){
 for(final quiet in [false,true]) {for(final lang in ['ar','en']){for(final dark in [false,true]){
 testWidgets('actual notification ${quiet?'quiet':'switch'} failure $lang dark$dark',(tester) async {
  tester.view.physicalSize=const Size(375,667);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
  final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),(call) async=>null);
  var hideMirrorCalls=0;NativeCaptureBridge.debugTreatHostAsNative=true;
  messenger.setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'),(call) async {if(call.method=='setHideCaptureDetails')hideMirrorCalls++;return null;});
  addTearDown((){NativeCaptureBridge.debugTreatHostAsNative=false;messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),null);messenger.setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'),null);});
  final db=await AppDatabase.open(executor:NativeDatabase.memory(),keyStore:_Keys(),initialLanguage:lang);
  // Real fixture preference saved before snapshot, not an accepted tested action.
  final seed=DriftUserSettingsRepository(db);final old=await seed.getSettings();await seed.saveSettings(old.copyWith(notificationsJson:jsonEncode(NotificationPreferences(quietHoursEnabled:quiet).toJson())));
  final before=await _sql(db);final repo=_FailureSettings(db);
  await tester.pumpWidget(ProviderScope(overrides:[appDatabaseProvider.overrideWithValue(db),userSettingsRepositoryProvider.overrideWithValue(repo)],child:MaterialApp(theme:dark?AppTheme.dark:AppTheme.light,locale:Locale(lang),supportedLocales:AppL10n.supportedLocales,localizationsDelegates:AppL10n.localizationsDelegates,home:SettingsScreen(page:quiet?SettingsPage.alerts:SettingsPage.capture))));// v2: quiet hours live on «تنبيهاتك», capture switches on «رصد العمليات».
  for(var i=0;i<5;i++){await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:50)));await tester.pump(const Duration(milliseconds:100));}await tester.pumpAndSettle();
  final l=AppL10n.of(tester.element(find.byType(SettingsScreen)));
  Future<void> reveal(Finder finder) async {await tester.scrollUntilVisible(finder,300,scrollable:find.byType(Scrollable).first);await tester.pumpAndSettle();}
  Finder target;
  if(quiet){await reveal(find.text(l.setEditQuietHours));await tester.tap(find.text(l.setEditQuietHours));await tester.pumpAndSettle();final context=tester.element(find.text(l.setStarts));await tester.tap(find.text(Formatters.hourOfDay(23,context)).last);await tester.pumpAndSettle();await tester.scrollUntilVisible(find.text(Formatters.hourOfDay(22,context)),240,scrollable:find.byType(Scrollable).last);await tester.tap(find.text(Formatters.hourOfDay(22,context)).last);await tester.pumpAndSettle();target=find.widgetWithText(FilledButton,l.setSave);}else{await reveal(find.text(l.setNotifyOnCapture));target=find.ancestor(of:find.text(l.setNotifyOnCapture),matching:find.byType(SwitchListTile));}
  await Scrollable.ensureVisible(tester.element(target),alignment:.5);await tester.pumpAndSettle();await tester.tap(target);await tester.pump();
  final disabled=quiet?tester.widget<FilledButton>(target).onPressed==null:tester.widget<SwitchListTile>(target).onChanged==null;
  final pickerDisabled=!quiet||tester.widgetList<GlassDropdownField<int>>(find.byType(GlassDropdownField<int>)).every((w)=>w.onChanged==null);
  await tester.tap(target,warnIfMissed:false);await tester.pump();final firstCalls=repo.calls;
  repo.gate.complete();await tester.pumpAndSettle();final firstException=tester.takeException();final errorVisible=find.text(l.setupSaveFailed).evaluate().isNotEmpty;
  final sheetRetained=!quiet||find.widgetWithText(FilledButton,l.setSave).evaluate().isNotEmpty;
  await tester.pump(const Duration(seconds:4));await tester.pumpAndSettle();await Scrollable.ensureVisible(tester.element(target),alignment:.5);await tester.pumpAndSettle();repo.gate=Completer<void>();await tester.tap(target);await tester.pump();repo.gate.complete();await tester.pumpAndSettle();final retryException=tester.takeException();
  await tester.pump(const Duration(seconds:4));await tester.pumpAndSettle();
  if(quiet){Navigator.of(tester.element(target)).pop();await tester.pumpAndSettle();}
  final after=await _sql(db);await tester.pumpWidget(const SizedBox.shrink());await tester.pumpAndSettle();await db.close();
  expect(disabled,isTrue);expect(pickerDisabled,isTrue);expect(firstCalls,1);expect(repo.calls,2);expect(firstException,isNull);expect(retryException,isNull);expect(errorVisible,isTrue);expect(sheetRetained,isTrue);expect(after,before);expect(hideMirrorCalls,0);expect(repo.inputs.toSet(),hasLength(1));final expected=NotificationPreferences(quietHoursEnabled:quiet).copyWith(quietHoursStartHour:quiet?22:23,captureLight:quiet?true:false);expect(jsonDecode(repo.inputs.first),expected.toJson());
 });}}}
}
