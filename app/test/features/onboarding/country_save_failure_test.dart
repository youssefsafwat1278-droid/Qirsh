import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/country_save_failure_surfaces.dart';
class _Keys implements DatabaseKeyStore {
 @override Future<String> readOrCreateKey() async => 'country-test-memory';
 @override Future<String?> readStoredKey() async => 'country-test-memory';
}
Future<String> snapshot(AppDatabase db) async {
 final tables=await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
 return jsonEncode({for(final row in tables) row.read<String>('name'):(await db.customSelect('SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get()).map((r)=>r.data).toList()});
}
void main() {
 for(final lang in ['ar','en']) {
  for(final dark in [false,true]) {
   testWidgets('country real usecase held error retry before write $lang $dark',(tester) async {
    tester.view.physicalSize=const Size(375,667);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
    final db=await AppDatabase.open(executor:NativeDatabase.memory(),keyStore:_Keys());
    final settings=FailureOnlyCountrySettings(db);final before=await snapshot(db);
    await tester.pumpWidget(ProviderScope(overrides:[appDatabaseProvider.overrideWithValue(db),userSettingsRepositoryProvider.overrideWithValue(settings),saveCountryCurrencyUseCaseProvider.overrideWithValue(SaveCountryCurrencyUseCase(settings,DriftAccountRepository(db),DriftTransactionRepository(db)))],child:MaterialApp(theme:dark?AppTheme.dark:AppTheme.light,locale:Locale(lang),supportedLocales:AppL10n.supportedLocales,localizationsDelegates:AppL10n.localizationsDelegates,home:const OnboardingSetupScreen())));
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:60)));await tester.pumpAndSettle();
    final l=AppL10n.of(tester.element(find.byType(OnboardingSetupScreen)));final egypt=find.text('${l.countryEG}\n🇪🇬 EGP');
    await tester.ensureVisible(egypt);await tester.pumpAndSettle();await tester.tap(egypt);
    for(var i=0;i<4;i++){await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:30)));await tester.pump();}
    expect(settings.calls,1);final pill=find.ancestor(of:egypt,matching:find.byType(InkWell)).first;expect(tester.widget<InkWell>(pill).onTap,isNull);
    await tester.tap(egypt,warnIfMissed:false);await tester.pump();expect(settings.calls,1);
    settings.release();await tester.pumpAndSettle();expect(find.text(l.setupSaveFailed),findsOneWidget);expect(find.textContaining('private_synthetic'),findsNothing);expect(tester.widget<InkWell>(pill).onTap,isNotNull);
    await tester.tap(egypt);await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:80)));await tester.pumpAndSettle();expect(settings.calls,2);expect(await snapshot(db),before);expect(tester.takeException(),isNull);
    await tester.pump(const Duration(seconds:4));await tester.pumpAndSettle();await tester.pumpWidget(const SizedBox.shrink());await tester.pumpAndSettle();await db.close();
   });
  }
 }
}
