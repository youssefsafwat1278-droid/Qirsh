import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
class _Keys implements DatabaseKeyStore {
 @override Future<String> readOrCreateKey() async => 'shortcut-memory';
 @override Future<String?> readStoredKey() async => 'shortcut-memory';
}
void main() {
 for(final lang in ['ar','en']) {
  for(final dark in [false,true]) {
   testWidgets('complete shortcut copy and Installed reachable $lang $dark',(tester) async {
    tester.view.physicalSize=const Size(375,667);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
    final db=await AppDatabase.open(executor:NativeDatabase.memory(),keyStore:_Keys());
    final before=(await db.customSelect('SELECT * FROM user_settings').get()).map((r)=>r.data).toList();
    await tester.pumpWidget(ProviderScope(overrides:[appDatabaseProvider.overrideWithValue(db)],child:MaterialApp(theme:dark?AppTheme.dark:AppTheme.light,locale:Locale(lang),supportedLocales:AppL10n.supportedLocales,localizationsDelegates:AppL10n.localizationsDelegates,home:const OnboardingSetupScreen(entry:OnboardingSetupEntry.captureGuide))));
    await tester.runAsync(() async=>Future<void>.delayed(const Duration(milliseconds:100)));await tester.pumpAndSettle();
    final l=AppL10n.of(tester.element(find.byType(OnboardingSetupScreen)));
    await tester.ensureVisible(find.text(l.shortcutManualSteps));
    await tester.tap(find.text(l.shortcutManualSteps));
    await tester.pumpAndSettle();
    final horizontal=find.byWidgetPredicate((w)=>w is Scrollable && w.axisDirection==AxisDirection.right || w is Scrollable && w.axisDirection==AxisDirection.left);
    final state=tester.state<ScrollableState>(horizontal.first);state.position.jumpTo(920);await tester.pumpAndSettle();
    final body=find.text(l.setupShortcutStep5Body);expect(body,findsOneWidget);
    final paragraph=tester.renderObject<RenderParagraph>(body);final truncated=paragraph.didExceedMaxLines;
    final installed=find.text(l.setupShortcutCta);await tester.ensureVisible(installed);await tester.pumpAndSettle();
    await tester.tap(installed);await tester.pumpAndSettle();
    final finish=find.widgetWithText(FilledButton,l.setupFinishCta);expect(tester.widget<FilledButton>(finish).onPressed,isNotNull);
    expect((await db.customSelect('SELECT * FROM user_settings').get()).map((r)=>r.data).toList(),before);
    expect(tester.takeException(),isNull);await tester.pumpWidget(const SizedBox.shrink());await tester.pumpAndSettle();await db.close();
    expect(truncated,isFalse,reason:'Instruction5 must expose its entire original text');
   },variant:TargetPlatformVariant.only(TargetPlatform.iOS));
  }
 }
}
