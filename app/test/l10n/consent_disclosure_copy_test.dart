import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Decisions 3.8–3.10: the first-run disclosure states what is sent, to whom,
/// why, how sync behaves, the shared-learning contribution, and how turning it
/// off works — in both languages, without calling sanitized text anonymous.
void main() {
  Map<String, dynamic> load(String p) =>
      jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;
  final en = load('lib/l10n/app_en.arb');
  final ar = load('lib/l10n/app_ar.arb');

  const keys = [
    'smartConsentIntro',
    'smartConsentBullet2',
    'smartConsentBullet1',
    'smartConsentWho',
    'smartConsentWhy',
    'smartConsentBullet3',
    'smartConsentShared',
    'smartConsentOff',
    'smartConsentLocal',
  ];
  String all(Map<String, dynamic> m) => keys.map((k) => m[k] as String).join(' ');

  test('the affirmative and the local action are named as decided', () {
    expect(en['initialConsentAccept'], 'Agree and enable');
    expect(en['initialConsentDecline'], 'Continue locally');
    expect(ar['initialConsentAccept'], 'أوافق وفعّل');
    expect(ar['initialConsentDecline'], 'المتابعة محليًا');
  });

  test('English names data, destinations, purposes, sync, sharing, off', () {
    final s = all(en);
    for (final part in [
      'turned on together',
      'transactions, accounts, cards',
      'profile (name, phone number, date of birth and photo)',
      'crash reports',
      'IBANs, mobile numbers and verification codes it recognises',
      'it can miss some',
      'Google Gemini',
      'the currency of the account it matches',
      'Google Places',
      'Supabase',
      'Sentry',
      'at most 7 days',
      'it is not anonymous',
      'retries and background processing',
      'does not turn them on for your other devices',
      'Shared category learning is included',
      'one-way code instead of your account ID',
      'at least 6 users',
      'off together',
      'cannot be recalled',
      'Nothing above is sent',
    ]) {
      expect(s, contains(part));
    }
    expect(s.toLowerCase(), isNot(contains('android')),
        reason: 'V1 is iPhone only (UX-15 item 4)');
    expect(s, isNot(contains('either permission')),
        reason: 'V1-017: withdrawal is combined');
    expect(s.toLowerCase().replaceAll('not anonymous', ''),
        isNot(contains('anonymous')));
  });

  test('Arabic says the same, in Western digits', () {
    final s = all(ar);
    for (final part in [
      'معًا',
      'تاريخ الميلاد',
      'وأرقام IBAN وأرقام الجوال ورموز التحقق',
      'فقد يفوته بعضها',
      'Google Gemini',
      'عملة الحساب المطابق لها',
      'Google Places',
      'Supabase',
      'Sentry',
      '7 أيام',
      'ليس مجهول الهوية',
      'إعادة المحاولة',
      'لا تفعّلهما على أجهزتك الأخرى',
      'التعلّم المشترك للتصنيفات مشمول',
      'رمز أحادي الاتجاه',
      '6 مستخدمين',
      'لا يمكن استرجاع ما أُرسل',
      'لا يُرسَل شيء مما سبق',
    ]) {
      expect(s, contains(part));
    }
    expect(s, isNot(contains('أندرويد')));
    expect(s, isNot(matches(RegExp('[٠-٩]'))));
  });

  test('withdrawal copy: both together, sending stops, no recall', () {
    for (final (m, parts) in [
      (en, ['turn off together', 'retries', 'shared-learning', 'cannot be recalled']),
      (ar, ['معًا', 'إعادة المحاولة', 'التعلّم المشترك', 'لا يمكن استرجاع']),
    ]) {
      for (final p in parts) {
        expect(m['consentWithdrawBody'], contains(p));
      }
    }
  });
}
