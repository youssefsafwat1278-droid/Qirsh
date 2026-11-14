// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppL10nAr extends AppL10n {
  AppL10nAr([String locale = 'ar']) : super(locale);

  @override
  String get shortcutAddReady => 'إضافة اختصار قرش';

  @override
  String get shortcutQuickHelp =>
      'أضف قالب QIRSH وراجع فلتر الرسائل، ثم فعّل أتمتة Message. في إصدارات iOS الأقدم، أنشئ أتمتة Message تشغّل الاختصار مع Shortcut Input.';

  @override
  String get shortcutTestConnection => 'اختبار الاتصال';

  @override
  String get shortcutProbeWaiting =>
      'شغّل الاختصار ثم ارجع لقرش. الاختبار لا يضيف معاملة مالية.';

  @override
  String get shortcutProbePassed =>
      'تم التحقق من الاتصال. التسجيل التلقائي يتطلب تفعيل أتمتة الرسائل أيضًا.';

  @override
  String get shortcutOpenFailed =>
      'تعذّر فتح الاختصارات. تأكّد من تثبيت تطبيق Shortcuts وحاول مرة أخرى.';

  @override
  String get shortcutVideoTitle => 'شاهد الشرح بالفيديو';

  @override
  String get shortcutVideoSubtitle => 'أقل من دقيقة · بدون صوت';

  @override
  String get shortcutManualSteps => 'تعليمات الإعداد بالتفصيل';

  @override
  String get appTitle => 'قرش';

  @override
  String get setupHeaderTitle => 'لنُجهّز قِرش';

  @override
  String get setupHeaderSubtitle => 'كام خطوة سريعة وتكون جاهز.';

  @override
  String setupStepLabel(int current, int total) {
    return 'الخطوة $current من $total';
  }

  @override
  String get setupCountryTitle => 'دولتك وعملتك';

  @override
  String get setupCountryBody => 'بنستخدمها كعملة أساسية لحساباتك.';

  @override
  String get setupNotificationsTitle => 'فعّل الإشعارات';

  @override
  String get setupNotificationsBody => 'لتصلك كل عملية فور حدوثها.';

  @override
  String get setupNotificationsCta => 'تفعيل';

  @override
  String get setupCloudTitle => 'المعالجة الذكية';

  @override
  String get setupCloudBody =>
      'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي لتحويلها إلى عمليات وتقارير، بدون تخزين أرقامك الكاملة.';

  @override
  String get setupCloudCta => 'متابعة';

  @override
  String get setupShortcutTitle => 'ثبّت اختصار قِرش';

  @override
  String get setupShortcutBody => 'هو اللي بيبعتلنا رسائل البنك تلقائياً.';

  @override
  String get setupShortcutStep1Title => 'احذف القديم';

  @override
  String get setupShortcutStep1Body =>
      'افتح تطبيق Shortcuts وروح لتبويب Automation واحذف أي أتمتة قديمة للتطبيق.';

  @override
  String get setupShortcutStep2Title => 'جديد (+)';

  @override
  String get setupShortcutStep2Body =>
      'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».';

  @override
  String get setupShortcutStep3Title => 'حدّد الرسائل';

  @override
  String setupShortcutStep3Body(String currency) {
    return 'اضغط «Message Contents» واكتب رمز عملتك مثل $currency.';
  }

  @override
  String get setupShortcutStep4Title => 'بدون تأكيد';

  @override
  String get setupShortcutStep4Body =>
      'فعّل «Run Immediately» واقفل «Notify When Run» لو ظهر، ثم Next.';

  @override
  String get setupShortcutStep5Title => 'إرسال للتطبيق';

  @override
  String get setupShortcutStep5Body =>
      'اختر New Blank Automation وابحث عن Process Bank SMS، واضبط SMS Text على Shortcut Input.';

  @override
  String get setupShortcutStep6Title => 'حفظ';

  @override
  String get setupShortcutStep6Body =>
      'اقفل «Show When Run» لو ظهر، واضغط حفظ.';

  @override
  String get setupShortcutCta => 'ثبّتّه';

  @override
  String get setupSmsCaptureBody =>
      'قِرش يسجّل عملياتك من رسائل البنك أول ما توصل. تقدر تقفلها من الإعدادات في أي وقت.';

  @override
  String get setupSmsCaptureCta => 'فعّلها';

  @override
  String get setupSmsCaptureContinue => 'متابعة';

  @override
  String get setupFinishCta => 'ابدأ';

  @override
  String get brandTagline => 'فلوسك أوضح. قرارك أذكى.';

  @override
  String get brandContinueCta => 'لنبدأ';

  @override
  String get authTitle => 'سجّل الدخول لقرش';

  @override
  String get authSubtitle => 'اختار طريقة تسجيل الدخول المناسبة ليك.';

  @override
  String get authTrustLocalEncryption => 'تشفير محلي';

  @override
  String get authTrustOnDevice => 'مشفّرة على جهازك، ومتزامنة بأمان';

  @override
  String get authTermsNotice =>
      'بالمتابعة أنت توافق على شروط الاستخدام وسياسة الخصوصية.';

  @override
  String get authAppleCta => 'المتابعة بحساب Apple';

  @override
  String get authGoogleCta => 'المتابعة بحساب Google';

  @override
  String get authSignInError => 'تعذّر تسجيل الدخول. جرب تاني.';

  @override
  String get authPreviousAccountCleanupPending =>
      'ما زلنا نمسح بيانات الحساب السابق من هذا الجهاز. حاول مرة أخرى بعد قليل، أو سجّل الدخول بذلك الحساب.';

  @override
  String get authBackupFoundTitle => 'لقينا نسخة احتياطية لحسابك';

  @override
  String get authBackupFoundBody =>
      'تحب نرجّع بياناتك من آخر نسخة، ولا تبدأ من جديد؟';

  @override
  String get authBackupStartFresh => 'ابدأ من جديد';

  @override
  String get authBackupRestore => 'استرجاعها';

  @override
  String get storyPromiseTitle => 'متحمّسين\nنبدأ معك';

  @override
  String get storyPromiseSubtitle => 'ونكون شريكك في رحلتك المالية.';

  @override
  String get storyPromiseHighlight =>
      'في قِرش، نؤمن أن الاستقرار المالي يبدأ بعادات بسيطة.';

  @override
  String get storyPromiseBody =>
      'بنينا تطبيقًا يساعدك على إدارة أموالك بسهولة، من تسجيل المصروفات ووضع الميزانيات، إلى تنبيهات الاشتراكات والتقارير الذكية.';

  @override
  String get storyPromiseSectionTitle => 'هدفنا؟';

  @override
  String get storyPromiseSectionBody =>
      'أن تعرف أين يذهب مالك، وتدّخر أكثر وتعيش براحة أكبر.';

  @override
  String get storyPromiseClosing => 'قِرش...\nشريكك في رحلتك المالية.';

  @override
  String get storySpendingTitle => 'المصروفات الصغيرة بتفرق';

  @override
  String get storySpendingBody =>
      'المصروفات اليومية قد تبدو بسيطة،\nلكنها مع الوقت تصنع فرقًا كبيرًا.';

  @override
  String get storySpendingHighlight => 'ما لا تتابعه... يصعب عليك التحكم به';

  @override
  String get storySpendingSupporting =>
      'يساعدك قِرش على رؤية الصورة كاملة،\nوفهم أين تذهب أموالك.';

  @override
  String get storyContinueCta => 'كمّل';

  @override
  String get storyStartCta => 'ابدأ مع قِرش';

  @override
  String get storySkip => 'تخطّي';

  @override
  String get storyPageOneSemanticLabel => 'الصفحة ١ من ٢';

  @override
  String get storyPageTwoSemanticLabel => 'الصفحة ٢ من ٢';

  @override
  String get next => 'التالي';

  @override
  String get skip => 'تخطي';

  @override
  String get registerAndStart => 'التسجيل والبدء';

  @override
  String get welcomeTitle => 'مساعدك المالي اليومي';

  @override
  String get welcomeSubtitle => 'صاحبك في فلوسك';

  @override
  String get today => 'اليوم';

  @override
  String get yesterday => 'أمس';

  @override
  String get welcomeDescription =>
      'اعرف أين تذهب أموالك، وادّخر تلقائيًا بطريقة ذكية وسهلة.';

  @override
  String get secureOnDevice => 'آمن · على جهازك';

  @override
  String get effortless => 'بدون مجهود';

  @override
  String get noTyping => 'لا تكتب — إحنا نفهمها لك';

  @override
  String get smsReadingDesc =>
      'شارك رسالة البنك مع قرش، ونطلّع المبلغ والمتجر ونصنّفها على جهازك.';

  @override
  String get now => 'الآن';

  @override
  String get snbSmsText => 'عملية مدى شراء بـ ';

  @override
  String get snbSmsSuffix => ' لدى هاف مليون.';

  @override
  String get alrajhi => 'الراجحي';

  @override
  String get oneMinuteAgo => 'قبل دقيقة';

  @override
  String get alrajhiSmsText => 'تم خصم ';

  @override
  String get alrajhiSmsSuffix => ' لدى مطعم هامبرغيني.';

  @override
  String get localProcessing => 'معالجة محلية بالكامل';

  @override
  String get privacyFirst => 'الخصوصية أولاً';

  @override
  String get howItWorks => 'كيف يعمل؟';

  @override
  String get smsToTx => 'من رسالة بنك إلى عملية واضحة';

  @override
  String get howItWorksDesc =>
      'قرش يلتقط المعنى من الرسالة، ويحوّلها لتصنيف ومبلغ ومتجر بدون إدخال يدوي.';

  @override
  String get howItWorksNote1 =>
      'لا حاجة لاختيار مصرفك — يتعرّف قِرش عليه من نص الرسالة.';

  @override
  String get howItWorksNote2 =>
      'لو ظهرت بطاقة جديدة، قرش يضيفها تلقائياً من آخر 4 أرقام.';

  @override
  String get howItWorksNote3 =>
      'تقدر تراجع وتعدل أي عملية أو بطاقة من داخل التطبيق.';

  @override
  String get messageFromBank => 'رسالة من البنك';

  @override
  String get burgerBoutiqueSms => 'شراء 45 ريال لدى BURGER BOUTIQUE';

  @override
  String get burgerBoutiqueSub => 'مطاعم · الآن · مدى';

  @override
  String get burgerBoutiqueAmount => '-45 ريال';

  @override
  String get financialMotivation => 'التحفيز المالي';

  @override
  String get saveLikeGame => 'وفّر وكأنها لعبة يومية';

  @override
  String get saveLikeGameDesc =>
      'حدّد أهدافك المالية ووفّر الفروقات يومًا بعد يوم بطابع تشجيعي ذكي.';

  @override
  String get totalSavings => 'مجموع الادخار المتراكم';

  @override
  String get sar => 'ر.س';

  @override
  String get travelVault => 'خزنة السفر';

  @override
  String get completedPercent => '75% مكتمل';

  @override
  String get goalLimit => 'الهدف: 15,000 ر.س';

  @override
  String get remainingAmount => 'متبقي: 3,750 ر.س';

  @override
  String get easyToUse => 'سهل الاستخدام';

  @override
  String get selectCountryCurrency => 'اختَر بلدك وعملتك';

  @override
  String get selectCountryDesc =>
      'نعرض الأعلام الرسمية، ونضبط العملة الأساسية، وتقدر تضيف عملات ثانية لو عندك بطاقات أو اشتراكات خارجية.';

  @override
  String get mainCountryCurrency => 'البلد والعملة الأساسية';

  @override
  String get additionalCurrencies => 'العملات الإضافية';

  @override
  String get activeSubscriptions => 'الاشتراكات النشطة';

  @override
  String get none => 'لا توجد';

  @override
  String get noActiveSubs => 'لا توجد اشتراكات نشطة';

  @override
  String get selectCountryTitle => 'اختر بلدك وعملتك الأساسية';

  @override
  String get searchCountryPlaceholder => 'البحث عن بلد أو عملة...';

  @override
  String get additionalCurrenciesTitle => 'العملات الإضافية';

  @override
  String get additionalCurrenciesDesc =>
      'اختياري، اختر العملات التي تتعامل بها بجانب عملتك الأساسية.';

  @override
  String get expectedSubscriptions => 'الاشتراكات المتوقعة';

  @override
  String get expectedSubscriptionsDesc =>
      'حدد الاشتراكات النشطة لديك وسنقوم بالتعرف عليها تلقائياً.';

  @override
  String get completePrivacy => 'خصوصية تامّة';

  @override
  String get dataStaysOnDevice => 'بياناتك تبقى في جهازك';

  @override
  String get privacyPrinciples =>
      'مبادئ الأمان والخصوصية لدينا تعني أنك المتحكم الوحيد ببياناتك المالية.';

  @override
  String get privacyRule1 =>
      'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي';

  @override
  String get privacyRule2 =>
      'نعالج فقط رسائل البنك التي تشاركها أو تلصقها بنفسك';

  @override
  String get privacyRule3 => 'ما نبيع بياناتك أبداً، ولك كامل الحرية في حذفها';

  @override
  String get enableAutoTracking => 'شارك رسائل البنك مع قرش';

  @override
  String get setupAppleShortcut => 'إعداد اختصار Apple';

  @override
  String get autoTrackingSubtitleAndroid =>
      'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى قرش. سنحللها على جهازك ونضيف العملية.';

  @override
  String get autoTrackingSubtitleIos =>
      'اتبع الخطوات مرة واحدة، وبعدها يمرّر iPhone رسائل البنك إلى قرش بأمان.';

  @override
  String get smsActivationSnack =>
      'تقدر تشارك رسالة البنك مع قرش أو تلصقها يدويًا.';

  @override
  String get howWillActivationWork => 'كيف سيتم التفعيل؟';

  @override
  String get allowSmsReading => 'فهمت';

  @override
  String get gotIt => 'تمام، فهمت';

  @override
  String get laterAddManually => 'لاحقاً، سأقوم بالإضافة يدوياً';

  @override
  String get shortcutSetupGuide => 'دليل إعداد الاختصار';

  @override
  String get doStepsOnceFromShortcuts =>
      'نفّذ هذه الخطوات مرة واحدة من تطبيق Apple Shortcuts.';

  @override
  String get signInToStart => 'سجّل دخولك للبدء';

  @override
  String get signInSubtitle =>
      'الدخول لتحديد هويتك ومزامنة إعداداتك فقط. بياناتك المالية تبقى آمنة على جهازك.';

  @override
  String get noPassword => 'بدون كلمة مرور';

  @override
  String get continueWithApple => 'المتابعة مع Apple';

  @override
  String get continueWithGoogle => 'المتابعة مع Google';

  @override
  String get or => 'أو';

  @override
  String get continueWithEmail => 'المتابعة بالبريد الإلكتروني';

  @override
  String get email => 'البريد الإلكتروني';

  @override
  String get sendOtpCode => 'إرسال رمز الدخول الآمن';

  @override
  String get byContinuingAgree =>
      'بالمتابعة توافق على شروط الخدمة وسياسة الخصوصية الخاصة بـ قرش.';

  @override
  String get enterOtpCode => 'أدخل رمز التحقق';

  @override
  String get otpSentTo =>
      'اكتب الكود اللي وصلك على البريد ده. راجع الرسائل غير المرغوب فيها كمان.';

  @override
  String get verifyCode => 'تأكيد الرمز';

  @override
  String get demoOtpCode => 'للتجربة: الرمز 123456';

  @override
  String get invalidOtpCode => 'الرمز غير صحيح';

  @override
  String get enterPasswordOrRecoveryCodeError =>
      'اكتب كلمة مرور النسخة أو رمز الاسترداد.';

  @override
  String get recoveryCodeIncorrect =>
      'رمز الاسترداد غير صحيح أو لا يطابق النسخة.';

  @override
  String get backupPasswordIncorrect =>
      'كلمة مرور النسخة الاحتياطية غير صحيحة.';

  @override
  String get backupFound => 'وجدنا نسخة احتياطية لحسابك';

  @override
  String get restoreDesc =>
      'استعادة بياناتك المشفّرة تتم على جهازك فقط. كلمة المرور لا تخرج من هاتفك.';

  @override
  String get recoveryCodeLabel => 'رمز الاسترداد';

  @override
  String get backupPasswordLabel => 'كلمة مرور النسخة الاحتياطية';

  @override
  String get recoveryCodeHint => 'XXXX-XXXX-XXXX';

  @override
  String get backupPasswordHint => 'اكتب كلمة المرور التي اخترتها';

  @override
  String get useBackupPassword => 'استخدام كلمة مرور النسخة';

  @override
  String get useRecoveryCode => 'استخدام رمز الاسترداد';

  @override
  String get restore => 'استعادة';

  @override
  String get startFresh => 'ابدأ جديد';

  @override
  String get notNow => 'ليس الآن';

  @override
  String get restoreNotEnabled =>
      'الاستعادة السحابية غير مفعّلة في هذا البناء.';

  @override
  String get appleSecuritySteps => 'خطوات الأمان لآبل';

  @override
  String get iosShortcutSubtitle =>
      'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ قرش تلقائياً وبأمان تام.';

  @override
  String get stepsLabel => 'الخطوات:';

  @override
  String get multipleCurrenciesQuestion => 'تتعامل بأكثر من عملة؟';

  @override
  String get multipleCurrenciesDesc =>
      'إذا كانت تصلك رسائل بنكية بعملات مختلفة، كرّر نفس الخطوات لكل عملة.';

  @override
  String get continueWithoutAccount => 'أكمل بدون حساب';

  @override
  String get continueWithoutAccountSub => 'بياناتك تبقى محلية على جهازك.';

  @override
  String get smsPermissionRationaleTitle => 'محتاجين إذن قراءة رسائل البنك بس';

  @override
  String get smsPermissionRationaleBody =>
      'يقرأ قِرش رسائل المصرف الواردة على جهازك ليسجّل عملياتك تلقائيًا. لا يقرأ رسائلك الشخصية، ويتم التحليل على الجهاز افتراضيًا — لا يخرج منه شيء إلا إذا فعّلت المعالجة السحابية بنفسك.';

  @override
  String get listeningTitle => 'جاهزين — بنستنى رسالتك الأولى';

  @override
  String get listeningSubtitle => 'اعمل أي شراء بكارتك وهيظهر هنا تلقائياً.';

  @override
  String get pasteMessageInstead => 'ألصق رسالة مصرفية بدلًا من ذلك';

  @override
  String get skipForNow => 'تخطي الآن';

  @override
  String get shortcutVerifyTitle => 'خلينا نتأكد إن الاختصار شغّال';

  @override
  String get shortcutVerifyBody =>
      'ارجع لتطبيق Shortcuts وابعت نفسك رسالة فيها كلمة العملة، ثم ارجع هنا.';

  @override
  String get shortcutVerifyWaiting => 'بنستنى رسالة...';

  @override
  String get recheckSetup => 'راجع الإعداد';

  @override
  String get filterKeywordsLabel => 'كلمة المفتاح:';

  @override
  String get firstTxTitle => 'أول عملية اتسجّلت لوحدها!';

  @override
  String get firstTxTrustLine =>
      'لم تفعل شيئًا — قرأ قِرش رسالة مصرفك وسجّلها.';

  @override
  String get firstTxContinue => 'تمام، كمّل';

  @override
  String get firstTxNeedsCheck => 'محتاجة تأكيد سريع';

  @override
  String get firstTxNeedsCheckSub => 'قِرش غير متأكد تمامًا — راجعها سريعًا.';

  @override
  String get wrongCategoryTap => 'التصنيف غير صحيح؟ اضغط لتغييره';

  @override
  String get couponsTitle => 'العروض';

  @override
  String get couponsSubtitle => 'عروض شركاء تساعدك توفر في مصروفاتك اليومية.';

  @override
  String get couponsFilterAll => 'الكل';

  @override
  String get couponsFeaturedSection => 'عروض مميزة';

  @override
  String get couponsEmptyTitle => 'لا توجد عروض حالياً';

  @override
  String get couponsEmptyBody => 'هنعرض لك عروض الشركاء هنا أول ما تكون متاحة.';

  @override
  String get couponsFilterEmptyTitle => 'لا توجد عروض بهذا الفلتر';

  @override
  String get couponsFilterEmptyBody => 'جرّب فئة أو وسم مختلف.';

  @override
  String get couponsErrorTitle => 'تعذر تحميل العروض';

  @override
  String get couponsErrorBody => 'حاول مرة أخرى بعد لحظات.';

  @override
  String get couponsRetry => 'إعادة المحاولة';

  @override
  String get couponsLoading => 'تحميل العروض...';

  @override
  String get couponsCopyCode => 'نسخ الكود';

  @override
  String couponsCodeCopied(String code) {
    return 'تم نسخ الكود $code';
  }

  @override
  String get couponsOpenPartner => 'فتح موقع الشريك';

  @override
  String get couponsUseOffer => 'احصل على العرض';

  @override
  String get couponsOpenFailed => 'تعذّر فتح الرابط';

  @override
  String get couponsOfferUnavailable => 'هذا العرض غير متاح حاليًا';

  @override
  String get couponsTerms => 'الشروط';

  @override
  String couponsValidUntil(String date) {
    return 'ينتهي $date';
  }

  @override
  String get couponsOpenEnded => 'مفتوح';

  @override
  String get couponsExpiresToday => 'ينتهي اليوم';

  @override
  String couponsExpiresInDays(int days) {
    return '$days يوم';
  }

  @override
  String get couponsAvailableGlobally => 'متاح في كل الدول';

  @override
  String couponsAvailableIn(String countries) {
    return 'متاح في $countries';
  }

  @override
  String couponsCardSemantics(String partner, String title) {
    return 'عرض من $partner: $title';
  }

  @override
  String couponsCodeSemantics(String code) {
    return 'كود الخصم $code';
  }

  @override
  String get couponsOffline => 'هذه آخر العروض المتاحة لديك دون اتصال.';

  @override
  String get referralTitle => 'دعوة الأصدقاء';

  @override
  String get referralSubtitle =>
      'ادعُ أصدقاءك بالرمز، ولما ينضمّوا ويأكّدوا حسابهم تكسب تقارير بدون إعلانات.';

  @override
  String get referralYourCodeLabel => 'رمز الدعوة';

  @override
  String get referralCopyAction => 'نسخ';

  @override
  String get referralCopiedToast => 'تم نسخ الرمز.';

  @override
  String get referralShareAction => 'مشاركة';

  @override
  String referralShareMessage(String code) {
    return 'جرّب قرش! استخدم رمز الدعوة $code وانت بتسجّل. حمّل التطبيق وابدأ.';
  }

  @override
  String referralProgressLabel(int progress, int required) {
    return '$progress / $required دعوات صالحة';
  }

  @override
  String referralCycleLabel(int cycle) {
    return 'الدورة $cycle';
  }

  @override
  String get referralRewardTitle => 'المكافأة';

  @override
  String referralRewardDays(int days) {
    return 'تقارير بدون إعلانات لمدة $days يومًا';
  }

  @override
  String get referralRewardScopeNote =>
      'تزيل المكافأة إعلانات تصدير التقارير فقط — وليست اشتراكًا بلا إعلانات لكامل التطبيق.';

  @override
  String referralRewardActiveUntil(String date) {
    return 'تقارير بدون إعلانات حتى $date';
  }

  @override
  String get referralEntitlementInactive => 'لا توجد مكافأة نشطة حاليًا.';

  @override
  String get referralApplyTitle => 'عندك رمز دعوة؟';

  @override
  String get referralApplyHint => 'أدخل رمز صديقك مرة واحدة.';

  @override
  String get referralApplyPlaceholder => 'رمز الدعوة';

  @override
  String get referralApplyAction => 'تفعيل الرمز';

  @override
  String get referralApplySuccess => 'تم قبول الرمز.';

  @override
  String get referralQualifiedToast => 'تم احتساب دعوتك.';

  @override
  String get referralAlreadyReferredNote => 'تم تفعيل رمز دعوة على حسابك.';

  @override
  String get referralLoading => 'جارٍ التحميل…';

  @override
  String get referralErrorTitle => 'تعذّر تحميل الدعوات';

  @override
  String get referralErrorBody => 'حاول مرة أخرى بعد لحظات.';

  @override
  String get referralRetry => 'إعادة المحاولة';

  @override
  String get referralUnavailableTitle => 'الدعوات غير متاحة حاليًا';

  @override
  String get referralUnavailableBody =>
      'هنعرض لك دعوة الأصدقاء هنا أول ما تكون متاحة.';

  @override
  String get referralErrorInvalidCode => 'رمز غير صحيح.';

  @override
  String get referralErrorSelfReferral => 'لا يمكنك استخدام رمزك الخاص.';

  @override
  String get referralErrorAlreadyReferred => 'لقد استخدمت رمز دعوة من قبل.';

  @override
  String get referralErrorNoActiveRule => 'الدعوات غير متاحة حاليًا.';

  @override
  String get referralErrorIdentityUnverified =>
      'أكمل تأكيد حسابك لتُحتسب دعوتك.';

  @override
  String get referralErrorGeneric => 'حصل خطأ، حاول تاني.';

  @override
  String get smsDisclosureTitle => 'قراءة رسائل البنك تلقائياً';

  @override
  String get smsDisclosureIntro =>
      'ليسجّل قِرش مصاريفك تلقائيًا، يحتاج إذن قراءة الرسائل الواردة على جهازك.';

  @override
  String get smsDisclosureDetect =>
      'يفحص قِرش الرسائل الواردة ليتعرّف على العمليات المالية (شراء، تحويل، سحب، إيداع).';

  @override
  String get smsDisclosureFilter =>
      'تُستبعد على جهازك الرسائل التي لا تبدو مالية — مثل الرسائل الشخصية ورموز التحقق — ولا تُخزَّن. هذا الفحص آلي وقد يحتفظ أحيانًا برسالة عن طريق الخطأ، ويمكنك حذفها من قِرش. وتُخزَّن الرسائل المحتفَظ بها مشفّرة على جهازك، وقد تُعالَج في الخلفية.';

  @override
  String get smsDisclosureOnDevice =>
      'عند إيقاف «التحليل الذكي والمزامنة السحابية» تُقرأ الرسائل على جهازك فقط. وإذا فعّلته، تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش وقد يحلّلها Google Gemini، بعد حذف أرقام البطاقات والحسابات والهواتف والآيبان والرموز، وإخفاء ما يُتعرَّف عليه من أسماء وعناوين بريد إلكتروني وأرقام مرجعية. يبقى في النص المبلغ والتاجر والتاريخ والرصيد وآخر أرقام البطاقة، لذا يظل معلومات مالية شخصية تخصّك.';

  @override
  String get smsDisclosureCloud =>
      '«التحليل الذكي والمزامنة السحابية» خيار منفصل عن هذا الإذن، ويبقى متوقفًا ما لم توافق عليه، ويمكنك سحب موافقتك في أي وقت من الإعدادات ← الخصوصية.';

  @override
  String get smsDisclosureControl =>
      'تقدر توقف القراءة التلقائية من إعدادات قِرش، أو تسحب الإذن من إعدادات الجهاز، في أي وقت.';

  @override
  String get smsDisclosureDecline => 'ليس الآن';

  @override
  String get smsDisclosureAccept => 'موافق، اطلب الإذن';

  @override
  String get couponsForYouSection => 'لأماكن تتسوق منها';

  @override
  String get couponsForYouSubtitle =>
      'مطابقة تمت على هذا الجهاز من مصروفاتك. لا يُرسَل أي شيء منها لأي مكان.';

  @override
  String get couponsStoresSection => 'المتاجر';

  @override
  String get couponsStoresSubtitle => 'متاجر لديها عروض سارية.';

  @override
  String couponsMerchantOffers(String merchant) {
    return 'عروض $merchant';
  }

  @override
  String get couponsMerchantEmptyTitle => 'لا توجد عروض سارية هنا الآن';

  @override
  String get couponsMerchantEmptyBody =>
      'لا عروض لهذا المتجر حاليًا. تابعنا لاحقًا.';

  @override
  String get couponsPersonalizationTitle => 'رتّب العروض حسب أماكن تسوقك';

  @override
  String get couponsPersonalizationBody =>
      'يطابق قِرش عملياتك مع المتاجر على هذا الجهاز ويعرض عروضها أولًا. مصروفاتك لا تغادر هاتفك من أجل هذا، ولا تُرسَل للمتاجر.';

  @override
  String get couponsPersonalizationOff => 'مُعطّل — ترتيب العروض واحد للجميع.';

  @override
  String get couponsPersonalizationOn =>
      'مُفعّل — عروض المتاجر التي تستخدمها تظهر أولًا.';

  @override
  String couponsValuePercent(String percent) {
    return 'خصم $percent%';
  }

  @override
  String couponsValueFixed(String amount) {
    return 'خصم $amount';
  }

  @override
  String get couponsValueFreeShipping => 'توصيل مجاني';

  @override
  String couponsValueMinSpend(String amount) {
    return 'عند $amount أو أكثر';
  }

  @override
  String couponsValueUpTo(String amount) {
    return 'حتى $amount';
  }

  @override
  String get couponsVerifiedByUs => 'تحقّق منه قِرش';

  @override
  String get couponsVerifiedByProvider => 'مؤكَّد من المزوّد';

  @override
  String get couponsUnverified => 'غير مُتحقَّق منه';

  @override
  String get savingsTitle => 'ما وفّرته';

  @override
  String get savingsEmptyTitle => 'لا توجد مبالغ موفَّرة بعد';

  @override
  String get savingsEmptyBody => 'عند استخدامك عرضًا وتأكيده، سيظهر هنا.';

  @override
  String get savingsVerifiedLabel => 'مؤكَّد من المتجر';

  @override
  String get savingsEstimatedLabel => 'تقديري';

  @override
  String get savingsSelfReportedLabel => 'بتأكيدك أنت';

  @override
  String get savingsBreakdownNote =>
      'نفصل هذه الأرقام لأنها ليست بنفس درجة التأكيد. المؤكَّد فقط هو ما أبلغنا به المتجر.';

  @override
  String get savingsCurrencyNote => 'العملات لا تُجمع معًا.';

  @override
  String get savingsConfirmTitle => 'هل استخدمت هذا العرض؟';

  @override
  String get savingsConfirmBody =>
      'أدخل قيمة طلبك لنحسب ما وفّرته. الحساب يتم على جهازك ولا يُرسَل لأي مكان.';

  @override
  String get savingsConfirmAmountLabel => 'قيمة الطلب';

  @override
  String get savingsConfirmAction => 'احسب';

  @override
  String get savingsCannotCompute =>
      'لا يمكننا حساب رقم دقيق لهذا العرض، فلن نعرض رقمًا.';

  @override
  String get savingsReversedNote =>
      'أُلغي هذا المبلغ بعد أن تراجع المتجر عن العملية.';

  @override
  String get adLabel => 'إعلان';

  @override
  String get smsAutoCaptureTitle => 'الالتقاط التلقائي لرسائل البنك';

  @override
  String get smsAutoCaptureSubtitleOff =>
      'مطفأ — أضف عملياتك يدويًا أو بالمشاركة';

  @override
  String get smsAutoCaptureSubtitleOn =>
      'يعمل — تُقرأ رسائل البنك الواردة على جهازك';

  @override
  String get smsAutoCaptureSubtitleOnSmart =>
      'يعمل — تُرسَل رسائل البنك بعد حذف الأرقام الحساسة إلى خوادم قِرش وقد يحلّلها Google Gemini';

  @override
  String get smsAutoCaptureSubtitleBlocked =>
      'تم رفض الإذن — افتح إعدادات النظام للسماح';

  @override
  String get smsAutoCaptureOpenSettings => 'فتح إعدادات النظام';

  @override
  String get smsAutoCaptureDeniedTitle => 'لم يُمنح الإذن';

  @override
  String get smsAutoCaptureDeniedBody =>
      'الالتقاط التلقائي يحتاج إذن قراءة الرسائل الواردة. تقدر تكمل بالإضافة اليدوية أو بمشاركة الرسالة مع قرش.';

  @override
  String get smsCaptureTrustNotice =>
      'على أندرويد، قرش يقرأ الرسائل الواردة فقط بعد ما تشغّل الالتقاط التلقائي وتمنح الإذن. لا يقرأ إشعارات تطبيقات البنوك، ولا يفتح أرشيف رسائلك.';

  @override
  String get commonCancel => 'إلغاء';

  @override
  String get helpTitle => 'كيف تستخدم قِرش';

  @override
  String get helpSubtitle => 'دليل مختصر لأهم ما يمكنك فعله في التطبيق.';

  @override
  String get helpSettingsTile => 'كيف تستخدم قِرش';

  @override
  String get helpSettingsSubtitle => 'دليل الاستخدام والأسئلة الشائعة';

  @override
  String get helpSectionBasics => 'الأساسيات';

  @override
  String get helpSectionReports => 'التقارير والتحليلات';

  @override
  String get helpSectionPlanning => 'التخطيط';

  @override
  String get helpSectionPrivacy => 'الخصوصية والبيانات';

  @override
  String get helpAddTransactionTitle => 'تسجيل عملية';

  @override
  String get helpAddTransactionBody =>
      'اضغط زر الإضافة في الشاشة الرئيسية، ثم اختر الإضافة اليدوية أو الصق نص رسالة البنك. يقرأ قِرش الرسالة ويستخرج المبلغ والتاجر والتاريخ، وتبقى لك الكلمة الأخيرة قبل الحفظ.';

  @override
  String get helpSmartInboxTitle => 'صندوق الوارد الذكي';

  @override
  String get helpSmartInboxBody =>
      'العمليات التي يلتقطها قِرش من رسائل البنك تصل هنا أولًا. راجعها وأكّدها أو عدّل تصنيفها، فتنتقل بعدها إلى سجل عملياتك.';

  @override
  String get helpCategoriesTitle => 'التصنيفات';

  @override
  String get helpCategoriesBody =>
      'لكل عملية تصنيف يحدد مكانها في التقارير والميزانيات. غيّر التصنيف من تفاصيل العملية، ويتعلّم قِرش اختيارك للمتجر نفسه مستقبلًا.';

  @override
  String get helpPeriodTitle => 'تغيير الفترة';

  @override
  String get helpPeriodBody =>
      'أعلى قوائم العمليات والتقارير تجد مُحدِّد الفترة: اليوم، الأسبوع، الشهر، السنة، أو مدى مخصص. كل الأرقام في الشاشة تتبع الفترة المختارة.';

  @override
  String get helpAnnualTitle => 'التقرير السنوي';

  @override
  String get helpAnnualBody =>
      'اختر «هذه السنة» أو «السنة الماضية» من مُحدِّد الفترة لتقرأ سلوكك المالي على مدار سنة كاملة: الإجمالي، التصنيفات، الاتجاهات، وأكثر المتاجر إنفاقًا.';

  @override
  String get helpAccountsTitle => 'الحسابات والبطاقات';

  @override
  String get helpAccountsBody =>
      'أضف حسابًا لكل محفظة أو بنك، ولكل حساب عملته الخاصة. تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافتها يدويًا.';

  @override
  String get helpBudgetsTitle => 'الميزانيات';

  @override
  String get helpBudgetsBody =>
      'حدد سقفًا لتصنيف أو لكل المصروفات، واختر دوريته. ينبّهك قِرش عند بلوغ 80% ثم عند التجاوز.';

  @override
  String get helpGoalsTitle => 'الأهداف';

  @override
  String get helpGoalsBody =>
      'أنشئ هدف ادخار بمبلغ وموعد، ثم أضف إليه مساهمات. يحسب قِرش المبلغ اليومي الموصى به ليبقى الهدف في مساره.';

  @override
  String get helpPrivacyTitle => 'تحكّمك في بياناتك';

  @override
  String get helpPrivacyBody =>
      'بياناتك المالية محفوظة على جهازك ومشفّرة. من شاشة الخصوصية يمكنك التحكم في المعالجة السحابية والتحليل بالذكاء الاصطناعي، وسحب موافقتك في أي وقت.';

  @override
  String get helpBackupTitle => 'النسخ الاحتياطي والاستعادة';

  @override
  String get helpBackupBody =>
      'صدّر نسخة مشفّرة من بياناتك واحتفظ بها، أو استعدها على جهاز آخر. تتم المعاينة على جهازك قبل أي كتابة، ولا تخرج كلمة المرور منه.';

  @override
  String get helpFooter => 'لم تجد إجابتك؟ راسلنا من شاشة الإعدادات.';

  @override
  String get coachMarkNext => 'التالي';

  @override
  String get coachMarkDone => 'تمام';

  @override
  String get coachMarkSkip => 'تخطّي';

  @override
  String get coachDashboardAddTitle => 'سجّل أول عملية';

  @override
  String get coachDashboardAddBody =>
      'من زر الإضافة تسجّل عملية يدويًا أو تلصق نص رسالة البنك ليقرأها قِرش نيابةً عنك.';

  @override
  String get coachDashboardPeriodTitle => 'اختر الفترة';

  @override
  String get coachDashboardPeriodBody =>
      'اختار اليوم أو الأسبوع أو الشهر لتغيير الملخص المالي المعروض.';

  @override
  String get coachDashboardInboxTitle => 'صندوق الوارد الذكي';

  @override
  String get coachDashboardInboxBody =>
      'ما يلتقطه قِرش من رسائل البنك ينتظرك هنا للمراجعة قبل أن يدخل سجلك.';

  @override
  String get coachDashboardHelpTitle => 'الدليل متاح دائمًا';

  @override
  String get coachDashboardHelpBody =>
      'تجد «كيف تستخدم قِرش» في الإعدادات في أي وقت، ويمكنك إعادة هذه الجولة من هناك.';

  @override
  String get helpReplayTour => 'إعادة الجولة التعريفية';

  @override
  String get helpReplayTourDone => 'ستظهر الجولة التعريفية من جديد.';

  @override
  String get setLoadingCountries => 'تحميل الدول...';

  @override
  String get setLoadingCurrencies => 'تحميل العملات...';

  @override
  String get setCountry => 'الدولة';

  @override
  String get setBaseCurrency => 'العملة الأساسية';

  @override
  String get bfBudgetAlert => 'تنبيه الميزانية';

  @override
  String get bfBudgetAlertHint =>
      'ننبّهك عند بلوغ إنفاقك هذه النسبة من الميزانية.';

  @override
  String bfBudgetAlertValue(String percent) {
    return '$percent٪ من الميزانية';
  }

  @override
  String get setLanguage => 'اللغة';

  @override
  String get setName => 'الاسم';

  @override
  String get setNameInApp => 'اسمك في التطبيق';

  @override
  String get setAccountData => 'بيانات حسابك';

  @override
  String get setMobileNumber => 'رقم الموبايل';

  @override
  String get setAddYourNumber => 'أضف رقمك';

  @override
  String get setAppearance => 'المظهر';

  @override
  String get setAppearanceSub => 'فاتح، داكن، أو حسب النظام';

  @override
  String get setAccountsAndDues => 'حساباتك والتزاماتك';

  @override
  String get setSyncConflicts => 'تعارضات المزامنة';

  @override
  String get setSyncConflictsSub =>
      'عناصر عُدّلت على أكثر من جهاز — بحاجة لقرارك';

  @override
  String get setAccountsWallets => 'الحسابات والمحافظ';

  @override
  String get setAccountsWalletsSub => 'حسابات متعددة، كل واحد بعملته الخاصة';

  @override
  String get setAllCards => 'كل البطاقات';

  @override
  String get setAllCardsSub => 'نظرة عامة على بطاقاتك مجمّعة حسب الحساب';

  @override
  String get setSubsAndBills => 'الاشتراكات والفواتير';

  @override
  String get setSubsAndBillsSub => 'التزاماتك الدورية ومواعيد السداد';

  @override
  String get setPlans => 'الخطط';

  @override
  String get setPlansSub => 'ميزانية رحلة أو مناسبة تتابع نفسها';

  @override
  String get setToolsAndSettings => 'أدوات وإعدادات';

  @override
  String get setCategories => 'التصنيفات';

  @override
  String get setCategoriesSub => 'نظم المصروفات والدخل والتحويلات';

  @override
  String get setAchievements => 'الإنجازات والمستوى';

  @override
  String get setAchievementsSub => 'شارات ومستويات تشجع عادة المتابعة';

  @override
  String get setCurrencyRepair => 'تأكيد عملة الميزانيات والأهداف';

  @override
  String get setCurrencyRepairSub => 'راجع عملة بيانات التخطيط القديمة بأمان';

  @override
  String get setAppleShortcut => 'اختصار آبل';

  @override
  String get setAppleShortcutSub => 'مرر رسائل البنك إلى قرش عبر Shortcuts';

  @override
  String get setRewardsAndSupport => 'المكافآت والدعم';

  @override
  String get setInviteFriends => 'دعوة الأصدقاء';

  @override
  String get setInviteFriendsSub => 'شارك رمز دعوتك واكسب تقارير بدون إعلانات';

  @override
  String get setAdPrivacyOptions => 'خيارات خصوصية الإعلانات';

  @override
  String get setAdPrivacyOptionsSub => 'إدارة موافقتك على الإعلانات';

  @override
  String get setContactUs => 'تواصل معنا';

  @override
  String get setContactUsSub => 'الدعم الفني والإجابة على استفساراتك';

  @override
  String get setAboutQirsh => 'عن قرش';

  @override
  String get setAboutQirshSub => 'معلومات التطبيق والإصدار';

  @override
  String get setCaptureStatus => 'رصد العمليات';

  @override
  String get setCaptureStatusSub => 'حالة الربط مع رسائل البنك واختصار آبل';

  @override
  String get setConfirmCaptured => 'تأكيد العمليات الملتقطة';

  @override
  String get setNotifyOnCapture => 'إشعار عند التقاط عملية';

  @override
  String get setHideOnLockScreen => 'إخفاء التفاصيل الحساسة على شاشة القفل';

  @override
  String get setYourAlerts => 'تنبيهاتك';

  @override
  String get setQirshMessages => 'رسائل ونصائح قرش';

  @override
  String get setBudgetAlerts => 'تنبيهات الميزانية';

  @override
  String get setBudgetOverAlert => 'تنبيه تجاوز الميزانية';

  @override
  String get setDailyReminder => 'التذكير اليومي';

  @override
  String get setDailyReminderTime => 'كل يوم الساعة 10 مساءً';

  @override
  String get setWeeklyReport => 'التقرير الأسبوعي';

  @override
  String get setBillReminders => 'تذكير الاشتراكات والفواتير';

  @override
  String get setGoalCelebrations => 'احتفالات الأهداف';

  @override
  String get setAchievementAlerts => 'تنبيهات الإنجازات';

  @override
  String get setQuietHours => 'ساعات الهدوء';

  @override
  String get setDisabled => 'معطّل';

  @override
  String get setEditQuietHours => 'تعديل وقت الهدوء';

  @override
  String get setNotificationTools => 'أدوات الإشعارات';

  @override
  String get setTestNotifications => 'اختبار إشعارات قرش';

  @override
  String get setTestNotificationsSub => 'أرسل إشعارًا تجريبيًا إلى هذا الجهاز';

  @override
  String get setMessageCentre => 'مركز رسائل قرش';

  @override
  String get setMessageCentreSub => 'الإشعارات والحملات والإعلانات السابقة';

  @override
  String get setDataTransfer => 'نقل البيانات';

  @override
  String get setDataTransferSub => 'بياناتك المالية تظل تحت سيطرتك';

  @override
  String get setImportFile => 'استيراد ملف';

  @override
  String get setImportFileSub => 'CSV من أي تطبيق أو ZIP صادر من قرش';

  @override
  String get setExportCsv => 'تصدير العمليات CSV';

  @override
  String get setExportCsvSub => 'ملف بسيط لكل عملياتك';

  @override
  String get setExportAll => 'تصدير كل بيانات قرش';

  @override
  String get setExportAllSub => 'حزمة ZIP قابلة للنقل والاستعادة';

  @override
  String get setSecurityPrivacy => 'الأمان والخصوصية';

  @override
  String get setEncryptedDbPart1 =>
      'بياناتك على الجهاز مخزّنة بقاعدة بيانات مشفّرة، ';

  @override
  String get setEncryptedDbPart2 => 'ومفتاحها محفوظ في خزنة النظام';

  @override
  String get setPrivacyAndData => 'الخصوصية والبيانات';

  @override
  String get setPrivacyAndDataSub => 'أمان بياناتك وسياسة الخصوصية';

  @override
  String get setHideAmounts => 'إخفاء الأرقام في الواجهة';

  @override
  String get setExitAndErase => 'الخروج وحذف البيانات';

  @override
  String get setExitAndEraseSub => 'إجراءات لا يمكن التراجع عن بعضها';

  @override
  String get setStartOver => 'ابدأ من جديد';

  @override
  String get setStartOverSub => 'امسح البيانات المحلية مع إبقاء الحساب نشطًا';

  @override
  String get setSignOut => 'تسجيل الخروج';

  @override
  String get setDeleteAccount => 'حذف الحساب وكل بياناتي';

  @override
  String get setDeleteAccountSub => 'إجراء نهائي يتطلب تأكيدك';

  @override
  String get setTestNotificationSent => 'أرسلنا إشعاراً تجريبياً من قرش.';

  @override
  String get setTestNotificationFailed => 'تعذّر إرسال الإشعار التجريبي.';

  @override
  String get setUnsyncedData => 'بيانات غير محفوظة سحابيًا';

  @override
  String get setCancel => 'إلغاء';

  @override
  String get setSignOutDiscard => 'تسجيل الخروج وحذف غير المحفوظ';

  @override
  String get setUnsyncedCheckFailed =>
      'تعذّر التحقق من البيانات غير المحفوظة. حاول مجدداً.';

  @override
  String get rebootUpdatingData => 'جارٍ تحديث بياناتك…';

  @override
  String get setDataRemovedNotice => 'تم حذف البيانات من هذا الجهاز';

  @override
  String get smartConsentAiNeedsCloud =>
      'فعّل المزامنة السحابية أولاً لاستخدام التحليل الذكي.';

  @override
  String get setSignOutFailed => 'تعذّر تسجيل الخروج بأمان. حاول مجدداً.';

  @override
  String get setPhotoUpdated => 'تم تحديث الصورة.';

  @override
  String get setSave => 'حفظ';

  @override
  String get setCategoriesSheetIntro =>
      'أضف أو عدّل التصنيفات التي تظهر في العمليات والتقارير.';

  @override
  String get setAddCategory => 'إضافة تصنيف';

  @override
  String get setExpenses => 'مصروفات';

  @override
  String get setIncome => 'دخل';

  @override
  String get setTransfers => 'تحويلات';

  @override
  String get setEditCategory => 'تعديل تصنيف';

  @override
  String get setCategoryName => 'اسم التصنيف';

  @override
  String get setIncomeCategory => 'تصنيف دخل';

  @override
  String get setIcon => 'الأيقونة';

  @override
  String get setColor => 'اللون';

  @override
  String get setEnterCategoryName => 'اكتب اسم التصنيف.';

  @override
  String get setSaveChanges => 'حفظ التعديلات';

  @override
  String get setAdd => 'إضافة';

  @override
  String get setDeleteCategoryQ => 'حذف التصنيف؟';

  @override
  String get setDeleteCategoryBody =>
      'سيتم نقل عملياته إلى «أخرى» أو «دخل»، وحذف أي ميزانية مرتبطة به.';

  @override
  String get setDelete => 'حذف';

  @override
  String get setQuietHoursNote =>
      'نؤجل الإشعارات المجدولة خلال هذه الفترة لأول وقت مسموح.';

  @override
  String get setStarts => 'تبدأ';

  @override
  String get setEnds => 'تنتهي';

  @override
  String get setAboutApp => 'عن التطبيق';

  @override
  String get setAboutBody =>
      'قرش لتتبع المصروفات من رسائل البنك والإدخال اليدوي. يمكنك نقل بياناتك المالية كملفات CSV أو حزمة ZIP من قسم البيانات والخصوصية.';

  @override
  String get setOk => 'تمام';

  @override
  String get setSupportBody =>
      'للدعم أو الملاحظات انسخ البريد وأرسل لنا تفاصيل المشكلة، نوع الجهاز، وخطوات تكرارها.';

  @override
  String get setCopyEmail => 'نسخ البريد';

  @override
  String get setEraseAllQ => 'مسح جميع البيانات؟';

  @override
  String get setEraseAllBody =>
      'سيتم مسح جميع بياناتك المحلية. لا يمكن التراجع.';

  @override
  String get setErase => 'مسح';

  @override
  String get setSettingsLoadFailed =>
      'تعذر تحميل الإعدادات. حاول مرة أخرى بعد قليل.';

  @override
  String get setSettings => 'الإعدادات';

  @override
  String get setBack => 'رجوع';

  @override
  String get setThemeAuto => 'تلقائي';

  @override
  String get setThemeLight => 'فاتح';

  @override
  String get setThemeDark => 'داكن';

  @override
  String get setEdit => 'تعديل';

  @override
  String get setAppLockFailed =>
      'تعذر تفعيل القفل. تأكد من إعداد بصمة أو رمز للجهاز.';

  @override
  String get setAppLock => 'قفل التطبيق';

  @override
  String get setNoBankMessageYet => 'لم نرصد أي رسالة بنكية بعد';

  @override
  String get setCaptureEnableFailed => 'تعذّر تفعيل إشعارات رصد البنك';

  @override
  String get setNoBankMessagesRecently => 'لم نستقبل رسائل بنكية منذ فترة';

  @override
  String get setBankCaptureStatus => 'حالة رصد رسائل البنك';

  @override
  String get setCheck => 'تحقق';

  @override
  String get setBackupFirst => 'خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.';

  @override
  String get setToday => 'اليوم';

  @override
  String get bdgError => 'حدث خطأ';

  @override
  String get bdgTabBudgets => 'الميزانيات';

  @override
  String get bdgTabHistory => 'سجل الميزانيات';

  @override
  String get bdgTabGoals => 'الأهداف';

  @override
  String get bdgEmptyBudgetsTitle => 'لا توجد ميزانيات';

  @override
  String get bdgEmptyBudgetsBody =>
      'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.';

  @override
  String get bdgEmptyGoalsTitle => 'لا توجد أهداف';

  @override
  String get bdgEmptyGoalsBody =>
      'أضف هدف ادخار ليتابع قِرش تقدمك إلى جانب ميزانياتك.';

  @override
  String get bdgAddGoal => 'إضافة هدف';

  @override
  String get bdgEmptyHistoryTitle => 'السجل فارغ';

  @override
  String get bdgEmptyHistoryBody =>
      'اختر فترة تحتوي على ميزانيات أو أضف ميزانية جديدة، وسيظهر كل يوم/أسبوع/شهر هنا كسجلّ منفصل.';

  @override
  String get bdgAddBudget => 'إضافة ميزانية';

  @override
  String get bdgDeleteTitle => 'حذف الميزانية؟';

  @override
  String get bdgDeleteBody => 'سيُحذف سقف الميزانية. لن تتأثر العمليات نفسها.';

  @override
  String get bdgDeleteFailed => 'تعذّر حذف الميزانية الآن.';

  @override
  String get bdgFilterAll => 'الكل';

  @override
  String get bdgFilterDaily => 'يومي';

  @override
  String get bdgFilterWeekly => 'أسبوعي';

  @override
  String get bdgFilterMonthly => 'شهري';

  @override
  String get bdgFilterYearly => 'سنوي';

  @override
  String get bdgStatHistoryCount => 'ميزانيات في السجل';

  @override
  String get bdgStatTargetSavings => 'مجموع المدخرات المستهدفة';

  @override
  String get bdgStatTotalBudgeted => 'إجمالي الميزانيات المرصودة';

  @override
  String get bdgStatActiveGoals => 'أهداف نشطة';

  @override
  String get bdgStatProgress => 'نسبة التقدم';

  @override
  String get bdgStatTotalSaved => 'إجمالي الادخار';

  @override
  String get bdgStateSafeF => 'آمنة';

  @override
  String get bdgStateNear => 'اقتربت';

  @override
  String get bdgStateOverF => 'تجاوزت';

  @override
  String get bdgBudgetsWord => 'ميزانيات';

  @override
  String get bdgUsageRate => 'نسبة الاستهلاك';

  @override
  String get bdgActualSpend => 'المصروف الفعلي';

  @override
  String get bdgBudgetWord => 'ميزانية';

  @override
  String get bdgOver => 'تجاوز';

  @override
  String get bdgSafe => 'آمن';

  @override
  String get bdgAllExpenses => 'كل المصروفات';

  @override
  String get bdgCategory => 'تصنيف';

  @override
  String get bdgSpent => 'مصروف';

  @override
  String get bdgRemaining => 'باقي';

  @override
  String get bdgLimit => 'الحد';

  @override
  String get bdgSaved => 'وفّرت';

  @override
  String get bdgPeriodCurrent => 'الفترة الحالية';

  @override
  String get bdgPeriodOver => 'فترة تجاوزت الحد';

  @override
  String get bdgPeriodEnded => 'فترة منتهية';

  @override
  String get bdgRecordLive => 'ما زال هذا السجل يُحدَّث حتى نهاية الفترة.';

  @override
  String get bdgRecordFinal =>
      'هذا السجل محسوب من العمليات الفعلية داخل هذه الفترة.';

  @override
  String get bdgEditBudget => 'تعديل الميزانية';

  @override
  String get bdgPeriodTransactions => 'عمليات الفترة';

  @override
  String get bdgNoConfirmedTx => 'لم تُسجَّل عمليات مؤكدة ضمن هذه الفترة.';

  @override
  String get bdgCountedOpenAll =>
      'داخلة في الحساب — افتح «العمليات» لعرضها كلها.';

  @override
  String get bdgDailyBudget => 'ميزانية يومية';

  @override
  String get bdgWeeklyBudget => 'ميزانية أسبوعية';

  @override
  String get bdgYearlyBudget => 'ميزانية سنوية';

  @override
  String get bdgMonthlyBudget => 'ميزانية شهرية';

  @override
  String get bdgTransactionWord => 'عملية';

  @override
  String get bdgGoalDone => 'اكتمل الهدف';

  @override
  String get bdgEnvelopeTitle => 'وزّع دخلك على المظاريف';

  @override
  String get bdgEnvelopeBody =>
      'اكتب راتبك ووزّعه بضغطة — و«قِرش» يحسب لك المتاح كل يوم';

  @override
  String bdgMoreTxCounted(int count) {
    return 'باقي $count عملية داخلة في الحساب — افتح «العمليات» لعرضها كلها.';
  }

  @override
  String get txnError => 'حدث خطأ';

  @override
  String get txnTransactionWord => 'عملية';

  @override
  String get txnFilterPending => 'تصفية: قيد المراجعة';

  @override
  String get txnConfirmAll => 'تأكيد الكل';

  @override
  String get txnTabTransactions => 'العمليات';

  @override
  String get txnTabBills => 'الفواتير';

  @override
  String get txnPendingEmptyTitle => 'لا توجد عمليات معلّقة في هذا العرض';

  @override
  String get txnPendingEmptyBody =>
      'اختر فترة أخرى أو غيّر عوامل التصفية لمراجعة عمليات أخرى.';

  @override
  String get txnEmptyPeriodTitle => 'لا توجد عمليات في هذه الفترة';

  @override
  String get txnEmptyPeriodBody =>
      'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.';

  @override
  String get txnConfirmAllTitle => 'تأكيد كل العمليات المعلّقة؟';

  @override
  String get txnConfirm => 'تأكيد';

  @override
  String get txnPickAccount => 'اختر الحساب';

  @override
  String get txnSearchHint => 'ابحث باسم متجر، تصنيف، مبلغ أو عملة';

  @override
  String get txnClearSearch => 'مسح البحث';

  @override
  String get txnRangeToday => 'اليوم';

  @override
  String get txnRangeThisWeek => 'هذا الأسبوع';

  @override
  String get txnRangeThisMonth => 'هذا الشهر';

  @override
  String get txnRangeLastMonth => 'الشهر السابق';

  @override
  String get txnRange7 => 'آخر 7 أيام';

  @override
  String get txnRange30 => 'آخر 30 يومًا';

  @override
  String get txnRange90 => 'آخر 90 يومًا';

  @override
  String get txnRangeThisYear => 'هذه السنة';

  @override
  String get txnRangeLastYear => 'السنة الماضية';

  @override
  String get txnRangeCustom => 'مخصص';

  @override
  String get txnPickRange => 'اختر فترة العرض';

  @override
  String get txnFrom => 'من';

  @override
  String get txnTo => 'إلى';

  @override
  String get txnApplyCustomRange => 'تطبيق الفترة المخصصة';

  @override
  String get txnKindAll => 'الكل';

  @override
  String get txnKindExpense => 'مصروفات';

  @override
  String get txnKindIncome => 'دخل';

  @override
  String get txnKindTransfer => 'تحويلات';

  @override
  String get txnPendingReview => 'قيد المراجعة';

  @override
  String get txnCategory => 'التصنيف';

  @override
  String get txnFilterByCategory => 'تصفية حسب التصنيف';

  @override
  String get txnAllCategories => 'كل التصنيفات';

  @override
  String get txnBillsSubs => 'اشتراكات';

  @override
  String get txnBillsInstalments => 'أقساط';

  @override
  String get txnAddSub => 'إضافة اشتراك';

  @override
  String get txnAddInstalment => 'إضافة قسط';

  @override
  String get txnLearnBills => 'اعرف أكثر عن الفواتير';

  @override
  String get txnSubsEmptyTitle => 'اشتراكاتك، متابعة تلقائية';

  @override
  String get txnInstEmptyTitle => 'أقساطك، واضحة كل شهر';

  @override
  String get txnSubsEmptyBody =>
      'أضف اشتراكك يدويًا أو دعه يُكتشف تلقائيًا من العمليات المتكررة.';

  @override
  String get txnInstEmptyBody =>
      'أضف القسط بتاريخه وتنبيهه ليظهر في الفواتير قبل الاستحقاق.';

  @override
  String get txnSuggestionsTitle => 'اقتراحات من العمليات المتكررة';

  @override
  String get txnHowSubsTitle => 'كيف يتابع قِرش الاشتراكات؟';

  @override
  String get txnHowInstTitle => 'كيف يتابع قِرش الأقساط؟';

  @override
  String get txnHowSubsBody =>
      'يتابع قِرش الأنماط المتكررة تلقائيًا، ويمكنك أيضًا إضافة اشتراك يدويًا بالمبلغ وتاريخ التجديد والتنبيه.';

  @override
  String get txnHowInstBody =>
      'أضف القسط يدويًا بالمبلغ وتاريخ الاستحقاق والتنبيه. لاحقًا نضيف المتبقي وعدد الأقساط.';

  @override
  String get txnTotalMonthlySubs => 'إجمالي الاشتراكات الشهرية';

  @override
  String get txnTotalMonthlyInst => 'إجمالي الأقساط الشهرية';

  @override
  String get txnActive => 'نشط';

  @override
  String get txnPerYear => 'سنويًا';

  @override
  String get txnDueToday => 'مستحق اليوم';

  @override
  String get txnPaused => 'متوقف';

  @override
  String get txnCancelled => 'ملغي';

  @override
  String get txnCycleWeekly => 'أسبوعي';

  @override
  String get txnCycleMonthly => 'شهري';

  @override
  String get txnCycleYearly => 'سنوي';

  @override
  String get txnTotalValueLabel => 'القيمة الكلية: ';

  @override
  String get txnPaidManuallyLabel => 'مدفوع يدويًا: ';

  @override
  String get txnAdd => 'إضافة';

  @override
  String get txnBillsAndSubs => 'الفواتير والاشتراكات';

  @override
  String get txnPeriodSpendTotal => 'إجمالي مصروفات الفترة';

  @override
  String get txnActiveMonthlySpend => 'إجمالي الصرف الشهري النشط';

  @override
  String get txnTxForPeriod => 'عملية للفترة';

  @override
  String get txnTotalSpent => 'إجمالي المصروف';

  @override
  String get txnActiveSub => 'اشتراك نشط';

  @override
  String get txnRunningInst => 'قسط جاري';

  @override
  String get txnYearlyTotal => 'المجموع سنويًا';

  @override
  String get txnSmartInbox => 'صندوق المراجعة الذكي';

  @override
  String get txnReviewTx => 'راجع العملية';

  @override
  String get txnHide => 'إخفاء';

  @override
  String get txnSuspectTxPlural => 'عمليات مشبوهة';

  @override
  String get txnDismissAll => 'تجاهل الكل';

  @override
  String get txnNoSuspectTx => 'لا توجد عمليات مشبوهة';

  @override
  String get txnSimilarExists => 'عملية مشابهة موجودة';

  @override
  String get txnSimilarBody =>
      'هذه العملية تشبه عملية موجودة بالمبلغ والتاجر والوقت نفسها.';

  @override
  String get txnTheNew => 'الجديدة';

  @override
  String get txnNoClearMerchant => 'بدون تاجر واضح';

  @override
  String get txnTheExisting => 'الموجودة';

  @override
  String get txnDismissDuplicate => 'تجاهل التكرار';

  @override
  String get txnSaveAsNew => 'احفظ كجديدة';

  @override
  String get txnEditTx => 'تعديل العملية';

  @override
  String get txnChangeCategory => 'تغيير التصنيف';

  @override
  String get txnTimeInSms => 'وقت العملية داخل SMS';

  @override
  String get txnTimeReceived => 'وقت استلام الرسالة';

  @override
  String txnDupBannerReview(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية مشبوهة',
      many: '$count عملية مشبوهة',
      few: '$count عمليات مشبوهة',
      two: 'عمليتان مشبوهتان',
      one: 'عملية مشبوهة واحدة',
    );
    return '$_temp0 — اضغط للمراجعة';
  }

  @override
  String get txnDismissAllDupesBody =>
      'ستُزال كل تنبيهات التكرار المعروضة. العمليات نفسها لن تتأثر، لكن لا يمكن مراجعتها من هنا مرة أخرى.';

  @override
  String txnTimeSource(String source) {
    return 'مصدر الوقت: $source';
  }

  @override
  String txnRecurredMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تكرر $count شهرًا',
      many: 'تكرر $count شهرًا',
      few: 'تكرر $count أشهر',
      two: 'تكرر شهرين',
      one: 'تكرر شهرًا واحدًا',
    );
    return '$_temp0 · اضغط للتفعيل';
  }

  @override
  String txnConfirmAllBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'سيتم تأكيد $count عملية بتصنيفاتها الحالية.',
      many: 'سيتم تأكيد $count عملية بتصنيفاتها الحالية.',
      few: 'سيتم تأكيد $count عمليات بتصنيفاتها الحالية.',
      two: 'سيتم تأكيد عمليتين بتصنيفيهما الحاليين.',
      one: 'سيتم تأكيد عملية واحدة بتصنيفها الحالي.',
    );
    return '$_temp0';
  }

  @override
  String txnOverdueDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'متأخر $days يومًا',
      many: 'متأخر $days يومًا',
      few: 'متأخر $days أيام',
      two: 'متأخر يومين',
      one: 'متأخر يومًا واحدًا',
    );
    return '$_temp0';
  }

  @override
  String txnInDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'بعد $days يومًا',
      many: 'بعد $days يومًا',
      few: 'بعد $days أيام',
      two: 'بعد يومين',
      one: 'بعد يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String txnPerInstalment(String amount) {
    return '$amount / قسط';
  }

  @override
  String txnPaidOfTotal(int paid, int total) {
    return '$paid من $total قسط مدفوع';
  }

  @override
  String txnRemainingInstalments(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'متبقٍ $count قسط',
      many: 'متبقٍ $count قسطًا',
      few: 'متبقٍ $count أقساط',
      two: 'متبقٍ قسطان',
      one: 'متبقٍ قسط واحد',
    );
    return '$_temp0';
  }

  @override
  String txnInterestRate(String rate) {
    return 'فائدة $rate%';
  }

  @override
  String txnNextInstalment(String due) {
    return 'القسط القادم: $due';
  }

  @override
  String txnEstPerMonth(String amount, String currency) {
    return '$amount $currency/شهر';
  }

  @override
  String txnSmartInboxCount(int count) {
    return 'صندوق المراجعة الذكي · $count';
  }

  @override
  String txnDismissNAlerts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تجاهل $count تنبيه؟',
      many: 'تجاهل $count تنبيهًا؟',
      few: 'تجاهل $count تنبيهات؟',
      two: 'تجاهل تنبيهين؟',
      one: 'تجاهل تنبيهًا واحدًا؟',
    );
    return '$_temp0';
  }

  @override
  String txnDismissAllCount(int count) {
    return 'تجاهل الكل ($count)';
  }

  @override
  String get subsOverdue => 'متأخر';

  @override
  String get subsToday => 'اليوم';

  @override
  String subsTabSubs(int count) {
    return 'الاشتراكات ($count)';
  }

  @override
  String subsTabInst(int count) {
    return 'الأقساط ($count)';
  }

  @override
  String subsMonthlyScoped(String account) {
    return 'الاشتراكات الشهرية · $account';
  }

  @override
  String subsPerYearApprox(String amount) {
    return '≈ $amount/سنة';
  }

  @override
  String get subsTitle => 'الاشتراكات والفواتير';

  @override
  String get subsMonthlyTotal => 'الاشتراكات الشهرية';

  @override
  String get subsActiveSubs => 'اشتراكات نشطة';

  @override
  String get subsRunningInst => 'أقساط جارية';

  @override
  String get subsMonthlyInstCommit => 'التزام الأقساط شهريًا';

  @override
  String get subsEmptyTitle => 'اشتراكاتك في مكان واحد';

  @override
  String get subsAutoDetected => 'مكتشفة تلقائيًا';

  @override
  String get subsAddNewSub => 'إضافة اشتراك جديد';

  @override
  String get subsMaybeUnused => 'قد لا تستخدم هذا الاشتراك';

  @override
  String get subsInstEmptyTitle => 'أقساطك، واضحة قبل ميعادها';

  @override
  String get subsInstEmptyBody => 'أضف القسط بالمبلغ والعدد وتاريخ الاستحقاق.';

  @override
  String get subsTotalInstDebt => 'إجمالي مديونية الأقساط';

  @override
  String get subsNearestInst => 'أقرب قسط';

  @override
  String get subsAddNewInst => 'إضافة قسط جديد';

  @override
  String rptAnomalyPrivate(String date) {
    return 'في يوم $date كان الصرف أعلى من نمطك المعتاد. راجعه إن أردت معرفة السبب.';
  }

  @override
  String rptAnomalyDetail(String date, String amount, String ratio) {
    return 'في يوم $date صرفت $amount، وهو أعلى من متوسطك اليومي $ratio×.';
  }

  @override
  String rptSpendLower(int percent) {
    return 'صرفك أقل $percent% من نفس الفترة السابقة.';
  }

  @override
  String rptSpendHigher(int percent) {
    return 'صرفك أعلى $percent% من نفس الفترة السابقة.';
  }

  @override
  String rptHighestDayBody(String amount) {
    return 'أعلى يوم في الفترة وصل إلى $amount.';
  }

  @override
  String rptTopCategoryHint(String category) {
    return 'أكبر إنفاق لديك على $category. راقب هذا التصنيف أولًا.';
  }

  @override
  String rptMerchantTxCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية',
      many: '$count عملية',
      few: '$count عمليات',
      two: 'عمليتان',
      one: 'عملية واحدة',
    );
    return '$_temp0';
  }

  @override
  String rptVsLastWeek(String sign, String percent) {
    return '$sign $percent% مقارنة بالأسبوع الماضي';
  }

  @override
  String rptTopCategoryWeek(String category) {
    return 'أكثر فئة صرفًا: $category';
  }

  @override
  String rptBestSavingDay(String date, String amount) {
    return 'أفضل يوم توفيرًا: $date ($amount)';
  }

  @override
  String rptTopMerchantWeek(String name, String amount) {
    return 'أكثر متجر صرفًا: $name ($amount)';
  }

  @override
  String get rptTabOverview => 'نظرة عامة';

  @override
  String get rptTabTrends => 'الاتجاهات';

  @override
  String get rptTabDetails => 'التفاصيل';

  @override
  String get rptUnusualSpend => 'صرف غير معتاد';

  @override
  String get rptVsPrevPeriod => 'مقارنة بنفس الفترة السابقة';

  @override
  String get rptNeedPrevPeriod =>
      'ما زلنا نحتاج فترة سابقة فيها إنفاق لعرض الاتجاه بدقة.';

  @override
  String get rptHighestSpendDay => 'أعلى يوم صرف';

  @override
  String get rptQuickTip => 'اقتراح سريع';

  @override
  String get rptAddMoreTx => 'ابدأ بإضافة عمليات أكثر لنقدّم اقتراحات أوضح.';

  @override
  String get rptSelectedPeriod => 'الفترة المختارة';

  @override
  String get rptNetPeriodSpend => 'صافي مصروف الفترة';

  @override
  String get rptSelectedPeriodSpend => 'مصروف الفترة المختارة';

  @override
  String get rptTotalExpenses => 'إجمالي المصروفات';

  @override
  String get rptRefunds => 'المرتجعات';

  @override
  String get rptNet => 'الصافي';

  @override
  String get rptThisWeekUsage => 'استهلاك الأسبوع الحالي';

  @override
  String get rptAverage => 'المتوسط';

  @override
  String get rptHighest => 'الأعلى';

  @override
  String get rptTotal => 'الإجمالي';

  @override
  String get rptByCategory => 'استهلاكك بالتصنيفات';

  @override
  String get rptByMerchant => 'مصروفاتك في المتاجر';

  @override
  String get rptTopMerchantsSub => 'أكبر أماكن الصرف في الفترة';

  @override
  String get rptMerchantsEmpty =>
      'ستظهر هنا أكثر المتاجر صرفاً بعد إضافة عمليات مؤكدة.';

  @override
  String get rptIncludesRefund => ' · شامل مرتجع ';

  @override
  String get rptInsightsTitle => 'الرؤى والتقارير';

  @override
  String get rptInsightsSub => 'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.';

  @override
  String get rptDailyAverage => 'متوسط يومي';

  @override
  String get rptHighestDay => 'أعلى يوم';

  @override
  String get rptWeekSummary => 'ملخص الأسبوع';

  @override
  String bdgPeriodSubtitle(String period, String date) {
    return 'ميزانية $period · $date';
  }

  @override
  String bdgPeriodSubtitleLive(String period, String date) {
    return 'ميزانية $period · $date · جارية';
  }

  @override
  String bdgLatestOfTotal(int shown, int total) {
    return 'أحدث $shown من $total';
  }

  @override
  String get bdgRemainingPrefix => 'باقي ';

  @override
  String bdgToReachSuffix(String currency) {
    return ' $currency للوصول';
  }

  @override
  String setUnsyncedLedger(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تغيير في المعاملات',
      many: '$count تغييرًا في المعاملات',
      few: '$count تغييرات في المعاملات',
      two: 'تغييران في المعاملات',
      one: 'تغيير واحد في المعاملات',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedPlanning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تغيير في الحسابات/الميزانيات/الأهداف/الفواتير',
      many: '$count تغييرًا في الحسابات/الميزانيات/الأهداف/الفواتير',
      few: '$count تغييرات في الحسابات/الميزانيات/الأهداف/الفواتير',
      two: 'تغييران في الحسابات/الميزانيات/الأهداف/الفواتير',
      one: 'تغيير واحد في الحسابات/الميزانيات/الأهداف/الفواتير',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedInbox(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عنصر في صندوق الوارد',
      many: '$count عنصرًا في صندوق الوارد',
      few: '$count عناصر في صندوق الوارد',
      two: 'عنصران في صندوق الوارد',
      one: 'عنصر واحد في صندوق الوارد',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count بطاقة محفوظة على هذا الجهاز فقط',
      many: '$count بطاقة محفوظة على هذا الجهاز فقط',
      few: '$count بطاقات محفوظة على هذا الجهاز فقط',
      two: 'بطاقتان محفوظتان على هذا الجهاز فقط',
      one: 'بطاقة واحدة محفوظة على هذا الجهاز فقط',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedUnproven(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count سجل مالي لم يُرفع للسحابة بعد',
      many: '$count سجلًا ماليًا لم يُرفع للسحابة بعد',
      few: '$count سجلات مالية لم تُرفع للسحابة بعد',
      two: 'سجلان ماليان لم يُرفعا للسحابة بعد',
      one: 'سجل مالي واحد لم يُرفع للسحابة بعد',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count سجل به تعارض لم يُحلّ',
      many: '$count سجلًا به تعارض لم يُحلّ',
      few: '$count سجلات بها تعارض لم يُحلّ',
      two: 'سجلان بهما تعارض لم يُحلّ',
      one: 'سجل واحد به تعارض لم يُحلّ',
    );
    return '$_temp0';
  }

  @override
  String get setListSeparator => '، ';

  @override
  String setUnsyncedSignOutBody(String list) {
    return 'لديك بيانات لم تُرفع للسحابة وسيحذفها تسجيل الخروج: $list. خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.';
  }

  @override
  String setGapDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'منذ $count يوم',
      many: 'منذ $count يومًا',
      few: 'منذ $count أيام',
      two: 'منذ يومين',
      one: 'منذ يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String setGapHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'منذ $count ساعة',
      many: 'منذ $count ساعة',
      few: 'منذ $count ساعات',
      two: 'منذ ساعتين',
      one: 'منذ ساعة واحدة',
    );
    return '$_temp0';
  }

  @override
  String get setGapToday => 'اليوم';

  @override
  String setLastCapture(String gap) {
    return 'آخر عملية رصد: $gap';
  }

  @override
  String setApnsFailed(String message) {
    return 'فشل تسجيل APNs: $message';
  }

  @override
  String setCheckShortcutStillOn(String subtitle) {
    return '$subtitle — تأكد أن الاختصار لا يزال مفعّلًا';
  }

  @override
  String get goalDueToday => 'الموعد اليوم';

  @override
  String goalDaysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'باقي $days يوم',
      many: 'باقي $days يومًا',
      few: 'باقي $days أيام',
      two: 'باقي يومان',
      one: 'باقي يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String goalMonthsLeft(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: 'باقي $months شهر',
      many: 'باقي $months شهرًا',
      few: 'باقي $months أشهر',
      two: 'باقي شهران',
      one: 'باقي شهر واحد',
    );
    return '$_temp0';
  }

  @override
  String goalRemainingToReach(String amount, String currency) {
    return 'باقي $amount $currency للوصول';
  }

  @override
  String goalSavedAmount(String amount, String currency) {
    return 'مدخر $amount $currency';
  }

  @override
  String goalTargetAmount(String amount, String currency) {
    return 'الهدف $amount $currency';
  }

  @override
  String get goalPerMonth => '/شهر';

  @override
  String get goalOverdue => 'تجاوز الموعد المستهدف';

  @override
  String get goalTotalSavedAll => 'إجمالي المدخر لكل أحلامك';

  @override
  String get goalTargetLabel => 'المستهدف';

  @override
  String get goalEmptyBody => 'أضف هدفك الأول وابدأ تعبئة الخزنة.';

  @override
  String cardLinkTxTo(String last4) {
    return 'اربط عملية بـ •••• $last4';
  }

  @override
  String cardTxLinkedTo(String last4) {
    return 'تم ربط العملية بـ •••• $last4';
  }

  @override
  String get cardAccountWord => 'حساب';

  @override
  String get cardUnassigned => 'غير مخصّصة';

  @override
  String get cardBack => 'رجوع';

  @override
  String get cardActivityTitle => 'حركة البطاقات';

  @override
  String get cardAllCards => 'كل البطاقات';

  @override
  String get cardLoadFailed => 'تعذّر تحميل بطاقاتك';

  @override
  String get cardLoadFailedBody => 'حاول مجددًا لعرض بطاقاتك المحفوظة.';

  @override
  String get cardAddCard => 'إضافة بطاقة';

  @override
  String get cardEmptyTitle => 'لا توجد بطاقات بعد';

  @override
  String get cardEmptyBody =>
      'تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافة بطاقة بتصميمك.';

  @override
  String get cardAddCardCta => 'أضف بطاقة';

  @override
  String get cardEdit => 'تعديل';

  @override
  String get cardIn => 'داخل';

  @override
  String get cardOut => 'خارج';

  @override
  String get cardAddTx => 'إضافة عملية';

  @override
  String get cardLinkExistingTx => 'اربط عملية موجودة';

  @override
  String get cardSearchHint => 'ابحث بالاسم أو المبلغ';

  @override
  String get cardNoTx => 'لا توجد عمليات';

  @override
  String get accAddAccount => 'إضافة حساب';

  @override
  String get accTitle => 'الحسابات والمحافظ';

  @override
  String get accSubtitle =>
      'كل حساب بعملته الخاصة — نقدي، بنك، محفظة أو بطاقة.';

  @override
  String get accDefault => 'افتراضي';

  @override
  String get accUnassignedCards => 'بطاقات غير مخصّصة';

  @override
  String get accUnassignedCardsBody =>
      'بطاقات ظهرت في رسائلك لكنها غير مرتبطة بحساب بعد.';

  @override
  String achCurrentStreak(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return 'السلسلة الحالية: $_temp0';
  }

  @override
  String achStreakDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String annFromDate(String date) {
    return 'من $date';
  }

  @override
  String pasteAnalysing(int processed, int total) {
    return 'نحلّل $processed من $total';
  }

  @override
  String pasteSummaryLine(int added, int duplicate, int review, int failed) {
    return 'أُضيفت $added · مكرر $duplicate · يحتاج مراجعة $review · غير مفهوم $failed';
  }

  @override
  String pasteAnalysedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تم تحليل $count رسالة من اللصق.',
      many: 'تم تحليل $count رسالة من اللصق.',
      few: 'تم تحليل $count رسائل من اللصق.',
      two: 'تم تحليل رسالتين من اللصق.',
      one: 'تم تحليل رسالة واحدة من اللصق.',
    );
    return '$_temp0';
  }

  @override
  String get achCurrentLevel => 'المستوى الحالي';

  @override
  String get achUnlocked => 'تم الفتح';

  @override
  String get achInProgress => 'قيد التقدّم';

  @override
  String get achLevelOrganised => 'منظّم';

  @override
  String get achLevelSmartSaver => 'موفّر ذكي';

  @override
  String get achLevelExpert => 'خبير مالي';

  @override
  String get achLevelLegend => 'أسطورة الادخار';

  @override
  String get achLevelBeginner => 'مبتدئ';

  @override
  String get achTitle => 'الإنجازات';

  @override
  String get achSubtitle => 'شارات ومستويات تشجعك تكمل عادة المتابعة.';

  @override
  String get achLevel => 'المستوى';

  @override
  String get achTotalXp => 'إجمالي الـ XP';

  @override
  String get achStreak => 'سلسلة المتابعة';

  @override
  String get annTitle => 'مركز رسائل قرش';

  @override
  String get annSubtitle =>
      'تاريخ إشعارات قرش، الحملات، والإعلانات في مكان واحد.';

  @override
  String get annClose => 'إغلاق';

  @override
  String get annLoading => 'تحميل مركز الرسائل...';

  @override
  String get annLoadFailed => 'تعذر تحميل الرسائل';

  @override
  String get annTryAgainSoon => 'حاول مرة أخرى بعد لحظات.';

  @override
  String get annRetry => 'إعادة المحاولة';

  @override
  String get annEmpty => 'لا توجد رسائل بعد';

  @override
  String get annEmptyBody =>
      'أي إشعار من قِرش أو إعلان من الإدارة سيظهر هنا تلقائيًا.';

  @override
  String get annShortcutCaptured => 'تم التقاط عملية جديدة';

  @override
  String get annShortcutReceived => 'تم استلام رسالة بنكية';

  @override
  String get annNotificationSent => 'إشعار مرسل';

  @override
  String get annOpen => 'فتح';

  @override
  String get annInAppCampaign => 'حملة داخل التطبيق';

  @override
  String get annFromQirsh => 'إعلان من قرش';

  @override
  String get privCloudProcessingBody =>
      'تتم مزامنة بياناتك ونسخها احتياطيًا على خوادم قِرش، وقد تُرسَل إليها رسائل البنك الملتقطة بعد حذف أرقام البطاقات والحسابات والهواتف والرموز لقراءتها، وقد يُرسَل اسم التاجر إلى Google Places لتصنيفه. عند الإيقاف يتوقف الإرسال: تُقرأ الرسائل بقواعد قِرش المحلية ولا تتم مزامنة أي بيانات جديدة، ويظل الإدخال اليدوي متاحًا.';

  @override
  String get privAiAnalysisBody =>
      'عند تشغيله مع المزامنة السحابية، قد تُحلَّل رسائل البنك الملتقطة — ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد — بعد حذف أرقام البطاقات والحسابات والهواتف والرموز وإخفاء ما يُتعرَّف عليه من أسماء وعناوين بريد إلكتروني وأرقام مرجعية، بواسطة Google Gemini لقراءة المبلغ والتاجر والبنك. يبقى في النص المبالغ والتجار والتواريخ والأرصدة. سحب الموافقة يقصر القراءة على قواعد قِرش داخل جهازك.';

  @override
  String get privDeleteAccountBody =>
      'سيتم جدولة حذف حسابك وكل بياناتك (العمليات، الأهداف، الميزانيات، النسخ الاحتياطي) نهائيًا بعد 30 يومًا. يمكنك التراجع عن الحذف خلال هذه المدة من نفس الشاشة قبل تسجيل الدخول مرة أخرى. سيتم تسجيل خروجك من هذا الجهاز الآن.';

  @override
  String privScheduledForDeletion(String date) {
    return 'حسابك مجدول للحذف بتاريخ $date';
  }

  @override
  String get privPolicy => 'سياسة الخصوصية';

  @override
  String get privTerms => 'الشروط والأحكام';

  @override
  String get privTransferMyData => 'نقل واستيراد بياناتي';

  @override
  String get privDataProcessing => 'معالجة البيانات';

  @override
  String get privCloudProcessing => 'المعالجة السحابية والمزامنة';

  @override
  String get privAiAnalysis => 'التحليل بالذكاء الاصطناعي';

  @override
  String get privDangerZone => 'منطقة خطرة';

  @override
  String get privDeleteAccountAll => 'حذف الحساب وكل بياناتي';

  @override
  String get privLinkFailed => 'تعذر فتح الرابط الآن.';

  @override
  String get privDeleteAccountTitle => 'حذف الحساب؟';

  @override
  String get privDeleteAccount => 'حذف الحساب';

  @override
  String get privScheduleFailed => 'تعذّر جدولة الحذف الآن. حاول مجدداً.';

  @override
  String get privCancelDeleteTitle => 'إلغاء حذف الحساب؟';

  @override
  String get privCancelDeleteBody => 'سيبقى حسابك وبياناتك كما هي.';

  @override
  String get privKeepAccount => 'تراجع';

  @override
  String get privCancelDeletion => 'إلغاء الحذف';

  @override
  String get privCancelFailed => 'تعذّر إلغاء الحذف الآن. حاول مجدداً.';

  @override
  String get privTitle => 'الخصوصية والبيانات';

  @override
  String get privIntro =>
      'عند تفعيل «التحليل الذكي والمزامنة السحابية»، قد تُعالَج رسائل البنك التي يلتقطها قِرش — رسائل SMS التي تُقرأ تلقائيًا على أندرويد، أو الرسائل التي تشاركها أو ترسلها عبر اختصار iOS — كنص مُنقّى على خوادم قِرش وبواسطة Google Gemini. عند إيقافه تُحلَّل الرسائل على هذا الجهاز. ويمكنك تصدير بياناتك المالية أو استيرادها من شاشة نقل البيانات.';

  @override
  String dtxPreviewRows(int rows, String format) {
    return '$rows سجل • $format';
  }

  @override
  String get dtxQirshPackage => 'حزمة قِرش';

  @override
  String dtxImportDupesAsNew(int count) {
    return 'استيراد $count عملية مشابهة كعمليات جديدة';
  }

  @override
  String dtxAdded(int count) {
    return 'تمت الإضافة: $count';
  }

  @override
  String dtxDuplicates(int count) {
    return 'مكرر: $count';
  }

  @override
  String dtxQuarantined(int count) {
    return 'معزول للحماية: $count';
  }

  @override
  String dtxFailed(int count) {
    return 'فشل: $count';
  }

  @override
  String get dtxScanFailed => 'تعذر فحص الملف. تأكد أنه CSV أو ZIP صالح.';

  @override
  String get dtxImportFailed =>
      'تعذر إكمال الاستيراد. لم تُحذف أي بيانات غير مؤكدة.';

  @override
  String get dtxReadFailed => 'تعذر قراءة البيانات وتجهيز ملف التصدير.';

  @override
  String get dtxSaveFailed => 'تعذر حفظ ملف التصدير مؤقتًا على الجهاز.';

  @override
  String get dtxZipShareText => 'ملف بيانات قرش المالية. احتفظ به في مكان خاص.';

  @override
  String get dtxCsvShareText => 'تصدير عمليات قرش بصيغة CSV.';

  @override
  String get dtxShareSheetFailed =>
      'تم تجهيز الملف، لكن تعذر فتح نافذة المشاركة. حاول مرة أخرى.';

  @override
  String get dtxTitle => 'نقل البيانات';

  @override
  String get dtxSubtitle =>
      'استورد بياناتك أو احتفظ بنسخة قابلة للنقل. تتم معاينة الملف على جهازك قبل أي كتابة.';

  @override
  String get dtxImportFile => 'استيراد ملف';

  @override
  String get dtxImportFileSub => 'CSV من أي تطبيق أو ZIP صادر من قرش';

  @override
  String get dtxExportCsv => 'تصدير العمليات CSV';

  @override
  String get dtxExportCsvSub => 'ملف واحد متوافق مع Excel وتطبيقات الميزانية';

  @override
  String get dtxExportZip => 'تصدير كل بيانات قرش ZIP';

  @override
  String get dtxExportZipSub => 'الحسابات والعمليات والميزانيات والخطط المالية';

  @override
  String get dtxRestoreOld => 'استعادة نسخة قديمة';

  @override
  String get dtxRestoreOldSub =>
      'متاح مؤقتاً للنسخ المشفرة التي أنشأتها سابقاً';

  @override
  String get dtxExportNotice =>
      'ملفات التصدير لا تحتوي رسائل البنك الخام أو بيانات الدخول أو رموز الأجهزة. ملف ZIP غير محمي بكلمة مرور؛ خزّنه في مكان خاص.';

  @override
  String get dtxReplace => 'استبدال';

  @override
  String get dtxReplaceGuestOnly =>
      'الاستبدال متاح فقط للبيانات المحفوظة على هذا الجهاز. لأن بياناتك مزامَنة مع حسابك، الدمج هو الخيار الوحيد: يضيف محتوى الحزمة ويُبقي ما لديك.';

  @override
  String get dtxConfirmReplace => 'تأكيد الاستبدال';

  @override
  String dtxReplaceBody(String word) {
    return 'سيتم إخفاء بياناتك المالية الحالية واستبدالها بمحتوى حزمة قِرش. اكتب «$word» للمتابعة.';
  }

  @override
  String dtxTypeReplace(String word) {
    return 'اكتب $word';
  }

  @override
  String get dtxImportPreview => 'معاينة الاستيراد';

  @override
  String get dtxColDate => 'عمود التاريخ';

  @override
  String get dtxColAmount => 'عمود المبلغ';

  @override
  String get dtxDefaultAccount => 'الحساب الافتراضي';

  @override
  String get dtxDebit => 'الخصم (Debit)';

  @override
  String get dtxCredit => 'الإيداع (Credit)';

  @override
  String get dtxCurrency => 'العملة';

  @override
  String get dtxMerchantDesc => 'التاجر / الوصف';

  @override
  String get dtxNotes => 'الملاحظات';

  @override
  String get dtxTxType => 'نوع العملية';

  @override
  String get dtxDateFormat => 'صيغة التاريخ';

  @override
  String get dtxDateAuto => 'تلقائية';

  @override
  String get dtxDateDMY => 'يوم / شهر / سنة';

  @override
  String get dtxDateMDY => 'شهر / يوم / سنة';

  @override
  String get dtxDateYMD => 'سنة / شهر / يوم';

  @override
  String get dtxWillCreate =>
      'عند التأكيد، سيُنشئ قرش الحسابات والتصنيفات غير الموجودة الواردة في الملف.';

  @override
  String get dtxMerge => 'دمج';

  @override
  String get dtxConfirmImport => 'تأكيد الاستيراد';

  @override
  String get dtxImportDone => 'اكتمل الاستيراد';

  @override
  String get dtxCacheRepair =>
      'تم الحفظ على الخادم، وسيُصلح قرش الكاش المحلي تلقائياً.';

  @override
  String get pasteTitle => 'ألصق رسالة البنك';

  @override
  String get pasteAlreadyExists => 'العملية موجودة بالفعل، فتحناها للمراجعة.';

  @override
  String get pasteAlreadyRecorded => 'هذه العملية مسجّلة بالفعل.';

  @override
  String get pasteSimilarNeedsReview => 'عملية مشابهة موجودة وتحتاج مراجعة.';

  @override
  String get pasteAiOffline =>
      'تحليل الذكاء الاصطناعي غير متاح. لم تُضَف عملية. يمكنك إضافتها يدويًا.';

  @override
  String get pasteUnreadableOnDevice =>
      'تعذّرت قراءة الرسالة على الجهاز — أضِفها يدويًا.';

  @override
  String get pasteNotATransaction => 'تعذّرت قراءتها كعملية — أضِفها يدويًا.';

  @override
  String get pasteNothingToOpen => 'لا توجد عملية لفتحها لهذه الرسالة.';

  @override
  String get pasteHint =>
      'يمكنك لصق رسالة واحدة أو عدة رسائل، وسيجري تحليل كل رسالة على حدة.';

  @override
  String get pasteFromClipboard => 'لصق من الحافظة';

  @override
  String get pasteAnalyse => 'حلّل الرسائل';

  @override
  String get pasteNeedsReview => 'يحتاج مراجعة';

  @override
  String get pasteAdded => 'أُضيفت';

  @override
  String get pasteDuplicate => 'مكرر';

  @override
  String get pasteSimilar => 'مشابهة للمراجعة';

  @override
  String get pasteNotUnderstood => 'غير مفهوم';

  @override
  String get pasteSummary => 'ملخص الرسائل';

  @override
  String get pasteReview => 'راجع';

  @override
  String get accTypeCash => 'نقدي';

  @override
  String get accTypeBank => 'بنك';

  @override
  String get accTypeWallet => 'محفظة';

  @override
  String get accTypeCreditCard => 'بطاقة ائتمانية';

  @override
  String txdValueIn(String currency) {
    return 'القيمة بـ $currency';
  }

  @override
  String txdAmountIn(String currency) {
    return 'المبلغ بـ $currency';
  }

  @override
  String txdAddValueIn(String currency) {
    return 'أضف القيمة بـ $currency';
  }

  @override
  String get txdPendingToday => 'غير مؤكدة · اليوم';

  @override
  String txdPendingDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'منذ $days يوم',
      many: 'منذ $days يومًا',
      few: 'منذ $days أيام',
      two: 'منذ يومين',
      one: 'منذ يوم',
    );
    return 'غير مؤكدة · $_temp0';
  }

  @override
  String txdLinkedToCard(String last4) {
    return 'رُبطت بالبطاقة •••• $last4. الحساب كما هو.';
  }

  @override
  String get txdTypePurchase => 'شراء';

  @override
  String get txdTypeCashWithdrawal => 'سحب نقدي';

  @override
  String get txdTypeTransfer => 'تحويل';

  @override
  String get txdTypeRefund => 'استرداد';

  @override
  String get txdTypeUnknown => 'غير محدد';

  @override
  String get txdSourceCard => 'بطاقة';

  @override
  String get txdSourceAi => 'ذكاء اصطناعي';

  @override
  String get txdSourceImport => 'ملف مستورد';

  @override
  String get txdNotFound => 'العملية غير موجودة';

  @override
  String get txdConfirmed => 'مؤكدة';

  @override
  String get txdNeedsReview => 'تحتاج مراجعة';

  @override
  String get txdIgnored => 'متجاهلة';

  @override
  String get txdUncategorised => 'غير مصنّف';

  @override
  String get txdType => 'النوع';

  @override
  String get txdSource => 'المصدر';

  @override
  String get txdCard => 'البطاقة';

  @override
  String get txdNoCard => 'بدون بطاقة';

  @override
  String get txdChange => 'تغيير';

  @override
  String get txdOriginalCurrency => 'بالعملة الأصلية';

  @override
  String get txdBalanceAfter => 'الرصيد بعد';

  @override
  String get txdNote => 'ملاحظة';

  @override
  String get txdStatus => 'الحالة';

  @override
  String get txdOriginalText => 'النص الأصلي';

  @override
  String get txdConfirmIgnored => 'تأكيد العملية المتجاهلة';

  @override
  String get txdConfirmTx => 'تأكيد العملية';

  @override
  String get txdDeleteTx => 'حذف العملية';

  @override
  String get txdTitle => 'تفاصيل العملية';

  @override
  String get txdCardSheetTitle => 'بطاقة العملية';

  @override
  String get txdCardSheetNote => 'تغيير البطاقة لا ينقل العملية إلى حساب آخر.';

  @override
  String get txdNoCardsOnAccount => 'لا توجد بطاقات مسجّلة على هذا الحساب.';

  @override
  String get txdStaysInAccount => 'العملية تظل في نفس الحساب وفي كل تقاريرك.';

  @override
  String get txdCardRemoved =>
      'أُزيلت البطاقة. ما زالت العملية في الحساب نفسه.';

  @override
  String get txdConfirmedToast => 'تم تأكيد العملية.';

  @override
  String get txdDeleteTitle => 'حذف العملية؟';

  @override
  String get txdDeleteBody =>
      'ستُحذف من تقاريرك ورصيدك. لا يمكن التراجع عن ذلك.';

  @override
  String get txdSave => 'حفظ';

  @override
  String accWillDetachTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية',
      many: '$count عملية',
      few: '$count عمليات',
      two: 'عمليتان',
      one: 'عملية واحدة',
    );
    return 'ستُفصل $_temp0';
  }

  @override
  String accWillArchiveCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count بطاقة',
      many: '$count بطاقة',
      few: '$count بطاقات',
      two: 'بطاقتان',
      one: 'بطاقة واحدة',
    );
    return 'تُؤرشف $_temp0';
  }

  @override
  String accWillArchiveBudgets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ميزانية',
      many: '$count ميزانية',
      few: '$count ميزانيات',
      two: 'ميزانيتان',
      one: 'ميزانية واحدة',
    );
    return 'تُؤرشف $_temp0';
  }

  @override
  String accDetachedTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية',
      many: '$count عملية',
      few: '$count عمليات',
      two: 'عمليتان',
      one: 'عملية واحدة',
    );
    return 'فُصلت $_temp0';
  }

  @override
  String accArchivedCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count بطاقة مؤرشفة',
      many: '$count بطاقة مؤرشفة',
      few: '$count بطاقات مؤرشفة',
      two: 'بطاقتان مؤرشفتان',
      one: 'بطاقة واحدة مؤرشفة',
    );
    return '$_temp0';
  }

  @override
  String accReassignedGoals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count هدف مُنقول',
      many: '$count هدفًا مُنقولًا',
      few: '$count أهداف مُنقولة',
      two: 'هدفان مُنقولان',
      one: 'هدف واحد مُنقول',
    );
    return '$_temp0';
  }

  @override
  String accArchivedGoals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count هدف مؤرشف',
      many: '$count هدفًا مؤرشفًا',
      few: '$count أهداف مؤرشفة',
      two: 'هدفان مؤرشفان',
      one: 'هدف واحد مؤرشف',
    );
    return '$_temp0';
  }

  @override
  String accReassignedSubs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count اشتراك مُنقول',
      many: '$count اشتراكًا مُنقولًا',
      few: '$count اشتراكات مُنقولة',
      two: 'اشتراكان مُنقولان',
      one: 'اشتراك واحد مُنقول',
    );
    return '$_temp0';
  }

  @override
  String accArchivedSubs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count اشتراك مؤرشف',
      many: '$count اشتراكًا مؤرشفًا',
      few: '$count اشتراكات مؤرشفة',
      two: 'اشتراكان مؤرشفان',
      one: 'اشتراك واحد مؤرشف',
    );
    return '$_temp0';
  }

  @override
  String accDeletedSummary(String summary) {
    return 'تم حذف الحساب — $summary.';
  }

  @override
  String get pasteFieldHint =>
      'الصق نص رسالة البنك هنا...\nيمكنك لصق عدة رسائل متتالية.';

  @override
  String get commonAccountDefinite => 'الحساب';

  @override
  String get commonOpenImperative => 'افتح';

  @override
  String homeVsLastWeek(int percent) {
    return '$percent% عن الأسبوع الماضي';
  }

  @override
  String homePendingReviewTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية في انتظار مراجعتك',
      many: '$count عملية في انتظار مراجعتك',
      few: '$count عمليات في انتظار مراجعتك',
      two: 'عمليتان في انتظار مراجعتك',
      one: 'عملية واحدة في انتظار مراجعتك',
    );
    return '$_temp0';
  }

  @override
  String homeWeekSpentMore(int percent) {
    return 'انتبه — إنفاقك أعلى بـ$percent% عن الأسبوع الماضي. راجع أكثر فئة تنفق فيها.';
  }

  @override
  String homeWeekSpentLess(int percent) {
    return 'أحسنت — إنفاقك أقل بـ$percent% عن الأسبوع الماضي. واصل على هذا النحو لتوفّر أكثر.';
  }

  @override
  String homeShownTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية معروضة',
      many: '$count عملية معروضة',
      few: '$count عمليات معروضة',
      two: 'عمليتان معروضتان',
      one: 'عملية واحدة معروضة',
    );
    return '$_temp0';
  }

  @override
  String homePendingSuffix(String count) {
    return '$count قيد المراجعة';
  }

  @override
  String homeGoalSaved(String amount) {
    return 'تم توفير $amount';
  }

  @override
  String homeGoalRemaining(String amount) {
    return 'باقي $amount';
  }

  @override
  String homeNeedPerMonth(String amount) {
    return 'يلزمك $amount شهريًا';
  }

  @override
  String homeArrivesOn(String date) {
    return 'بمعدلك الحالي ستصل $date';
  }

  @override
  String homeLateBy(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months شهرًا',
      many: '$months شهرًا',
      few: '$months أشهر',
      two: 'شهرين',
      one: 'شهرًا واحدًا',
    );
    return 'متأخر $_temp0';
  }

  @override
  String get homeSessionExpiredTitle => 'الرجاء تسجيل الدخول مرة أخرى';

  @override
  String get homeSessionExpiredBody =>
      'انتهت صلاحية الجلسة، سجّل دخولك للمتابعة.';

  @override
  String get homeSignIn => 'تسجيل الدخول';

  @override
  String get homeLoadFailed => 'تعذر تحميل لوحة التحكم الآن';

  @override
  String get homeLoadFailedBody => 'تحقق من البيانات أو حاول التحديث مرة أخرى.';

  @override
  String get homeDailySpend => 'المصروفات اليومية';

  @override
  String get homeAllAccounts => 'كل الحسابات';

  @override
  String get homeSetMonthlyBudget => 'حدّد ميزانية شهرية لتتابع المتاح';

  @override
  String get homeOverMonthBudget => 'تجاوزت ميزانية الشهر';

  @override
  String get homeSpendAboveUsual => 'مصروفك أعلى من المعتاد';

  @override
  String get homeSteady => 'وضعك مستقر';

  @override
  String get homeReviewToStayAccurate => 'راجعها لتبقى أرصدتك دقيقة';

  @override
  String get homeAvailableFromMonthBudget => 'متاح من ميزانية الشهر';

  @override
  String get homeNoTxTitle => 'لا توجد عمليات مضافة';

  @override
  String get homeNoTxBody =>
      'ألصق رسالة الخصم أو الإيداع من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائيًا على جهازك.';

  @override
  String get homeMoneyFriend => 'صديق مالي';

  @override
  String get homeTodaySpend => 'مصروف اليوم';

  @override
  String get homeWeekSpend => 'مصروف الأسبوع';

  @override
  String get homeMonthSpend => 'مصروف الشهر';

  @override
  String get homeVsYesterday => 'عن أمس';

  @override
  String get homeVsLastWeekShort => 'عن الأسبوع الماضي';

  @override
  String get homeGreeting => 'مرحباً 👋';

  @override
  String get homeTodayIncome => 'دخل اليوم';

  @override
  String get homeWeek => 'الأسبوع';

  @override
  String get homeMonth => 'الشهر';

  @override
  String get homeMonthlySpend => 'المصروفات الشهرية';

  @override
  String get homeBudget => 'الميزانية';

  @override
  String get homeManage => 'إدارة';

  @override
  String get homeSubsAndInstalments => 'الاشتراكات والأقساط';

  @override
  String get homeNoBillsOnAccount =>
      'لا توجد اشتراكات ولا أقساط على هذا الحساب.';

  @override
  String get homeNoGoalsOnAccount => 'لا توجد أهداف على هذا الحساب.';

  @override
  String get homeFinishSetup => 'أكمل إعداد قِرش ✨';

  @override
  String get homeEnableBiometrics => 'فعّل قفل البصمة';

  @override
  String get homeAddSavingsGoal => 'أضف هدف ادخار';

  @override
  String get homePlans => 'الخطط';

  @override
  String get homeNoActivePlans => 'لا توجد خطط نشطة';

  @override
  String get homeCreatePlanHint => 'أنشئ خطة ميزانية للسفر أو المناسبات';

  @override
  String get homeNewPlan => 'خطة جديدة';

  @override
  String get homeSavingsCorner => 'ركن التوفير';

  @override
  String homeCouponExpires(String date) {
    return 'ينتهي $date';
  }

  @override
  String homeDayAmountSemantics(String day, String amount) {
    return '$day، $amount';
  }

  @override
  String homeVsYesterdayValue(String value) {
    return '$value عن أمس';
  }

  @override
  String homeExpectedPctOfMonth(int percent) {
    return 'المتوقع $percent% من الشهر';
  }

  @override
  String homeAheadPct(int percent) {
    return 'مسبّق $percent%';
  }

  @override
  String homeBehindPct(int percent) {
    return 'متأخر $percent%';
  }

  @override
  String get homeAtThisRatePrefix => 'بهذا المعدل ستنهي الشهر على ';

  @override
  String homeOverBudgetBy(String amount) {
    return 'أعلى بـ$amount عن ميزانيتك.';
  }

  @override
  String homeNofM(int shown, int total) {
    return '$shown من $total';
  }

  @override
  String homeInDaysShort(int days) {
    return 'بعد $days ي';
  }

  @override
  String homePerYearAmount(String amount, String currency) {
    return '$amount $currency سنويًا';
  }

  @override
  String get homeNoBudgetsOnAccount => 'لا توجد ميزانيات على هذا الحساب.';

  @override
  String get homeActiveBudget => 'ميزانية نشطة';

  @override
  String homeAvailableCoupons(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count كوبون متاح',
      many: '$count كوبونًا متاحًا',
      few: '$count كوبونات متاحة',
      two: 'كوبونان متاحان',
      one: 'كوبون واحد متاح',
      zero: 'لا توجد كوبونات متاحة',
    );
    return '$_temp0';
  }

  @override
  String get homePartnerOffers => 'عروض من شركاء قرش';

  @override
  String get homeAllCoupons => 'عرض كل الكوبونات';

  @override
  String get homeSpentToday => 'صرفت اليوم';

  @override
  String get homeSevenDayAverage => 'متوسط ٧ أيام';

  @override
  String get homeSetMonthlyBudgetShort => 'حدّد ميزانية شهرية';

  @override
  String get homeAvailableToday => 'متاح لليوم';

  @override
  String get homeTodayTransactions => 'عمليات اليوم';

  @override
  String get homeTopThreeToday => 'أعلى ٣ اليوم';

  @override
  String get homeUncategorised => 'غير مصنّفة';

  @override
  String get homeNoMonthlyBudget =>
      'لا توجد ميزانية شهرية — حدّدها لتعرف المتاح';

  @override
  String get homeTopCategories => 'أكبر التصنيفات';

  @override
  String get homeSubsPerMonth => 'اشتراكات شهريًا';

  @override
  String get homeInstalmentsPerMonth => 'أقساط شهريًا';

  @override
  String get homeNextCharge => 'أقرب خصم';

  @override
  String get homeChargeDatesThisMonth => 'مواعيد الخصم خلال الشهر';

  @override
  String get homeInstalmentWord => 'قسط';

  @override
  String get homeNoTxInPeriod => 'لا توجد عمليات في هذه الفترة.';

  @override
  String get homeSwipeForMore =>
      'اسحب لباقي العمليات · أو «الكل» لصفحة العمليات';

  @override
  String gdSavedOfTarget(String saved, String target, String currency) {
    return 'وفّرت $saved من $target $currency';
  }

  @override
  String gdRemaining(String amount, String currency) {
    return 'باقي $amount $currency';
  }

  @override
  String gdRemainingWithDays(String amount, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return 'باقي $amount · $_temp0';
  }

  @override
  String gdRecommendedDaily(String amount, String currency) {
    return 'موصى: $amount $currency يوميًا';
  }

  @override
  String cdCardTitle(String last4) {
    return 'بطاقة •••• $last4';
  }

  @override
  String get gdTitle => 'تفاصيل الهدف';

  @override
  String get gdAddToGoal => 'أضف للهدف';

  @override
  String get gdNotFound => 'الهدف غير موجود';

  @override
  String get gdDeleteGoal => 'حذف الهدف';

  @override
  String get gdContributions => 'المساهمات';

  @override
  String get gdNoContributions => 'لا توجد مساهمات بعد.';

  @override
  String get gdDeleteTitle => 'حذف الهدف؟';

  @override
  String get gdDeleteBody => 'سيتم حذف الهدف ومساهماته نهائياً.';

  @override
  String get gdSaveFailed => 'تعذّر حفظ المساهمة الآن.';

  @override
  String get gdAddContribution => 'إضافة مساهمة';

  @override
  String get bdgAmount => 'المبلغ';

  @override
  String get gdSaveContribution => 'حفظ المساهمة';

  @override
  String get cdCardTransactions => 'عمليات هذه البطاقة';

  @override
  String get cdNoTxYet => 'لا توجد عمليات بعد';

  @override
  String get bfInvalidAmount => 'مبلغ غير صالح';

  @override
  String get bfPickFutureDue => 'اختر تاريخ استحقاق قادمًا أو اليوم.';

  @override
  String get bfPaidFromForm => 'مدفوع يدويًا من النموذج';

  @override
  String get bfSavedButPaymentFailed =>
      'تم حفظ الفاتورة، لكن فشل تسجيل الدفعة — أعد المحاولة بنفس البيانات.';

  @override
  String get bfSaveFailed => 'حدث خطأ غير متوقع أثناء الحفظ. حاول مجددًا.';

  @override
  String get bfAddBill => 'إضافة فاتورة';

  @override
  String get bfEditBill => 'تعديل فاتورة';

  @override
  String get bfSubscription => 'اشتراك';

  @override
  String get bfInstalment => 'قسط';

  @override
  String get bfBillName => 'اسم الفاتورة';

  @override
  String get bfEnterName => 'اكتب الاسم';

  @override
  String get bfEnterValidAmount => 'اكتب مبلغ صحيح';

  @override
  String get bfManuallyPaidAmount => 'مبلغ مدفوع يدويًا';

  @override
  String get bfPaidManuallyFromSub => 'مدفوع من الاشتراك يدويًا';

  @override
  String get bfRecordManualHint => 'إذا دفعت مبلغًا ولم يظهر كعملية، سجّله هنا';

  @override
  String get bfAmountAboveZero => 'اكتب مبلغ أكبر من صفر';

  @override
  String get bfAccountCurrency => 'عملة الحساب';

  @override
  String get bfLender => 'المقرض / الجهة (Tamara, بنك...)';

  @override
  String get bfTotalInstalments => 'عدد الأقساط الكلي';

  @override
  String get bfPaidSoFar => 'المدفوع منها';

  @override
  String get bfPurchaseValue => 'قيمة الشراء / القرض';

  @override
  String get bfInterestOptional => 'الفائدة % (اختياري)';

  @override
  String get bfHowOften => 'كل كم؟';

  @override
  String get bfEveryHowManyDays => 'كل كم يوم؟';

  @override
  String get bfEnterValidDays => 'اكتب عدد أيام صحيح';

  @override
  String get bfNextDueDate => 'تاريخ الاستحقاق القادم';

  @override
  String get bfEnableReminder => 'تفعيل التذكير';

  @override
  String get bfConfirmedBill => 'فاتورة مؤكدة';

  @override
  String get bfPresetCarInstalment => 'قسط سيارة';

  @override
  String get bfPresetRent => 'إيجار';

  @override
  String get bfPresetPhone => 'جوال';

  @override
  String get bfPresetLaptop => 'لابتوب';

  @override
  String get bfPresetFurniture => 'أثاث';

  @override
  String get bfPresetEducation => 'تعليم';

  @override
  String get bfPresetTravel => 'سفر';

  @override
  String get bfPresetMedical => 'علاج';

  @override
  String get bfPresetWedding => 'زواج';

  @override
  String get bfPresetGold => 'ذهب';

  @override
  String get bfPresetAppliances => 'أجهزة منزلية';

  @override
  String get bfPresetComputer => 'كمبيوتر';

  @override
  String get bfSearchService => 'ابحث عن خدمة...';

  @override
  String get bfSearchInstalment => 'ابحث عن قسط...';

  @override
  String get bfCustomSub => 'اشتراك مخصص';

  @override
  String get bfCustomInstalment => 'قسط مخصص';

  @override
  String get bfAddManuallyHint => 'أضف الاسم والمبلغ والتكرار يدويًا';

  @override
  String get bfMostUsed => 'الأكثر استخدامًا';

  @override
  String get afVodafoneCash => 'فودافون كاش';

  @override
  String get afOrangeCash => 'أورنج كاش';

  @override
  String get afEtisalatCash => 'e& كاش';

  @override
  String get afWePay => 'وي باي';

  @override
  String get afCurrencyLockedInUse =>
      'لا يمكن تغيير عملة حساب يحتوي على رصيد أو عمليات.';

  @override
  String get afUsageCheckFailed =>
      'تعذر التحقق من استخدام الحساب؛ لم يتم تغيير العملة.';

  @override
  String get afEnterAccountName => 'الرجاء إدخال اسم الحساب';

  @override
  String get afPaymentDayRange => 'يوم السداد يجب أن يكون بين 1 و31';

  @override
  String get afSaveFailed => 'حدث خطأ غير متوقع — بياناتك محفوظة، حاول مجددًا.';

  @override
  String get afDeleteAccount => 'حذف الحساب';

  @override
  String get afDeletePrepFailed => 'تعذّر تحضير الحذف — حاول مجددًا.';

  @override
  String get afCannotDeleteLast => 'لا يمكن حذف آخر حساب.';

  @override
  String get afNeedsExplicitDecision =>
      'تعذّر الحذف — بعض العناصر تحتاج قرارًا صريحًا.';

  @override
  String get afDeleteFailed => 'تعذّر حذف الحساب — حاول مجددًا.';

  @override
  String get afEditAccount => 'تعديل حساب';

  @override
  String get afNewAccount => 'حساب جديد';

  @override
  String get afAccountName => 'اسم الحساب';

  @override
  String get afAccountNameHint => 'مثال: كاش مصر، بنك الراجحي، محفظة USD';

  @override
  String get afCurrencyLockedShort => 'لا يمكن تغيير عملة حساب مستخدم';

  @override
  String get afDefaultAccountHint => 'العمليات الجديدة تتسجّل هنا تلقائيًا';

  @override
  String get afExcludeFromTotals => 'استبعاد من الإجماليات';

  @override
  String get afOpeningBalance => 'الرصيد الافتتاحي (اختياري)';

  @override
  String get afBankAccountNumber => 'رقم الحساب البنكي (اختياري)';

  @override
  String get afHelpsMatching => 'يساعد مطابقة الرسائل';

  @override
  String get afCreditLimit => 'الحد الائتماني (اختياري)';

  @override
  String get afAvailableBalance => 'الرصيد المتاح (اختياري)';

  @override
  String get afPaymentDay => 'يوم السداد (1–31، اختياري)';

  @override
  String get afProvider => 'المزوّد';

  @override
  String get afUnspecified => 'غير محدَّد';

  @override
  String get afAdvancedOptions => 'خيارات متقدمة';

  @override
  String gfRecommendedFor(String amount, String currency, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومين',
      one: 'يوم واحد',
    );
    return 'المبلغ الموصى به: $amount $currency يوميًا لـ $_temp0.';
  }

  @override
  String bfsSuggestAfterMoreTx(String period) {
    return 'بعد إضافة عمليات أكثر، سنقترح ميزانية $period مناسبة.';
  }

  @override
  String bfsSuggestion(String period, String value) {
    return 'اقتراح ميزانية $period: $value';
  }

  @override
  String get cfDeleteCardBody =>
      'حذف البطاقة لن يحذف عملياتها — تبقى محفوظة بأرقامها. قد تظهر بطاقة تلقائية بنفس الأرقام إذا وصلت رسالة جديدة.';

  @override
  String get mtEnterValidAmount => 'اكتب مبلغًا صحيحًا.';

  @override
  String get mtPickCategory => 'اختر تصنيف العملية.';

  @override
  String get mtSaveFailed => 'تعذر حفظ العملية الآن.';

  @override
  String get mtDeleteBody => 'سيتم حذف العملية من التقارير والميزانيات.';

  @override
  String get mtDeleteFailed => 'تعذر حذف العملية الآن.';

  @override
  String get mtConfirmFailed => 'تعذر تأكيد العملية الآن.';

  @override
  String get mtAddManually => 'إضافة عملية يدويًا';

  @override
  String get mtCategoriesFailed => 'تعذر تحميل التصنيفات';

  @override
  String get mtMerchantOptional => 'المتجر أو المصدر (اختياري)';

  @override
  String get mtNoteOptional => 'ملاحظة (اختياري)';

  @override
  String get mtSaveEdits => 'حفظ التعديلات';

  @override
  String get mtAddTransaction => 'إضافة العملية';

  @override
  String get mtTxConfirmed => 'العملية مؤكدة';

  @override
  String get cfEnterValidLast4 => 'أدخل آخر 4 أرقام صحيحة';

  @override
  String get cfDuplicateCard => 'توجد بطاقة بنفس الأرقام في هذا الحساب';

  @override
  String get cfSaveFailed => 'تعذّر حفظ البطاقة — حاول مجددًا.';

  @override
  String get cfDeleteTitle => 'حذف البطاقة؟';

  @override
  String get cfDeleteFailed => 'تعذّر حذف البطاقة — حاول مجددًا.';

  @override
  String get cfEditCard => 'تعديل بطاقة';

  @override
  String get cfNewCard => 'بطاقة جديدة';

  @override
  String get cfAutoDetected => 'مكتشفة تلقائيًا من رسائلك';

  @override
  String get cfShortNameOptional => 'اسم مختصر (اختياري)';

  @override
  String get cfShortNameHint => 'مثال: راتب، سفر';

  @override
  String get cfLast4 => 'آخر 4 أرقام';

  @override
  String get cfNetwork => 'الشبكة';

  @override
  String get cardNetworkGeneric => 'بطاقة';

  @override
  String get cfDesign => 'التصميم';

  @override
  String get cfAccentOptional => 'لون مميّز (اختياري)';

  @override
  String get cfAccentNone => 'بدون لون مميّز';

  @override
  String cfAccentColourName(String colour) {
    String _temp0 = intl.Intl.selectLogic(
      colour,
      {
        'amber': 'كهرماني',
        'red': 'أحمر',
        'pink': 'وردي',
        'purple': 'بنفسجي',
        'blue': 'أزرق',
        'cyan': 'سماوي',
        'emerald': 'زمردي',
        'lime': 'أخضر ليموني',
        'orange': 'برتقالي',
        'teal': 'فيروزي',
        'other': 'لون مميّز',
      },
    );
    return '$_temp0';
  }

  @override
  String get cfLinkedAccount => 'الحساب المرتبط';

  @override
  String get cfDeleteCard => 'حذف البطاقة';

  @override
  String get cfNoAccount => 'بدون حساب';

  @override
  String get gfNewGoal => 'هدف جديد';

  @override
  String get gfEditGoal => 'تعديل الهدف';

  @override
  String get gfGoalName => 'اسم الهدف';

  @override
  String get gfEnterGoalName => 'اكتب اسم الهدف';

  @override
  String get gfTargetAmount => 'المبلغ المستهدف';

  @override
  String get gfEnterValidAmount => 'أدخل مبلغًا صحيحًا';

  @override
  String get gfDeadline => 'الموعد النهائي';

  @override
  String get gfOptional => 'اختياري';

  @override
  String get gfRecommendedAfterDate =>
      'المبلغ الموصى به يظهر بعد اختيار التاريخ.';

  @override
  String get gfAutoSaving => 'ادخار تلقائي';

  @override
  String get gfAutoSavingHint => 'يضيف قِرش المبلغ للهدف كل فترة تلقائيًا';

  @override
  String get gfFrequency => 'التكرار';

  @override
  String get gfCreateGoal => 'أنشئ الهدف';

  @override
  String get gfSaveEdit => 'حفظ التعديل';

  @override
  String get gfPickFutureDeadline => 'اختر موعدًا نهائيًا قادمًا أو اليوم.';

  @override
  String get bfsNewBudget => 'ميزانية جديدة';

  @override
  String get bfsPickCategory => 'اختر تصنيفًا';

  @override
  String get bfsSaveBudget => 'حفظ الميزانية';

  @override
  String get bfsDeleteBody => 'سيتم حذف هذه الميزانية نهائياً.';

  @override
  String get bfsPeriodDaily => 'يومية';

  @override
  String get bfsPeriodWeekly => 'أسبوعية';

  @override
  String get bfsPeriodMonthly => 'شهرية';

  @override
  String get bfsPeriodYearly => 'سنوية';

  @override
  String get bfsComputingSuggestion => 'نحسب اقتراحًا من آخر 30 يومًا...';

  @override
  String get bfsUseIt => 'استخدمه';

  @override
  String get bfsBudgetPeriod => 'دورية الميزانية';

  @override
  String get bdgDeleteBudget => 'حذف الميزانية';

  @override
  String get mtKindExpense => 'مصروف';

  @override
  String bdsIncludesLegacyManual(String amount, String currency) {
    return 'يشمل $amount $currency مدفوعة يدويًا قديمة.';
  }

  @override
  String bdsPayAllRemaining(int count) {
    return 'سداد كل الأقساط المتبقية ($count) دفعة واحدة';
  }

  @override
  String bdsPaymentForPeriod(String from, String to) {
    return 'هذه الدفعة عن الفترة $from - $to';
  }

  @override
  String bdsPaymentForInstalment(int index, String from, String to) {
    return 'هذه الدفعة عن قسط رقم $index للفترة $from - $to';
  }

  @override
  String bdsPayRemainingInFull(String amount, String currency) {
    return 'سدّد المتبقي بالكامل ($amount $currency)';
  }

  @override
  String bdsInstalmentNamed(String name) {
    return 'قسط $name';
  }

  @override
  String bdsSubscriptionNamed(String name) {
    return 'اشتراك $name';
  }

  @override
  String bdsDeleteBody(String name) {
    return 'سيتم حذف «$name» من الاشتراكات والأقساط.';
  }

  @override
  String bdsDeleted(String name) {
    return 'حُذف $name';
  }

  @override
  String bdsInstalmentNumber(int index) {
    return 'قسط رقم $index';
  }

  @override
  String bdsPaymentNamed(String name) {
    return 'دفعة $name';
  }

  @override
  String plCardShort(String last4) {
    return 'بطاقة ••$last4';
  }

  @override
  String plPerDayLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return '/يوم · $_temp0';
  }

  @override
  String plDeleteBody(String name) {
    return 'ستُحذف خطة «$name». لن تتأثر العمليات نفسها.';
  }

  @override
  String plOfBudget(String amount, String currency) {
    return 'من $amount $currency';
  }

  @override
  String get bdsInstalmentValue => 'قيمة القسط';

  @override
  String get bdsTotalPaid => 'إجمالي مدفوع';

  @override
  String get bdsRecordedPayments => 'دفعات مسجّلة';

  @override
  String get bdsPaid => 'مدفوع';

  @override
  String get bdsRemaining => 'متبقي';

  @override
  String get bdsProgress => 'تقدم';

  @override
  String get bdsRecordInstalmentPayment => 'تسجيل دفع قسط';

  @override
  String get bdsRecordPayment => 'تسجيل دفعة';

  @override
  String get bdsPaymentHistory => 'سجل الدفعات';

  @override
  String get bdsNoManualInstalmentPayments =>
      'لا توجد بعد دفعات أقساط مسجّلة يدويًا.';

  @override
  String get bdsNoManualSubPayments =>
      'لا توجد بعد دفعات اشتراك مسجّلة يدويًا.';

  @override
  String get bdsSuggestedToLink => 'عمليات مقترحة للربط';

  @override
  String get bdsNameMatchNote =>
      'مطابقة بالاسم — لا تُحتسب ضمن المدفوع حتى تربطها كدفعة.';

  @override
  String get bdsNoSuggestions => 'لا توجد عمليات مقترحة للربط.';

  @override
  String get bdsOptionalNote => 'ملاحظة اختيارية';

  @override
  String get bdsRecordFailed => 'تعذّر تسجيل الدفعة الآن. حاول مجددًا.';

  @override
  String get bdsSavedButNotLinked =>
      'تم حفظ العملية، لكن تعذّر ربط الدفعة. أعد المحاولة ولن تتكرر العملية.';

  @override
  String get bdsRecord => 'تسجيل';

  @override
  String get bdsPaymentRecorded => 'تم تسجيل الدفعة وأضيفت للعمليات.';

  @override
  String get bdsDeleteBillTitle => 'حذف الفاتورة؟';

  @override
  String get bdsDeleteBillFailed => 'تعذّر حذف الفاتورة الآن.';

  @override
  String get bdsDeletePaymentTitle => 'حذف الدفعة؟';

  @override
  String get bdsDeletePaymentBody => 'سيُحذف سجل الدفع اليدوي هذا نهائيًا.';

  @override
  String get bdsDeletePaymentFailed => 'تعذّر حذف الدفعة الآن.';

  @override
  String get plSubtitle => 'ميزانية لكل مناسبة، تتابع نفسها';

  @override
  String get plLoadFailed => 'تعذّر التحميل';

  @override
  String get plNoPlans => 'لا توجد خطط بعد';

  @override
  String get plEmptyBody =>
      'أنشئ خطة لرحلة أو مناسبة: ميزانية وفترة والبطاقات التي ستصرف منها، ويتابعها قِرش لك.';

  @override
  String get plAllSpendInPeriod => 'كل المصروفات في الفترة';

  @override
  String get plSpecificAccounts => 'حسابات محددة';

  @override
  String get plEnded => 'منتهية';

  @override
  String get plPlanOptions => 'خيارات الخطة';

  @override
  String get plDeleteTitle => 'حذف الخطة؟';

  @override
  String get plDeleteFailed => 'تعذّر حذف الخطة الآن.';

  @override
  String get plDetails => 'تفاصيل الخطة';

  @override
  String get plNotFound => 'الخطة غير موجودة';

  @override
  String get plLinkTransaction => 'ربط عملية';

  @override
  String get plHistory => 'سجل الخطة';

  @override
  String get plTxLoadFailed => 'تعذّر تحميل العمليات';

  @override
  String get plNoLinkedTx => 'لا توجد عمليات مرتبطة';

  @override
  String get plLinkHint => 'اربط عملية موجودة أو اختر حسابًا أو بطاقة للخطة.';

  @override
  String get plLinkToPlan => 'ربط عملية بالخطة';

  @override
  String get plNoSuitableTx => 'لا توجد عمليات مناسبة';

  @override
  String get plAllLinkedAlready =>
      'كل العمليات المناسبة مرتبطة بالفعل أو غير مؤكدة.';

  @override
  String get pcrWhyBody =>
      'الميزانيات والأهداف القديمة لا تحفظ عملة مع المبلغ. لذلك لن يخمّن قِرش عملتها، بل تختار أنت كيف تريد معاملتها. لن يتغيّر أي مبلغ ولن تُحذف أي بيانات. مساهمات الأهداف تتبع عملة الهدف تلقائيًا.';

  @override
  String pcrNoCurrencySet(String amount) {
    return '$amount · بدون عملة محددة';
  }

  @override
  String pcrConfirmedFor(String currency) {
    return 'تم تأكيد $currency لكل الميزانيات والأهداف الحالية.';
  }

  @override
  String bkLastBackup(String date, String time) {
    return 'آخر نسخة: $date · $time';
  }

  @override
  String get pcrTitle => 'تأكيد عملة التخطيط';

  @override
  String get pcrListChanged => 'تغيّرت الميزانيات أو الأهداف';

  @override
  String get pcrListChangedBody =>
      'القرار السابق لم يعد يطابق القائمة الحالية. حدّث القائمة ثم أكّد العملات مرة أخرى.';

  @override
  String get pcrRefreshList => 'تحديث القائمة';

  @override
  String get pcrWhyTitle => 'لماذا نحتاج تأكيدك؟';

  @override
  String get pcrDefaultSuggestion => 'الاقتراح الافتراضي';

  @override
  String get pcrSuggestionNote =>
      'هذا اقتراح من عملتك الحالية فقط، وليس قراراً محفوظاً حتى تؤكده.';

  @override
  String get pcrHowToConfirm => 'طريقة التأكيد';

  @override
  String get pcrOneCurrencyForAll => 'عملة واحدة للجميع';

  @override
  String get pcrOneCurrencyHint =>
      'كل الميزانيات والأهداف الحالية تستخدم نفس العملة';

  @override
  String get pcrPerItem => 'تحديد عملة لكل عنصر';

  @override
  String get pcrPerItemHint => 'اختر عملة مختلفة لكل ميزانية أو هدف عند الحاجة';

  @override
  String get pcrSaveSelected => 'حفظ العملات المحددة';

  @override
  String get pcrNotNow => 'ليس الآن — سأكمل لاحقاً';

  @override
  String get pcrAllOneCurrency => 'كل العناصر بعملة واحدة';

  @override
  String get pcrCurrencyCode => 'رمز العملة';

  @override
  String get pcrWillRecord =>
      'سيسجل التأكيد أن كل الميزانيات والأهداف الحالية تستخدم هذا الرمز.';

  @override
  String get pcrUnsupportedCodeLong =>
      'رمز العملة غير مدعوم. استخدم رمزاً من ثلاث حروف مثل EGP أو SAR.';

  @override
  String get pcrUnsupportedCode => 'رمز العملة غير مدعوم.';

  @override
  String get pcrSaveFailed =>
      'تعذر حفظ التأكيد الآن. لم تتغير أي من بياناتك المالية.';

  @override
  String get pcrTreatAsCurrency => 'اعتبرها بهذه العملة';

  @override
  String get pcrNothingToFix => 'لا يوجد شيء يحتاج إلى إصلاح';

  @override
  String get pcrNothingToFixBody =>
      'لا توجد ميزانيات أو أهداف قديمة تحتاج إلى تأكيد عملتها.';

  @override
  String get pcrPerItemSaved => 'تم حفظ عملة مستقلة لكل ميزانية وهدف حالي.';

  @override
  String get pcrConfirmed => 'تم تأكيد العملات';

  @override
  String get pcrBackToSettings => 'العودة إلى الإعدادات';

  @override
  String get pcrReadFailed => 'تعذر قراءة بيانات التخطيط. لم يتغير أي شيء.';

  @override
  String get rcTitle => 'إنشاء تقرير مالي';

  @override
  String get rcPeriod => 'الفترة';

  @override
  String get rcCustom => 'مخصّص';

  @override
  String get rcPickRange => 'اختر المدى';

  @override
  String get accTitleShort => 'الحسابات';

  @override
  String get rcLanguage => 'اللغة';

  @override
  String get rcArabic => 'العربية';

  @override
  String get rcTxDetails => 'تفاصيل العمليات';

  @override
  String get rcMerchantNames => 'أسماء المتاجر';

  @override
  String get rcAccountNames => 'أسماء الحسابات';

  @override
  String get rcBalances => 'الأرصدة';

  @override
  String get rcNotes => 'الملاحظات';

  @override
  String get rcPrivacyMode => 'وضع الخصوصية (إخفاء المبالغ)';

  @override
  String get rcCreateReport => 'إنشاء التقرير';

  @override
  String get rcNoDataInPeriod => 'لا توجد بيانات في هذه الفترة';

  @override
  String get rcFontsFailed => 'تعذّر تحميل الخطوط';

  @override
  String get rcPdfFailed => 'تعذّر إنشاء ملف PDF';

  @override
  String get rcSaveFailed => 'تعذّر حفظ الملف';

  @override
  String get rcCancelled => 'أُلغي';

  @override
  String get rcUnexpectedError => 'حدث خطأ غير متوقع';

  @override
  String get rcGenerating => 'جاري إنشاء التقرير…';

  @override
  String get rcStepCollect => 'جمع البيانات';

  @override
  String get rcStepMetrics => 'حساب المؤشرات';

  @override
  String get rcStepDraw => 'رسم الصفحات';

  @override
  String get rcStepSave => 'حفظ الملف';

  @override
  String get rcStepDone => 'اكتمل';

  @override
  String get bkTitle => 'النسخ الاحتياطي والاستعادة';

  @override
  String get bkSubtitle =>
      'احفظ بياناتك المالية واسترجعها بأمان وسرية تامة في أي وقت.';

  @override
  String get bkCreateAccountTitle => 'أنشئ حسابًا لتفعيل النسخ الاحتياطي';

  @override
  String get bkCreateAccountBody =>
      'يمكنك استخدام قِرش محليًا بدون حساب. النسخ الاحتياطي يحتاج تسجيل دخول حتى نربط النسخة المشفّرة بك.';

  @override
  String get bkNoBackupYet => 'لم تُنشأ نسخة بعد';

  @override
  String get bkBackupNow => 'نسخ احتياطي الآن';

  @override
  String get bkTurnOff => 'إيقاف النسخ الاحتياطي';

  @override
  String get bkLocalDataStays => 'بياناتك المحلية تبقى عند الإيقاف.';

  @override
  String get bkEnableFailed => 'فشل تفعيل النسخ الاحتياطي. حاول مرة أخرى.';

  @override
  String get bkEncryptedWeCannotRead => 'نسخة مشفّرة لا يمكننا قراءتها';

  @override
  String get bkOptionalOffByDefault =>
      'النسخ الاحتياطي اختياري ومطفأ افتراضياً. عند تفعيله تُشفّر بياناتك end-to-end وترجع على أي جهاز.';

  @override
  String get bkPassphrase => 'كلمة مرور التشفير (passphrase)';

  @override
  String get bkContinue => 'متابعة';

  @override
  String get bkRecoveryCode => 'رمز الاسترداد (Recovery Code)';

  @override
  String get bkCopyCode => 'نسخ الرمز';

  @override
  String get bkLoseBothWarning =>
      'إذا فقدت كلمة المرور والرمز معًا لن نتمكّن من استعادة نسختك.';

  @override
  String get bkSavedTheCode => 'حفظت الرمز وأفهم ذلك';

  @override
  String get bkEnable => 'تفعيل';

  @override
  String get bkRestoreFromBackup => 'استعادة من نسخة احتياطية';

  @override
  String get pcrOldAmount => 'المبلغ القديم';

  @override
  String get pcrOldTarget => 'المبلغ المستهدف القديم';

  @override
  String get cesTitle => 'إضافة عملية جديدة';

  @override
  String get cesPasteBankMessage => 'ألصق رسالة بنك';

  @override
  String get cesPasteHint => 'نقرأ الرسالة ونجهّز العملية للمراجعة.';

  @override
  String get cesManualEntry => 'إضافة يدوية';

  @override
  String get cesManualHint => 'اكتب تفاصيل العملية بنفسك.';

  @override
  String get bkStateDisabled => 'النسخ الاحتياطي متوقف';

  @override
  String get bkStateEnabling => 'جارٍ التفعيل…';

  @override
  String get bkStatePreparing => 'جارٍ التحضير…';

  @override
  String get bkStateEncrypting => 'جارٍ التشفير…';

  @override
  String get bkStateUploading => 'جارٍ الرفع…';

  @override
  String get bkStateVerifying => 'جارٍ التحقق…';

  @override
  String get bkStateDownloading => 'جارٍ التنزيل…';

  @override
  String get bkStateProtected => 'محمي';

  @override
  String get bkStateWaitingForConnection => 'بانتظار الاتصال';

  @override
  String get bkStateWillRetry => 'ستتم إعادة المحاولة';

  @override
  String get bkStateNeedsSignIn => 'يلزم تسجيل الدخول';

  @override
  String get bkStateNeedsCloudSync => 'يلزم تفعيل المزامنة السحابية';

  @override
  String get bkStateFailedRetryable => 'فشل — أعد المحاولة';

  @override
  String get bkStateFailed => 'فشل';

  @override
  String get bkStateDeleting => 'جارٍ حذف النسخة عن بُعد';

  @override
  String get bkStateCancelled => 'أُلغيت';

  @override
  String get iosStep1 => 'افتح تطبيق الاختصارات';

  @override
  String get iosStep1Body =>
      'ادخل على Shortcuts ثم تبويب Automation من الأسفل.';

  @override
  String get iosStep2 => 'أنشئ Automation جديد';

  @override
  String get iosStep2Body => 'اضغط New Automation أو علامة +، ثم اختر Message.';

  @override
  String get iosStep3 => 'حدّد رسائل البنك';

  @override
  String get iosStep4 => 'اجعله يعمل فورًا';

  @override
  String get iosStep4Body =>
      'اختَر Run Immediately. إذا ظهر Notify When Run فأغلقه، ثم اضغط Next.';

  @override
  String get iosStep5 => 'اختَر اختصار قِرش';

  @override
  String get iosStep5Body =>
      'اضغط New Blank Automation، وابحث عن Process Bank SMS.';

  @override
  String get iosStep6 => 'مرّر نص الرسالة';

  @override
  String get iosStep6Body =>
      'اضبط SMS Text على Shortcut Input وسيب Sender على مرسل الرسالة. قرش بيسجّل وقت الالتقاط تلقائيًا.';

  @override
  String get iosStep7 => 'طابق الشكل النهائي';

  @override
  String get iosStep7Body =>
      'يجب أن يكون: Receive messages as input ثم Process Bank SMS وفيها SMS Text = Shortcut Input. افتح تفاصيل الأكشن وأغلق Show When Run إذا ظهر.';

  @override
  String get iosStep8 => 'احفظ الاختصار';

  @override
  String get iosStep8Body =>
      'اضغط Done. بعدها أي رسالة بنك مطابقة ستتحول لعملية داخل قِرش.';

  @override
  String get countrySA => 'السعودية';

  @override
  String get countryAE => 'الإمارات';

  @override
  String get countryEG => 'مصر';

  @override
  String get countryKW => 'الكويت';

  @override
  String get countryQA => 'قطر';

  @override
  String get countryBH => 'البحرين';

  @override
  String get countryOM => 'عُمان';

  @override
  String get countryJO => 'الأردن';

  @override
  String get setupSaveFailed => 'تعذّر حفظ الإعدادات. حاول مرة أخرى.';

  @override
  String get setupFinishFailed => 'تعذّر إنهاء الإعداد. حاول مرة أخرى.';

  @override
  String iosStep3Body(String currency) {
    return 'في Message Contents اكتب رمز العملة مثل $currency، وكرّر لاحقًا لأي عملة إضافية.';
  }

  @override
  String pfCurrencyOnly(String currency) {
    return 'تحسب الخطة عمليات $currency فقط — ولا يُحتسب فيها أي حساب بعملة أخرى.';
  }

  @override
  String pfCardNamed(String last4) {
    return 'بطاقة $last4';
  }

  @override
  String obPerMonth(String amount, String currency) {
    return '$amount $currency شهريًا';
  }

  @override
  String get aiTitle => 'وزّع دخلك';

  @override
  String get aiSubtitle =>
      'اكتب دخلك، ووزّعه على المظاريف — يمكنك تعديل أي رقم.';

  @override
  String get aiSaving => 'جارٍ الحفظ...';

  @override
  String get aiSaveSplit => 'احفظ التوزيع';

  @override
  String get aiMonthlyIncome => 'دخلك الشهري';

  @override
  String get aiSuggestSplit => 'اقترح توزيع تلقائي';

  @override
  String get aiSavings => 'الادخار';

  @override
  String get aiCreateGoalHint => 'أنشئ هدف ادخار لنحوّله تلقائيًا كل شهر.';

  @override
  String get aiAutoToGoal => 'يتحوّل تلقائيًا لهدف';

  @override
  String get aiAllocated => 'موزّع على المظاريف';

  @override
  String get aiUnallocated => 'متبقي غير موزّع';

  @override
  String get aiOverIncomeBy => 'تجاوزت دخلك بـ';

  @override
  String get pfEditPlan => 'تعديل الخطة';

  @override
  String get pfSubtitle => 'سفر، عُرس، رمضان… ميزانية لفترة محددة تتابع نفسها.';

  @override
  String get pfSavePlan => 'احفظ الخطة';

  @override
  String get pfPlanName => 'اسم الخطة';

  @override
  String get pfPlanNameHint => 'مثلاً: رحلة دبي';

  @override
  String get pfPlanBudget => 'ميزانية الخطة';

  @override
  String get pfAccountsToSpendFrom => 'الحسابات التي ستصرف منها';

  @override
  String get pfCardsOptional => 'البطاقات (اختياري)';

  @override
  String get pfNoScopeHint =>
      'إذا لم تختر حسابًا أو بطاقة، ستحسب الخطة كل المصاريف في الفترة.';

  @override
  String ctsFeeAlsoAdded(String amount, String currency) {
    return 'وجدنا عمليتين في الرسالة: أضفنا أيضًا الرسوم/الضريبة $amount $currency (بعملة مختلفة).';
  }

  @override
  String ctsForeignCurrencyHint(String amount, String foreign, String home) {
    return 'عملية بعملة مختلفة ($amount $foreign). اكتب قيمتها بـ $home لتُحتسب — أو اتركها وعدّلها لاحقًا عند وصول المبلغ المخصوم.';
  }

  @override
  String get pcsIntro =>
      'عُدِّل هذا العنصر على جهاز آخر أيضًا. اختر النسخة التي تريد الاحتفاظ بها.';

  @override
  String get ctsNeedsCategory =>
      'محتاجة تصنيف — اختَر التصنيف المناسب بالأسفل.';

  @override
  String get ctsAiParsed => 'حلّلها الذكاء الاصطناعي — أكّد المبلغ والتصنيف.';

  @override
  String get ctsLowConfidence =>
      'القراءة غير مؤكدة تمامًا — راجع التفاصيل قبل التأكيد.';

  @override
  String get ctsReviewBeforeConfirm => 'راجِع التفاصيل قبل التأكيد.';

  @override
  String get ctsTitle => 'مراجعة العملية';

  @override
  String get ctsCategoryLabel => 'التصنيف:';

  @override
  String get ctsCategoryUpdateFailed => 'تعذر تحديث التصنيف.';

  @override
  String get ctsConfirmFailed => 'تعذّر تأكيد العملية. حاول مرة أخرى.';

  @override
  String get ctsEditDetails => 'تعديل التفاصيل';

  @override
  String get adTitle => 'الحساب';

  @override
  String get adNotFound => 'الحساب غير موجود';

  @override
  String get adCards => 'البطاقات';

  @override
  String get adNoCards =>
      'لا توجد بطاقات بعد — تظهر تلقائيًا من رسائلك أو أضفها يدويًا.';

  @override
  String get adRecentTx => 'آخر العمليات';

  @override
  String get pcsLoadFailed => 'تعذّر تحميل التعارضات — حاول مجددًا.';

  @override
  String get pcsNoConflicts => 'لا توجد تعارضات';

  @override
  String get pcsAllSynced => 'كل بيانات التخطيط متزامنة.';

  @override
  String get pcsTitle => 'حل تعارضات المزامنة';

  @override
  String get pcsKeptMine => 'تم الاحتفاظ بنسختك.';

  @override
  String get pcsKeptTheirs => 'تم اعتماد نسخة الجهاز الآخر.';

  @override
  String get pcsKeepMine => 'احتفظ بنسختي';

  @override
  String get pcsKeepTheirs => 'نسخة الجهاز الآخر';

  @override
  String get rprUnsupportedCode => 'رمز عملة غير مدعوم';

  @override
  String get rprTitle => 'عملة بيانات النسخة الاحتياطية';

  @override
  String get rprPerItem => 'عملة لكل عنصر';

  @override
  String get rprTreatAllAs => 'اعتبر كل العناصر بهذه العملة';

  @override
  String get rprContinueRestore => 'متابعة الاستعادة';

  @override
  String get rprCancelRestore => 'إلغاء الاستعادة';

  @override
  String get rprGoal => 'هدف';

  @override
  String get rprBudget => 'ميزانية';

  @override
  String get psrTitle => 'بنود بانتظار تحديد العملة (من المزامنة)';

  @override
  String get psrUnsupported => 'عملة غير مدعومة';

  @override
  String get psrConfirmed => 'تم التأكيد';

  @override
  String get psrConfirmFailed => 'تعذّر التأكيد — حاول مرة أخرى';

  @override
  String get psrCurrencyExample => 'العملة (مثال: KWD)';

  @override
  String get adsSubsAndBills => 'الاشتراكات والفواتير';

  @override
  String get adsPickDestination =>
      'اختر وجهة كل اشتراك نشط — لن يُحذف تلقائيًا.';

  @override
  String get adsChoose => 'اختر…';

  @override
  String get adsArchive => 'أرشفة';

  @override
  String get rpTitle => 'معاينة التقرير';

  @override
  String get rpShare => 'مشاركة';

  @override
  String get rpPrint => 'طباعة';

  @override
  String get rpShareFinancialData => 'مشاركة بيانات مالية';

  @override
  String get rpShareWarning =>
      'يحتوي هذا التقرير على أرصدة وأسماء متاجر. هل تريد مشاركته؟';

  @override
  String get rpFinancialReport => 'التقرير المالي';

  @override
  String get psrIntro =>
      'وصلت هذه الصفوف من المزامنة بدون عملة. اختر العملة الصحيحة لكل صف — لن يُخمّن قِرش عملتها، ولن يتغيّر أي مبلغ.';

  @override
  String psrAmount(String amount) {
    return 'المبلغ: $amount';
  }

  @override
  String adsWillDetach(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عملية',
      many: '$count عملية',
      few: '$count عمليات',
      two: 'عمليتان',
      one: 'عملية واحدة',
    );
    return 'ستُفصل $_temp0 (يبقى سجلها كاملًا).';
  }

  @override
  String adsMoveTo(String account) {
    return 'نقل إلى $account';
  }

  @override
  String get rprIntro =>
      'النسخة الاحتياطية لا تحفظ عملة الميزانيات والأهداف. اختر كيف تريد معاملة هذه العناصر عند الاستعادة.';

  @override
  String rprLegacyAmount(String amount) {
    return 'المبلغ القديم: $amount · العملة غير محددة';
  }

  @override
  String get dpeCsvTooLarge => 'حجم ملف CSV أكبر من 25MB.';

  @override
  String get dpeCsvEmpty => 'ملف CSV فارغ.';

  @override
  String get dpeCsvTooManyRows => 'ملف CSV يتجاوز 100,000 صف.';

  @override
  String get dpeCsvBadHeaders => 'عناوين أعمدة CSV غير صالحة.';

  @override
  String get dpeCsvDuplicateColumns => 'ملف CSV يحتوي أعمدة مكررة.';

  @override
  String get dpeFileTooLarge => 'حجم الملف أكبر من 25MB.';

  @override
  String get dpeZipInvalid => 'ملف ZIP غير صالح أو تالف.';

  @override
  String get dpePickCsvOrZip => 'اختر ملف CSV أو ZIP.';

  @override
  String get dpeFixErrorsFirst => 'أصلح أخطاء الملف قبل الاستيراد.';

  @override
  String get dpeExternalCsvMergeOnly => 'CSV الخارجي يدعم الدمج فقط.';

  @override
  String get dpeReplaceUnavailableMixed =>
      'الاستبدال غير متاح أثناء تشغيل مصادر بيانات مختلطة.';

  @override
  String get dpeReplaceUnavailableCloud =>
      'الاستبدال متاح فقط للبيانات المحفوظة على هذا الجهاز. لأن بياناتك مزامَنة مع حسابك، استخدم «دمج» بدلًا من ذلك.';

  @override
  String get dpeReselectFile => 'أعد اختيار الملف ثم حاول مرة أخرى.';

  @override
  String get dpeCsvMappingIncomplete => 'مطابقة أعمدة CSV غير مكتملة.';

  @override
  String get dpeExportTooLarge => 'حجم التصدير تجاوز الحد المسموح (100MB).';

  @override
  String get dpePackageAlreadyImported =>
      'تم استيراد هذه الحزمة سابقًا بوضع مختلف.';

  @override
  String get dpeForeignPairRequired =>
      'المبلغ والعملة الأجنبية يجب أن يوجدا معًا.';

  @override
  String dpeUnsupportedTable(String value) {
    return 'جدول غير مدعوم: $value';
  }

  @override
  String get dpeOtherCategoryMissing => 'تصنيف «أخرى» غير موجود.';

  @override
  String dpeMissingValue(String value) {
    return 'قيمة $value مفقودة.';
  }

  @override
  String dpeInvalidCurrencyCode(String value) {
    return 'رمز عملة غير صالح: $value';
  }

  @override
  String dpeInvalidMinorAmount(String value) {
    return 'قيمة مالية دقيقة غير صالحة: $value';
  }

  @override
  String dpeInvalidAmount(String value) {
    return 'قيمة مالية غير صالحة: $value';
  }

  @override
  String dpeInvalidDate(String value) {
    return 'تاريخ غير صالح: $value';
  }

  @override
  String dpeExportFileMissing(String value) {
    return 'ملف $value مفقود من التصدير.';
  }

  @override
  String get dpeZipTooLarge => 'حجم ملف ZIP أكبر من 25MB.';

  @override
  String get dpePackageUnsafePath =>
      'حزمة قِرش تحتوي مسارًا أو ملفًا غير مسموح.';

  @override
  String get dpePackageInflatedTooLarge => 'حجم الحزمة بعد الفك أكبر من 100MB.';

  @override
  String dpeEntryUnreadable(String value) {
    return 'تعذر قراءة $value.';
  }

  @override
  String dpeEntrySizeMismatch(String value) {
    return 'حجم $value لا يطابق ترويسة ZIP.';
  }

  @override
  String get dpeManifestMissing => 'manifest.json مفقود.';

  @override
  String get dpeManifestInvalid => 'manifest.json غير صالح.';

  @override
  String get dpeNotAQirshExport => 'هذا ليس ملف تصدير قِرش.';

  @override
  String get dpeNewerVersion =>
      'الملف من إصدار أحدث. حدّث قِرش ثم أعد المحاولة.';

  @override
  String get dpeUnsupportedVersion => 'إصدار ملف قِرش غير مدعوم.';

  @override
  String get dpePackageMetaIncomplete => 'بيانات تعريف الحزمة ناقصة.';

  @override
  String dpePackageEntryMissing(String value) {
    return '$value مفقود من الحزمة.';
  }

  @override
  String dpeIntegrityCheckFailed(String value) {
    return 'فشل التحقق من سلامة $value.';
  }

  @override
  String get dpePackageTooManyRows => 'الحزمة تتجاوز 100,000 صف إجمالي.';

  @override
  String get repoErrNetwork =>
      'تعذّر الاتصال بالخادم — تحقّق من الإنترنت وحاول مجددًا.';

  @override
  String get repoErrAuth => 'الرجاء تسجيل الدخول للمتابعة.';

  @override
  String repoErrValidation(String detail) {
    return 'بيانات غير صالحة: $detail';
  }

  @override
  String get repoErrForbidden => 'لا تملك صلاحية تنفيذ هذه العملية.';

  @override
  String get repoErrDuplicate => 'هذا العنصر موجود بالفعل.';

  @override
  String get repoErrNotFound => 'العنصر غير موجود أو تم حذفه.';

  @override
  String get repoErrServer => 'حدث خطأ في الخادم — حاول لاحقًا.';

  @override
  String get repoErrUnknown => 'حدث خطأ غير متوقع — حاول مجددًا.';

  @override
  String get cardThemeNavy => 'كحلي';

  @override
  String get cardThemeEmerald => 'زمرّدي';

  @override
  String get cardThemePlum => 'برقوقي';

  @override
  String get cardThemeSunset => 'غروب';

  @override
  String get cardThemeGraphite => 'جرافيت';

  @override
  String get cardThemeOcean => 'محيط';

  @override
  String get authGoogleUnavailable =>
      'تسجيل الدخول بجوجل غير متاح في هذه النسخة. استخدم طريقة أخرى.';

  @override
  String get authGoogleCancelled => 'تم إلغاء تسجيل الدخول بجوجل.';

  @override
  String get authGoogleTokenUnreadable => 'لم نستطع قراءة رمز دخول جوجل.';

  @override
  String get authAppleCancelled => 'تم إلغاء تسجيل الدخول بـ Apple.';

  @override
  String get authAppleFailed => 'تعذّر تسجيل الدخول بـ Apple.';

  @override
  String get authAppleTokenUnreadable => 'لم نستطع قراءة رمز دخول Apple.';

  @override
  String get navHome => 'الرئيسية';

  @override
  String get navTransactions => 'العمليات';

  @override
  String get navBudgets => 'الميزانيات';

  @override
  String get navMore => 'المزيد';

  @override
  String get navAnalytics => 'التحليلات';

  @override
  String navExpandBar(String tab) {
    return 'فتح شريط التنقل — $tab';
  }

  @override
  String get bkeNoLocalBackup => 'لا توجد نسخة احتياطية على هذا الجهاز.';

  @override
  String get bkeNeedsReenable => 'النسخ الاحتياطي يحتاج تفعيلًا جديدًا.';

  @override
  String get bkeSignInRequired => 'سجّل الدخول أولًا لتفعيل النسخ الاحتياطي.';

  @override
  String get bkeStateSaveFailed =>
      'تعذّر حفظ حالة النسخ الاحتياطي. أعد المحاولة.';

  @override
  String get bkeBucketMissing =>
      'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups في Supabase ثم أعد المحاولة.';

  @override
  String bkeUploadFailed(String value) {
    return 'فشل رفع النسخة الاحتياطية: $value';
  }

  @override
  String get bkeWrongPassphrase => 'كلمة مرور النسخة الاحتياطية غير صحيحة.';

  @override
  String get bkeInvalidBackupFile => 'ملف النسخة الاحتياطية غير صالح.';

  @override
  String get bkeDecryptFailed =>
      'تعذّر فك النسخة الاحتياطية: كلمة المرور غير صحيحة أو الملف تالف.';

  @override
  String get bkeUnsupportedEnvelopeVersion =>
      'هذه النسخة الاحتياطية من إصدار غير مدعوم. حدّث التطبيق ثم أعد المحاولة.';

  @override
  String get bkeBackupFromNewerApp =>
      'هذه النسخة الاحتياطية من إصدار أحدث من التطبيق. حدّث التطبيق ثم أعد المحاولة.';

  @override
  String bkeUnsupportedBackupVersion(String value) {
    return 'هذه النسخة الاحتياطية من إصدار غير مدعوم ($value). حدّث التطبيق.';
  }

  @override
  String get bkeBackupCorrupt =>
      'النسخة الاحتياطية تالفة أو غير مكتملة. تعذّرت الاستعادة.';

  @override
  String bkeTableCorrupt(String value) {
    return 'النسخة الاحتياطية تالفة عند الجدول «$value». تعذّرت الاستعادة.';
  }

  @override
  String bkeRequiredTableMissing(String value) {
    return 'النسخة الاحتياطية غير مكتملة — الجدول «$value» مفقود. تعذّرت الاستعادة.';
  }

  @override
  String bkeUnsupportedTable(String value) {
    return 'النسخة الاحتياطية تحتوي على جدول غير مدعوم «$value». تعذّرت الاستعادة.';
  }

  @override
  String bkeUnexpectedSensitiveField(String value) {
    return 'النسخة الاحتياطية تحتوي على حقل حسّاس غير متوقع «$value». تعذّرت الاستعادة.';
  }

  @override
  String bkeInvalidMoneyValue(String value) {
    return 'تعذّرت الاستعادة: قيمة نقدية غير صالحة «$value».';
  }

  @override
  String get bkeAccountChanged =>
      'تغيّر الحساب أثناء تجهيز الاستعادة. أعد المحاولة.';

  @override
  String get bkeRelationalIntegrity =>
      'تعذّرت الاستعادة: النسخة الاحتياطية تنتهك سلامة العلاقات بين البيانات.';

  @override
  String get bkePlanningInconsistent =>
      'تعذّرت الاستعادة: بيانات التخطيط غير متسقة بعد الاستعادة.';

  @override
  String get bkeForeignKeys => 'تعذّر إعادة تفعيل قيود العلاقات بعد الاستعادة.';

  @override
  String bkeOrphanGoalContribution(String value) {
    return 'تعذّرت الاستعادة: مساهمة هدف يتيمة «$value».';
  }

  @override
  String get bkePrepareFailed =>
      'تعذّر تجهيز الاستعادة. تحقّق من الملف وكلمة المرور.';

  @override
  String get bkeRestoreFailedNoChanges =>
      'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.';

  @override
  String get bkeCommittedPendingBackupState =>
      'اكتملت استعادة البيانات، لكن تعذّر إكمال حماية النسخة الاحتياطية. أعد المحاولة.';

  @override
  String get bkeRestoredDbNotReady =>
      'اكتملت الاستعادة لكن تعذّر تجهيز قاعدة البيانات. أعد تشغيل التطبيق.';

  @override
  String get bkeNeedsDatabaseRepair =>
      'تعذّرت الاستعادة وتحتاج قاعدة البيانات إلى إصلاح.';

  @override
  String get startPreparing => 'جارٍ تجهيز التطبيق...';

  @override
  String get startTookLonger => 'استغرق التجهيز وقتًا أطول من المتوقع';

  @override
  String get startFailed => 'تعذّر تجهيز التطبيق';

  @override
  String get startCheckConnection => 'تأكد من اتصالك بالإنترنت وحاول مرة أخرى.';

  @override
  String startStepId(String step) {
    return 'معرّف: $step';
  }

  @override
  String get startRetry => 'إعادة المحاولة';

  @override
  String get dbRecoveryTitle => 'تعذّر فتح بياناتك';

  @override
  String get dbRecoveryBody =>
      'ملف البيانات تالف أو مشفّر بمفتاح غير متطابق ولا يمكن فتحه. يمكنك إعادة تعيين بيانات التطبيق للبدء من جديد (ستُحذف العمليات المحفوظة محليًا فقط).';

  @override
  String get dbRecoveryReset => 'إعادة تعيين البيانات';

  @override
  String get lockTitle => 'قِرش مقفل';

  @override
  String get lockBody => 'افتح التطبيق للتحقق من هويتك وعرض بياناتك المالية.';

  @override
  String get lockVerifying => 'جارٍ التحقق...';

  @override
  String get lockUnlock => 'فتح قِرش';

  @override
  String get lockPrompt => 'افتح قِرش لحماية بياناتك المالية.';

  @override
  String get bdConfirmTitle => 'تأكيد البنك';

  @override
  String bdIsSenderFrom(String bank) {
    return 'هل هذا المرسل من $bank؟';
  }

  @override
  String get bdSender => 'المرسل';

  @override
  String get bdCountry => 'الدولة';

  @override
  String get bdConfidence => 'الثقة';

  @override
  String get bdKey => 'المفتاح';

  @override
  String bdReason(String reason) {
    return 'السبب: $reason';
  }

  @override
  String bdReasonDefault(String bank) {
    return 'السبب: $bank يطابق هذا المرسل ونمط الرسائل بدرجة عالية.';
  }

  @override
  String get bdConfirmThis => 'تأكيد هذا البنك';

  @override
  String get bdNotThis => 'ليس هذا البنك';

  @override
  String get bdAskLater => 'اسألني لاحقًا';

  @override
  String get smsShareTitle => 'شارك رسالة البنك مع قِرش';

  @override
  String get smsShareBody =>
      'بدون إذن قراءة الرسائل: افتح رسالة البنك، اضغط «مشاركة»، واختر قِرش. عند إيقاف التحليل الذكي نحلّل النص على جهازك فقط.';

  @override
  String get smsShareExample => 'مثال: «شراء 45 ريالًا لدى BURGER BOUTIQUE»';

  @override
  String get smsShareFallback =>
      'إن لم يظهر زر المشاركة في تطبيق الرسائل، استخدم اللصق اليدوي كبديل سريع.';

  @override
  String get smsPasteManually => 'لصق رسالة يدويًا';

  @override
  String get smsPasteLater => 'لاحقًا، ألصق يدويًا';

  @override
  String get rngPickAccount => 'اختر الحساب';

  @override
  String get rngPickPeriod => 'اختر فترة العرض';

  @override
  String get rngFrom => 'من';

  @override
  String get rngTo => 'إلى';

  @override
  String get rngApplyCustom => 'تطبيق الفترة المخصصة';

  @override
  String get ccTitle => 'غيّر التصنيف';

  @override
  String get ccScope => 'نطاق التعديل';

  @override
  String get ccThisOnly => 'هذه العملية فقط';

  @override
  String get ccAllMerchant => 'كل عمليات هذا المتجر';

  @override
  String get ccSave => 'حفظ التعديل';

  @override
  String get commonClose => 'إغلاق';

  @override
  String get commonHide => 'إخفاء';

  @override
  String get commonSkip => 'تخطّى';

  @override
  String get commonDefault => 'افتراضي';

  @override
  String get commonReview => 'مراجعة';

  @override
  String get commonSmart => 'ذكاء';

  @override
  String get commonPending => 'معلّقة';

  @override
  String get commonTransaction => 'عملية';

  @override
  String get commonUnderReview => 'قيد المراجعة';

  @override
  String get chartCategories => 'التصنيفات';

  @override
  String get chartCategoriesEmpty =>
      'أضف عمليات مؤكدة ليظهر توزيع التصنيفات هنا.';

  @override
  String get chartRefund => 'مرتجع';

  @override
  String get chartTotal => 'إجمالي';

  @override
  String get prgTitle => 'التخطيط غير متاح مؤقتًا';

  @override
  String get prgBody =>
      'قبل استخدام الميزانيات والأهداف، نحتاج تأكيد العملة التي تُعامَل بها بيانات التخطيط الحالية. لن نغيّر أي مبلغ.';

  @override
  String get prgConfirmNow => 'تأكيد العملة الآن';

  @override
  String get prgNotNow => 'ليس الآن';

  @override
  String get fuTitle => 'تحديث مطلوب';

  @override
  String get fuBody => 'يرجى تحديث التطبيق للاستمرار في الاستخدام.';

  @override
  String get fuNow => 'تحديث الآن';

  @override
  String get rpConfirmTitle => 'تأكيد الاستعادة';

  @override
  String get rpConfirmBody =>
      'ستحل النسخة الاحتياطية محل بياناتك الحالية على هذا الجهاز. لا يمكن التراجع بعد التأكيد. هل تريد المتابعة؟';

  @override
  String get rpCancel => 'إلغاء';

  @override
  String get rpRestore => 'استعادة';

  @override
  String get rpPrivacyNote =>
      'الاستعادة تحتاج كلمة المرور أو رمز الاسترداد فقط. قِرش لا يقرأ محتوى النسخة بدونهما.';

  @override
  String get adNoticeTitle => 'إعلان قبل إنشاء التقرير';

  @override
  String get adNoticeBody => 'قد يظهر إعلان قصير قبل إنشاء التقرير.';

  @override
  String get adNoticeCancel => 'إلغاء';

  @override
  String get adNoticeContinue => 'متابعة';

  @override
  String get plansFrom => 'من';

  @override
  String get plansOverBudget => 'تجاوزت الميزانية بـ';

  @override
  String get plansRemaining => 'باقٍ';

  @override
  String get pcrConfirmAll => 'تأكيد أن كل الميزانيات والأهداف الحالية تستخدم';

  @override
  String get cardNetworkMada => 'مدى';

  @override
  String get budgetsAllAccounts => 'كل الحسابات';

  @override
  String txnCountSuffix(String count) {
    return '· $count عملية';
  }

  @override
  String get a11yDebit => 'خصم';

  @override
  String get a11yCredit => 'إيداع';

  @override
  String get a11yPending => 'معلق';

  @override
  String get a11yAi => 'ذكاء اصطناعي';

  @override
  String chartSliceCount(String count) {
    return '$count عملية';
  }

  @override
  String planSpent(String amount) {
    return 'المصروف: $amount';
  }

  @override
  String planEnds(String date) {
    return 'تنتهي: $date';
  }

  @override
  String planPerDayLeft(String amount) {
    return 'متاح $amount في اليوم لباقي الخطة';
  }

  @override
  String get iiUnreadableDate => 'تعذّر قراءة التاريخ.';

  @override
  String get iiCurrencyNotIso => 'العملة يجب أن تكون رمز ISO من ثلاثة أحرف.';

  @override
  String get iiAmountInvalidOrZero => 'المبلغ غير صالح أو يساوي صفرًا.';

  @override
  String get iiCsvNeedsTwoColumns =>
      'ملف CSV يحتاج عمودين على الأقل: التاريخ والمبلغ.';

  @override
  String get iiHeadersNotRecognised =>
      'لم نتعرّف على العناوين تلقائيًا. راجع مطابقة الأعمدة.';

  @override
  String iiDuplicatesFound(String value) {
    return '$value عملية مشابهة موجودة وستُعرض قبل الحفظ.';
  }

  @override
  String iiRowPrefix(String row) {
    return 'صف $row: ';
  }

  @override
  String conflictBudgetLabel(String amount) {
    return 'ميزانية $amount';
  }

  @override
  String get cardSourceAuto => 'اتُعرِّفت من رسائل البنك';

  @override
  String get cardSourceManual => 'أضفتها بنفسك';

  @override
  String get smartConsentTitle => 'التحليل الذكي والمزامنة السحابية';

  @override
  String get smartConsentBullet1 =>
      'تُرسل الرسائل البنكية الملتقطة، ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد، إلى خوادم قرش بعد إزالة أرقام البطاقات والحسابات والهواتف والرموز. قد تعالج خدمة Google Gemini هذا النص لتحديد المبلغ والتاجر والبنك، وقد تتلقى Google Places أسماء التجار. تبقى فيه المبالغ والتجار والأرصدة، لذا فهو ليس مجهول الهوية.';

  @override
  String get smartConsentBullet2 =>
      'كما تتم مزامنة معاملاتك وحساباتك وميزانياتك وأهدافك وإعداداتك ونسخها احتياطيًا في حسابك السحابي على قِرش.';

  @override
  String get smartConsentBullet3 =>
      'بعد الموافقة، تعمل المزامنة والتحليلات المسموح بها تلقائيًا عند توفر الخدمة. يمكنك سحب أي موافقة من الإعدادات ← الخصوصية. المتابعة محليًا لا ترسل هذه البيانات.';

  @override
  String get smartConsentEnable => 'تفعيل التحليل الذكي والمزامنة السحابية';

  @override
  String get smartConsentNotNow => 'ليس الآن';

  @override
  String get smartConsentPrivacyLink => 'إعدادات الخصوصية';

  @override
  String get smartConsentStatusConnecting => 'جارٍ الاتصال…';

  @override
  String get smartConsentStatusConnected => 'التحليل الذكي متصل';

  @override
  String get smartConsentStatusFailed =>
      'التحليل الذكي غير متصل، لذا تُقرأ رسائل البنك على هذا الجهاز فقط حتى يتم الاتصال.';

  @override
  String get smartConsentRetry => 'إعادة المحاولة';

  @override
  String get txnAwaitingPrice => 'بانتظار السعر';

  @override
  String get onbCloudTitle => 'المزامنة السحابية';

  @override
  String get onbCloudBullet1 =>
      'تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش لقراءتها بعد حذف أرقام البطاقات والحسابات والهواتف والرموز، وتتم مزامنة معاملاتك وحساباتك وميزانياتك وأهدافك وإعداداتك ونسخها احتياطيًا في حسابك السحابي على قِرش.';

  @override
  String get onbCloudBullet2 =>
      'بدونها تبقى بياناتك على هذا الهاتف فقط ولا يُحتفظ لها بنسخة احتياطية.';

  @override
  String get onbCloudBullet3 =>
      'يمكنك إيقافها في أي وقت من الإعدادات ← الخصوصية.';

  @override
  String get onbCloudEnable => 'تفعيل المزامنة السحابية';

  @override
  String get onbAiTitle => 'التحليل الذكي';

  @override
  String get onbAiBullet1 =>
      'عند تشغيل التحليل الذكي، قد تُحلَّل رسائل البنك الملتقطة — بعد حذف أرقام البطاقات والحسابات والهواتف والرموز — بواسطة مزوّد ذكاء اصطناعي لقراءة المبلغ والتاجر والبنك.';

  @override
  String get onbAiBullet2 => 'يمكنك إيقافه في أي وقت من الإعدادات ← الخصوصية.';

  @override
  String get onbAiEnable => 'تفعيل التحليل الذكي';

  @override
  String get onbAiNeedsCloud =>
      'يحتاج التحليل الذكي إلى المزامنة السحابية، وهي متوقفة الآن. يمكنك تفعيل الاثنين معًا:';

  @override
  String get onbAiEnableBoth => 'تفعيل المزامنة السحابية والتحليل الذكي';

  @override
  String get onbReadyTitle => 'حالة الاتصال';

  @override
  String get onbReadyBodyOn =>
      'يربط قِرش هذا الجهاز بالخدمات السحابية. يمكنك المتابعة بينما ينتهي الاتصال.';

  @override
  String get onbReadyBodyOff =>
      'المزامنة السحابية والتحليل الذكي متوقفان، لذا تبقى بياناتك على هذا الهاتف. يمكنك تفعيلهما في أي وقت من الإعدادات ← الخصوصية.';

  @override
  String get onbAccountTitle => 'جهّز حسابك';

  @override
  String get onbAccountBody =>
      'أضف الحساب الذي تحتفظ فيه بأموالك، مثل حساب بنكي أو نقد أو محفظة. يمكنك إضافة المزيد لاحقًا.';

  @override
  String get onbAccountExistingTitle => 'حساباتك';

  @override
  String get onbAccountExistingBody =>
      'لديك هذه الحسابات بالفعل. يمكنك المتابعة أو إضافة حساب آخر.';

  @override
  String get onbAccountAddAnother => 'إضافة حساب آخر';

  @override
  String get onbAccountContinue => 'متابعة';

  @override
  String get onbAccountRequired => 'أضف حسابًا لإنهاء الإعداد.';

  @override
  String get syncStatusAllSynced => 'تمت مزامنة كل البيانات';

  @override
  String get syncStatusSyncing => 'جارٍ المزامنة…';

  @override
  String syncStatusWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تغيير بانتظار المزامنة',
      many: '$count تغييرًا بانتظار المزامنة',
      few: '$count تغييرات بانتظار المزامنة',
      two: 'تغييران بانتظار المزامنة',
      one: 'تغيير واحد بانتظار المزامنة',
      zero: 'بانتظار المزامنة',
    );
    return '$_temp0';
  }

  @override
  String get syncStatusConsentOff =>
      'المزامنة السحابية متوقفة — بياناتك تبقى على هذا الجهاز';

  @override
  String get syncStatusSignedOut =>
      'لم تسجّل الدخول — بياناتك تبقى على هذا الجهاز';

  @override
  String get syncStatusFailed => 'فشلت المزامنة — إعادة المحاولة';

  @override
  String get syncStatusNeedsAttention => 'تحتاج إلى انتباهك';

  @override
  String get syncSheetTitle => 'حالة المزامنة';

  @override
  String syncSheetKeptOnDevice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count تغيير محفوظ على هذا الجهاز',
      many: '$count تغييرًا محفوظًا على هذا الجهاز',
      few: '$count تغييرات محفوظة على هذا الجهاز',
      two: 'تغييران محفوظان على هذا الجهاز',
      one: 'تغيير واحد محفوظ على هذا الجهاز',
      zero: 'لا توجد تغييرات معلّقة',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetWaitingConnection => 'بانتظار الاتصال';

  @override
  String get syncSheetWaitingServer => 'بانتظار تحديث الخادم';

  @override
  String get syncSheetNeedsAttention => 'تحتاج إلى انتباه';

  @override
  String syncSheetStayFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عنصر لا يمكن إعادة محاولتها وتبقى فاشلة',
      many: '$count عنصرًا لا يمكن إعادة محاولتها وتبقى فاشلة',
      few: '$count عناصر لا يمكن إعادة محاولتها وتبقى فاشلة',
      two: 'عنصران لا يمكن إعادة محاولتهما ويبقيان فاشلين',
      one: 'عنصر واحد لا يمكن إعادة محاولته ويبقى فاشلًا',
    );
    return '$_temp0';
  }

  @override
  String syncSheetLastSync(String time) {
    return 'آخر مزامنة ناجحة: $time';
  }

  @override
  String get syncSheetNeverSynced => 'لا توجد مزامنة ناجحة بعد';

  @override
  String get syncSheetRetry => 'إعادة المحاولة';

  @override
  String get signOutKeepData => 'تسجيل الخروج مع الاحتفاظ بالبيانات المشفّرة';

  @override
  String get signOutKeepDataHint =>
      'تبقى بياناتك مشفّرة على هذا الجهاز. سجّل الدخول مجددًا لفتحها.';

  @override
  String get signOutRemoveData => 'تسجيل الخروج وحذف البيانات من هذا الجهاز';

  @override
  String get signOutRemoveDataHint =>
      'يحذف بيانات هذا الحساب من هذا الجهاز فقط. لا تتأثر البيانات المحفوظة بالفعل في السحابة.';

  @override
  String signOutUnsyncedKeepBody(String list) {
    return 'بعض البيانات لم تصل إلى السحابة بعد: $list. تبقى على هذا الجهاز وتُزامَن عند تسجيل دخولك مجددًا.';
  }

  @override
  String get removeDataTitle => 'حذف البيانات من هذا الجهاز؟';

  @override
  String get removeDataBody =>
      'سيُحذف نهائيًا كل ما يخص هذا الحساب على هذا الجهاز. يمكنك تنزيل البيانات المحفوظة في السحابة مجددًا بتسجيل الدخول.';

  @override
  String removeDataUnsyncedBody(String list) {
    return 'هذه البيانات لم تصل إلى السحابة وستُفقد: $list.';
  }

  @override
  String get removeDataAction => 'حذف البيانات';

  @override
  String get captureUnboundTitle => 'رسائل وصلت أثناء تسجيل الخروج';

  @override
  String captureUnboundBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'وصلت $count رسالة بنكية',
      few: 'وصلت $count رسائل بنكية',
      two: 'وصلت رسالتان بنكيتان',
      one: 'وصلت رسالة بنكية واحدة',
    );
    return '$_temp0 أثناء تسجيل خروجك.';
  }

  @override
  String captureUnboundSenders(String senders) {
    return 'من: $senders';
  }

  @override
  String get captureUnboundAdd => 'أضفها إلى حسابي';

  @override
  String get captureUnboundDiscard => 'تجاهلها';

  @override
  String get conflictKeepMine => 'الإبقاء على نسختي';

  @override
  String get conflictKeepMineAsNew => 'الإبقاء على نسختي كنسخة جديدة';

  @override
  String get conflictKeepCloud => 'الإبقاء على نسخة السحابة';

  @override
  String get conflictKeptCloud => 'تم الإبقاء على نسخة السحابة.';

  @override
  String get conflictThisDevice => 'هذا الجهاز';

  @override
  String get conflictCloud => 'السحابة';

  @override
  String get conflictDeletedInCloud => 'محذوف في السحابة';

  @override
  String get conflictDeletedHere => 'محذوف على هذا الجهاز';

  @override
  String get conflictNotSet => 'غير محدد';

  @override
  String get conflictFieldAmount => 'المبلغ';

  @override
  String get conflictFieldCurrency => 'العملة';

  @override
  String get conflictFieldMerchant => 'التاجر';

  @override
  String get conflictFieldNote => 'ملاحظة';

  @override
  String get conflictFieldDate => 'التاريخ';

  @override
  String get conflictFieldStatus => 'الحالة';

  @override
  String get conflictFieldCategory => 'الفئة';

  @override
  String get conflictFieldName => 'الاسم';

  @override
  String get conflictFieldType => 'النوع';

  @override
  String get conflictFieldBalance => 'الرصيد';

  @override
  String get conflictFieldInitialBalance => 'الرصيد الابتدائي';

  @override
  String get conflictFieldCreditLimit => 'الحد الائتماني';

  @override
  String get conflictFieldPeriod => 'الفترة';

  @override
  String get conflictFieldStartDate => 'تاريخ البداية';

  @override
  String get conflictFieldEndDate => 'تاريخ النهاية';

  @override
  String get conflictFieldFrequency => 'التكرار';

  @override
  String get conflictFieldNextDue => 'تاريخ الاستحقاق القادم';

  @override
  String get conflictFieldTargetAmount => 'المبلغ المستهدف';

  @override
  String get conflictFieldDeadline => 'الموعد النهائي';

  @override
  String get conflictFieldNickname => 'اسم البطاقة';

  @override
  String get conflictFieldLast4 => 'آخر 4 أرقام';

  @override
  String get conflictFieldActive => 'نشط';

  @override
  String get startupCoordinatorTitle => 'تعذّر بدء التطبيق بأمان';

  @override
  String get startupCoordinatorBody =>
      'لم يتمكن قِرش من التأكد أن أي جزء آخر من التطبيق لا يستخدم بياناتك، فلم يفتح شيئًا. لم تتغير بياناتك. حاول مرة أخرى، وإن تكررت المشكلة فأعد تشغيل التطبيق.';

  @override
  String get startupCoordinatorRetry => 'حاول مرة أخرى';

  @override
  String get sessionRecoveryTitle => 'تعذّر إكمال فتح قرش';

  @override
  String get sessionRecoveryBody =>
      'تأكد من اتصالك وأعد المحاولة، أو سجّل الدخول من جديد للمتابعة. بياناتك المحفوظة باقية على هذا الجهاز.';

  @override
  String get sessionRecoverySignIn => 'تسجيل الدخول من جديد';

  @override
  String get localReadBannerTitle => 'بدون اتصال — للعرض فقط';

  @override
  String get localReadBannerBody =>
      'بياناتك على هذا الجهاز معروضة للاطّلاع فقط. سجّل الدخول من جديد لإضافة العمليات أو تعديلها أو مزامنتها.';

  @override
  String get localReadReconnect => 'إعادة الاتصال';

  @override
  String get localReadLogout => 'تسجيل الخروج';

  @override
  String get localReadBalancesTitle => 'الأرصدة';

  @override
  String get localReadTransactionsTitle => 'العمليات';

  @override
  String get localReadNoTransactions => 'لا توجد عمليات على هذا الجهاز.';

  @override
  String get localReadNoAccounts => 'لا توجد حسابات على هذا الجهاز.';

  @override
  String get localReadLoadError => 'تعذّرت قراءة بياناتك على هذا الجهاز.';

  @override
  String get localReadLogoutFailed => 'لم يكتمل تسجيل الخروج. حاول مرة أخرى.';

  @override
  String get signOutCleanupIncompleteMessage =>
      'تم تسجيل خروجك على هذا الجهاز، لكن تعذّر إكمال قفل بياناتك دون اتصال، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.';

  @override
  String get signOutCleanupRetry => 'إعادة المحاولة';

  @override
  String get signOutCleanupStillIncomplete =>
      'ما زال تعذّر قفل بياناتك دون اتصال، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.';

  @override
  String get removeDataDenyIncompleteMessage =>
      'تعذّر إكمال إلغاء الوصول دون اتصال إلى البيانات على هذا الجهاز، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.';

  @override
  String get removeDataDenyStillIncomplete =>
      'ما زال تعذّر إلغاء الوصول دون اتصال، وقد يُتاح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.';

  @override
  String get cloudEnableIncomplete =>
      'تعذّر تشغيل المعالجة السحابية. ستبقى متوقفة. حاول مرة أخرى.';

  @override
  String get cloudEnableWithdrawFirst =>
      'لا يمكننا التأكد من الحالة الحالية، لذلك لم يتغيّر شيء. أوقفها أولًا ثم فعّلها من جديد.';

  @override
  String get cloudEnableChoiceNotSaved =>
      'اكتملت المعالجة السحابية باختيارك السابق، ولم يُحفظ اختيارك الجديد. راجِع الخيارات واختر من جديد لإضافته.';

  @override
  String get initialConsentAccept => 'أوافق على المزامنة والتحليل الذكي';

  @override
  String get initialConsentDecline => 'المتابعة محليًا';

  @override
  String get consentMgmtTitle => 'المزامنة السحابية والتحليل الذكي';

  @override
  String get consentStatusActive => 'مفعّلة';

  @override
  String get consentStatusPartial => 'مفعّلة جزئيًا';

  @override
  String get consentStatusOff => 'متوقفة';

  @override
  String get consentStatusUnknown => 'تعذّر التأكد';

  @override
  String get consentStatusTurningOn => 'جارٍ التفعيل…';

  @override
  String get consentStatusTurningOff => 'جارٍ الإيقاف…';

  @override
  String get consentStatusActiveBody =>
      'المزامنة السحابية والتحليل الذكي مفعّلان معًا.';

  @override
  String get consentStatusPartialBody =>
      'جزء فقط من هذه الموافقة مفعّل. فعّلها لمراجعتها واتخاذ قرارك من جديد، أو أوقفها.';

  @override
  String get consentStatusOffBody =>
      'لا يُرسل أي شيء إلى خوادم قرش ولا يحلله الذكاء الاصطناعي. تبقى بياناتك على هذا الجهاز، ويظل الإدخال اليدوي متاحًا.';

  @override
  String get consentStatusUnknownBody =>
      'لا يمكننا التأكد من الحالة الحالية الآن، لذا تبقى المزامنة والتحليل متوقفين إلى أن يتم التأكد.';

  @override
  String get consentStatusUnknownRecovery =>
      'لاستعادتها، أوقفها أولًا ثم فعّلها من جديد.';

  @override
  String get consentStatusTurningOnBody =>
      'لم نتمكن من التأكد من اكتمال التفعيل. تبقى المزامنة والتحليل متوقفين إلى أن يكتمل.';

  @override
  String get consentStatusTurningOffBody =>
      'تم إيقاف المزامنة والتحليل بالفعل. نُنهي الإجراء الآن.';

  @override
  String get consentTurnOn => 'مراجعة وتفعيل';

  @override
  String get consentTurnOff => 'إيقاف';

  @override
  String get consentRefresh => 'تحقّق مجددًا';

  @override
  String get consentWithdrawTitle => 'إيقاف المزامنة السحابية والتحليل الذكي؟';

  @override
  String get consentWithdrawBody =>
      'تتوقف المزامنة والتحليل فورًا معًا. تبقى بياناتك على هذا الجهاز، ويمكنك تفعيلهما مجددًا من هنا في أي وقت.';

  @override
  String get consentWithdrawConfirm => 'إيقاف';

  @override
  String get consentWithdrawFailed =>
      'لم نتمكن من التأكد من إيقاف هذه الميزة. يبقى الإرسال متوقفًا. حاول مجددًا.';

  @override
  String get signOutDataStays =>
      'تبقى بياناتك على هذا الجهاز وتعود إليك عند تسجيل الدخول مجددًا.';

  @override
  String get deleteAccountTitle => 'حذف الحساب';

  @override
  String get deleteAccountIntro =>
      'احذف حساب قرش والبيانات المحفوظة فيه نهائيًا وعلى الفور. ستؤكد هويتك أولًا عبر Apple أو طريقة الدخول التي تستخدمها.';

  @override
  String get deleteAccountAction => 'حذف الحساب';

  @override
  String get deleteAccountConfirmTitle => 'حذف حسابك؟';

  @override
  String get deleteAccountConfirmBody =>
      'سيُحذف حسابك وبياناته نهائيًا وعلى الفور. أكّد هويتك عبر Apple أو طريقة الدخول التي تستخدمها للمتابعة. لا يمكن التراجع عن الحذف.';

  @override
  String get deleteAccountConfirmAction => 'حذف نهائي';

  @override
  String get deleteAccountProgress => 'جارٍ حذف حسابك…';

  @override
  String get deleteAccountSuccess => 'تم حذف حسابك.';

  @override
  String get deleteAccountAcceptedBody =>
      'استلمنا طلب الحذف، لكن حسابك لم يُحذف بعد. يمكنك متابعته أو إلغاؤه من الخصوصية والبيانات.';

  @override
  String get deleteAccountFailed => 'تعذّر إكمال حذف حسابك. حاول مجددًا.';

  @override
  String get deleteAccountFailedFinal =>
      'لا يمكننا حذف حسابك من هنا الآن. حاول لاحقًا أو تواصل مع الدعم.';

  @override
  String get deleteAccountUnconfirmed => 'لم نتمكن من التأكد من حذف حسابك بعد.';

  @override
  String get deleteAccountRetry => 'حاول مجددًا';

  @override
  String get deleteAccountRejected =>
      'فشل التأكيد أو انتهت صلاحيته. حاول مجددًا.';

  @override
  String get deleteAccountDone => 'تم';

  @override
  String get deleteAccountConfirmBodyScheduled =>
      'سيُرسل طلب الحذف، ثم يحذف الخادم حسابك وكل بياناتك نهائيًا لاحقًا، ولا يمكن التراجع عن ذلك.';

  @override
  String get deleteAccountPendingBody =>
      'حذف حسابك قيد التنفيذ، وحسابك لم يُحذف بعد. تحقق مرة أخرى بعد قليل.';

  @override
  String get deleteAccountCheckStatus => 'تحقق من الحالة';

  @override
  String get deleteAccountUnconfirmedStale =>
      'تغيّرت جلسة الدخول قبل أن نتأكد من النتيجة. افتح هذه الشاشة مجددًا للتحقق.';

  @override
  String get deleteAccountAdminBlocked =>
      'هذا حساب مشرف ولا يمكن حذفه قبل إزالة صلاحيات الإشراف عنه. تواصل مع الفريق لإزالتها أولًا.';

  @override
  String get deleteAccountRateLimited =>
      'محاولات كثيرة. انتظر بضع دقائق ثم حاول مجددًا.';

  @override
  String get deleteAccountLocalCleanupPending =>
      'تم حذف حسابك من خوادمنا، لكن تعذّر إنهاء مسح البيانات على هذا الجهاز. أغلق التطبيق وافتحه مجددًا.';

  @override
  String get pasteAnalysisHowItWorks =>
      'لما السحابة والتحليل الذكي يكونوا مفعّلين، الذكاء الاصطناعي بيقرأ الرسائل. عند إيقافهم، قرش بيحلل على الجهاز.';

  @override
  String get pasteReadOnDevice =>
      'قُرئت على جهازك — لم نحتج إلى الذكاء الاصطناعي.';

  @override
  String get pasteReadWithAi => 'قُرئت باستخدام الذكاء الاصطناعي.';

  @override
  String get pasteAiOff =>
      'قُرئت على جهازك — الذكاء الاصطناعي متوقف. فعّل السحابة وتحليل الذكاء الاصطناعي من الإعدادات.';

  @override
  String get pasteAiUnavailable =>
      'قُرئت على جهازك — الذكاء الاصطناعي غير متاح في هذه النسخة.';

  @override
  String get pasteAiMismatch =>
      'قُرئت على جهازك — إجابة الذكاء الاصطناعي لم تطابق الرسالة فلم تُستخدم.';

  @override
  String pasteAiFailed(String code) {
    return 'قُرئت على جهازك — تعذّر الوصول إلى الذكاء الاصطناعي ($code).';
  }

  @override
  String get pasteAiConsentOff =>
      'تعذّرت قراءة هذه الرسالة على جهازك. فعّل السحابة والتحليل الذكي من الخصوصية للسماح بمساعدة الذكاء الاصطناعي.';

  @override
  String get homeGoodMorning => 'صباح الخير';

  @override
  String get homeGoodEvening => 'مساء الخير';

  @override
  String get homeQuickAdd => 'إضافة';

  @override
  String get homeQuickPaste => 'لصق رسالة';

  @override
  String get homeQuickBudget => 'ميزانية';

  @override
  String get homeQuickGoals => 'أهداف';

  @override
  String homeBudgetLeft(String limit, String left) {
    return 'من ميزانية $limit · متبقي $left';
  }

  @override
  String homeBudgetOverBy(String limit, String over) {
    return 'تجاوزت ميزانية $limit بـ $over';
  }

  @override
  String homeProjectedMonthEnd(String amount) {
    return 'المتوقع نهاية الشهر $amount';
  }

  @override
  String homeLastWeekWas(String amount) {
    return 'الأسبوع الماضي $amount';
  }

  @override
  String homeTodayTxCount(int count) {
    return 'عمليات اليوم: $count';
  }

  @override
  String homeLeftTodayShort(String amount) {
    return 'متاح لليوم $amount';
  }

  @override
  String homePaceUnder(int percent) {
    return 'أقل من وتيرة الميزانية بـ $percent%';
  }

  @override
  String homePaceOver(int percent) {
    return 'أعلى من وتيرة الميزانية بـ $percent%';
  }

  @override
  String get homePaceOnTrack => 'على وتيرة الميزانية';

  @override
  String get homePaceSetBudget => 'حدّد ميزانية لتتابع الوتيرة';

  @override
  String homeWeekMoreThan(int percent) {
    return 'أعلى من الأسبوع الماضي بـ $percent%';
  }

  @override
  String homeWeekLessThan(int percent) {
    return 'أقل من الأسبوع الماضي بـ $percent%';
  }

  @override
  String homeDayMoreThan(int percent) {
    return 'أعلى من أمس بـ $percent%';
  }

  @override
  String homeDayLessThan(int percent) {
    return 'أقل من أمس بـ $percent%';
  }

  @override
  String get homeToReview => 'للمراجعة';

  @override
  String get homeReviewNow => 'راجعها';

  @override
  String homeSpentOfAllowance(String spent, String allowance) {
    return 'صرفت $spent من $allowance';
  }

  @override
  String get homeLastSevenDays => 'آخر ٧ أيام';

  @override
  String homeDailyAverage(String amount) {
    return 'المتوسط $amount يوميًا';
  }

  @override
  String get homeWhereMoneyWent => 'أين ذهبت أموالك';

  @override
  String get homeDetails => 'التفاصيل';

  @override
  String get homeUpcoming => 'مدفوعات قادمة';

  @override
  String homeInstalmentProgress(int n, int total) {
    return 'الدفعة $n من $total';
  }

  @override
  String get homeGoalsAndPlans => 'أهدافي وخططي';

  @override
  String get homeNewGoal => 'هدف جديد';

  @override
  String get homeRecentTx => 'آخر العمليات';

  @override
  String get homeSeeAll => 'عرض الكل';

  @override
  String get homeWelcomeTo => 'أهلاً بك في قِرش';

  @override
  String get homeWelcomeTitle => 'أضف أول عملية،\nوقِرش يرتّب الباقي';

  @override
  String get homeWelcomeBody =>
      'صرفك اليومي، المتاح لك، وأين تذهب أموالك. كلها تظهر هنا بعد أول عملية.';

  @override
  String get homeStartSteps => 'ابدأ في ٣ خطوات';

  @override
  String get homeStartStepsHint => 'أقل من دقيقتين';

  @override
  String get homeStepAddTitle => 'أضف أول عملية';

  @override
  String get homeStepAddBody => 'ألصق رسالة البنك أو أدخلها يدويًا';

  @override
  String get homeStepAddCta => 'أضف عملية';

  @override
  String get homeStepBudgetTitle => 'حدّد ميزانية الشهر';

  @override
  String get homeStepBudgetBody => 'لتعرف كم يتاح لك كل يوم';

  @override
  String get homeStepBudgetCta => 'حدّد الميزانية';

  @override
  String get homeStepCaptureTitle => 'فعّل التقاط رسائل البنك';

  @override
  String get homeStepCaptureBody => 'لتُضاف العمليات بدون لصق';

  @override
  String get homeStepCaptureCta => 'طريقة التفعيل';

  @override
  String get homeOnDeviceTitle => 'بياناتك محفوظة على جهازك';

  @override
  String get homeOnDeviceBody => 'قاعدة بياناتك مشفّرة على هذا الجهاز.';

  @override
  String get homeCreateYourself => 'أو أنشئ بنفسك';

  @override
  String get homeTileBudgetSub => 'شهرية أو لتصنيف';

  @override
  String get homeTileGoal => 'هدف ادخار';

  @override
  String get homeTileGoalSub => 'سفر، سيارة، طوارئ';

  @override
  String get homeTileBill => 'اشتراك أو قسط';

  @override
  String get homeTileBillSub => 'ونذكّرك قبل الخصم';

  @override
  String get homeTilePlan => 'خطة';

  @override
  String get homeTilePlanSub => 'للسفر أو المناسبات';

  @override
  String get homePrivacyToggle => 'إظهار المبالغ أو إخفاؤها';

  @override
  String get accTotalBalance => 'إجمالي الأرصدة';

  @override
  String get achBadges => 'الشارات';

  @override
  String achEarnedCount(int earned, int total) {
    return '$earned من $total مكتملة';
  }

  @override
  String achNextLevelXp(int remaining) {
    return 'باقي $remaining للمستوى التالي';
  }

  @override
  String get gdSavedLabel => 'ادّخرت';

  @override
  String get homeSavingsGrowing => 'نمو مدخراتك';

  @override
  String homeSavingsSurplus(String amount) {
    return 'دخلك سبق صرفك بـ $amount هذا الشهر';
  }

  @override
  String get homeSavingsMotivation => 'حوّل جزء منه لأهدافك وخلّيه يكبر.';

  @override
  String get homeAddToGoal => 'أضف لهدف';

  @override
  String get rptPhotoKicker => 'صورة أوضح لأموالك';

  @override
  String get rptPhotoTitle => 'تفاصيل صرفك في مكان واحد';

  @override
  String homeSpendingAhead(String amount) {
    return 'صرفك سبق دخلك بـ $amount هذا الشهر';
  }

  @override
  String get goalCoverLabel => 'صورة الهدف';

  @override
  String get goalCoverTravel => 'سفر';

  @override
  String get goalCoverCar => 'عربية';

  @override
  String get goalCoverHome => 'بيت';

  @override
  String get goalCoverEducation => 'تعليم';

  @override
  String get goalCoverGadgets => 'أجهزة';

  @override
  String get goalCoverEmergency => 'طوارئ';

  @override
  String get bdgOverviewSubtitle => 'حدودك وأهدافك في مكان واحد';

  @override
  String get rptExpenseCountLabel => 'عمليات الصرف';

  @override
  String get rptDailySpending => 'الصرف اليومي';

  @override
  String get dtxExportSection => 'تصدير';

  @override
  String get dtxImportSection => 'استيراد';

  @override
  String get dtxPdfReport => 'تقرير مالي PDF';

  @override
  String get dtxPdfReportSub => 'ملخص مصمم للمشاركة';

  @override
  String get captureAutomaticTitle => 'الالتقاط التلقائي';

  @override
  String get captureAutomaticBody => 'إعداد اختصار آبل أو التقاط رسائل البنك';

  @override
  String get homeHeroIncome => 'دخل';

  @override
  String get homeHeroSpent => 'مصروف';

  @override
  String get homeHeroNet => 'الصافي';

  @override
  String homePaceUsed(int percent) {
    return 'استخدمت $percent%';
  }

  @override
  String homePaceExpected(int percent) {
    return 'المتوقع حتى الآن $percent%';
  }

  @override
  String get introWelcomeTitle => 'فلوسك واضحة… من غير مجهود';

  @override
  String get introWelcomeBody =>
      'قِرش يحوّل رسائل البنك لصورة واضحة لصرفك وميزانياتك وأهدافك.';

  @override
  String get introCaptureTitle => 'عملياتك من رسائل البنك';

  @override
  String get introCaptureBody =>
      'اختصار آبل يرسل رسالة البنك لقِرش. تُقرأ على جهازك، وتراجع النتيجة قبل حفظها.';

  @override
  String get introBudgetTitle => 'ميزانية تنبهك قبل التجاوز';

  @override
  String get introBudgetBody => 'شوف وتيرة صرفك يوم بيوم، واعرف إمتى تهدّي.';

  @override
  String get introPrivacyTitle => 'خصوصيتك قبل أي حاجة';

  @override
  String get introPrivacyBody =>
      'بياناتك مشفّرة على جهازك. المعالجة السحابية اختيارية، وتتحكم فيها من الإعدادات.';

  @override
  String introPageSemantic(int page, int total) {
    return 'الصفحة $page من $total';
  }

  @override
  String get introPrivacyLocalBody => 'تُحفظ سجلاتك مشفّرة على هذا الجهاز.';

  @override
  String get introPrivacyCloudBody =>
      'اختياري. اختر تفعيله أثناء الإعداد أو لاحقًا من الإعدادات.';

  @override
  String get annPreferencesTitle => 'اختر الإشعارات التي تهمك';

  @override
  String get annPreferencesAction => 'إعدادات الإشعارات';

  @override
  String get couponsAvailableLabel => 'العروض المتاحة';

  @override
  String setCategoryIconName(String icon) {
    String _temp0 = intl.Intl.selectLogic(
      icon,
      {
        'restaurants': 'مطاعم',
        'groceries': 'بقالة',
        'shopping': 'تسوق',
        'transport': 'مواصلات',
        'bills': 'فواتير',
        'cards': 'بطاقات',
        'cash': 'نقود',
        'cafes': 'مقاهٍ',
        'gifts': 'هدايا',
        'home': 'منزل',
        'travel': 'سفر',
        'health': 'صحة',
        'education': 'تعليم',
        'transfers': 'تحويلات',
        'other': 'أيقونة أخرى',
      },
    );
    return '$_temp0';
  }

  @override
  String setCategoryColourName(String colour) {
    String _temp0 = intl.Intl.selectLogic(
      colour,
      {
        'grey': 'رمادي',
        'coral': 'مرجاني',
        'green': 'أخضر',
        'blue': 'أزرق',
        'purple': 'بنفسجي',
        'brightGreen': 'أخضر زاهٍ',
        'teal': 'أخضر مزرق',
        'pink': 'وردي',
        'blueGrey': 'رمادي مزرق',
        'orange': 'برتقالي',
        'other': 'لون مخصص',
      },
    );
    return '$_temp0';
  }

  @override
  String get rptPreviousPeriod => 'الفترة السابقة';

  @override
  String get cloudResumeTitle => 'شغّل الخدمات السحابية من جديد';

  @override
  String get cloudResumeBody =>
      'المزامنة والتحليل الذكي متوقفان بعد تسجيل الخروج. فعّلهما من جديد لاستئناف الخدمة.';

  @override
  String get languageFirstTitle => 'اختر لغتك';

  @override
  String get languageFirstBody =>
      'اختار اللغة اللي تحب تستخدم بيها قِرش. تقدر تغيّرها بعدين.';

  @override
  String get coachPasteTitle => 'اقرأ رسالة البنك';

  @override
  String get coachPasteBody =>
      'الصق رسالة البنك هنا، أو اختر «لصق رسالة» من قائمة الإضافة لكي يحلّلها قرش.';

  @override
  String get coachAccountTitle => 'اختار الحساب';

  @override
  String get coachAccountBody =>
      'من هنا اختار الحساب اللي تحب تتابعه. الأرقام والعملة بتتغيّر حسب اختيارك.';

  @override
  String get coachBudgetTitle => 'حدّد أول ميزانية';

  @override
  String get coachBudgetBody =>
      'اضغط + وحدّد مبلغ الميزانية والفترة والحساب. تقدر تعدّلها في أي وقت.';

  @override
  String get coachBillsTitle => 'تابع مدفوعاتك';

  @override
  String get coachBillsBody =>
      'اضغط + لإضافة اشتراك أو قسط، وحدّد المبلغ وموعد الدفع. ثم سجّل الدفعات من صفحة التفاصيل.';

  @override
  String get pasteSavedForAnalysis =>
      'الرسالة محفوظة في الوارد الذكي وبانتظار التحليل.';

  @override
  String get retryBankAnalysis => 'أعد التحليل بالذكاء الاصطناعي';

  @override
  String get onboardingAccountCheckFailed =>
      'تعذّر التحقق من إعداد حسابك. تحقّق من اتصالك ثم أعد المحاولة.';

  @override
  String get onboardingUseAnotherAccount => 'الدخول بحساب آخر';

  @override
  String get shortcutVisualInstallTitle => 'أضف اختصار قرش';

  @override
  String get shortcutVisualInstallBody =>
      'اضغط «إضافة اختصار قرش»، ثم Add Shortcut في iOS. احتفظ باسم القالب الجديد QIRSH ليتمكّن اختبار الاتصال من فتحه.';

  @override
  String get shortcutVisualFilterTitle => 'اختار الرسائل البنكية المطلوبة';

  @override
  String shortcutVisualFilterBody(String currencyCode) {
    return 'القالب المشترك بيبدأ بـ EGP. اضبط Message contains على $currencyCode؛ لو هي نفس الكلمة سيبها زي ما هي. سيب Shortcut Input وSender في Process.';
  }

  @override
  String get shortcutVisualAutomationTitle => 'فعّل الالتقاط التلقائي';

  @override
  String get shortcutVisualAutomationBody =>
      'اضغط السهم جنب When I receive a message. شغّل Automation واقفل Confirm Before Run، ثم احفظ.\n\nلو إصدار iOS عندك بيعرض Run Immediately اختاره.';

  @override
  String get shortcutVisualTestTitle => 'اختبر الاتصال بقرش';

  @override
  String get shortcutVisualTestBody =>
      'اختبار الاتصال بيشغّل QIRSH من غير إضافة معاملة. نجاحه بيأكد الاتصال.\n\nوللتأكد من الالتقاط التلقائي، استقبل رسالة بنكية تطابق الفلتر اللي اخترته.';

  @override
  String get shortcutVisualImageCaption =>
      'مرجع من iOS · اضغط للتكبير. اسم الاختصار المستخدم في الاختبار QIRSH.';

  @override
  String get shortcutVisualEnlarge => 'تكبير صورة إعداد الاختصار في iOS';

  @override
  String get shortcutVisualReviewed =>
      'راجعت الخطوات. يتطلّب الالتقاط التلقائي تفعيل Automation داخل الاختصارات.';

  @override
  String get shortcutCatalogTitle => 'رسائل البنك';

  @override
  String get shortcutCatalogBody =>
      'اختار الكلمة اللي بنكك بيستخدمها، وهنظبط معاك الفلتر والالتقاط التلقائي خطوة بخطوة.';

  @override
  String get shortcutCatalogSearch => 'كلمة أو عملة';

  @override
  String get shortcutCatalogOther => 'كلمات وعملات أخرى';

  @override
  String shortcutCatalogKeyword(String keyword) {
    return 'رسائل فيها «$keyword»';
  }

  @override
  String shortcutCatalogExample(String keyword) {
    return 'تم خصم $keyword 450.00 عند Talabat.';
  }

  @override
  String get shortcutCatalogSetUp => 'إعداد';

  @override
  String get shortcutCatalogReviewed => 'راجعت الخطوات';

  @override
  String get shortcutCatalogNoMatches =>
      'لا توجد نتائج. جرّب رمز عملة مثل EGP أو USD.';

  @override
  String get shortcutCatalogSingleTemplate =>
      'كل الاختيارات بتستخدم قالب QIRSH نفسه. هتغيّر الفلتر الحالي داخل الاختصارات. مراجعة الخطوات مش تأكيد إن Automation اتفعّل في iOS.';

  @override
  String shortcutVisualInstallDedicatedBody(String keyword) {
    return 'اضغط «إضافة اختصار قرش»، ثم Add Shortcut في iOS. هذا الاختصار مُعدّ مسبقًا لالتقاط الرسائل التي تحتوي على $keyword، فلا حاجة إلى كتابة أي شيء.';
  }

  @override
  String shortcutCatalogDedicated(String keyword) {
    return 'الكلمة $keyword لها اختصار جاهز أُضيفت فيه مسبقًا. ما زال iOS يطلب منك تفعيل Automation بنفسك، ولا يستطيع قرش معرفة ما إذا كانت مفعّلة.';
  }

  @override
  String get shortcutConfirmAutomation => 'فعّلتُ Automation';

  @override
  String get shortcutStateConfirmed =>
      'أكّدتَ أن Automation مفعّلة. لا يستطيع قرش التحقق من ذلك داخل iOS.';

  @override
  String get shortcutStateTested =>
      'تم اختبار الاتصال. فعّل Automation لالتقاط الرسائل تلقائيًا.';

  @override
  String shortcutOverlapWarning(String keyword) {
    return 'سبق أن أعددت $keyword لهذه العملة. استخدم كلمة واحدة لكل عملة حتى لا تُلتقط الرسالة نفسها مرتين.';
  }

  @override
  String shortcutOpenEditor(String name) {
    return 'افتح $name في الاختصارات';
  }

  @override
  String get shortcutVisualArrowTitle => 'افتح إعدادات التشغيل التلقائي';

  @override
  String shortcutVisualArrowBody(String name) {
    return 'افتح $name في الاختصارات. اضغط السهم الأزرق الصغير جنب where تحت When I receive a message.';
  }

  @override
  String shortcutVisualStep(int current, int total) {
    return 'الخطوة $current من $total';
  }

  @override
  String get shortcutStudioTitle => 'رسائلك مع قرش';

  @override
  String get shortcutStudioBody =>
      'وصلة بسيطة بين رسائل بنكك وقرش. اختار الفلتر، جهّز الربط، وبعدها اختبره.';

  @override
  String get shortcutRouteMessage => 'رسالة';

  @override
  String get shortcutRouteAutomation => 'اختصار';

  @override
  String get shortcutStudioCurrency => '١ · عملة الرسائل';

  @override
  String get shortcutStudioWord => '٢ · الكلمة المطلوبة';

  @override
  String get shortcutStudioPreview => 'فلتر الالتقاط الخاص بك';

  @override
  String shortcutStudioBegin(String keyword) {
    return 'ربط رسائل «$keyword»';
  }

  @override
  String get authEmailExplanation =>
      'أدخل البريد المرتبط بحساب قرش لاستلام رمز دخول يُستخدم مرة واحدة.';

  @override
  String get authEmailLinkExplanation =>
      'أضف بريدًا لحسابك الحالي. عملياتك وإعداداتك هتفضل في نفس الحساب. تغيير البريد بيتطلب تأكيد البريد الحالي والجديد.';

  @override
  String get authInvalidEmail => 'اكتب بريدًا إلكترونيًا صحيحًا.';

  @override
  String get authCodeSendFailed =>
      'تعذّر إرسال الكود. تأكد من اتصالك وحاول تاني بعد دقيقة.';

  @override
  String get authCodeVerifyFailed => 'تعذّر تأكيد الكود. راجعه وحاول تاني.';

  @override
  String get authCodeExpired => 'انتهت صلاحية هذا الرمز. اطلب رمزًا جديدًا.';

  @override
  String get authResendCode => 'إرسال الكود مرة تانية';

  @override
  String get authChangeEmail => 'استخدام بريد آخر';

  @override
  String get authConfirmBothEmails =>
      'تم تأكيد البريد الجديد. أدخل الرمز المُرسل إلى بريدك الحالي للمتابعة.';

  @override
  String get authCurrentEmailCode => 'كود البريد الحالي';

  @override
  String get authSignInMethods => 'طرق تسجيل الدخول';

  @override
  String get authSignInMethodsDescription =>
      'أضف طريقة دخول لنفس الحساب، واحتفظ بكل بياناتك مع بعض.';

  @override
  String get authLinked => 'مرتبط';

  @override
  String get authLinkGoogle => 'ربط حساب Google';

  @override
  String get authLinkEmail => 'ربط البريد الإلكتروني';

  @override
  String get authLinkSuccess => 'تم ربط طريقة الدخول بحسابك.';

  @override
  String get authLinkFailed =>
      'تعذّر ربط طريقة الدخول. لو مرتبطة بحساب قرش تاني، استخدم غيرها.';

  @override
  String get authExistingAccountHint =>
      'تستخدم Apple؟ سجّل الدخول به أولًا لربط طريقة دخول جديدة.';

  @override
  String get authCreateAccount => 'إنشاء حساب';

  @override
  String get authBackToSignIn => 'عندك حساب بالفعل؟ سجّل الدخول';

  @override
  String get authCreateAccountSubtitle =>
      'اختار طريقة الدخول لحساب قرش الجديد.';

  @override
  String get authCreateEmailExplanation =>
      'اكتب بريدك الإلكتروني وأكّد الكود لإكمال إنشاء حساب قرش.';

  @override
  String get deleteAccountEmailProofTitle => 'كود تأكيد البريد';

  @override
  String get deleteAccountEmailProofBody =>
      'بعتنا كود لمرة واحدة على البريد المؤكّد لحساب قرش ده. أدخل الكود لتأكيد الحذف.';

  @override
  String get authGoogleSignupRequired =>
      'حساب Google هذا جديد على قرش. اختر «إنشاء حساب» للتسجيل.';

  @override
  String get accV2Balance => 'الرصيد';

  @override
  String get accV2YourAccounts => 'حساباتك';

  @override
  String get subsV2Upcoming => 'قادمة';

  @override
  String get subsV2AllSubs => 'كل الاشتراكات';

  @override
  String get gfV2Preview => 'معاينة';

  @override
  String gdV2DaysCount(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days يوم',
      many: '$days يومًا',
      few: '$days أيام',
      two: 'يومان',
      one: 'يوم واحد',
    );
    return '$_temp0';
  }

  @override
  String get gdV2MoreActions => 'خيارات الهدف';

  @override
  String get setV2Tools => 'أدوات';

  @override
  String setV2Version(String version) {
    return 'قِرش $version';
  }

  @override
  String get setV2AppearanceLead => 'اختار شكل قِرش — بيتغير فورًا.';

  @override
  String get setV2CaptureNeedsCheck => 'يحتاج مراجعة';

  @override
  String get bdgV2YourBudgets => 'ميزانياتك';

  @override
  String get bdgV2WorstFirst => 'الأسوأ أولًا';

  @override
  String get bfsV2ShowAll => 'عرض الكل';

  @override
  String get bfsV2ShowLess => 'عرض أقل';

  @override
  String get couponsV2BrowseOffers => 'تصفّح العروض';

  @override
  String get txnV2EndOfList => '— دي كل عمليات الفترة —';

  @override
  String get txnV2Filters => 'الفلاتر';

  @override
  String pasteV2DetectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count رسالة مكتشفة',
      many: '$count رسالة مكتشفة',
      few: '$count رسائل مكتشفة',
      two: 'رسالتين مكتشفتين',
      one: 'رسالة واحدة مكتشفة',
    );
    return '$_temp0';
  }

  @override
  String get pasteV2Clear => 'مسح النص';

  @override
  String get smsV2Step1 => 'افتح رسالة البنك';

  @override
  String get smsV2Step2 => 'اضغط «مشاركة»';

  @override
  String get smsV2Step3 => 'اختر قِرش';

  @override
  String get smsV2PrivacyLine =>
      'بدون إذن قراءة الرسائل · عند إيقاف التحليل الذكي نحلّل النص على جهازك فقط.';

  @override
  String get insV3Report => 'تقرير';

  @override
  String get txnV3NetThisMonth => 'صافي الشهر';

  @override
  String get txnV3NetThisPeriod => 'صافي الفترة';

  @override
  String billsV3Counts(int subs, int instalments) {
    return '$subs اشتراك · $instalments أقساط';
  }

  @override
  String get captureQueueNotSaved =>
      'تعذّر حفظ رسالة بنكية واحدة أو أكثر على هذا الجهاز. أعد مشاركتها أو أضف العملية يدوياً.';

  @override
  String get captureQueueReadFailed =>
      'تعذّرت قراءة الرسائل البنكية المحفوظة على هذا الجهاز. لم يُحذف شيء، وسنعيد المحاولة تلقائياً.';

  @override
  String get smsAutoCaptureRestoredNotice =>
      'تمت إعادة تشغيل الالتقاط التلقائي للرسائل لهذا الحساب.';
}
