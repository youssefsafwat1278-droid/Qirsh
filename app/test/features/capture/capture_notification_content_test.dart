import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';

final _fixedNow = DateTime.utc(2026, 7, 2, 14);

TransactionEntity _tx({
  double amount = 150,
  String currency = 'SAR',
  TransactionTypeEntity type = TransactionTypeEntity.payment,
  String? rawMerchant,
  String? categoryId,
  String? cardLast4,
  double? balanceAfter,
  double? foreignAmount,
  String? foreignCurrency,
}) {
  final now = DateTime.utc(2026, 7, 2, 12);
  return TransactionEntity(
    id: 'tx-1',
    amountMoney: Money.fromLegacyReal(amount, currency),
    currency: currency,
    type: type,
    source: TransactionSourceEntity.bank,
    occurredAt: now,
    rawMessage: 'msg',
    parseConfidence: 0.9,
    status: TransactionStatus.pending,
    createdAt: now,
    updatedAt: now,
    rawMerchant: rawMerchant,
    categoryId: categoryId,
    cardLast4: cardLast4,
    balanceAfterMoney: balanceAfter == null
        ? null
        : Money.fromLegacyReal(balanceAfter, currency),
    foreignMoney: foreignAmount == null || foreignCurrency == null
        ? null
        : Money.fromLegacyReal(foreignAmount, foreignCurrency),
    foreignCurrency: foreignCurrency,
  );
}

void main() {
  group('buildConfirmedCaptureContent', () {
    test('full details: labeled line per field, no balance line', () {
      final content = buildConfirmedCaptureContent(
        _tx(
          rawMerchant: 'STARBUCKS',
          categoryId: 'cafes',
          cardLast4: '1234',
          balanceAfter: 3450,
        ),
        now: _fixedNow,
      );

      expect(content.title, 'تم رصد عملية شراء 🛒');
      final lines = content.body.split('\n');
      expect(lines[0], 'المبلغ: 150 SAR');
      expect(lines[1], 'التاجر: STARBUCKS');
      expect(lines[2], 'البطاقة: ****1234');
      expect(lines[3], startsWith('الوقت: '));
      expect(lines[4], 'التصنيف: مقاهي ☕');
      // الرصيد لا يظهر أبداً في الإشعار (خصوصية شاشة القفل).
      expect(content.body.contains('رصيد'), isFalse);
    });

    test('income uses إيداع title and المصدر label', () {
      final content = buildConfirmedCaptureContent(
        _tx(
          type: TransactionTypeEntity.income,
          amount: 5000,
          rawMerchant: 'شركة أرامكو',
        ),
        now: _fixedNow,
      );

      expect(content.title, 'تم رصد إيداع 💰');
      expect(content.body, contains('المصدر: شركة أرامكو'));
    });

    test('foreign amount shown in parentheses in the amount line', () {
      final content = buildConfirmedCaptureContent(
        _tx(amount: 187.5, foreignAmount: 50, foreignCurrency: 'USD'),
        now: _fixedNow,
      );

      expect(content.body, contains('المبلغ: 187.50 SAR (50 USD)'));
    });

    test('minimal transaction still shows amount and time lines', () {
      final content = buildConfirmedCaptureContent(_tx(), now: _fixedNow);
      final lines = content.body.split('\n');
      expect(lines[0], 'المبلغ: 150 SAR');
      expect(lines[1], startsWith('الوقت: '));
    });

    test('null transaction has a generic fallback', () {
      final content = buildConfirmedCaptureContent(null);
      expect(content.title, 'تم التقاط العملية');
    });
  });

  group('buildReviewCaptureContent', () {
    test('title asks to confirm; body has details plus tap hint', () {
      final content = buildReviewCaptureContent(
        _tx(
          type: TransactionTypeEntity.withdrawal,
          amount: 500,
          cardLast4: '9876',
        ),
        now: _fixedNow,
      );

      expect(content.title, 'أكّد السحب — 500 SAR');
      expect(content.body, contains('المبلغ: 500 SAR'));
      expect(content.body, contains('البطاقة: ****9876'));
      expect(content.body, endsWith('اضغط للمراجعة والتأكيد.'));
    });

    test('null transaction has a generic fallback', () {
      final content = buildReviewCaptureContent(null);
      expect(content.title, 'أكّد العملية');
    });

    // Owner decision 3.12: an entry awaiting review shows its category as a
    // suggestion, never as the final category; a saved one shows it plainly.
    test('category of an entry awaiting review is labelled a suggestion', () {
      for (final lang in const ['ar', 'en']) {
        final review = buildReviewCaptureContent(
            _tx(categoryId: 'groceries'),
            now: _fixedNow,
            lang: lang);
        final saved = buildConfirmedCaptureContent(
            _tx(categoryId: 'groceries'),
            now: _fixedNow,
            lang: lang);
        final suggested = lang == 'en' ? 'Suggested category: ' : 'التصنيف المقترح: ';
        final plain = lang == 'en' ? '\nCategory: ' : '\nالتصنيف: ';
        expect(review.body, contains(suggested));
        expect(review.body, isNot(contains(plain)));
        expect(saved.body, contains(plain));
        expect(saved.body, isNot(contains(suggested)));
      }
    });
  });

  group('buildDuplicateCaptureContent', () {
    test('body includes details and review hint', () {
      final content = buildDuplicateCaptureContent(
        _tx(rawMerchant: 'AMAZON'),
        now: _fixedNow,
      );

      expect(content.title, 'عملية مشابهة ⚠️');
      expect(content.body, contains('المبلغ: 150 SAR'));
      expect(content.body, contains('التاجر: AMAZON'));
      expect(content.body, endsWith('موجودة مسبقًا؟ اضغط للمراجعة.'));
    });
  });

  group('captureTimeLabel', () {
    test('same day → اليوم with 12h time', () {
      final occurred = DateTime(2026, 7, 2, 21, 41);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), 'اليوم 9:41 م');
    });

    test('previous day → أمس', () {
      final occurred = DateTime(2026, 7, 1, 9, 5);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), 'أمس 9:05 ص');
    });

    test('older → d/M', () {
      final occurred = DateTime(2026, 6, 20, 12, 0);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), '20/6 12:00 م');
    });
  });

  test('fmtCaptureAmount trims whole numbers and keeps 2dp otherwise', () {
    expect(fmtCaptureAmount(150), '150');
    expect(fmtCaptureAmount(150.5), '150.50');
  });


  group('English capture content', () {
    // The capture notification is the one the user sees most, and it is raised
    // from a background isolate — the path least likely to be exercised by a
    // widget test. Assert the English side explicitly.
    test('every builder produces English when asked', () {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      for (final build in [
        buildConfirmedCaptureContent,
        buildReviewCaptureContent,
        buildDuplicateCaptureContent,
      ]) {
        final withTx = build(_tx(), now: _fixedNow, lang: 'en');
        final withoutTx = build(null, lang: 'en');
        for (final c in [withTx, withoutTx]) {
          expect(c.title.trim(), isNotEmpty);
          expect(c.body.trim(), isNotEmpty);
        }
        // `_tx()` carries an English merchant, so any Arabic left in the body
        // is copy, not data.
        expect(arabic.hasMatch(withoutTx.title), isFalse,
            reason: 'title: ${withoutTx.title}');
        expect(arabic.hasMatch(withoutTx.body), isFalse,
            reason: 'body: ${withoutTx.body}');
      }
    });

    test('Arabic remains the default, so no caller changed language silently',
        () {
      expect(buildConfirmedCaptureContent(_tx(), now: _fixedNow).title,
          buildConfirmedCaptureContent(_tx(), now: _fixedNow, lang: 'ar').title);
    });

    test('the time label localizes its day words and meridiem', () {
      final ar = captureTimeLabel(_fixedNow, now: _fixedNow);
      final en = captureTimeLabel(_fixedNow, now: _fixedNow, lang: 'en');
      expect(ar, startsWith('اليوم'));
      expect(en, startsWith('Today'));
      expect(en, anyOf(contains('AM'), contains('PM')));
    });

    test('category labels keep the emoji and change the word', () {
      expect(captureCategoryLabel('restaurants'), 'مطاعم 🍔');
      expect(captureCategoryLabel('restaurants', lang: 'en'), 'Restaurants 🍔');
      expect(captureCategoryLabel('not_a_key', lang: 'en'), isNull);
    });
  });
}
