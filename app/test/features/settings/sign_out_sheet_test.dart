import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/settings/sign_out_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// WP-3b — SYNC-Q8 sheet defaults and SYNC-Q2 warn-and-keep.

const _pending = UnsyncedInventory(
  ledgerOutbox: 3,
  planningOutbox: 0,
  smartInboxPending: 0,
  localOnlyCards: 0,
  senderMappingsPending: 0,
  notificationLogPending: 0,
);
const _clean = UnsyncedInventory(
  ledgerOutbox: 0,
  planningOutbox: 0,
  smartInboxPending: 0,
  localOnlyCards: 0,
  senderMappingsPending: 0,
  notificationLogPending: 0,
);

Future<SignOutChoice?> _open(
  WidgetTester tester, {
  UnsyncedInventory? pending,
  Locale locale = const Locale('en'),
  Future<void> Function()? act,
  bool? cloudSyncOn,
}) async {
  SignOutChoice? result;
  var done = false;
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: const [
      ...AppL10n.localizationsDelegates,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await showSignOutSheet(context,
              pending: pending, cloudSyncOn: cloudSyncOn);
          done = true;
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (act != null) {
    await act();
    await tester.pumpAndSettle();
    expect(done, isTrue);
  }
  return result;
}

void main() {
  testWidgets('the primary, default action keeps the encrypted data',
      (tester) async {
    await _open(tester);
    final primary = find.byKey(const Key('signOutKeepData'));
    expect(primary, findsOneWidget);
    expect(tester.widget(primary), isA<FilledButton>(),
        reason: 'the default action is the filled, primary button');
    expect(find.text('Sign out'), findsNWidgets(2));
    expect(find.byKey(const Key('signOutRemoveData')), findsNothing);
  });

  testWidgets('tapping the default returns keepData', (tester) async {
    SignOutChoice? choice;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showSignOutSheet(context);
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('signOutKeepData')));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(choice, SignOutChoice.keepData);
  });

  testWidgets('unsynced work WARNS but never blocks or replaces the default',
      (tester) async {
    await _open(tester, pending: _pending);
    expect(find.byKey(const Key('signOutUnsyncedWarning')), findsOneWidget);
    expect(find.textContaining('syncs when you sign back in'), findsOneWidget);
    // Both choices remain available and enabled.
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('signOutKeepData')))
            .onPressed,
        isNotNull);
    expect(find.byKey(const Key('signOutRemoveData')), findsNothing);
  });

  testWidgets('says plainly that the data stays on this device and returns on '
      'sign-in, with one action and no encrypted keep/remove choice',
      (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('signOutDataStays')), findsOneWidget);
    expect(find.text(lookupAppL10n(const Locale('en')).signOutDataStays),
        findsOneWidget);
    expect(find.textContaining('ncrypted'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('the Arabic sheet says the data stays on the device',
      (tester) async {
    await _open(tester, locale: const Locale('ar'));
    expect(find.text(lookupAppL10n(const Locale('ar')).signOutDataStays),
        findsOneWidget);
  });

  testWidgets('no warning when nothing is unsynced', (tester) async {
    await _open(tester, pending: _clean);
    expect(find.byKey(const Key('signOutUnsyncedWarning')), findsNothing);
  });

  testWidgets('the Arabic sheet renders the proposed copy', (tester) async {
    await _open(tester, locale: const Locale('ar'));
    expect(find.text('تسجيل الخروج'), findsNWidgets(2));
    expect(find.byKey(const Key('signOutRemoveData')), findsNothing);
  });

  // V1-067 / decision B26 (a): with Smart Analysis & Cloud Sync off nothing
  // syncs on sign-in, so the sheet must not say it does.
  testWidgets('Cloud off: unsynced warning says changes are not synced',
      (tester) async {
    await _open(tester, pending: _pending, cloudSyncOn: false);
    expect(find.byKey(const Key('signOutUnsyncedWarning')), findsOneWidget);
    expect(find.textContaining('syncs when you sign back in'), findsNothing);
    expect(
        find.textContaining('are not synced while Smart Analysis & Cloud Sync '
            'is off'),
        findsOneWidget);
  });

  testWidgets('Cloud off, nothing pending: a note says changes stay local',
      (tester) async {
    await _open(tester, pending: _clean, cloudSyncOn: false);
    expect(find.byKey(const Key('signOutUnsyncedWarning')), findsNothing);
    expect(find.byKey(const Key('signOutCloudOffNote')), findsOneWidget);
  });

  testWidgets('Cloud off in Arabic says the changes are not synced',
      (tester) async {
    await _open(tester,
        pending: _pending, cloudSyncOn: false, locale: const Locale('ar'));
    expect(find.textContaining('تُزامَن عند تسجيل دخولك'), findsNothing);
    expect(find.textContaining('ولا تُزامَن ما دام التحليل الذكي'),
        findsOneWidget);
  });

  testWidgets('Cloud on keeps the sync-on-sign-in sentence', (tester) async {
    await _open(tester, pending: _pending, cloudSyncOn: true);
    expect(find.textContaining('syncs when you sign back in'), findsOneWidget);
    expect(find.byKey(const Key('signOutCloudOffNote')), findsNothing);
  });
}
