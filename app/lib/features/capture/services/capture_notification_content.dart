import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';

/// محتوى إشعار الالتقاط — builder واحد مشترك بين مساري الإشعارات
/// (CapturedMessageProcessor في الخلفية و AppShell في الواجهة) حتى يظهر
/// نفس النص بكل التفاصيل في الحالتين.
///
/// الشكل: عنوان بنوع العملية، وجسم متعدد الأسطر بكل التفاصيل المتاحة
/// (المبلغ/التاجر/البطاقة/الوقت/التصنيف). الرصيد لا يظهر أبداً في
/// الإشعار — يظهر على شاشة القفل لأي شخص يرى الجهاز.
class CaptureNotificationContent {
  const CaptureNotificationContent({required this.title, required this.body});

  final String title;
  final String body;
}

/// إشعار عملية مؤكدة: "تم رصد عملية شراء 🛒" + قائمة التفاصيل.
CaptureNotificationContent buildConfirmedCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
  String lang = 'ar',
}) {
  final en = lang == 'en';
  if (tx == null) {
    return CaptureNotificationContent(
      title: en ? 'Transaction captured' : 'تم التقاط العملية',
      body: en
          ? 'We added it to your ledger.'
          : 'أضفنا العملية إلى سجلك.',
    );
  }
  return CaptureNotificationContent(
    title: en
        ? '${_typeTitle(tx.type, lang)} detected ${_typeEmoji(tx.type)}'
        : 'تم رصد ${_typeTitle(tx.type, lang)} ${_typeEmoji(tx.type)}',
    body: _detailsBlock(tx, now: now, lang: lang),
  );
}

/// إشعار يطلب تأكيداً: "أكّد الخصم — 150.00 ر.س" + قائمة التفاصيل.
CaptureNotificationContent buildReviewCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
  String lang = 'ar',
}) {
  final en = lang == 'en';
  if (tx == null) {
    return CaptureNotificationContent(
      title: en ? 'Confirm this transaction' : 'أكّد العملية',
      body: en
          ? 'Tap to review and confirm it.'
          : 'اضغط لمراجعة العملية وتأكيدها.',
    );
  }
  return CaptureNotificationContent(
    title: en
        ? 'Confirm ${_typeLabelDefinite(tx.type, lang)} — ${_amountLine(tx)}'
        : 'أكّد ${_typeLabelDefinite(tx.type, lang)} — ${_amountLine(tx)}',
    // Owner decision 3.12: an entry awaiting review is not final, so its
    // category is labelled as a suggestion, never as the category.
    body: en
        ? '${_detailsBlock(tx, now: now, lang: lang, suggestedCategory: true)}'
            '\nTap to review and confirm.'
        : '${_detailsBlock(tx, now: now, lang: lang, suggestedCategory: true)}'
            '\nاضغط للمراجعة والتأكيد.',
  );
}

/// إشعار عملية مشابهة (suspicious duplicate).
CaptureNotificationContent buildDuplicateCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
  String lang = 'ar',
}) {
  final en = lang == 'en';
  if (tx == null) {
    return CaptureNotificationContent(
      title: en ? 'Possible duplicate' : 'عملية مشابهة',
      body: en
          ? 'Open Qirsh and check the Smart Inbox.'
          : 'افتح قِرش وراجع الـ Smart Inbox.',
    );
  }
  return CaptureNotificationContent(
    title: en ? 'Possible duplicate ⚠️' : 'عملية مشابهة ⚠️',
    body: en
        ? '${_detailsBlock(tx, now: now, lang: lang)}\nAlready recorded? Tap to review.'
        : '${_detailsBlock(tx, now: now, lang: lang)}\nموجودة مسبقًا؟ اضغط للمراجعة.',
  );
}

/// المبلغ + العملة، مع المبلغ الأجنبي بين قوسين إن وُجد.
String _amountLine(TransactionEntity tx) {
  final base = '${fmtCaptureMoney(tx.amountMoney)} ${tx.currency}';
  final foreign = tx.foreignMoney;
  if (foreign != null && tx.foreignCurrency != null) {
    return '$base (${fmtCaptureMoney(foreign)} ${tx.foreignCurrency})';
  }
  return base;
}

/// قائمة التفاصيل — سطر لكل معلومة متاحة.
String _detailsBlock(
  TransactionEntity tx, {
  DateTime? now,
  String lang = 'ar',
  bool suggestedCategory = false,
}) {
  final en = lang == 'en';
  final lines = <String>[
    '${en ? 'Amount' : 'المبلغ'}: ${_amountLine(tx)}'
  ];
  if (tx.rawMerchant != null && tx.rawMerchant!.trim().isNotEmpty) {
    final key = switch (tx.type) {
      TransactionTypeEntity.income || TransactionTypeEntity.refund =>
        en ? 'Source' : 'المصدر',
      _ => en ? 'Merchant' : 'التاجر',
    };
    lines.add('$key: ${tx.rawMerchant}');
  }
  if (tx.cardLast4 != null && tx.cardLast4!.isNotEmpty) {
    lines.add('${en ? 'Card' : 'البطاقة'}: ****${tx.cardLast4}');
  }
  lines.add('${en ? 'Time' : 'الوقت'}: '
      '${captureTimeLabel(tx.occurredAt, now: now, lang: lang)}');
  final cat = captureCategoryLabel(tx.categoryId, lang: lang);
  if (cat != null) {
    final label = suggestedCategory
        ? (en ? 'Suggested category' : 'التصنيف المقترح')
        : (en ? 'Category' : 'التصنيف');
    lines.add('$label: $cat');
  }
  return lines.join('\n');
}

String _typeTitle(TransactionTypeEntity type, String lang) {
  final en = lang == 'en';
  return switch (type) {
    TransactionTypeEntity.income => en ? 'A deposit' : 'إيداع',
    TransactionTypeEntity.refund => en ? 'A refund' : 'استرداد',
    TransactionTypeEntity.transfer => en ? 'A transfer' : 'تحويل',
    TransactionTypeEntity.withdrawal => en ? 'A cash withdrawal' : 'سحب نقدي',
    TransactionTypeEntity.payment => en ? 'A purchase' : 'عملية شراء',
    TransactionTypeEntity.unknown => en ? 'A transaction' : 'عملية',
  };
}

String _typeEmoji(TransactionTypeEntity type) {
  return switch (type) {
    TransactionTypeEntity.income => '💰',
    TransactionTypeEntity.refund => '↩️',
    TransactionTypeEntity.transfer => '🔁',
    TransactionTypeEntity.withdrawal => '🏧',
    TransactionTypeEntity.payment => '🛒',
    TransactionTypeEntity.unknown => '💳',
  };
}

String _typeLabelDefinite(TransactionTypeEntity type, String lang) {
  final en = lang == 'en';
  return switch (type) {
    TransactionTypeEntity.income => en ? 'the deposit' : 'الإيداع',
    TransactionTypeEntity.refund => en ? 'the refund' : 'الاسترداد',
    TransactionTypeEntity.transfer => en ? 'the transfer' : 'التحويل',
    TransactionTypeEntity.withdrawal => en ? 'the withdrawal' : 'السحب',
    TransactionTypeEntity.payment => en ? 'the charge' : 'الخصم',
    TransactionTypeEntity.unknown => en ? 'the transaction' : 'العملية',
  };
}

String fmtCaptureAmount(double amount) {
  return amount == amount.truncateToDouble()
      ? amount.toInt().toString()
      : amount.toStringAsFixed(2);
}

/// R-8 — the same brevity rule, computed from exact minor units.
///
/// [fmtCaptureAmount] is hardcoded to two decimals, so a 3-decimal currency
/// (KWD 12.345) was ROUNDED in the notification — a different number, not a
/// different formatting of the same number. This reads the canonical scale
/// registry instead.
///
/// The approved brevity behaviour is preserved deliberately: a whole amount
/// still prints as `150`, not `150.00`. A lock-screen banner is glanced at, and
/// the exact figure is one tap away in the app. What changes is that the digits
/// it does show are now always right.
String fmtCaptureMoney(Money money) {
  final parts = splitMoneyForDisplay(money);
  final sign = parts.negative ? '-' : '';
  if (parts.fraction.isEmpty || int.tryParse(parts.fraction) == 0) {
    return '$sign${parts.integerPart}';
  }
  return '$sign${parts.integerPart}.${parts.fraction}';
}

/// "اليوم 9:41 م" / "أمس 9:41 م" / "2/7 9:41 م" — بتوقيت الجهاز.
String captureTimeLabel(DateTime occurredAt,
    {DateTime? now, String lang = 'ar'}) {
  final en = lang == 'en';
  final local = occurredAt.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour < 12 ? (en ? 'AM' : 'ص') : (en ? 'PM' : 'م');
  final time = '$hour12:$minute $suffix';
  final sameDay = local.year == ref.year &&
      local.month == ref.month &&
      local.day == ref.day;
  if (sameDay) return en ? 'Today $time' : 'اليوم $time';
  final yesterday = ref.subtract(const Duration(days: 1));
  final isYesterday = local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;
  if (isYesterday) return en ? 'Yesterday $time' : 'أمس $time';
  return '${local.day}/${local.month} $time';
}

/// تسمية عربية للتصنيف بمفتاحه الثابت.
String? captureCategoryLabel(String? key, {String lang = 'ar'}) {
  if (lang == 'en') return _captureCategoryLabelEn(key);
  return switch (key) {
    'restaurants' => 'مطاعم 🍔',
    'cafes' => 'مقاهي ☕',
    'groceries' => 'بقالة 🛒',
    'transport' => 'مواصلات 🚗',
    'fuel' => 'وقود ⛽',
    'bills' => 'فواتير 📱',
    'shopping' => 'تسوق 🛍',
    'health' => 'صحة 🏥',
    'education' => 'تعليم 📚',
    'entertainment' => 'ترفيه 🎬',
    'subscriptions' => 'اشتراكات 📲',
    'transfers' => 'تحويل 💸',
    'cash' => 'كاش 💵',
    'travel' => 'سفر ✈️',
    'gifts' => 'هدايا 🎁',
    'kids' => 'أطفال 👶',
    'home' => 'منزل 🏠',
    'maintenance' => 'صيانة 🔧',
    'fitness' => 'رياضة 💪',
    'beauty' => 'جمال 💅',
    'charity' => 'خيرية 🤲',
    'pets' => 'حيوانات 🐾',
    'insurance' => 'تأمين 🛡️',
    'income' => 'دخل 💰',
    _ => null,
  };
}

/// The English half of `captureCategoryLabel`. Emoji are shared — they are not
/// language.
String? _captureCategoryLabelEn(String? key) {
  return switch (key) {
    'restaurants' => 'Restaurants 🍔',
    'cafes' => 'Cafés ☕',
    'groceries' => 'Groceries 🛒',
    'transport' => 'Transport 🚗',
    'fuel' => 'Fuel ⛽',
    'bills' => 'Bills 📱',
    'shopping' => 'Shopping 🛍',
    'health' => 'Health 🏥',
    'education' => 'Education 📚',
    'entertainment' => 'Entertainment 🎬',
    'subscriptions' => 'Subscriptions 📲',
    'transfers' => 'Transfers 💸',
    'cash' => 'Cash 💵',
    'travel' => 'Travel ✈️',
    'gifts' => 'Gifts 🎁',
    'kids' => 'Kids 👶',
    'home' => 'Home 🏠',
    'maintenance' => 'Maintenance 🔧',
    'fitness' => 'Fitness 💪',
    'beauty' => 'Beauty 💅',
    'charity' => 'Charity 🤲',
    'pets' => 'Pets 🐾',
    'insurance' => 'Insurance 🛡️',
    'income' => 'Income 💰',
    _ => null,
  };
}

/// إشعار رسالة لم يستطع المحرّك تحليلها.
///
/// Both notification paths (CapturedMessageProcessor in the background and
/// AppShell in the foreground) showed this with their own literals, in Arabic
/// only and with two different wordings. One builder, both languages.
CaptureNotificationContent buildUnsupportedCaptureContent({String lang = 'ar'}) {
  final en = lang == 'en';
  return CaptureNotificationContent(
    title: en ? 'Message not recognised' : 'رسالة لم نتمكن من تحليلها',
    body: en
        ? 'Open Qirsh and paste the message to add it manually.'
        : 'افتح قِرش والصق الرسالة يدويًا للإضافة.',
  );
}

// ── CAP-7 (`capture_notify_v2`, manifest Q3 / X9) ───────────────────────────
//
// Generic capture alerts on every channel: nothing in them names an amount, a
// merchant, a card or a sender. The detail is shown only inside the app, after
// unlock. PROPOSED COPY, pending user approval: the English generic body mirrors
// the server push (GENERIC_CAPTURE_PUSH); every Arabic string and the summary /
// correction wording are proposals.

/// The brand name is the same in both languages, as in
/// `LocalNotificationService.redactedContentFor`.
String _captureBrand(bool en) => en ? 'Qirsh' : 'قرش';

/// One captured transaction, whatever the disposition.
CaptureNotificationContent buildGenericCaptureContent({String lang = 'ar'}) {
  final en = lang == 'en';
  return CaptureNotificationContent(
    title: _captureBrand(en),
    body: en ? 'New transaction captured' : 'تم رصد عملية جديدة',
  );
}

/// An offline backlog of [count] imported captures: one alert, not [count].
CaptureNotificationContent buildCaptureSummaryContent(
  int count, {
  String lang = 'ar',
}) {
  final en = lang == 'en';
  return CaptureNotificationContent(
    title: _captureBrand(en),
    body: en
        ? '$count new transactions captured'
        : (count <= 10
            ? 'تم رصد $count عمليات جديدة'
            : 'تم رصد $count عملية جديدة'),
  );
}

/// Replaces an earlier "received a bank message" alert once the local parser
/// has added the transaction. Tapping it opens the transaction to review or edit.
CaptureNotificationContent buildCaptureCorrectionContent({String lang = 'ar'}) {
  final en = lang == 'en';
  return CaptureNotificationContent(
    title: _captureBrand(en),
    body: en ? 'Transaction added' : 'تمت إضافة العملية',
  );
}
