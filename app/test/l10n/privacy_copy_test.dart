import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pre-production privacy copy: every string that describes where bank
/// messages go must state that sensitive numbers are removed first, and must
/// stay truthful under both server regimes (pre-WP4: AI on every consented
/// message; WP4-Lite: AI only when rules cannot resolve) — so no absolute
/// "every" / "only when" claims about AI behaviour.
void main() {
  const keys = [
    'privCloudProcessingBody',
    'privAiAnalysisBody',
    'smartConsentBullet1',
    'onbCloudBullet1',
    'onbAiBullet1',
  ];
  // AI-describing strings must use conditional language, including the named
  // provider disclosure on the initial consent sheet.
  const aiKeys = {
    'privAiAnalysisBody',
    'smartConsentBullet1',
    'onbAiBullet1',
  };

  Map<String, dynamic> load(String p) =>
      jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;

  final en = load('lib/l10n/app_en.arb');
  final ar = load('lib/l10n/app_ar.arb');

  for (final k in keys) {
    test('$k (en) states sanitisation and no absolute claims', () {
      final s = en[k] as String;
      if (k == 'smartConsentBullet1') {
        expect(
            s,
            contains('sent to Qirsh servers after card, account and phone '
                'numbers and codes are removed'));
        expect(s, contains('Google Gemini may process this text'));
      } else {
        expect(
            s, contains('card, account and phone numbers and codes removed'));
      }
      expect(s.toLowerCase(), isNot(matches(RegExp(r'\bevery\b'))));
      expect(s.toLowerCase(), isNot(contains('only when')));
      if (aiKeys.contains(k) && k != 'smartConsentBullet1') {
        expect(s, contains('may be analysed'));
      }
    });

    test('$k (ar) states sanitisation and no absolute claims', () {
      final s = ar[k] as String;
      if (k == 'smartConsentBullet1') {
        expect(
            s,
            contains('إلى خوادم قرش بعد إزالة أرقام البطاقات والحسابات '
                'والهواتف والرموز'));
        expect(s, contains('قد تعالج خدمة Google Gemini هذا النص'));
      } else {
        expect(
            s, contains('بعد حذف أرقام البطاقات والحسابات والهواتف والرموز'));
      }
      expect(s, isNot(contains('كل رسالة')));
      expect(s, isNot(contains('فقط عندما')));
      if (aiKeys.contains(k)) expect(s, contains('قد '));
    });
  }

  test('privAiAnalysisBody (en) is not in the old absolute form', () {
    expect(en['privAiAnalysisBody'], isNot(contains('EVERY')));
  });

  test('the shared-learning switch says what is sent and what is not', () {
    expect(
        en['privSharedLearningTitle'], 'Help improve categories for everyone');
    final s = en['privSharedLearningBody'] as String;
    for (final part in [
      // Decision 3.10: included with the explicit activation, not a default.
      'Included when you agree to Cloud Sync and Smart Analysis; you can turn it off at any time',
      'Remember for this merchant',
      'only that merchant’s name and the category you chose',
      'Amounts, dates, messages, transfers and names of people are never sent',
      'pooled with other users',
      'at least 6 users agree on it and they are a clear majority (75%)',
      'or after an admin reviews it',
      'an admin can remove it',
      'Needs Cloud Sync and Smart Analysis on',
    ]) {
      expect(s, contains(part));
    }
    final a = ar['privSharedLearningBody'] as String;
    for (final part in [
      'يُفعَّل عند موافقتك على المزامنة السحابية والتحليل الذكي، ويمكنك إيقافه في أي وقت',
      ar['ccAllMerchant'] as String,
      'اسم المتجر والتصنيف الذي اخترته فقط',
      'المبالغ أو التواريخ أو الرسائل أو التحويلات أو أسماء الأشخاص',
      'مع اختيارات المستخدمين الآخرين',
      'يتفق عليه 6 مستخدمين على الأقل ويكونون أغلبية واضحة (75%)',
      'أو بعد مراجعة مشرف',
      'المزامنة السحابية والتحليل الذكي',
    ]) {
      expect(a, contains(part));
    }
  });
}
