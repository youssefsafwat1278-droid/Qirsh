import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

// V1 audit PROD-06 / PROD-07 — the Help screen must describe what the app does.
//
// PROD-06: the Data transfer ZIP export is not password-protected, so Help must
// not call it encrypted and must carry the same warning the Data transfer screen
// shows (one sentence, worded identically on both screens).
//
// PROD-07: high-confidence captures are saved without review, so Help must not
// promise that the user always confirms first or that every capture lands in
// the Smart Inbox first.

void main() {
  final locales = <String, AppL10n>{'en': AppL10nEn(), 'ar': AppL10nAr()};

  /// The last sentence of dtxExportNotice: the "not password-protected" fact.
  String zipWarning(AppL10n l10n) {
    // EN: "... device tokens. The ZIP is not ..." / AR: "... رموز الأجهزة. ملف ZIP ..."
    final notice = l10n.dtxExportNotice;
    return notice.substring(notice.lastIndexOf('. ') + 2);
  }

  locales.forEach((code, l10n) {
    test('$code: Help backup text repeats the Data transfer ZIP warning', () {
      final warning = zipWarning(l10n);
      expect(warning, contains('ZIP'));
      expect(l10n.helpBackupBody, contains(warning));
    });
  });

  test('en: Help never calls the export encrypted or mentions a passphrase', () {
    final body = locales['en']!.helpBackupBody.toLowerCase();
    expect(body, isNot(contains('encrypted')));
    expect(body, isNot(contains('passphrase')));
  });

  test('ar: Help never calls the export encrypted', () {
    final body = locales['ar']!.helpBackupBody;
    expect(body, isNot(contains('مشفّرة')));
    expect(body, isNot(contains('مشفرة')));
    expect(body, isNot(contains('لا تخرج كلمة المرور')));
  });

  test('en: Help does not promise a confirmation before every save', () {
    final en = locales['en']!;
    expect(en.helpAddTransactionBody.toLowerCase(),
        isNot(contains('always confirm')));
    expect(en.helpSmartInboxBody.toLowerCase(),
        isNot(contains('arrive here first')));
  });

  test('ar: Help does not promise a confirmation before every save', () {
    final ar = locales['ar']!;
    expect(ar.helpAddTransactionBody,
        isNot(contains('الكلمة الأخيرة قبل الحفظ')));
    expect(ar.helpSmartInboxBody, isNot(contains('تصل هنا أولًا')));
  });
}
