import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// RT-02 — a pasted DECLINED payment used to answer "could not be read — add it
// manually", inviting the user to record a purchase that never happened.

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'paste-declined-memory-only';
  @override
  Future<String?> readStoredKey() async => 'paste-declined-memory-only';
}

/// Answers "no transaction" for every message, as the real use case does for
/// a declined payment and for an unreadable one.
class _NoTransactionIngest implements IngestCapturedMessageUseCase {
  @override
  Future<CapturedMessageResult> fromCapturedMessage(
    CapturedMessage message, {
    bool onDeviceOnly = false,
    CaptureCommit? capture,
    bool forceLocalAutoConfirm = false,
  }) async {
    return CapturedMessageResult(
      disposition: CapturedMessageDisposition.values.first,
      addTransactionResult: AddTransactionResult.notTransaction(
        ParseResult.notTransaction(),
        aiFailureReason: 'on_device_only',
      ),
      notificationStableId: 'synthetic',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  Future<AppL10n> analyse(
      WidgetTester tester, String language, String text) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        ingestCapturedMessageUseCaseProvider
            .overrideWithValue(_NoTransactionIngest()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: ManualPasteScreen(onTransactionAdded: (_) {}),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(tester.element(find.byType(ManualPasteScreen)));
    final analyze = find.widgetWithText(FilledButton, l10n.pasteAnalyse);
    await tester.ensureVisible(analyze);
    await tester.pumpAndSettle();
    await tester.tap(analyze);
    await tester.pump(const Duration(milliseconds: 400));
    return l10n;
  }

  for (final language in ['en', 'ar']) {
    testWidgets('a declined payment says nothing was recorded ($language)',
        (tester) async {
      final l10n = await analyse(tester, language,
          'Purchase of SAR 250.00 at Test Shop was declined.');
      expect(find.text(l10n.pasteNotCompleted), findsOneWidget);
      expect(find.text(l10n.pasteNotATransaction), findsNothing);
      expect(find.text(l10n.pasteUnreadableOnDevice), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an unreadable message keeps the existing wording ($language)',
        (tester) async {
      final l10n = await analyse(tester, language, 'Hello from Test Shop 123');
      expect(find.text(l10n.pasteNotCompleted), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }

  // LR-08 — a declined message kept in Smart Inbox for analysis was told
  // "nothing was recorded"; it gets the saved-for-analysis wording instead.
  test('a declined message saved to Smart Inbox is not told nothing was '
      'recorded', () {
    const declined = 'Purchase of SAR 250.00 at Test Shop was declined.';
    expect(
        pasteSaysNotCompleted(message: declined, savedForAnalysis: false),
        isTrue);
    expect(pasteSaysNotCompleted(message: declined, savedForAnalysis: true),
        isFalse);
    expect(
        pasteSaysNotCompleted(
            message: 'Hello from Test Shop 123', savedForAnalysis: false),
        isFalse);
  });

  test('the not-completed wording does not invite a manual entry', () {
    for (final locale in AppL10n.supportedLocales) {
      final text = lookupAppL10n(locale).pasteNotCompleted;
      expect(text.toLowerCase(), isNot(contains('manually')));
      expect(text, isNot(contains('يدوي')));
    }
  });

  // V1-066 — the batch list said "Not understood" for a declined message; it
  // now uses the same distinction as the single-message path.
  test('the batch label matches the single-message outcome', () {
    for (final locale in AppL10n.supportedLocales) {
      final l10n = lookupAppL10n(locale);
      const declined = 'Purchase of SAR 250.00 at Test Shop was declined.';
      expect(
          pasteBatchNotTransactionLabel(l10n,
              message: declined, savedForAnalysis: false),
          l10n.pasteNotCompletedShort);
      expect(
          pasteBatchNotTransactionLabel(l10n,
              message: declined, savedForAnalysis: true),
          l10n.pasteSavedForAnalysisShort);
      expect(
          pasteBatchNotTransactionLabel(l10n,
              message: 'Hello from Test Shop 123', savedForAnalysis: false),
          l10n.pasteNotUnderstood);
    }
  });

  test('the not-completed wording covers holds and pending, not only '
      'declines', () {
    final en = lookupAppL10n(const Locale('en')).pasteNotCompleted;
    final ar = lookupAppL10n(const Locale('ar')).pasteNotCompleted;
    expect(en, contains('on hold'));
    expect(en, contains('nothing was recorded'));
    expect(ar, contains('معلّقة'));
    expect(ar, contains('لم يُسجَّل شيء'));
  });
}
