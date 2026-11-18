import 'direction_signal.dart';

/// What a captured message means, decided before any amount is trusted
/// (owner brief round 3, 4.1 / 4.6).
///
/// [MessageMeaning] is read by [ParserEngine.meaningOf] clause by clause: a
/// sentence that carries an unlabelled amount is an *event* sentence; a
/// sentence whose only figures are labelled (a balance, a limit, an amount
/// due, a fee) or that carries only a footer cue (security advice, an advert,
/// an account notice, a reminder, another attempt's status) is a *footer*
/// and never changes the status of the event. The same rule runs on the
/// server (`process-ios-sms/message_meaning.ts`) over the same word lists
/// (`parser_rules.json` → `messageMeaning`, drift test).
enum MessageKind {
  /// A completed money movement: may be recorded.
  completedMovement,

  /// Declined, failed, cancelled, pending or held: not a movement.
  notCompleted,

  /// A reminder, a bill due, a scheduled or upcoming operation, an expected
  /// salary or deposit, an offer or a spending summary: names an amount but
  /// no movement that happened.
  noMovementNotice,

  /// Money between the user's own accounts (two own accounts, a term
  /// deposit, savings ↔ current): direction-neutral; not decidable here.
  ownAccountTransfer,

  /// A cash deposit (ATM/cash): money in, but not proven to be income.
  cashDeposit,

  /// More than one money movement with different amounts.
  multipleEvents,

  /// An OTP or purchase code.
  otp,

  /// No event sentence (no unlabelled amount): decided by the legacy rules.
  undetermined,

  /// Follow-up 3: the text does not settle whether the movement completed (a
  /// status that may belong to another operation, a status that the footers
  /// and the whole message disagree on, a status cut off mid-word): kept for
  /// review, never recorded and never silent.
  uncertain,
}

/// How the capture pipeline should treat the message.
enum MessageDisposition {
  /// Supported by the parser: may be recorded (subject to the usual checks).
  record,

  /// Kept for the user's review: never confirmed money, never silent.
  review,

  /// A clear notice: no financial movement and no confirmed record.
  noMovement,

  /// Dropped (OTP).
  ignore,
}

class MessageMeaning {
  const MessageMeaning({
    required this.kind,
    required this.reason,
    this.direction = TxnDirection.unknown,
    this.footerCount = 0,
    this.eventCount = 0,
    this.currencyAbsent = false,
  });

  final MessageKind kind;

  /// Machine-readable reason (`footer_ignored`, `bill_due`, `own_accounts`,
  /// `multiple_amounts`, …).
  final String reason;

  /// The direction the transaction clause's own verbs and prepositions give
  /// ([DirectionSignal.flowOf]); unknown when they do not settle it.
  final TxnDirection direction;

  /// Footer sentences set aside (their cues did not apply to the event).
  final int footerCount;

  /// Sentences that carry an unlabelled amount.
  final int eventCount;

  /// The message names no currency for its amount: a caller must not invent
  /// one (4.4) — it may use a confidently identified account's currency, or
  /// send the capture to review.
  final bool currencyAbsent;

  MessageDisposition get disposition => switch (kind) {
        MessageKind.completedMovement => MessageDisposition.record,
        MessageKind.undetermined => MessageDisposition.record,
        MessageKind.noMovementNotice => MessageDisposition.noMovement,
        MessageKind.otp => MessageDisposition.ignore,
        _ => MessageDisposition.review,
      };

  MessageMeaning copyWith({bool? currencyAbsent}) => MessageMeaning(
        kind: kind,
        reason: reason,
        direction: direction,
        footerCount: footerCount,
        eventCount: eventCount,
        currencyAbsent: currencyAbsent ?? this.currencyAbsent,
      );

  // ── Word lists (equal to parser_rules.json → messageMeaning; drift test) ──

  /// A footer sentence about another operation ("Previous attempt
  /// declined", "Your earlier payment did not go through"): its status cue
  /// is not this event's status.
  static const List<String> otherEventMarkers = [
    'previous', 'earlier', 'prior', 'another', 'last attempt',
    'first attempt', 'dispute', 'السابقة', 'السابق', 'سابقة',
    // Follow-up 4 (SM-06): "Last transaction SAR 30 …", «آخر عملية 30 ريال».
    'last', 'آخر',
  ];

  /// Follow-up 3 (SM-01): an [otherEventMarkers] word attaches a status cue
  /// to another operation only through one of these nouns ("Previous
  /// transaction declined", "العملية السابقة مرفوضة"); "declined, please use
  /// another card" is this event's status.
  static const List<String> otherEventNouns = [
    'transaction', 'transactions', 'attempt', 'attempts', 'purchase',
    'purchases', 'payment', 'payments', 'transfer', 'transfers', 'withdrawal',
    'operation', 'charge', 'txn', 'trx', 'عملية', 'العملية', 'محاولة',
    'المحاولة', 'معاملة', 'المعاملة', 'حركة', 'الحركة',
    // Follow-up 4 (SM-06): "Previous salary SAR …", «الراتب السابق».
    'salary', 'راتب', 'الراتب',
  ];

  /// An amount that is owed or due, not paid.
  static const List<String> dueMarkers = [
    'is due', 'are due', 'due on', 'due by', 'due date', 'due tomorrow',
    'due today', 'due in', 'payment due', 'amount due', 'minimum due',
    'due amount', 'reminder', 'remind', 'تذكير', 'مستحق', 'مستحقة',
    'موعد سداد', 'يستحق', 'تستحق',
  ];

  /// An operation that has not happened yet: scheduled, upcoming, expected.
  static const List<String> futureMarkers = [
    'will be', 'will run', 'will arrive', 'will reach', 'will be executed',
    'scheduled', 'upcoming', 'expected', 'is expected', 'to be paid',
    'to be debited', 'to be credited', 'under processing', 'under process',
    'refund request', 'refund requested', 'request to refund',
    'requested a refund', 'سيتم', 'سوف', 'المتوقع', 'متوقع', 'مجدول',
    'مجدولة', 'ستتم', 'سيخصم', 'سيُخصم', 'سيضاف', 'سيودع', 'جاري تنفيذ',
    'جاري معالجة', 'جارٍ تنفيذ', 'جارٍ معالجة',
    'طلب استرداد', 'طلب الاسترداد',
    // Follow-up 4: an execution date ahead ("standing order … executes
    // tomorrow", «سينفذ غدا»).
    'tomorrow', 'غدا', 'غداً', 'execution date', 'executes', 'تاريخ التنفيذ',
    'سينفذ', 'ستنفذ',
  ];

  /// An offer, a call to act or a condition ("Deposit SAR 1,000 or more to
  /// get …", "Convert your purchase … to instalments").
  static const List<String> offerMarkers = [
    'or more', 'to get', 'and get', 'get up to', 'earn', 'open a', 'convert',
    'instalment plan', 'installment plan', 'in instalments', 'in installments',
    'into instalments', 'into installments', 'minimum deposit', 'eligible',
    'when you', 'next purchase', 'offer ends', 'offer valid', 'limited time',
    'احصل', 'اربح', 'افتح', 'قسّط', 'قسط مشترياتك', 'للحصول', 'ربحت',
    'مشترياتك القادمة', 'عملية الشراء القادمة', 'ينتهي العرض',
    'on every', 'for every', 'up to', 'على كل', 'لكل', 'win', 'and win',
    'to claim', 'على مشترياتك',
  ];

  /// A summary or settings notice ("Your spending this month: …").
  static const List<String> summaryMarkers = [
    'spending this month', 'spending summary', 'monthly statement',
    'total spent', 'total received', 'alert settings', 'alerts for',
    'notify me', 'مصروفاتك', 'ملخص',
    // Follow-up 5 (S3): a month-to-date total.
    'هذا الشهر', 'الشهر الحالي', 'إجمالي مشترياتك', 'اجمالي مشترياتك',
  ];

  /// Words that report the operation as done; one outside a future or
  /// conditional clause makes a sentence a completed movement even when it
  /// also names a due amount ("Due amount SAR 230 paid successfully").
  static const List<String> doneVerbs = [
    'debited', 'credited', 'deducted', 'charged', 'paid', 'spent',
    'withdrawn', 'received', 'deposited', 'refunded', 'transferred', 'sent',
    'approved', 'authorised', 'authorized', 'completed', 'successful',
    'successfully', 'processed', 'posted', 'settled', 'done', 'executed',
    'made', 'تم', 'تمت', 'سداد المستحق', 'سداد المبلغ المستحق',
  ];

  /// Strong evidence that money moved between the user's own accounts.
  static const List<String> ownAccountStrong = [
    'term deposit', 'fixed deposit', 'time deposit', 'deposit account',
    'from savings', 'between your accounts', 'own account',
    'وديعة',
  ];

  /// Evidence of the user's own accounts that counts only when the clause
  /// both takes money out and puts it in.
  static const List<String> ownAccountMarkers = [
    'to current', 'from current',
    'current account', 'savings account', 'between your accounts',
    'own account', 'وديعة', 'حساب التوفير', 'الحساب الجاري',
  ];

  /// A cash deposit (money in from cash the user already had).
  static const List<String> cashDepositMarkers = [
    'cash deposit', 'cash deposited', 'deposited in cash', 'إيداع نقدي',
    'ايداع نقدي',
  ];

  /// Earlier in its clause, one of these makes a [doneVerbs] word not done
  /// ("will be credited", "سيتم خصم", "if paid").
  static const List<String> tenseMarkers = [
    'will', 'will be', 'to be', 'shall', 'once', 'if', 'when', 'please',
    'request', 'سيتم', 'سوف', 'إذا', 'عند', 'يرجى', 'الرجاء', 'طلب',
    'every',
  ];

  /// Follow-up 3 (SM-04): a courtesy opener is not a request ("Please note
  /// SAR 500 has been debited", "يرجى العلم بأنه تم خصم"): it is read as
  /// plain text before the tense of a done verb is judged.
  static const List<String> noticeOpeners = [
    'please note', 'kindly note', 'please be informed', 'please be advised',
    'kindly be informed', 'يرجى العلم', 'نود إعلامكم', 'نود اعلامكم',
    'نحيطكم علما',
    // Follow-up 6 (NEW-2r): "as per your request" attributes a completed
    // operation to the user's earlier instruction; it is not a new request.
    'as per your request', 'as per your instruction',
    'as per your instructions', 'per your request', 'upon your request',
    'at your request', 'as requested', 'بناء على طلبك', 'حسب طلبك',
  ];

  /// Follow-up 3 (SM-04): words that lead a completed card or cash movement.
  /// The clause that carries the figure with one of these (or a done verb)
  /// and no notice, offer or future word of its own states a movement; an
  /// offer, due or "will be posted" tail does not undo it.
  static const List<String> movementLeads = [
    'purchase', 'pos', 'withdrawal', 'شراء', 'سحب', 'مشتريات',
  ];

  /// Follow-up: a [doneVerbs] word whose clause holds one of these is a
  /// future operation even with no scheduling word ("Annual fee of SAR 250
  /// will be charged on 1 Dec", `سيتم خصم 250 ريال`).
  static const List<String> futureTense = [
    'will', 'shall', 'to be', 'سيتم', 'سوف',
    // Follow-up 6 (CUE-1): "You are going to receive …", «ستحصل على …».
    'going to', 'ستحصل', 'ستستلم', 'ستتلقى', 'سيصلك',
  ];

  /// Follow-up: loyalty points are not money; a sentence about them is a
  /// footer ("Credited points 45"). Not a bare `نقاط`: `نقاط البيع` is a
  /// point of sale.
  static const List<String> rewardMarkers = [
    'points', 'reward points', 'loyalty points', 'miles', 'نقاط مكافأة',
    'نقاط المكافآت', 'نقاط الولاء', 'رصيد النقاط',
  ];

  /// Round 3 (V1-082): a clause that takes money from the user's own account
  /// or card ("SAR 500 credited to Ali from your account") is outgoing unless
  /// it also names the user's account as the destination ([ownDestination]).
  static const List<String> sourceOfFunds = [
    'from your account', 'from your card', 'من حسابك', 'من بطاقتك',
  ];

  /// The user's own account as the destination of the money.
  static const List<String> ownDestination = [
    'to your account', 'into your account', 'in your account', 'to your card',
    'إلى حسابك', 'الى حسابك', 'لحسابك', 'في حسابك', 'إلى بطاقتك',
  ];

  /// Explicit evidence of a transfer between the user's own accounts that
  /// the capture pipeline books as a neutral transfer
  /// (`AddTransactionUseCase.looksLikeInternalTransfer`): recorded as a
  /// transfer, not sent to review.
  static const List<String> explicitOwnTransfer = [
    'internal transfer', 'own account', 'self transfer',
    'between your accounts', 'تحويل داخلي', 'بين حساباتك', 'بين حساباتكم',
    'لحسابك الآخر', 'من حسابك إلى حسابك',
  ];

  /// Words that make a not-completed message a pending one (the reason).
  static const List<String> pendingWords = [
    'pending', 'on hold', 'hold', 'awaiting', 'under review',
    'being processed', 'will be processed', 'initiated', 'معلق', 'معلقة',
    'قيد',
  ];

  /// A period after one of these does not end a sentence ("Avl. Bal.").
  static const List<String> abbreviations = [
    'bal', 'avl', 'avail', 'no', 'ref', 'amt', 'txn', 'trx', 'acct', 'ac',
    'a/c', 'dr', 'cr', 'co', 'ltd', 'st', 'min', 'max', 'mr', 'ms', 'dt',
    'inc', 'approx', 'tel', 'sr', 'rs',
  ];
}
