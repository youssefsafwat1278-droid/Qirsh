import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en')
  ];

  /// No description provided for @shortcutAddReady.
  ///
  /// In ar, this message translates to:
  /// **'إضافة اختصار قرش'**
  String get shortcutAddReady;

  /// No description provided for @shortcutQuickHelp.
  ///
  /// In ar, this message translates to:
  /// **'أضف قالب QIRSH وراجع فلتر الرسائل، ثم فعّل أتمتة Message. في إصدارات iOS الأقدم، أنشئ أتمتة Message تشغّل الاختصار مع Shortcut Input.'**
  String get shortcutQuickHelp;

  /// No description provided for @shortcutTestConnection.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الاتصال'**
  String get shortcutTestConnection;

  /// No description provided for @shortcutProbeWaiting.
  ///
  /// In ar, this message translates to:
  /// **'شغّل الاختصار ثم ارجع لقرش. الاختبار لا يضيف معاملة مالية.'**
  String get shortcutProbeWaiting;

  /// No description provided for @shortcutProbePassed.
  ///
  /// In ar, this message translates to:
  /// **'تم التحقق من الاتصال. التسجيل التلقائي يتطلب تفعيل أتمتة الرسائل أيضًا.'**
  String get shortcutProbePassed;

  /// No description provided for @shortcutOpenFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح الاختصارات. تأكّد من تثبيت تطبيق Shortcuts وحاول مرة أخرى.'**
  String get shortcutOpenFailed;

  /// No description provided for @shortcutManualSteps.
  ///
  /// In ar, this message translates to:
  /// **'تعليمات الإعداد بالتفصيل'**
  String get shortcutManualSteps;

  /// No description provided for @appTitle.
  ///
  /// In ar, this message translates to:
  /// **'قرش'**
  String get appTitle;

  /// No description provided for @setupHeaderTitle.
  ///
  /// In ar, this message translates to:
  /// **'لنُجهّز قِرش'**
  String get setupHeaderTitle;

  /// No description provided for @setupHeaderSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'كام خطوة سريعة وتكون جاهز.'**
  String get setupHeaderSubtitle;

  /// No description provided for @setupStepLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخطوة {current} من {total}'**
  String setupStepLabel(int current, int total);

  /// No description provided for @setupCountryTitle.
  ///
  /// In ar, this message translates to:
  /// **'دولتك وعملتك'**
  String get setupCountryTitle;

  /// No description provided for @setupCountryBody.
  ///
  /// In ar, this message translates to:
  /// **'بنستخدمها كعملة أساسية لحساباتك.'**
  String get setupCountryBody;

  /// No description provided for @setupNotificationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'فعّل الإشعارات'**
  String get setupNotificationsTitle;

  /// No description provided for @setupNotificationsBody.
  ///
  /// In ar, this message translates to:
  /// **'لتصلك كل عملية فور حدوثها.'**
  String get setupNotificationsBody;

  /// No description provided for @setupNotificationsCta.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل'**
  String get setupNotificationsCta;

  /// No description provided for @setupCloudTitle.
  ///
  /// In ar, this message translates to:
  /// **'المعالجة الذكية'**
  String get setupCloudTitle;

  /// No description provided for @setupCloudBody.
  ///
  /// In ar, this message translates to:
  /// **'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي لتحويلها إلى عمليات وتقارير، بدون تخزين أرقامك الكاملة.'**
  String get setupCloudBody;

  /// No description provided for @setupCloudCta.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get setupCloudCta;

  /// No description provided for @setupShortcutTitle.
  ///
  /// In ar, this message translates to:
  /// **'ثبّت اختصار قِرش'**
  String get setupShortcutTitle;

  /// No description provided for @setupShortcutBody.
  ///
  /// In ar, this message translates to:
  /// **'هو اللي بيبعتلنا رسائل البنك تلقائياً.'**
  String get setupShortcutBody;

  /// No description provided for @setupShortcutStep1Title.
  ///
  /// In ar, this message translates to:
  /// **'احذف القديم'**
  String get setupShortcutStep1Title;

  /// No description provided for @setupShortcutStep1Body.
  ///
  /// In ar, this message translates to:
  /// **'افتح تطبيق Shortcuts وروح لتبويب Automation واحذف أي أتمتة قديمة للتطبيق.'**
  String get setupShortcutStep1Body;

  /// No description provided for @setupShortcutStep2Title.
  ///
  /// In ar, this message translates to:
  /// **'جديد (+)'**
  String get setupShortcutStep2Title;

  /// No description provided for @setupShortcutStep2Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».'**
  String get setupShortcutStep2Body;

  /// No description provided for @setupShortcutStep3Title.
  ///
  /// In ar, this message translates to:
  /// **'حدّد الرسائل'**
  String get setupShortcutStep3Title;

  /// No description provided for @setupShortcutStep3Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط «Message Contents» واكتب رمز عملتك مثل {currency}.'**
  String setupShortcutStep3Body(String currency);

  /// No description provided for @setupShortcutStep4Title.
  ///
  /// In ar, this message translates to:
  /// **'بدون تأكيد'**
  String get setupShortcutStep4Title;

  /// No description provided for @setupShortcutStep4Body.
  ///
  /// In ar, this message translates to:
  /// **'فعّل «Run Immediately» واقفل «Notify When Run» لو ظهر، ثم Next.'**
  String get setupShortcutStep4Body;

  /// No description provided for @setupShortcutStep5Title.
  ///
  /// In ar, this message translates to:
  /// **'إرسال للتطبيق'**
  String get setupShortcutStep5Title;

  /// No description provided for @setupShortcutStep5Body.
  ///
  /// In ar, this message translates to:
  /// **'اختر New Blank Automation وابحث عن Process Bank SMS، واضبط SMS Text على Shortcut Input.'**
  String get setupShortcutStep5Body;

  /// No description provided for @setupShortcutStep6Title.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get setupShortcutStep6Title;

  /// No description provided for @setupShortcutStep6Body.
  ///
  /// In ar, this message translates to:
  /// **'اقفل «Show When Run» لو ظهر، واضغط حفظ.'**
  String get setupShortcutStep6Body;

  /// No description provided for @setupShortcutCta.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتّه'**
  String get setupShortcutCta;

  /// No description provided for @setupFinishCta.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ'**
  String get setupFinishCta;

  /// No description provided for @brandTagline.
  ///
  /// In ar, this message translates to:
  /// **'فلوسك أوضح. قرارك أذكى.'**
  String get brandTagline;

  /// No description provided for @brandContinueCta.
  ///
  /// In ar, this message translates to:
  /// **'لنبدأ'**
  String get brandContinueCta;

  /// No description provided for @authTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الدخول لقرش'**
  String get authTitle;

  /// No description provided for @authSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختار طريقة تسجيل الدخول المناسبة ليك.'**
  String get authSubtitle;

  /// No description provided for @authTrustLocalEncryption.
  ///
  /// In ar, this message translates to:
  /// **'تشفير محلي'**
  String get authTrustLocalEncryption;

  /// No description provided for @authTrustOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'مشفّرة على جهازك، ومتزامنة بأمان'**
  String get authTrustOnDevice;

  /// No description provided for @authTermsNotice.
  ///
  /// In ar, this message translates to:
  /// **'بالمتابعة أنت توافق على شروط الاستخدام وسياسة الخصوصية.'**
  String get authTermsNotice;

  /// No description provided for @authAppleCta.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بحساب Apple'**
  String get authAppleCta;

  /// No description provided for @authGoogleCta.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بحساب Google'**
  String get authGoogleCta;

  /// No description provided for @authSignInError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدخول. جرب تاني.'**
  String get authSignInError;

  /// No description provided for @authBackupFoundTitle.
  ///
  /// In ar, this message translates to:
  /// **'لقينا نسخة احتياطية لحسابك'**
  String get authBackupFoundTitle;

  /// No description provided for @authBackupFoundBody.
  ///
  /// In ar, this message translates to:
  /// **'تحب نرجّع بياناتك من آخر نسخة، ولا تبدأ من جديد؟'**
  String get authBackupFoundBody;

  /// No description provided for @authBackupStartFresh.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ من جديد'**
  String get authBackupStartFresh;

  /// No description provided for @authBackupRestore.
  ///
  /// In ar, this message translates to:
  /// **'استرجاعها'**
  String get authBackupRestore;

  /// No description provided for @storyPromiseTitle.
  ///
  /// In ar, this message translates to:
  /// **'متحمّسين\nنبدأ معك'**
  String get storyPromiseTitle;

  /// No description provided for @storyPromiseSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ونكون شريكك في رحلتك المالية.'**
  String get storyPromiseSubtitle;

  /// No description provided for @storyPromiseHighlight.
  ///
  /// In ar, this message translates to:
  /// **'في قِرش، نؤمن أن الاستقرار المالي يبدأ بعادات بسيطة.'**
  String get storyPromiseHighlight;

  /// No description provided for @storyPromiseBody.
  ///
  /// In ar, this message translates to:
  /// **'بنينا تطبيقًا يساعدك على إدارة أموالك بسهولة، من تسجيل المصروفات ووضع الميزانيات، إلى تنبيهات الاشتراكات والتقارير الذكية.'**
  String get storyPromiseBody;

  /// No description provided for @storyPromiseSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'هدفنا؟'**
  String get storyPromiseSectionTitle;

  /// No description provided for @storyPromiseSectionBody.
  ///
  /// In ar, this message translates to:
  /// **'أن تعرف أين يذهب مالك، وتدّخر أكثر وتعيش براحة أكبر.'**
  String get storyPromiseSectionBody;

  /// No description provided for @storyPromiseClosing.
  ///
  /// In ar, this message translates to:
  /// **'قِرش...\nشريكك في رحلتك المالية.'**
  String get storyPromiseClosing;

  /// No description provided for @storySpendingTitle.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات الصغيرة بتفرق'**
  String get storySpendingTitle;

  /// No description provided for @storySpendingBody.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات اليومية قد تبدو بسيطة،\nلكنها مع الوقت تصنع فرقًا كبيرًا.'**
  String get storySpendingBody;

  /// No description provided for @storySpendingHighlight.
  ///
  /// In ar, this message translates to:
  /// **'ما لا تتابعه... يصعب عليك التحكم به'**
  String get storySpendingHighlight;

  /// No description provided for @storySpendingSupporting.
  ///
  /// In ar, this message translates to:
  /// **'يساعدك قِرش على رؤية الصورة كاملة،\nوفهم أين تذهب أموالك.'**
  String get storySpendingSupporting;

  /// No description provided for @storyContinueCta.
  ///
  /// In ar, this message translates to:
  /// **'كمّل'**
  String get storyContinueCta;

  /// No description provided for @storyStartCta.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ مع قِرش'**
  String get storyStartCta;

  /// No description provided for @storySkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّي'**
  String get storySkip;

  /// No description provided for @storyPageOneSemanticLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصفحة ١ من ٢'**
  String get storyPageOneSemanticLabel;

  /// No description provided for @storyPageTwoSemanticLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصفحة ٢ من ٢'**
  String get storyPageTwoSemanticLabel;

  /// No description provided for @next.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get next;

  /// No description provided for @skip.
  ///
  /// In ar, this message translates to:
  /// **'تخطي'**
  String get skip;

  /// No description provided for @registerAndStart.
  ///
  /// In ar, this message translates to:
  /// **'التسجيل والبدء'**
  String get registerAndStart;

  /// No description provided for @welcomeTitle.
  ///
  /// In ar, this message translates to:
  /// **'مساعدك المالي اليومي'**
  String get welcomeTitle;

  /// No description provided for @welcomeSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'صاحبك في فلوسك'**
  String get welcomeSubtitle;

  /// No description provided for @today.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In ar, this message translates to:
  /// **'أمس'**
  String get yesterday;

  /// No description provided for @welcomeDescription.
  ///
  /// In ar, this message translates to:
  /// **'اعرف أين تذهب أموالك، وادّخر تلقائيًا بطريقة ذكية وسهلة.'**
  String get welcomeDescription;

  /// No description provided for @secureOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'آمن · على جهازك'**
  String get secureOnDevice;

  /// No description provided for @effortless.
  ///
  /// In ar, this message translates to:
  /// **'بدون مجهود'**
  String get effortless;

  /// No description provided for @noTyping.
  ///
  /// In ar, this message translates to:
  /// **'لا تكتب — إحنا نفهمها لك'**
  String get noTyping;

  /// No description provided for @smsReadingDesc.
  ///
  /// In ar, this message translates to:
  /// **'شارك رسالة البنك مع قرش، ونطلّع المبلغ والمتجر ونصنّفها على جهازك.'**
  String get smsReadingDesc;

  /// No description provided for @now.
  ///
  /// In ar, this message translates to:
  /// **'الآن'**
  String get now;

  /// No description provided for @snbSmsText.
  ///
  /// In ar, this message translates to:
  /// **'عملية مدى شراء بـ '**
  String get snbSmsText;

  /// No description provided for @snbSmsSuffix.
  ///
  /// In ar, this message translates to:
  /// **' لدى هاف مليون.'**
  String get snbSmsSuffix;

  /// No description provided for @alrajhi.
  ///
  /// In ar, this message translates to:
  /// **'الراجحي'**
  String get alrajhi;

  /// No description provided for @oneMinuteAgo.
  ///
  /// In ar, this message translates to:
  /// **'قبل دقيقة'**
  String get oneMinuteAgo;

  /// No description provided for @alrajhiSmsText.
  ///
  /// In ar, this message translates to:
  /// **'تم خصم '**
  String get alrajhiSmsText;

  /// No description provided for @alrajhiSmsSuffix.
  ///
  /// In ar, this message translates to:
  /// **' لدى مطعم هامبرغيني.'**
  String get alrajhiSmsSuffix;

  /// No description provided for @localProcessing.
  ///
  /// In ar, this message translates to:
  /// **'معالجة محلية بالكامل'**
  String get localProcessing;

  /// No description provided for @privacyFirst.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية أولاً'**
  String get privacyFirst;

  /// No description provided for @howItWorks.
  ///
  /// In ar, this message translates to:
  /// **'كيف يعمل؟'**
  String get howItWorks;

  /// No description provided for @smsToTx.
  ///
  /// In ar, this message translates to:
  /// **'من رسالة بنك إلى عملية واضحة'**
  String get smsToTx;

  /// No description provided for @howItWorksDesc.
  ///
  /// In ar, this message translates to:
  /// **'قرش يلتقط المعنى من الرسالة، ويحوّلها لتصنيف ومبلغ ومتجر بدون إدخال يدوي.'**
  String get howItWorksDesc;

  /// No description provided for @howItWorksNote1.
  ///
  /// In ar, this message translates to:
  /// **'لا حاجة لاختيار مصرفك — يتعرّف قِرش عليه من نص الرسالة.'**
  String get howItWorksNote1;

  /// No description provided for @howItWorksNote2.
  ///
  /// In ar, this message translates to:
  /// **'لو ظهرت بطاقة جديدة، قرش يضيفها تلقائياً من آخر 4 أرقام.'**
  String get howItWorksNote2;

  /// No description provided for @howItWorksNote3.
  ///
  /// In ar, this message translates to:
  /// **'تقدر تراجع وتعدل أي عملية أو بطاقة من داخل التطبيق.'**
  String get howItWorksNote3;

  /// No description provided for @messageFromBank.
  ///
  /// In ar, this message translates to:
  /// **'رسالة من البنك'**
  String get messageFromBank;

  /// No description provided for @burgerBoutiqueSms.
  ///
  /// In ar, this message translates to:
  /// **'شراء 45 ريال لدى BURGER BOUTIQUE'**
  String get burgerBoutiqueSms;

  /// No description provided for @burgerBoutiqueSub.
  ///
  /// In ar, this message translates to:
  /// **'مطاعم · الآن · مدى'**
  String get burgerBoutiqueSub;

  /// No description provided for @burgerBoutiqueAmount.
  ///
  /// In ar, this message translates to:
  /// **'-45 ريال'**
  String get burgerBoutiqueAmount;

  /// No description provided for @financialMotivation.
  ///
  /// In ar, this message translates to:
  /// **'التحفيز المالي'**
  String get financialMotivation;

  /// No description provided for @saveLikeGame.
  ///
  /// In ar, this message translates to:
  /// **'وفّر وكأنها لعبة يومية'**
  String get saveLikeGame;

  /// No description provided for @saveLikeGameDesc.
  ///
  /// In ar, this message translates to:
  /// **'حدّد أهدافك المالية ووفّر الفروقات يومًا بعد يوم بطابع تشجيعي ذكي.'**
  String get saveLikeGameDesc;

  /// No description provided for @totalSavings.
  ///
  /// In ar, this message translates to:
  /// **'مجموع الادخار المتراكم'**
  String get totalSavings;

  /// No description provided for @sar.
  ///
  /// In ar, this message translates to:
  /// **'ر.س'**
  String get sar;

  /// No description provided for @travelVault.
  ///
  /// In ar, this message translates to:
  /// **'خزنة السفر'**
  String get travelVault;

  /// No description provided for @completedPercent.
  ///
  /// In ar, this message translates to:
  /// **'75% مكتمل'**
  String get completedPercent;

  /// No description provided for @goalLimit.
  ///
  /// In ar, this message translates to:
  /// **'الهدف: 15,000 ر.س'**
  String get goalLimit;

  /// No description provided for @remainingAmount.
  ///
  /// In ar, this message translates to:
  /// **'متبقي: 3,750 ر.س'**
  String get remainingAmount;

  /// No description provided for @easyToUse.
  ///
  /// In ar, this message translates to:
  /// **'سهل الاستخدام'**
  String get easyToUse;

  /// No description provided for @selectCountryCurrency.
  ///
  /// In ar, this message translates to:
  /// **'اختَر بلدك وعملتك'**
  String get selectCountryCurrency;

  /// No description provided for @selectCountryDesc.
  ///
  /// In ar, this message translates to:
  /// **'نعرض الأعلام الرسمية، ونضبط العملة الأساسية، وتقدر تضيف عملات ثانية لو عندك بطاقات أو اشتراكات خارجية.'**
  String get selectCountryDesc;

  /// No description provided for @mainCountryCurrency.
  ///
  /// In ar, this message translates to:
  /// **'البلد والعملة الأساسية'**
  String get mainCountryCurrency;

  /// No description provided for @additionalCurrencies.
  ///
  /// In ar, this message translates to:
  /// **'العملات الإضافية'**
  String get additionalCurrencies;

  /// No description provided for @activeSubscriptions.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات النشطة'**
  String get activeSubscriptions;

  /// No description provided for @none.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد'**
  String get none;

  /// No description provided for @noActiveSubs.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد اشتراكات نشطة'**
  String get noActiveSubs;

  /// No description provided for @selectCountryTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر بلدك وعملتك الأساسية'**
  String get selectCountryTitle;

  /// No description provided for @searchCountryPlaceholder.
  ///
  /// In ar, this message translates to:
  /// **'البحث عن بلد أو عملة...'**
  String get searchCountryPlaceholder;

  /// No description provided for @additionalCurrenciesTitle.
  ///
  /// In ar, this message translates to:
  /// **'العملات الإضافية'**
  String get additionalCurrenciesTitle;

  /// No description provided for @additionalCurrenciesDesc.
  ///
  /// In ar, this message translates to:
  /// **'اختياري، اختر العملات التي تتعامل بها بجانب عملتك الأساسية.'**
  String get additionalCurrenciesDesc;

  /// No description provided for @expectedSubscriptions.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات المتوقعة'**
  String get expectedSubscriptions;

  /// No description provided for @expectedSubscriptionsDesc.
  ///
  /// In ar, this message translates to:
  /// **'حدد الاشتراكات النشطة لديك وسنقوم بالتعرف عليها تلقائياً.'**
  String get expectedSubscriptionsDesc;

  /// No description provided for @completePrivacy.
  ///
  /// In ar, this message translates to:
  /// **'خصوصية تامّة'**
  String get completePrivacy;

  /// No description provided for @dataStaysOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك تبقى في جهازك'**
  String get dataStaysOnDevice;

  /// No description provided for @privacyPrinciples.
  ///
  /// In ar, this message translates to:
  /// **'مبادئ الأمان والخصوصية لدينا تعني أنك المتحكم الوحيد ببياناتك المالية.'**
  String get privacyPrinciples;

  /// No description provided for @privacyRule1.
  ///
  /// In ar, this message translates to:
  /// **'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي'**
  String get privacyRule1;

  /// No description provided for @privacyRule2.
  ///
  /// In ar, this message translates to:
  /// **'نعالج فقط رسائل البنك التي تشاركها أو تلصقها بنفسك'**
  String get privacyRule2;

  /// No description provided for @privacyRule3.
  ///
  /// In ar, this message translates to:
  /// **'ما نبيع بياناتك أبداً، ولك كامل الحرية في حذفها'**
  String get privacyRule3;

  /// No description provided for @enableAutoTracking.
  ///
  /// In ar, this message translates to:
  /// **'شارك رسائل البنك مع قرش'**
  String get enableAutoTracking;

  /// No description provided for @setupAppleShortcut.
  ///
  /// In ar, this message translates to:
  /// **'إعداد اختصار Apple'**
  String get setupAppleShortcut;

  /// No description provided for @autoTrackingSubtitleAndroid.
  ///
  /// In ar, this message translates to:
  /// **'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى قرش. سنحللها على جهازك ونضيف العملية.'**
  String get autoTrackingSubtitleAndroid;

  /// No description provided for @autoTrackingSubtitleIos.
  ///
  /// In ar, this message translates to:
  /// **'اتبع الخطوات مرة واحدة، وبعدها يمرّر iPhone رسائل البنك إلى قرش بأمان.'**
  String get autoTrackingSubtitleIos;

  /// No description provided for @smsActivationSnack.
  ///
  /// In ar, this message translates to:
  /// **'تقدر تشارك رسالة البنك مع قرش أو تلصقها يدويًا.'**
  String get smsActivationSnack;

  /// No description provided for @howWillActivationWork.
  ///
  /// In ar, this message translates to:
  /// **'كيف سيتم التفعيل؟'**
  String get howWillActivationWork;

  /// No description provided for @allowSmsReading.
  ///
  /// In ar, this message translates to:
  /// **'فهمت'**
  String get allowSmsReading;

  /// No description provided for @gotIt.
  ///
  /// In ar, this message translates to:
  /// **'تمام، فهمت'**
  String get gotIt;

  /// No description provided for @laterAddManually.
  ///
  /// In ar, this message translates to:
  /// **'لاحقاً، سأقوم بالإضافة يدوياً'**
  String get laterAddManually;

  /// No description provided for @shortcutSetupGuide.
  ///
  /// In ar, this message translates to:
  /// **'دليل إعداد الاختصار'**
  String get shortcutSetupGuide;

  /// No description provided for @doStepsOnceFromShortcuts.
  ///
  /// In ar, this message translates to:
  /// **'نفّذ هذه الخطوات مرة واحدة من تطبيق Apple Shortcuts.'**
  String get doStepsOnceFromShortcuts;

  /// No description provided for @signInToStart.
  ///
  /// In ar, this message translates to:
  /// **'سجّل دخولك للبدء'**
  String get signInToStart;

  /// No description provided for @signInSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الدخول لتحديد هويتك ومزامنة إعداداتك فقط. بياناتك المالية تبقى آمنة على جهازك.'**
  String get signInSubtitle;

  /// No description provided for @noPassword.
  ///
  /// In ar, this message translates to:
  /// **'بدون كلمة مرور'**
  String get noPassword;

  /// No description provided for @continueWithApple.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة مع Apple'**
  String get continueWithApple;

  /// No description provided for @continueWithGoogle.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة مع Google'**
  String get continueWithGoogle;

  /// No description provided for @or.
  ///
  /// In ar, this message translates to:
  /// **'أو'**
  String get or;

  /// No description provided for @continueWithEmail.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بالبريد الإلكتروني'**
  String get continueWithEmail;

  /// No description provided for @email.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني'**
  String get email;

  /// No description provided for @sendOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'إرسال رمز الدخول الآمن'**
  String get sendOtpCode;

  /// No description provided for @byContinuingAgree.
  ///
  /// In ar, this message translates to:
  /// **'بالمتابعة توافق على شروط الخدمة وسياسة الخصوصية الخاصة بـ قرش.'**
  String get byContinuingAgree;

  /// No description provided for @enterOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رمز التحقق'**
  String get enterOtpCode;

  /// No description provided for @otpSentTo.
  ///
  /// In ar, this message translates to:
  /// **'اكتب الكود اللي وصلك على البريد ده. راجع الرسائل غير المرغوب فيها كمان.'**
  String get otpSentTo;

  /// No description provided for @verifyCode.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الرمز'**
  String get verifyCode;

  /// No description provided for @demoOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'للتجربة: الرمز 123456'**
  String get demoOtpCode;

  /// No description provided for @invalidOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'الرمز غير صحيح'**
  String get invalidOtpCode;

  /// No description provided for @enterPasswordOrRecoveryCodeError.
  ///
  /// In ar, this message translates to:
  /// **'اكتب كلمة مرور النسخة أو رمز الاسترداد.'**
  String get enterPasswordOrRecoveryCodeError;

  /// No description provided for @recoveryCodeIncorrect.
  ///
  /// In ar, this message translates to:
  /// **'رمز الاسترداد غير صحيح أو لا يطابق النسخة.'**
  String get recoveryCodeIncorrect;

  /// No description provided for @backupPasswordIncorrect.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور النسخة الاحتياطية غير صحيحة.'**
  String get backupPasswordIncorrect;

  /// No description provided for @backupFound.
  ///
  /// In ar, this message translates to:
  /// **'وجدنا نسخة احتياطية لحسابك'**
  String get backupFound;

  /// No description provided for @restoreDesc.
  ///
  /// In ar, this message translates to:
  /// **'استعادة بياناتك المشفّرة تتم على جهازك فقط. كلمة المرور لا تخرج من هاتفك.'**
  String get restoreDesc;

  /// No description provided for @recoveryCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز الاسترداد'**
  String get recoveryCodeLabel;

  /// No description provided for @backupPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور النسخة الاحتياطية'**
  String get backupPasswordLabel;

  /// No description provided for @recoveryCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'XXXX-XXXX-XXXX'**
  String get recoveryCodeHint;

  /// No description provided for @backupPasswordHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب كلمة المرور التي اخترتها'**
  String get backupPasswordHint;

  /// No description provided for @useBackupPassword.
  ///
  /// In ar, this message translates to:
  /// **'استخدام كلمة مرور النسخة'**
  String get useBackupPassword;

  /// No description provided for @useRecoveryCode.
  ///
  /// In ar, this message translates to:
  /// **'استخدام رمز الاسترداد'**
  String get useRecoveryCode;

  /// No description provided for @restore.
  ///
  /// In ar, this message translates to:
  /// **'استعادة'**
  String get restore;

  /// No description provided for @startFresh.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ جديد'**
  String get startFresh;

  /// No description provided for @notNow.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get notNow;

  /// No description provided for @restoreNotEnabled.
  ///
  /// In ar, this message translates to:
  /// **'الاستعادة السحابية غير مفعّلة في هذا البناء.'**
  String get restoreNotEnabled;

  /// No description provided for @appleSecuritySteps.
  ///
  /// In ar, this message translates to:
  /// **'خطوات الأمان لآبل'**
  String get appleSecuritySteps;

  /// No description provided for @iosShortcutSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ قرش تلقائياً وبأمان تام.'**
  String get iosShortcutSubtitle;

  /// No description provided for @stepsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخطوات:'**
  String get stepsLabel;

  /// No description provided for @multipleCurrenciesQuestion.
  ///
  /// In ar, this message translates to:
  /// **'تتعامل بأكثر من عملة؟'**
  String get multipleCurrenciesQuestion;

  /// No description provided for @multipleCurrenciesDesc.
  ///
  /// In ar, this message translates to:
  /// **'إذا كانت تصلك رسائل بنكية بعملات مختلفة، كرّر نفس الخطوات لكل عملة.'**
  String get multipleCurrenciesDesc;

  /// No description provided for @continueWithoutAccount.
  ///
  /// In ar, this message translates to:
  /// **'أكمل بدون حساب'**
  String get continueWithoutAccount;

  /// No description provided for @continueWithoutAccountSub.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك تبقى محلية على جهازك.'**
  String get continueWithoutAccountSub;

  /// No description provided for @smsPermissionRationaleTitle.
  ///
  /// In ar, this message translates to:
  /// **'محتاجين إذن قراءة رسائل البنك بس'**
  String get smsPermissionRationaleTitle;

  /// No description provided for @smsPermissionRationaleBody.
  ///
  /// In ar, this message translates to:
  /// **'يقرأ قِرش رسائل المصرف الواردة على جهازك ليسجّل عملياتك تلقائيًا. لا يقرأ رسائلك الشخصية، ويتم التحليل على الجهاز افتراضيًا — لا يخرج منه شيء إلا إذا فعّلت المعالجة السحابية بنفسك.'**
  String get smsPermissionRationaleBody;

  /// No description provided for @listeningTitle.
  ///
  /// In ar, this message translates to:
  /// **'جاهزين — بنستنى رسالتك الأولى'**
  String get listeningTitle;

  /// No description provided for @listeningSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اعمل أي شراء بكارتك وهيظهر هنا تلقائياً.'**
  String get listeningSubtitle;

  /// No description provided for @pasteMessageInstead.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة مصرفية بدلًا من ذلك'**
  String get pasteMessageInstead;

  /// No description provided for @skipForNow.
  ///
  /// In ar, this message translates to:
  /// **'تخطي الآن'**
  String get skipForNow;

  /// No description provided for @shortcutVerifyTitle.
  ///
  /// In ar, this message translates to:
  /// **'خلينا نتأكد إن الاختصار شغّال'**
  String get shortcutVerifyTitle;

  /// No description provided for @shortcutVerifyBody.
  ///
  /// In ar, this message translates to:
  /// **'ارجع لتطبيق Shortcuts وابعت نفسك رسالة فيها كلمة العملة، ثم ارجع هنا.'**
  String get shortcutVerifyBody;

  /// No description provided for @shortcutVerifyWaiting.
  ///
  /// In ar, this message translates to:
  /// **'بنستنى رسالة...'**
  String get shortcutVerifyWaiting;

  /// No description provided for @recheckSetup.
  ///
  /// In ar, this message translates to:
  /// **'راجع الإعداد'**
  String get recheckSetup;

  /// No description provided for @filterKeywordsLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المفتاح:'**
  String get filterKeywordsLabel;

  /// No description provided for @firstTxTitle.
  ///
  /// In ar, this message translates to:
  /// **'أول عملية اتسجّلت لوحدها!'**
  String get firstTxTitle;

  /// No description provided for @firstTxTrustLine.
  ///
  /// In ar, this message translates to:
  /// **'لم تفعل شيئًا — قرأ قِرش رسالة مصرفك وسجّلها.'**
  String get firstTxTrustLine;

  /// No description provided for @firstTxContinue.
  ///
  /// In ar, this message translates to:
  /// **'تمام، كمّل'**
  String get firstTxContinue;

  /// No description provided for @firstTxNeedsCheck.
  ///
  /// In ar, this message translates to:
  /// **'محتاجة تأكيد سريع'**
  String get firstTxNeedsCheck;

  /// No description provided for @firstTxNeedsCheckSub.
  ///
  /// In ar, this message translates to:
  /// **'قِرش غير متأكد تمامًا — راجعها سريعًا.'**
  String get firstTxNeedsCheckSub;

  /// No description provided for @wrongCategoryTap.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف غير صحيح؟ اضغط لتغييره'**
  String get wrongCategoryTap;

  /// No description provided for @couponsTitle.
  ///
  /// In ar, this message translates to:
  /// **'العروض'**
  String get couponsTitle;

  /// No description provided for @couponsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عروض شركاء تساعدك توفر في مصروفاتك اليومية.'**
  String get couponsSubtitle;

  /// No description provided for @couponsFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get couponsFilterAll;

  /// No description provided for @couponsFeaturedSection.
  ///
  /// In ar, this message translates to:
  /// **'عروض مميزة'**
  String get couponsFeaturedSection;

  /// No description provided for @couponsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض حالياً'**
  String get couponsEmptyTitle;

  /// No description provided for @couponsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'هنعرض لك عروض الشركاء هنا أول ما تكون متاحة.'**
  String get couponsEmptyBody;

  /// No description provided for @couponsFilterEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض بهذا الفلتر'**
  String get couponsFilterEmptyTitle;

  /// No description provided for @couponsFilterEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'جرّب فئة أو وسم مختلف.'**
  String get couponsFilterEmptyBody;

  /// No description provided for @couponsErrorTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل العروض'**
  String get couponsErrorTitle;

  /// No description provided for @couponsErrorBody.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى بعد لحظات.'**
  String get couponsErrorBody;

  /// No description provided for @couponsRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get couponsRetry;

  /// No description provided for @couponsLoading.
  ///
  /// In ar, this message translates to:
  /// **'تحميل العروض...'**
  String get couponsLoading;

  /// No description provided for @couponsCopyCode.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الكود'**
  String get couponsCopyCode;

  /// No description provided for @couponsCodeCopied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الكود {code}'**
  String couponsCodeCopied(String code);

  /// No description provided for @couponsOpenPartner.
  ///
  /// In ar, this message translates to:
  /// **'فتح موقع الشريك'**
  String get couponsOpenPartner;

  /// No description provided for @couponsUseOffer.
  ///
  /// In ar, this message translates to:
  /// **'احصل على العرض'**
  String get couponsUseOffer;

  /// No description provided for @couponsOpenFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح الرابط'**
  String get couponsOpenFailed;

  /// No description provided for @couponsOfferUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'هذا العرض غير متاح حاليًا'**
  String get couponsOfferUnavailable;

  /// No description provided for @couponsTerms.
  ///
  /// In ar, this message translates to:
  /// **'الشروط'**
  String get couponsTerms;

  /// No description provided for @couponsValidUntil.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي {date}'**
  String couponsValidUntil(String date);

  /// No description provided for @couponsOpenEnded.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح'**
  String get couponsOpenEnded;

  /// No description provided for @couponsExpiresToday.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي اليوم'**
  String get couponsExpiresToday;

  /// No description provided for @couponsExpiresInDays.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم'**
  String couponsExpiresInDays(int days);

  /// No description provided for @couponsAvailableGlobally.
  ///
  /// In ar, this message translates to:
  /// **'متاح في كل الدول'**
  String get couponsAvailableGlobally;

  /// No description provided for @couponsAvailableIn.
  ///
  /// In ar, this message translates to:
  /// **'متاح في {countries}'**
  String couponsAvailableIn(String countries);

  /// No description provided for @couponsCardSemantics.
  ///
  /// In ar, this message translates to:
  /// **'عرض من {partner}: {title}'**
  String couponsCardSemantics(String partner, String title);

  /// No description provided for @couponsCodeSemantics.
  ///
  /// In ar, this message translates to:
  /// **'كود الخصم {code}'**
  String couponsCodeSemantics(String code);

  /// No description provided for @couponsOffline.
  ///
  /// In ar, this message translates to:
  /// **'هذه آخر العروض المتاحة لديك دون اتصال.'**
  String get couponsOffline;

  /// No description provided for @referralTitle.
  ///
  /// In ar, this message translates to:
  /// **'دعوة الأصدقاء'**
  String get referralTitle;

  /// No description provided for @referralSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ادعُ أصدقاءك بالرمز، ولما ينضمّوا ويأكّدوا حسابهم تكسب تقارير بدون إعلانات.'**
  String get referralSubtitle;

  /// No description provided for @referralYourCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز الدعوة'**
  String get referralYourCodeLabel;

  /// No description provided for @referralCopyAction.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get referralCopyAction;

  /// No description provided for @referralCopiedToast.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرمز.'**
  String get referralCopiedToast;

  /// No description provided for @referralShareAction.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة'**
  String get referralShareAction;

  /// No description provided for @referralShareMessage.
  ///
  /// In ar, this message translates to:
  /// **'جرّب قرش! استخدم رمز الدعوة {code} وانت بتسجّل. حمّل التطبيق وابدأ.'**
  String referralShareMessage(String code);

  /// No description provided for @referralProgressLabel.
  ///
  /// In ar, this message translates to:
  /// **'{progress} / {required} دعوات صالحة'**
  String referralProgressLabel(int progress, int required);

  /// No description provided for @referralCycleLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدورة {cycle}'**
  String referralCycleLabel(int cycle);

  /// No description provided for @referralRewardTitle.
  ///
  /// In ar, this message translates to:
  /// **'المكافأة'**
  String get referralRewardTitle;

  /// No description provided for @referralRewardDays.
  ///
  /// In ar, this message translates to:
  /// **'تقارير بدون إعلانات لمدة {days} يومًا'**
  String referralRewardDays(int days);

  /// No description provided for @referralRewardScopeNote.
  ///
  /// In ar, this message translates to:
  /// **'تزيل المكافأة إعلانات تصدير التقارير فقط — وليست اشتراكًا بلا إعلانات لكامل التطبيق.'**
  String get referralRewardScopeNote;

  /// No description provided for @referralRewardActiveUntil.
  ///
  /// In ar, this message translates to:
  /// **'تقارير بدون إعلانات حتى {date}'**
  String referralRewardActiveUntil(String date);

  /// No description provided for @referralEntitlementInactive.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مكافأة نشطة حاليًا.'**
  String get referralEntitlementInactive;

  /// No description provided for @referralApplyTitle.
  ///
  /// In ar, this message translates to:
  /// **'عندك رمز دعوة؟'**
  String get referralApplyTitle;

  /// No description provided for @referralApplyHint.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رمز صديقك مرة واحدة.'**
  String get referralApplyHint;

  /// No description provided for @referralApplyPlaceholder.
  ///
  /// In ar, this message translates to:
  /// **'رمز الدعوة'**
  String get referralApplyPlaceholder;

  /// No description provided for @referralApplyAction.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل الرمز'**
  String get referralApplyAction;

  /// No description provided for @referralApplySuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم قبول الرمز.'**
  String get referralApplySuccess;

  /// No description provided for @referralQualifiedToast.
  ///
  /// In ar, this message translates to:
  /// **'تم احتساب دعوتك.'**
  String get referralQualifiedToast;

  /// No description provided for @referralAlreadyReferredNote.
  ///
  /// In ar, this message translates to:
  /// **'تم تفعيل رمز دعوة على حسابك.'**
  String get referralAlreadyReferredNote;

  /// No description provided for @referralLoading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحميل…'**
  String get referralLoading;

  /// No description provided for @referralErrorTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الدعوات'**
  String get referralErrorTitle;

  /// No description provided for @referralErrorBody.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى بعد لحظات.'**
  String get referralErrorBody;

  /// No description provided for @referralRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get referralRetry;

  /// No description provided for @referralUnavailableTitle.
  ///
  /// In ar, this message translates to:
  /// **'الدعوات غير متاحة حاليًا'**
  String get referralUnavailableTitle;

  /// No description provided for @referralUnavailableBody.
  ///
  /// In ar, this message translates to:
  /// **'هنعرض لك دعوة الأصدقاء هنا أول ما تكون متاحة.'**
  String get referralUnavailableBody;

  /// No description provided for @referralErrorInvalidCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز غير صحيح.'**
  String get referralErrorInvalidCode;

  /// No description provided for @referralErrorSelfReferral.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكنك استخدام رمزك الخاص.'**
  String get referralErrorSelfReferral;

  /// No description provided for @referralErrorAlreadyReferred.
  ///
  /// In ar, this message translates to:
  /// **'لقد استخدمت رمز دعوة من قبل.'**
  String get referralErrorAlreadyReferred;

  /// No description provided for @referralErrorNoActiveRule.
  ///
  /// In ar, this message translates to:
  /// **'الدعوات غير متاحة حاليًا.'**
  String get referralErrorNoActiveRule;

  /// No description provided for @referralErrorIdentityUnverified.
  ///
  /// In ar, this message translates to:
  /// **'أكمل تأكيد حسابك لتُحتسب دعوتك.'**
  String get referralErrorIdentityUnverified;

  /// No description provided for @referralErrorGeneric.
  ///
  /// In ar, this message translates to:
  /// **'حصل خطأ، حاول تاني.'**
  String get referralErrorGeneric;

  /// Title of the Android prominent disclosure shown immediately before the RECEIVE_SMS system dialog.
  ///
  /// In ar, this message translates to:
  /// **'قراءة رسائل البنك تلقائياً'**
  String get smsDisclosureTitle;

  /// Opening line of the SMS prominent disclosure.
  ///
  /// In ar, this message translates to:
  /// **'ليسجّل قِرش مصاريفك تلقائيًا، يحتاج إذن قراءة الرسائل الواردة على جهازك.'**
  String get smsDisclosureIntro;

  /// Disclosure point: what Qirsh looks for in incoming messages.
  ///
  /// In ar, this message translates to:
  /// **'يفحص قِرش الرسائل الواردة ليتعرّف على العمليات المالية (شراء، تحويل، سحب، إيداع).'**
  String get smsDisclosureDetect;

  /// Disclosure point: non-financial messages are discarded, not stored.
  ///
  /// In ar, this message translates to:
  /// **'تُستبعد على جهازك الرسائل التي لا تبدو مالية — مثل الرسائل الشخصية ورموز التحقق — ولا تُخزَّن. هذا الفحص آلي وقد يحتفظ أحيانًا برسالة عن طريق الخطأ، ويمكنك حذفها من قِرش. وتُخزَّن الرسائل المحتفَظ بها مشفّرة على جهازك، وقد تُعالَج في الخلفية.'**
  String get smsDisclosureFilter;

  /// Disclosure point: parsing happens on-device.
  ///
  /// In ar, this message translates to:
  /// **'عند إيقاف «التحليل الذكي والمزامنة السحابية» تُقرأ الرسائل على جهازك فقط. وإذا فعّلته، تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش وقد يحلّلها Google Gemini، بعد حذف أرقام البطاقات والحسابات والهواتف والآيبان والرموز، وإخفاء ما يُتعرَّف عليه من أسماء وعناوين بريد إلكتروني وأرقام مرجعية. يبقى في النص المبلغ والتاجر والتاريخ والرصيد وآخر أرقام البطاقة، لذا يظل معلومات مالية شخصية تخصّك.'**
  String get smsDisclosureOnDevice;

  /// Disclosure point: cloud sync is a separate, off-by-default consent.
  ///
  /// In ar, this message translates to:
  /// **'«التحليل الذكي والمزامنة السحابية» خيار منفصل عن هذا الإذن، ويبقى متوقفًا ما لم توافق عليه، ويمكنك سحب موافقتك في أي وقت من الإعدادات ← الخصوصية.'**
  String get smsDisclosureCloud;

  /// Disclosure point: how to turn the feature off or revoke the permission.
  ///
  /// In ar, this message translates to:
  /// **'تقدر توقف القراءة التلقائية من إعدادات قِرش، أو تسحب الإذن من إعدادات الجهاز، في أي وقت.'**
  String get smsDisclosureControl;

  /// Decline button on the SMS prominent disclosure.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get smsDisclosureDecline;

  /// Affirmative button that proceeds to the system permission dialog.
  ///
  /// In ar, this message translates to:
  /// **'موافق، اطلب الإذن'**
  String get smsDisclosureAccept;

  /// No description provided for @couponsForYouSection.
  ///
  /// In ar, this message translates to:
  /// **'لأماكن تتسوق منها'**
  String get couponsForYouSection;

  /// No description provided for @couponsForYouSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'مطابقة تمت على هذا الجهاز من مصروفاتك. لا يُرسَل أي شيء منها لأي مكان.'**
  String get couponsForYouSubtitle;

  /// No description provided for @couponsStoresSection.
  ///
  /// In ar, this message translates to:
  /// **'المتاجر'**
  String get couponsStoresSection;

  /// No description provided for @couponsStoresSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'متاجر لديها عروض سارية.'**
  String get couponsStoresSubtitle;

  /// No description provided for @couponsMerchantOffers.
  ///
  /// In ar, this message translates to:
  /// **'عروض {merchant}'**
  String couponsMerchantOffers(String merchant);

  /// No description provided for @couponsMerchantEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض سارية هنا الآن'**
  String get couponsMerchantEmptyTitle;

  /// No description provided for @couponsMerchantEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'لا عروض لهذا المتجر حاليًا. تابعنا لاحقًا.'**
  String get couponsMerchantEmptyBody;

  /// No description provided for @couponsPersonalizationTitle.
  ///
  /// In ar, this message translates to:
  /// **'رتّب العروض حسب أماكن تسوقك'**
  String get couponsPersonalizationTitle;

  /// No description provided for @couponsPersonalizationBody.
  ///
  /// In ar, this message translates to:
  /// **'يطابق قِرش عملياتك مع المتاجر على هذا الجهاز ويعرض عروضها أولًا. مصروفاتك لا تغادر هاتفك من أجل هذا، ولا تُرسَل للمتاجر.'**
  String get couponsPersonalizationBody;

  /// No description provided for @couponsPersonalizationOff.
  ///
  /// In ar, this message translates to:
  /// **'مُعطّل — ترتيب العروض واحد للجميع.'**
  String get couponsPersonalizationOff;

  /// No description provided for @couponsPersonalizationOn.
  ///
  /// In ar, this message translates to:
  /// **'مُفعّل — عروض المتاجر التي تستخدمها تظهر أولًا.'**
  String get couponsPersonalizationOn;

  /// No description provided for @couponsValuePercent.
  ///
  /// In ar, this message translates to:
  /// **'خصم {percent}%'**
  String couponsValuePercent(String percent);

  /// No description provided for @couponsValueFixed.
  ///
  /// In ar, this message translates to:
  /// **'خصم {amount}'**
  String couponsValueFixed(String amount);

  /// No description provided for @couponsValueFreeShipping.
  ///
  /// In ar, this message translates to:
  /// **'توصيل مجاني'**
  String get couponsValueFreeShipping;

  /// No description provided for @couponsValueMinSpend.
  ///
  /// In ar, this message translates to:
  /// **'عند {amount} أو أكثر'**
  String couponsValueMinSpend(String amount);

  /// No description provided for @couponsValueUpTo.
  ///
  /// In ar, this message translates to:
  /// **'حتى {amount}'**
  String couponsValueUpTo(String amount);

  /// No description provided for @couponsVerifiedByUs.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق منه قِرش'**
  String get couponsVerifiedByUs;

  /// No description provided for @couponsVerifiedByProvider.
  ///
  /// In ar, this message translates to:
  /// **'مؤكَّد من المزوّد'**
  String get couponsVerifiedByProvider;

  /// No description provided for @couponsUnverified.
  ///
  /// In ar, this message translates to:
  /// **'غير مُتحقَّق منه'**
  String get couponsUnverified;

  /// No description provided for @savingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'ما وفّرته'**
  String get savingsTitle;

  /// No description provided for @savingsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مبالغ موفَّرة بعد'**
  String get savingsEmptyTitle;

  /// No description provided for @savingsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'عند استخدامك عرضًا وتأكيده، سيظهر هنا.'**
  String get savingsEmptyBody;

  /// No description provided for @savingsVerifiedLabel.
  ///
  /// In ar, this message translates to:
  /// **'مؤكَّد من المتجر'**
  String get savingsVerifiedLabel;

  /// No description provided for @savingsEstimatedLabel.
  ///
  /// In ar, this message translates to:
  /// **'تقديري'**
  String get savingsEstimatedLabel;

  /// No description provided for @savingsSelfReportedLabel.
  ///
  /// In ar, this message translates to:
  /// **'بتأكيدك أنت'**
  String get savingsSelfReportedLabel;

  /// No description provided for @savingsBreakdownNote.
  ///
  /// In ar, this message translates to:
  /// **'نفصل هذه الأرقام لأنها ليست بنفس درجة التأكيد. المؤكَّد فقط هو ما أبلغنا به المتجر.'**
  String get savingsBreakdownNote;

  /// No description provided for @savingsCurrencyNote.
  ///
  /// In ar, this message translates to:
  /// **'العملات لا تُجمع معًا.'**
  String get savingsCurrencyNote;

  /// No description provided for @savingsConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'هل استخدمت هذا العرض؟'**
  String get savingsConfirmTitle;

  /// No description provided for @savingsConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'أدخل قيمة طلبك لنحسب ما وفّرته. الحساب يتم على جهازك ولا يُرسَل لأي مكان.'**
  String get savingsConfirmBody;

  /// No description provided for @savingsConfirmAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة الطلب'**
  String get savingsConfirmAmountLabel;

  /// No description provided for @savingsConfirmAction.
  ///
  /// In ar, this message translates to:
  /// **'احسب'**
  String get savingsConfirmAction;

  /// No description provided for @savingsCannotCompute.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكننا حساب رقم دقيق لهذا العرض، فلن نعرض رقمًا.'**
  String get savingsCannotCompute;

  /// No description provided for @savingsReversedNote.
  ///
  /// In ar, this message translates to:
  /// **'أُلغي هذا المبلغ بعد أن تراجع المتجر عن العملية.'**
  String get savingsReversedNote;

  /// Label above a third-party advertisement, distinguishing it from Qirsh's own offers.
  ///
  /// In ar, this message translates to:
  /// **'إعلان'**
  String get adLabel;

  /// Settings toggle enabling Android automatic bank-SMS capture.
  ///
  /// In ar, this message translates to:
  /// **'الالتقاط التلقائي لرسائل البنك'**
  String get smsAutoCaptureTitle;

  /// No description provided for @smsAutoCaptureSubtitleOff.
  ///
  /// In ar, this message translates to:
  /// **'مطفأ — أضف عملياتك يدويًا أو بالمشاركة'**
  String get smsAutoCaptureSubtitleOff;

  /// No description provided for @smsAutoCaptureSubtitleOn.
  ///
  /// In ar, this message translates to:
  /// **'يعمل — تُقرأ رسائل البنك الواردة على جهازك'**
  String get smsAutoCaptureSubtitleOn;

  /// Settings subtitle for the Android automatic SMS capture switch when it is on AND Smart Analysis & Cloud Sync (cloud + AI consent) is accepted: captured messages may leave the device, so it must not say 'on your device'.
  ///
  /// In ar, this message translates to:
  /// **'يعمل — تُرسَل رسائل البنك بعد حذف الأرقام الحساسة إلى خوادم قِرش وقد يحلّلها Google Gemini'**
  String get smsAutoCaptureSubtitleOnSmart;

  /// No description provided for @smsAutoCaptureSubtitleBlocked.
  ///
  /// In ar, this message translates to:
  /// **'تم رفض الإذن — افتح إعدادات النظام للسماح'**
  String get smsAutoCaptureSubtitleBlocked;

  /// No description provided for @smsAutoCaptureOpenSettings.
  ///
  /// In ar, this message translates to:
  /// **'فتح إعدادات النظام'**
  String get smsAutoCaptureOpenSettings;

  /// No description provided for @smsAutoCaptureDeniedTitle.
  ///
  /// In ar, this message translates to:
  /// **'لم يُمنح الإذن'**
  String get smsAutoCaptureDeniedTitle;

  /// No description provided for @smsAutoCaptureDeniedBody.
  ///
  /// In ar, this message translates to:
  /// **'الالتقاط التلقائي يحتاج إذن قراءة الرسائل الواردة. تقدر تكمل بالإضافة اليدوية أو بمشاركة الرسالة مع قرش.'**
  String get smsAutoCaptureDeniedBody;

  /// Accurate description of what Qirsh does and does not read.
  ///
  /// In ar, this message translates to:
  /// **'على أندرويد، قرش يقرأ الرسائل الواردة فقط بعد ما تشغّل الالتقاط التلقائي وتمنح الإذن. لا يقرأ إشعارات تطبيقات البنوك، ولا يفتح أرشيف رسائلك.'**
  String get smsCaptureTrustNotice;

  /// Generic cancel action in a dialog.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get commonCancel;

  /// No description provided for @helpTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف تستخدم قِرش'**
  String get helpTitle;

  /// No description provided for @helpSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'دليل مختصر لأهم ما يمكنك فعله في التطبيق.'**
  String get helpSubtitle;

  /// No description provided for @helpSettingsTile.
  ///
  /// In ar, this message translates to:
  /// **'كيف تستخدم قِرش'**
  String get helpSettingsTile;

  /// No description provided for @helpSettingsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'دليل الاستخدام والأسئلة الشائعة'**
  String get helpSettingsSubtitle;

  /// No description provided for @helpSectionBasics.
  ///
  /// In ar, this message translates to:
  /// **'الأساسيات'**
  String get helpSectionBasics;

  /// No description provided for @helpSectionReports.
  ///
  /// In ar, this message translates to:
  /// **'التقارير والتحليلات'**
  String get helpSectionReports;

  /// No description provided for @helpSectionPlanning.
  ///
  /// In ar, this message translates to:
  /// **'التخطيط'**
  String get helpSectionPlanning;

  /// No description provided for @helpSectionPrivacy.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية والبيانات'**
  String get helpSectionPrivacy;

  /// No description provided for @helpAddTransactionTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل عملية'**
  String get helpAddTransactionTitle;

  /// No description provided for @helpAddTransactionBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط زر الإضافة في الشاشة الرئيسية، ثم اختر الإضافة اليدوية أو الصق نص رسالة البنك. يقرأ قِرش الرسالة ويستخرج المبلغ والتاجر والتاريخ، وتبقى لك الكلمة الأخيرة قبل الحفظ.'**
  String get helpAddTransactionBody;

  /// No description provided for @helpSmartInboxTitle.
  ///
  /// In ar, this message translates to:
  /// **'صندوق الوارد الذكي'**
  String get helpSmartInboxTitle;

  /// No description provided for @helpSmartInboxBody.
  ///
  /// In ar, this message translates to:
  /// **'العمليات التي يلتقطها قِرش من رسائل البنك تصل هنا أولًا. راجعها وأكّدها أو عدّل تصنيفها، فتنتقل بعدها إلى سجل عملياتك.'**
  String get helpSmartInboxBody;

  /// No description provided for @helpCategoriesTitle.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get helpCategoriesTitle;

  /// No description provided for @helpCategoriesBody.
  ///
  /// In ar, this message translates to:
  /// **'لكل عملية تصنيف يحدد مكانها في التقارير والميزانيات. غيّر التصنيف من تفاصيل العملية، ويتعلّم قِرش اختيارك للمتجر نفسه مستقبلًا.'**
  String get helpCategoriesBody;

  /// No description provided for @helpPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الفترة'**
  String get helpPeriodTitle;

  /// No description provided for @helpPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'أعلى قوائم العمليات والتقارير تجد مُحدِّد الفترة: اليوم، الأسبوع، الشهر، السنة، أو مدى مخصص. كل الأرقام في الشاشة تتبع الفترة المختارة.'**
  String get helpPeriodBody;

  /// No description provided for @helpAnnualTitle.
  ///
  /// In ar, this message translates to:
  /// **'التقرير السنوي'**
  String get helpAnnualTitle;

  /// No description provided for @helpAnnualBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر «هذه السنة» أو «السنة الماضية» من مُحدِّد الفترة لتقرأ سلوكك المالي على مدار سنة كاملة: الإجمالي، التصنيفات، الاتجاهات، وأكثر المتاجر إنفاقًا.'**
  String get helpAnnualBody;

  /// No description provided for @helpAccountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والبطاقات'**
  String get helpAccountsTitle;

  /// No description provided for @helpAccountsBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف حسابًا لكل محفظة أو بنك، ولكل حساب عملته الخاصة. تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافتها يدويًا.'**
  String get helpAccountsBody;

  /// No description provided for @helpBudgetsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات'**
  String get helpBudgetsTitle;

  /// No description provided for @helpBudgetsBody.
  ///
  /// In ar, this message translates to:
  /// **'حدد سقفًا لتصنيف أو لكل المصروفات، واختر دوريته. ينبّهك قِرش عند بلوغ 80% ثم عند التجاوز.'**
  String get helpBudgetsBody;

  /// No description provided for @helpGoalsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأهداف'**
  String get helpGoalsTitle;

  /// No description provided for @helpGoalsBody.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ هدف ادخار بمبلغ وموعد، ثم أضف إليه مساهمات. يحسب قِرش المبلغ اليومي الموصى به ليبقى الهدف في مساره.'**
  String get helpGoalsBody;

  /// No description provided for @helpPrivacyTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحكّمك في بياناتك'**
  String get helpPrivacyTitle;

  /// No description provided for @helpPrivacyBody.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك المالية محفوظة على جهازك ومشفّرة. من شاشة الخصوصية يمكنك التحكم في المعالجة السحابية والتحليل بالذكاء الاصطناعي، وسحب موافقتك في أي وقت.'**
  String get helpPrivacyBody;

  /// No description provided for @helpBackupTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي والاستعادة'**
  String get helpBackupTitle;

  /// No description provided for @helpBackupBody.
  ///
  /// In ar, this message translates to:
  /// **'صدّر نسخة مشفّرة من بياناتك واحتفظ بها، أو استعدها على جهاز آخر. تتم المعاينة على جهازك قبل أي كتابة، ولا تخرج كلمة المرور منه.'**
  String get helpBackupBody;

  /// No description provided for @helpFooter.
  ///
  /// In ar, this message translates to:
  /// **'لم تجد إجابتك؟ راسلنا من شاشة الإعدادات.'**
  String get helpFooter;

  /// No description provided for @coachMarkNext.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get coachMarkNext;

  /// No description provided for @coachMarkDone.
  ///
  /// In ar, this message translates to:
  /// **'تمام'**
  String get coachMarkDone;

  /// No description provided for @coachMarkSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّي'**
  String get coachMarkSkip;

  /// No description provided for @coachDashboardAddTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجّل أول عملية'**
  String get coachDashboardAddTitle;

  /// No description provided for @coachDashboardAddBody.
  ///
  /// In ar, this message translates to:
  /// **'من زر الإضافة تسجّل عملية يدويًا أو تلصق نص رسالة البنك ليقرأها قِرش نيابةً عنك.'**
  String get coachDashboardAddBody;

  /// No description provided for @coachDashboardPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر الفترة'**
  String get coachDashboardPeriodTitle;

  /// No description provided for @coachDashboardPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'اختار اليوم أو الأسبوع أو الشهر لتغيير الملخص المالي المعروض.'**
  String get coachDashboardPeriodBody;

  /// No description provided for @coachDashboardInboxTitle.
  ///
  /// In ar, this message translates to:
  /// **'صندوق الوارد الذكي'**
  String get coachDashboardInboxTitle;

  /// No description provided for @coachDashboardInboxBody.
  ///
  /// In ar, this message translates to:
  /// **'ما يلتقطه قِرش من رسائل البنك ينتظرك هنا للمراجعة قبل أن يدخل سجلك.'**
  String get coachDashboardInboxBody;

  /// No description provided for @coachDashboardHelpTitle.
  ///
  /// In ar, this message translates to:
  /// **'الدليل متاح دائمًا'**
  String get coachDashboardHelpTitle;

  /// No description provided for @coachDashboardHelpBody.
  ///
  /// In ar, this message translates to:
  /// **'تجد «كيف تستخدم قِرش» في الإعدادات في أي وقت، ويمكنك إعادة هذه الجولة من هناك.'**
  String get coachDashboardHelpBody;

  /// No description provided for @helpReplayTour.
  ///
  /// In ar, this message translates to:
  /// **'إعادة الجولة التعريفية'**
  String get helpReplayTour;

  /// No description provided for @helpReplayTourDone.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر الجولة التعريفية من جديد.'**
  String get helpReplayTourDone;

  /// No description provided for @setLoadingCountries.
  ///
  /// In ar, this message translates to:
  /// **'تحميل الدول...'**
  String get setLoadingCountries;

  /// No description provided for @setLoadingCurrencies.
  ///
  /// In ar, this message translates to:
  /// **'تحميل العملات...'**
  String get setLoadingCurrencies;

  /// No description provided for @setCountry.
  ///
  /// In ar, this message translates to:
  /// **'الدولة'**
  String get setCountry;

  /// No description provided for @setBaseCurrency.
  ///
  /// In ar, this message translates to:
  /// **'العملة الأساسية'**
  String get setBaseCurrency;

  /// No description provided for @bfBudgetAlert.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه الميزانية'**
  String get bfBudgetAlert;

  /// No description provided for @bfBudgetAlertHint.
  ///
  /// In ar, this message translates to:
  /// **'ننبّهك عند بلوغ إنفاقك هذه النسبة من الميزانية.'**
  String get bfBudgetAlertHint;

  /// No description provided for @bfBudgetAlertValue.
  ///
  /// In ar, this message translates to:
  /// **'{percent}٪ من الميزانية'**
  String bfBudgetAlertValue(String percent);

  /// No description provided for @setLanguage.
  ///
  /// In ar, this message translates to:
  /// **'اللغة'**
  String get setLanguage;

  /// No description provided for @setName.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get setName;

  /// No description provided for @setNameInApp.
  ///
  /// In ar, this message translates to:
  /// **'اسمك في التطبيق'**
  String get setNameInApp;

  /// No description provided for @setAccountData.
  ///
  /// In ar, this message translates to:
  /// **'بيانات حسابك'**
  String get setAccountData;

  /// No description provided for @setMobileNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم الموبايل'**
  String get setMobileNumber;

  /// No description provided for @setAddYourNumber.
  ///
  /// In ar, this message translates to:
  /// **'أضف رقمك'**
  String get setAddYourNumber;

  /// No description provided for @setAppearance.
  ///
  /// In ar, this message translates to:
  /// **'المظهر'**
  String get setAppearance;

  /// No description provided for @setAppearanceSub.
  ///
  /// In ar, this message translates to:
  /// **'فاتح، داكن، أو حسب النظام'**
  String get setAppearanceSub;

  /// No description provided for @setAccountsAndDues.
  ///
  /// In ar, this message translates to:
  /// **'حساباتك والتزاماتك'**
  String get setAccountsAndDues;

  /// No description provided for @setSyncConflicts.
  ///
  /// In ar, this message translates to:
  /// **'تعارضات المزامنة'**
  String get setSyncConflicts;

  /// No description provided for @setSyncConflictsSub.
  ///
  /// In ar, this message translates to:
  /// **'عناصر عُدّلت على أكثر من جهاز — بحاجة لقرارك'**
  String get setSyncConflictsSub;

  /// No description provided for @setAccountsWallets.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والمحافظ'**
  String get setAccountsWallets;

  /// No description provided for @setAccountsWalletsSub.
  ///
  /// In ar, this message translates to:
  /// **'حسابات متعددة، كل واحد بعملته الخاصة'**
  String get setAccountsWalletsSub;

  /// No description provided for @setAllCards.
  ///
  /// In ar, this message translates to:
  /// **'كل البطاقات'**
  String get setAllCards;

  /// No description provided for @setAllCardsSub.
  ///
  /// In ar, this message translates to:
  /// **'نظرة عامة على بطاقاتك مجمّعة حسب الحساب'**
  String get setAllCardsSub;

  /// No description provided for @setSubsAndBills.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والفواتير'**
  String get setSubsAndBills;

  /// No description provided for @setSubsAndBillsSub.
  ///
  /// In ar, this message translates to:
  /// **'التزاماتك الدورية ومواعيد السداد'**
  String get setSubsAndBillsSub;

  /// No description provided for @setPlans.
  ///
  /// In ar, this message translates to:
  /// **'الخطط'**
  String get setPlans;

  /// No description provided for @setPlansSub.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية رحلة أو مناسبة تتابع نفسها'**
  String get setPlansSub;

  /// No description provided for @setToolsAndSettings.
  ///
  /// In ar, this message translates to:
  /// **'أدوات وإعدادات'**
  String get setToolsAndSettings;

  /// No description provided for @setCategories.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get setCategories;

  /// No description provided for @setCategoriesSub.
  ///
  /// In ar, this message translates to:
  /// **'نظم المصروفات والدخل والتحويلات'**
  String get setCategoriesSub;

  /// No description provided for @setAchievements.
  ///
  /// In ar, this message translates to:
  /// **'الإنجازات والمستوى'**
  String get setAchievements;

  /// No description provided for @setAchievementsSub.
  ///
  /// In ar, this message translates to:
  /// **'شارات ومستويات تشجع عادة المتابعة'**
  String get setAchievementsSub;

  /// No description provided for @setCurrencyRepair.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد عملة الميزانيات والأهداف'**
  String get setCurrencyRepair;

  /// No description provided for @setCurrencyRepairSub.
  ///
  /// In ar, this message translates to:
  /// **'راجع عملة بيانات التخطيط القديمة بأمان'**
  String get setCurrencyRepairSub;

  /// No description provided for @setAppleShortcut.
  ///
  /// In ar, this message translates to:
  /// **'اختصار آبل'**
  String get setAppleShortcut;

  /// No description provided for @setAppleShortcutSub.
  ///
  /// In ar, this message translates to:
  /// **'مرر رسائل البنك إلى قرش عبر Shortcuts'**
  String get setAppleShortcutSub;

  /// No description provided for @setRewardsAndSupport.
  ///
  /// In ar, this message translates to:
  /// **'المكافآت والدعم'**
  String get setRewardsAndSupport;

  /// No description provided for @setInviteFriends.
  ///
  /// In ar, this message translates to:
  /// **'دعوة الأصدقاء'**
  String get setInviteFriends;

  /// No description provided for @setInviteFriendsSub.
  ///
  /// In ar, this message translates to:
  /// **'شارك رمز دعوتك واكسب تقارير بدون إعلانات'**
  String get setInviteFriendsSub;

  /// No description provided for @setAdPrivacyOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات خصوصية الإعلانات'**
  String get setAdPrivacyOptions;

  /// No description provided for @setAdPrivacyOptionsSub.
  ///
  /// In ar, this message translates to:
  /// **'إدارة موافقتك على الإعلانات'**
  String get setAdPrivacyOptionsSub;

  /// No description provided for @setContactUs.
  ///
  /// In ar, this message translates to:
  /// **'تواصل معنا'**
  String get setContactUs;

  /// No description provided for @setContactUsSub.
  ///
  /// In ar, this message translates to:
  /// **'الدعم الفني والإجابة على استفساراتك'**
  String get setContactUsSub;

  /// No description provided for @setAboutQirsh.
  ///
  /// In ar, this message translates to:
  /// **'عن قرش'**
  String get setAboutQirsh;

  /// No description provided for @setAboutQirshSub.
  ///
  /// In ar, this message translates to:
  /// **'معلومات التطبيق والإصدار'**
  String get setAboutQirshSub;

  /// No description provided for @setCaptureStatus.
  ///
  /// In ar, this message translates to:
  /// **'رصد العمليات'**
  String get setCaptureStatus;

  /// No description provided for @setCaptureStatusSub.
  ///
  /// In ar, this message translates to:
  /// **'حالة الربط مع رسائل البنك واختصار آبل'**
  String get setCaptureStatusSub;

  /// No description provided for @setConfirmCaptured.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد العمليات الملتقطة'**
  String get setConfirmCaptured;

  /// No description provided for @setNotifyOnCapture.
  ///
  /// In ar, this message translates to:
  /// **'إشعار عند التقاط عملية'**
  String get setNotifyOnCapture;

  /// No description provided for @setHideOnLockScreen.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء التفاصيل الحساسة على شاشة القفل'**
  String get setHideOnLockScreen;

  /// No description provided for @setYourAlerts.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهاتك'**
  String get setYourAlerts;

  /// No description provided for @setQirshMessages.
  ///
  /// In ar, this message translates to:
  /// **'رسائل ونصائح قرش'**
  String get setQirshMessages;

  /// No description provided for @setBudgetAlerts.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهات الميزانية'**
  String get setBudgetAlerts;

  /// No description provided for @setBudgetOverAlert.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه تجاوز الميزانية'**
  String get setBudgetOverAlert;

  /// No description provided for @setDailyReminder.
  ///
  /// In ar, this message translates to:
  /// **'التذكير اليومي'**
  String get setDailyReminder;

  /// No description provided for @setDailyReminderTime.
  ///
  /// In ar, this message translates to:
  /// **'كل يوم الساعة 10 مساءً'**
  String get setDailyReminderTime;

  /// No description provided for @setWeeklyReport.
  ///
  /// In ar, this message translates to:
  /// **'التقرير الأسبوعي'**
  String get setWeeklyReport;

  /// No description provided for @setBillReminders.
  ///
  /// In ar, this message translates to:
  /// **'تذكير الاشتراكات والفواتير'**
  String get setBillReminders;

  /// No description provided for @setGoalCelebrations.
  ///
  /// In ar, this message translates to:
  /// **'احتفالات الأهداف'**
  String get setGoalCelebrations;

  /// No description provided for @setAchievementAlerts.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهات الإنجازات'**
  String get setAchievementAlerts;

  /// No description provided for @setQuietHours.
  ///
  /// In ar, this message translates to:
  /// **'ساعات الهدوء'**
  String get setQuietHours;

  /// No description provided for @setDisabled.
  ///
  /// In ar, this message translates to:
  /// **'معطّل'**
  String get setDisabled;

  /// No description provided for @setEditQuietHours.
  ///
  /// In ar, this message translates to:
  /// **'تعديل وقت الهدوء'**
  String get setEditQuietHours;

  /// No description provided for @setNotificationTools.
  ///
  /// In ar, this message translates to:
  /// **'أدوات الإشعارات'**
  String get setNotificationTools;

  /// No description provided for @setTestNotifications.
  ///
  /// In ar, this message translates to:
  /// **'اختبار إشعارات قرش'**
  String get setTestNotifications;

  /// No description provided for @setTestNotificationsSub.
  ///
  /// In ar, this message translates to:
  /// **'أرسل إشعارًا تجريبيًا إلى هذا الجهاز'**
  String get setTestNotificationsSub;

  /// No description provided for @setMessageCentre.
  ///
  /// In ar, this message translates to:
  /// **'مركز رسائل قرش'**
  String get setMessageCentre;

  /// No description provided for @setMessageCentreSub.
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات والحملات والإعلانات السابقة'**
  String get setMessageCentreSub;

  /// No description provided for @setDataTransfer.
  ///
  /// In ar, this message translates to:
  /// **'نقل البيانات'**
  String get setDataTransfer;

  /// No description provided for @setDataTransferSub.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك المالية تظل تحت سيطرتك'**
  String get setDataTransferSub;

  /// No description provided for @setImportFile.
  ///
  /// In ar, this message translates to:
  /// **'استيراد ملف'**
  String get setImportFile;

  /// No description provided for @setImportFileSub.
  ///
  /// In ar, this message translates to:
  /// **'CSV من أي تطبيق أو ZIP صادر من قرش'**
  String get setImportFileSub;

  /// No description provided for @setExportCsv.
  ///
  /// In ar, this message translates to:
  /// **'تصدير العمليات CSV'**
  String get setExportCsv;

  /// No description provided for @setExportCsvSub.
  ///
  /// In ar, this message translates to:
  /// **'ملف بسيط لكل عملياتك'**
  String get setExportCsvSub;

  /// No description provided for @setExportAll.
  ///
  /// In ar, this message translates to:
  /// **'تصدير كل بيانات قرش'**
  String get setExportAll;

  /// No description provided for @setExportAllSub.
  ///
  /// In ar, this message translates to:
  /// **'حزمة ZIP قابلة للنقل والاستعادة'**
  String get setExportAllSub;

  /// No description provided for @setSecurityPrivacy.
  ///
  /// In ar, this message translates to:
  /// **'الأمان والخصوصية'**
  String get setSecurityPrivacy;

  /// No description provided for @setEncryptedDbPart1.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك على الجهاز مخزّنة بقاعدة بيانات مشفّرة، '**
  String get setEncryptedDbPart1;

  /// No description provided for @setEncryptedDbPart2.
  ///
  /// In ar, this message translates to:
  /// **'ومفتاحها محفوظ في خزنة النظام'**
  String get setEncryptedDbPart2;

  /// No description provided for @setPrivacyAndData.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية والبيانات'**
  String get setPrivacyAndData;

  /// No description provided for @setPrivacyAndDataSub.
  ///
  /// In ar, this message translates to:
  /// **'أمان بياناتك وسياسة الخصوصية'**
  String get setPrivacyAndDataSub;

  /// No description provided for @setHideAmounts.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء الأرقام في الواجهة'**
  String get setHideAmounts;

  /// No description provided for @setExitAndErase.
  ///
  /// In ar, this message translates to:
  /// **'الخروج وحذف البيانات'**
  String get setExitAndErase;

  /// No description provided for @setExitAndEraseSub.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات لا يمكن التراجع عن بعضها'**
  String get setExitAndEraseSub;

  /// No description provided for @setStartOver.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ من جديد'**
  String get setStartOver;

  /// No description provided for @setStartOverSub.
  ///
  /// In ar, this message translates to:
  /// **'امسح البيانات المحلية مع إبقاء الحساب نشطًا'**
  String get setStartOverSub;

  /// No description provided for @setSignOut.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get setSignOut;

  /// No description provided for @setDeleteAccount.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب وكل بياناتي'**
  String get setDeleteAccount;

  /// No description provided for @setDeleteAccountSub.
  ///
  /// In ar, this message translates to:
  /// **'إجراء نهائي يتطلب تأكيدك'**
  String get setDeleteAccountSub;

  /// No description provided for @setTestNotificationSent.
  ///
  /// In ar, this message translates to:
  /// **'أرسلنا إشعاراً تجريبياً من قرش.'**
  String get setTestNotificationSent;

  /// No description provided for @setTestNotificationFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الإشعار التجريبي.'**
  String get setTestNotificationFailed;

  /// No description provided for @setUnsyncedData.
  ///
  /// In ar, this message translates to:
  /// **'بيانات غير محفوظة سحابيًا'**
  String get setUnsyncedData;

  /// No description provided for @setCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get setCancel;

  /// No description provided for @setSignOutDiscard.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج وحذف غير المحفوظ'**
  String get setSignOutDiscard;

  /// No description provided for @setUnsyncedCheckFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحقق من البيانات غير المحفوظة. حاول مجدداً.'**
  String get setUnsyncedCheckFailed;

  /// No description provided for @rebootUpdatingData.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تحديث بياناتك…'**
  String get rebootUpdatingData;

  /// No description provided for @setDataRemovedNotice.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف البيانات من هذا الجهاز'**
  String get setDataRemovedNotice;

  /// No description provided for @smartConsentAiNeedsCloud.
  ///
  /// In ar, this message translates to:
  /// **'فعّل المزامنة السحابية أولاً لاستخدام التحليل الذكي.'**
  String get smartConsentAiNeedsCloud;

  /// No description provided for @setSignOutFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الخروج بأمان. حاول مجدداً.'**
  String get setSignOutFailed;

  /// No description provided for @setPhotoUpdated.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الصورة.'**
  String get setPhotoUpdated;

  /// No description provided for @setSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get setSave;

  /// No description provided for @setCategoriesSheetIntro.
  ///
  /// In ar, this message translates to:
  /// **'أضف أو عدّل التصنيفات التي تظهر في العمليات والتقارير.'**
  String get setCategoriesSheetIntro;

  /// No description provided for @setAddCategory.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تصنيف'**
  String get setAddCategory;

  /// No description provided for @setExpenses.
  ///
  /// In ar, this message translates to:
  /// **'مصروفات'**
  String get setExpenses;

  /// No description provided for @setIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل'**
  String get setIncome;

  /// No description provided for @setTransfers.
  ///
  /// In ar, this message translates to:
  /// **'تحويلات'**
  String get setTransfers;

  /// No description provided for @setEditCategory.
  ///
  /// In ar, this message translates to:
  /// **'تعديل تصنيف'**
  String get setEditCategory;

  /// No description provided for @setCategoryName.
  ///
  /// In ar, this message translates to:
  /// **'اسم التصنيف'**
  String get setCategoryName;

  /// No description provided for @setIncomeCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف دخل'**
  String get setIncomeCategory;

  /// No description provided for @setIcon.
  ///
  /// In ar, this message translates to:
  /// **'الأيقونة'**
  String get setIcon;

  /// No description provided for @setColor.
  ///
  /// In ar, this message translates to:
  /// **'اللون'**
  String get setColor;

  /// No description provided for @setEnterCategoryName.
  ///
  /// In ar, this message translates to:
  /// **'اكتب اسم التصنيف.'**
  String get setEnterCategoryName;

  /// No description provided for @setSaveChanges.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديلات'**
  String get setSaveChanges;

  /// No description provided for @setAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get setAdd;

  /// No description provided for @setDeleteCategoryQ.
  ///
  /// In ar, this message translates to:
  /// **'حذف التصنيف؟'**
  String get setDeleteCategoryQ;

  /// No description provided for @setDeleteCategoryBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم نقل عملياته إلى «أخرى» أو «دخل»، وحذف أي ميزانية مرتبطة به.'**
  String get setDeleteCategoryBody;

  /// No description provided for @setDelete.
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get setDelete;

  /// No description provided for @setQuietHoursNote.
  ///
  /// In ar, this message translates to:
  /// **'نؤجل الإشعارات المجدولة خلال هذه الفترة لأول وقت مسموح.'**
  String get setQuietHoursNote;

  /// No description provided for @setStarts.
  ///
  /// In ar, this message translates to:
  /// **'تبدأ'**
  String get setStarts;

  /// No description provided for @setEnds.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي'**
  String get setEnds;

  /// No description provided for @setAboutApp.
  ///
  /// In ar, this message translates to:
  /// **'عن التطبيق'**
  String get setAboutApp;

  /// No description provided for @setAboutBody.
  ///
  /// In ar, this message translates to:
  /// **'قرش لتتبع المصروفات من رسائل البنك والإدخال اليدوي. يمكنك نقل بياناتك المالية كملفات CSV أو حزمة ZIP من قسم البيانات والخصوصية.'**
  String get setAboutBody;

  /// No description provided for @setOk.
  ///
  /// In ar, this message translates to:
  /// **'تمام'**
  String get setOk;

  /// No description provided for @setSupportBody.
  ///
  /// In ar, this message translates to:
  /// **'للدعم أو الملاحظات انسخ البريد وأرسل لنا تفاصيل المشكلة، نوع الجهاز، وخطوات تكرارها.'**
  String get setSupportBody;

  /// No description provided for @setCopyEmail.
  ///
  /// In ar, this message translates to:
  /// **'نسخ البريد'**
  String get setCopyEmail;

  /// No description provided for @setEraseAllQ.
  ///
  /// In ar, this message translates to:
  /// **'مسح جميع البيانات؟'**
  String get setEraseAllQ;

  /// No description provided for @setEraseAllBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم مسح جميع بياناتك المحلية. لا يمكن التراجع.'**
  String get setEraseAllBody;

  /// No description provided for @setErase.
  ///
  /// In ar, this message translates to:
  /// **'مسح'**
  String get setErase;

  /// No description provided for @setSettingsLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الإعدادات. حاول مرة أخرى بعد قليل.'**
  String get setSettingsLoadFailed;

  /// No description provided for @setSettings.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات'**
  String get setSettings;

  /// No description provided for @setBack.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get setBack;

  /// No description provided for @setThemeAuto.
  ///
  /// In ar, this message translates to:
  /// **'تلقائي'**
  String get setThemeAuto;

  /// No description provided for @setThemeLight.
  ///
  /// In ar, this message translates to:
  /// **'فاتح'**
  String get setThemeLight;

  /// No description provided for @setThemeDark.
  ///
  /// In ar, this message translates to:
  /// **'داكن'**
  String get setThemeDark;

  /// No description provided for @setEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get setEdit;

  /// No description provided for @setAppLockFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تفعيل القفل. تأكد من إعداد بصمة أو رمز للجهاز.'**
  String get setAppLockFailed;

  /// No description provided for @setAppLock.
  ///
  /// In ar, this message translates to:
  /// **'قفل التطبيق'**
  String get setAppLock;

  /// No description provided for @setNoBankMessageYet.
  ///
  /// In ar, this message translates to:
  /// **'لم نرصد أي رسالة بنكية بعد'**
  String get setNoBankMessageYet;

  /// No description provided for @setCaptureEnableFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تفعيل إشعارات رصد البنك'**
  String get setCaptureEnableFailed;

  /// No description provided for @setNoBankMessagesRecently.
  ///
  /// In ar, this message translates to:
  /// **'لم نستقبل رسائل بنكية منذ فترة'**
  String get setNoBankMessagesRecently;

  /// No description provided for @setBankCaptureStatus.
  ///
  /// In ar, this message translates to:
  /// **'حالة رصد رسائل البنك'**
  String get setBankCaptureStatus;

  /// No description provided for @setCheck.
  ///
  /// In ar, this message translates to:
  /// **'تحقق'**
  String get setCheck;

  /// No description provided for @setBackupFirst.
  ///
  /// In ar, this message translates to:
  /// **'خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.'**
  String get setBackupFirst;

  /// No description provided for @setToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get setToday;

  /// No description provided for @bdgError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ'**
  String get bdgError;

  /// No description provided for @bdgTabBudgets.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات'**
  String get bdgTabBudgets;

  /// No description provided for @bdgTabHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل الميزانيات'**
  String get bdgTabHistory;

  /// No description provided for @bdgTabGoals.
  ///
  /// In ar, this message translates to:
  /// **'الأهداف'**
  String get bdgTabGoals;

  /// No description provided for @bdgEmptyBudgetsTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ميزانيات'**
  String get bdgEmptyBudgetsTitle;

  /// No description provided for @bdgEmptyBudgetsBody.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.'**
  String get bdgEmptyBudgetsBody;

  /// No description provided for @bdgEmptyGoalsTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أهداف'**
  String get bdgEmptyGoalsTitle;

  /// No description provided for @bdgEmptyGoalsBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف هدف ادخار ليتابع قِرش تقدمك إلى جانب ميزانياتك.'**
  String get bdgEmptyGoalsBody;

  /// No description provided for @bdgAddGoal.
  ///
  /// In ar, this message translates to:
  /// **'إضافة هدف'**
  String get bdgAddGoal;

  /// No description provided for @bdgEmptyHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'السجل فارغ'**
  String get bdgEmptyHistoryTitle;

  /// No description provided for @bdgEmptyHistoryBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة تحتوي على ميزانيات أو أضف ميزانية جديدة، وسيظهر كل يوم/أسبوع/شهر هنا كسجلّ منفصل.'**
  String get bdgEmptyHistoryBody;

  /// No description provided for @bdgAddBudget.
  ///
  /// In ar, this message translates to:
  /// **'إضافة ميزانية'**
  String get bdgAddBudget;

  /// No description provided for @bdgDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الميزانية؟'**
  String get bdgDeleteTitle;

  /// No description provided for @bdgDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيُحذف سقف الميزانية. لن تتأثر العمليات نفسها.'**
  String get bdgDeleteBody;

  /// No description provided for @bdgDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الميزانية الآن.'**
  String get bdgDeleteFailed;

  /// No description provided for @bdgFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get bdgFilterAll;

  /// No description provided for @bdgFilterDaily.
  ///
  /// In ar, this message translates to:
  /// **'يومي'**
  String get bdgFilterDaily;

  /// No description provided for @bdgFilterWeekly.
  ///
  /// In ar, this message translates to:
  /// **'أسبوعي'**
  String get bdgFilterWeekly;

  /// No description provided for @bdgFilterMonthly.
  ///
  /// In ar, this message translates to:
  /// **'شهري'**
  String get bdgFilterMonthly;

  /// No description provided for @bdgFilterYearly.
  ///
  /// In ar, this message translates to:
  /// **'سنوي'**
  String get bdgFilterYearly;

  /// No description provided for @bdgStatHistoryCount.
  ///
  /// In ar, this message translates to:
  /// **'ميزانيات في السجل'**
  String get bdgStatHistoryCount;

  /// No description provided for @bdgStatTargetSavings.
  ///
  /// In ar, this message translates to:
  /// **'مجموع المدخرات المستهدفة'**
  String get bdgStatTargetSavings;

  /// No description provided for @bdgStatTotalBudgeted.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الميزانيات المرصودة'**
  String get bdgStatTotalBudgeted;

  /// No description provided for @bdgStatActiveGoals.
  ///
  /// In ar, this message translates to:
  /// **'أهداف نشطة'**
  String get bdgStatActiveGoals;

  /// No description provided for @bdgStatProgress.
  ///
  /// In ar, this message translates to:
  /// **'نسبة التقدم'**
  String get bdgStatProgress;

  /// No description provided for @bdgStatTotalSaved.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الادخار'**
  String get bdgStatTotalSaved;

  /// No description provided for @bdgStateSafeF.
  ///
  /// In ar, this message translates to:
  /// **'آمنة'**
  String get bdgStateSafeF;

  /// No description provided for @bdgStateNear.
  ///
  /// In ar, this message translates to:
  /// **'اقتربت'**
  String get bdgStateNear;

  /// No description provided for @bdgStateOverF.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت'**
  String get bdgStateOverF;

  /// No description provided for @bdgBudgetsWord.
  ///
  /// In ar, this message translates to:
  /// **'ميزانيات'**
  String get bdgBudgetsWord;

  /// No description provided for @bdgUsageRate.
  ///
  /// In ar, this message translates to:
  /// **'نسبة الاستهلاك'**
  String get bdgUsageRate;

  /// No description provided for @bdgActualSpend.
  ///
  /// In ar, this message translates to:
  /// **'المصروف الفعلي'**
  String get bdgActualSpend;

  /// No description provided for @bdgBudgetWord.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية'**
  String get bdgBudgetWord;

  /// No description provided for @bdgOver.
  ///
  /// In ar, this message translates to:
  /// **'تجاوز'**
  String get bdgOver;

  /// No description provided for @bdgSafe.
  ///
  /// In ar, this message translates to:
  /// **'آمن'**
  String get bdgSafe;

  /// No description provided for @bdgAllExpenses.
  ///
  /// In ar, this message translates to:
  /// **'كل المصروفات'**
  String get bdgAllExpenses;

  /// No description provided for @bdgCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف'**
  String get bdgCategory;

  /// No description provided for @bdgSpent.
  ///
  /// In ar, this message translates to:
  /// **'مصروف'**
  String get bdgSpent;

  /// No description provided for @bdgRemaining.
  ///
  /// In ar, this message translates to:
  /// **'باقي'**
  String get bdgRemaining;

  /// No description provided for @bdgLimit.
  ///
  /// In ar, this message translates to:
  /// **'الحد'**
  String get bdgLimit;

  /// No description provided for @bdgSaved.
  ///
  /// In ar, this message translates to:
  /// **'وفّرت'**
  String get bdgSaved;

  /// No description provided for @bdgPeriodCurrent.
  ///
  /// In ar, this message translates to:
  /// **'الفترة الحالية'**
  String get bdgPeriodCurrent;

  /// No description provided for @bdgPeriodOver.
  ///
  /// In ar, this message translates to:
  /// **'فترة تجاوزت الحد'**
  String get bdgPeriodOver;

  /// No description provided for @bdgPeriodEnded.
  ///
  /// In ar, this message translates to:
  /// **'فترة منتهية'**
  String get bdgPeriodEnded;

  /// No description provided for @bdgRecordLive.
  ///
  /// In ar, this message translates to:
  /// **'ما زال هذا السجل يُحدَّث حتى نهاية الفترة.'**
  String get bdgRecordLive;

  /// No description provided for @bdgRecordFinal.
  ///
  /// In ar, this message translates to:
  /// **'هذا السجل محسوب من العمليات الفعلية داخل هذه الفترة.'**
  String get bdgRecordFinal;

  /// No description provided for @bdgEditBudget.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الميزانية'**
  String get bdgEditBudget;

  /// No description provided for @bdgPeriodTransactions.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الفترة'**
  String get bdgPeriodTransactions;

  /// No description provided for @bdgNoConfirmedTx.
  ///
  /// In ar, this message translates to:
  /// **'لم تُسجَّل عمليات مؤكدة ضمن هذه الفترة.'**
  String get bdgNoConfirmedTx;

  /// No description provided for @bdgCountedOpenAll.
  ///
  /// In ar, this message translates to:
  /// **'داخلة في الحساب — افتح «العمليات» لعرضها كلها.'**
  String get bdgCountedOpenAll;

  /// No description provided for @bdgDailyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية يومية'**
  String get bdgDailyBudget;

  /// No description provided for @bdgWeeklyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية أسبوعية'**
  String get bdgWeeklyBudget;

  /// No description provided for @bdgYearlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية سنوية'**
  String get bdgYearlyBudget;

  /// No description provided for @bdgMonthlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية شهرية'**
  String get bdgMonthlyBudget;

  /// No description provided for @bdgTransactionWord.
  ///
  /// In ar, this message translates to:
  /// **'عملية'**
  String get bdgTransactionWord;

  /// No description provided for @bdgGoalDone.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل الهدف'**
  String get bdgGoalDone;

  /// No description provided for @bdgEnvelopeTitle.
  ///
  /// In ar, this message translates to:
  /// **'وزّع دخلك على المظاريف'**
  String get bdgEnvelopeTitle;

  /// No description provided for @bdgEnvelopeBody.
  ///
  /// In ar, this message translates to:
  /// **'اكتب راتبك ووزّعه بضغطة — و«قِرش» يحسب لك المتاح كل يوم'**
  String get bdgEnvelopeBody;

  /// No description provided for @bdgMoreTxCounted.
  ///
  /// In ar, this message translates to:
  /// **'باقي {count} عملية داخلة في الحساب — افتح «العمليات» لعرضها كلها.'**
  String bdgMoreTxCounted(int count);

  /// No description provided for @txnError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ'**
  String get txnError;

  /// No description provided for @txnTransactionWord.
  ///
  /// In ar, this message translates to:
  /// **'عملية'**
  String get txnTransactionWord;

  /// No description provided for @txnFilterPending.
  ///
  /// In ar, this message translates to:
  /// **'تصفية: قيد المراجعة'**
  String get txnFilterPending;

  /// No description provided for @txnConfirmAll.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الكل'**
  String get txnConfirmAll;

  /// No description provided for @txnTabTransactions.
  ///
  /// In ar, this message translates to:
  /// **'العمليات'**
  String get txnTabTransactions;

  /// No description provided for @txnTabBills.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get txnTabBills;

  /// No description provided for @txnPendingEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات معلّقة في هذا العرض'**
  String get txnPendingEmptyTitle;

  /// No description provided for @txnPendingEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة أخرى أو غيّر عوامل التصفية لمراجعة عمليات أخرى.'**
  String get txnPendingEmptyBody;

  /// No description provided for @txnEmptyPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات في هذه الفترة'**
  String get txnEmptyPeriodTitle;

  /// No description provided for @txnEmptyPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.'**
  String get txnEmptyPeriodBody;

  /// No description provided for @txnConfirmAllTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد كل العمليات المعلّقة؟'**
  String get txnConfirmAllTitle;

  /// No description provided for @txnConfirm.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get txnConfirm;

  /// No description provided for @txnPickAccount.
  ///
  /// In ar, this message translates to:
  /// **'اختر الحساب'**
  String get txnPickAccount;

  /// No description provided for @txnSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم متجر، تصنيف، مبلغ أو عملة'**
  String get txnSearchHint;

  /// No description provided for @txnClearSearch.
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get txnClearSearch;

  /// No description provided for @txnRangeToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get txnRangeToday;

  /// No description provided for @txnRangeThisWeek.
  ///
  /// In ar, this message translates to:
  /// **'هذا الأسبوع'**
  String get txnRangeThisWeek;

  /// No description provided for @txnRangeThisMonth.
  ///
  /// In ar, this message translates to:
  /// **'هذا الشهر'**
  String get txnRangeThisMonth;

  /// No description provided for @txnRangeLastMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر السابق'**
  String get txnRangeLastMonth;

  /// No description provided for @txnRange7.
  ///
  /// In ar, this message translates to:
  /// **'آخر 7 أيام'**
  String get txnRange7;

  /// No description provided for @txnRange30.
  ///
  /// In ar, this message translates to:
  /// **'آخر 30 يومًا'**
  String get txnRange30;

  /// No description provided for @txnRange90.
  ///
  /// In ar, this message translates to:
  /// **'آخر 90 يومًا'**
  String get txnRange90;

  /// No description provided for @txnRangeThisYear.
  ///
  /// In ar, this message translates to:
  /// **'هذه السنة'**
  String get txnRangeThisYear;

  /// No description provided for @txnRangeLastYear.
  ///
  /// In ar, this message translates to:
  /// **'السنة الماضية'**
  String get txnRangeLastYear;

  /// No description provided for @txnRangeCustom.
  ///
  /// In ar, this message translates to:
  /// **'مخصص'**
  String get txnRangeCustom;

  /// No description provided for @txnPickRange.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة العرض'**
  String get txnPickRange;

  /// No description provided for @txnFrom.
  ///
  /// In ar, this message translates to:
  /// **'من'**
  String get txnFrom;

  /// No description provided for @txnTo.
  ///
  /// In ar, this message translates to:
  /// **'إلى'**
  String get txnTo;

  /// No description provided for @txnApplyCustomRange.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الفترة المخصصة'**
  String get txnApplyCustomRange;

  /// No description provided for @txnKindAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get txnKindAll;

  /// No description provided for @txnKindExpense.
  ///
  /// In ar, this message translates to:
  /// **'مصروفات'**
  String get txnKindExpense;

  /// No description provided for @txnKindIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل'**
  String get txnKindIncome;

  /// No description provided for @txnKindTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويلات'**
  String get txnKindTransfer;

  /// No description provided for @txnPendingReview.
  ///
  /// In ar, this message translates to:
  /// **'قيد المراجعة'**
  String get txnPendingReview;

  /// No description provided for @txnCategory.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف'**
  String get txnCategory;

  /// No description provided for @txnFilterByCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصفية حسب التصنيف'**
  String get txnFilterByCategory;

  /// No description provided for @txnAllCategories.
  ///
  /// In ar, this message translates to:
  /// **'كل التصنيفات'**
  String get txnAllCategories;

  /// No description provided for @txnBillsSubs.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكات'**
  String get txnBillsSubs;

  /// No description provided for @txnBillsInstalments.
  ///
  /// In ar, this message translates to:
  /// **'أقساط'**
  String get txnBillsInstalments;

  /// No description provided for @txnAddSub.
  ///
  /// In ar, this message translates to:
  /// **'إضافة اشتراك'**
  String get txnAddSub;

  /// No description provided for @txnAddInstalment.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسط'**
  String get txnAddInstalment;

  /// No description provided for @txnLearnBills.
  ///
  /// In ar, this message translates to:
  /// **'اعرف أكثر عن الفواتير'**
  String get txnLearnBills;

  /// No description provided for @txnSubsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكاتك، متابعة تلقائية'**
  String get txnSubsEmptyTitle;

  /// No description provided for @txnInstEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'أقساطك، واضحة كل شهر'**
  String get txnInstEmptyTitle;

  /// No description provided for @txnSubsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف اشتراكك يدويًا أو دعه يُكتشف تلقائيًا من العمليات المتكررة.'**
  String get txnSubsEmptyBody;

  /// No description provided for @txnInstEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط بتاريخه وتنبيهه ليظهر في الفواتير قبل الاستحقاق.'**
  String get txnInstEmptyBody;

  /// No description provided for @txnSuggestionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'اقتراحات من العمليات المتكررة'**
  String get txnSuggestionsTitle;

  /// No description provided for @txnHowSubsTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف يتابع قِرش الاشتراكات؟'**
  String get txnHowSubsTitle;

  /// No description provided for @txnHowInstTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف يتابع قِرش الأقساط؟'**
  String get txnHowInstTitle;

  /// No description provided for @txnHowSubsBody.
  ///
  /// In ar, this message translates to:
  /// **'يتابع قِرش الأنماط المتكررة تلقائيًا، ويمكنك أيضًا إضافة اشتراك يدويًا بالمبلغ وتاريخ التجديد والتنبيه.'**
  String get txnHowSubsBody;

  /// No description provided for @txnHowInstBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط يدويًا بالمبلغ وتاريخ الاستحقاق والتنبيه. لاحقًا نضيف المتبقي وعدد الأقساط.'**
  String get txnHowInstBody;

  /// No description provided for @txnTotalMonthlySubs.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الاشتراكات الشهرية'**
  String get txnTotalMonthlySubs;

  /// No description provided for @txnTotalMonthlyInst.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الأقساط الشهرية'**
  String get txnTotalMonthlyInst;

  /// No description provided for @txnActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get txnActive;

  /// No description provided for @txnPerYear.
  ///
  /// In ar, this message translates to:
  /// **'سنويًا'**
  String get txnPerYear;

  /// No description provided for @txnDueToday.
  ///
  /// In ar, this message translates to:
  /// **'مستحق اليوم'**
  String get txnDueToday;

  /// No description provided for @txnPaused.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get txnPaused;

  /// No description provided for @txnCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغي'**
  String get txnCancelled;

  /// No description provided for @txnCycleWeekly.
  ///
  /// In ar, this message translates to:
  /// **'أسبوعي'**
  String get txnCycleWeekly;

  /// No description provided for @txnCycleMonthly.
  ///
  /// In ar, this message translates to:
  /// **'شهري'**
  String get txnCycleMonthly;

  /// No description provided for @txnCycleYearly.
  ///
  /// In ar, this message translates to:
  /// **'سنوي'**
  String get txnCycleYearly;

  /// No description provided for @txnTotalValueLabel.
  ///
  /// In ar, this message translates to:
  /// **'القيمة الكلية: '**
  String get txnTotalValueLabel;

  /// No description provided for @txnPaidManuallyLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع يدويًا: '**
  String get txnPaidManuallyLabel;

  /// No description provided for @txnAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get txnAdd;

  /// No description provided for @txnBillsAndSubs.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير والاشتراكات'**
  String get txnBillsAndSubs;

  /// No description provided for @txnPeriodSpendTotal.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مصروفات الفترة'**
  String get txnPeriodSpendTotal;

  /// No description provided for @txnActiveMonthlySpend.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الصرف الشهري النشط'**
  String get txnActiveMonthlySpend;

  /// No description provided for @txnTxForPeriod.
  ///
  /// In ar, this message translates to:
  /// **'عملية للفترة'**
  String get txnTxForPeriod;

  /// No description provided for @txnTotalSpent.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المصروف'**
  String get txnTotalSpent;

  /// No description provided for @txnActiveSub.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك نشط'**
  String get txnActiveSub;

  /// No description provided for @txnRunningInst.
  ///
  /// In ar, this message translates to:
  /// **'قسط جاري'**
  String get txnRunningInst;

  /// No description provided for @txnYearlyTotal.
  ///
  /// In ar, this message translates to:
  /// **'المجموع سنويًا'**
  String get txnYearlyTotal;

  /// No description provided for @txnSmartInbox.
  ///
  /// In ar, this message translates to:
  /// **'صندوق المراجعة الذكي'**
  String get txnSmartInbox;

  /// No description provided for @txnReviewTx.
  ///
  /// In ar, this message translates to:
  /// **'راجع العملية'**
  String get txnReviewTx;

  /// No description provided for @txnHide.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء'**
  String get txnHide;

  /// No description provided for @txnSuspectTxPlural.
  ///
  /// In ar, this message translates to:
  /// **'عمليات مشبوهة'**
  String get txnSuspectTxPlural;

  /// No description provided for @txnDismissAll.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل الكل'**
  String get txnDismissAll;

  /// No description provided for @txnNoSuspectTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مشبوهة'**
  String get txnNoSuspectTx;

  /// No description provided for @txnSimilarExists.
  ///
  /// In ar, this message translates to:
  /// **'عملية مشابهة موجودة'**
  String get txnSimilarExists;

  /// No description provided for @txnSimilarBody.
  ///
  /// In ar, this message translates to:
  /// **'هذه العملية تشبه عملية موجودة بالمبلغ والتاجر والوقت نفسها.'**
  String get txnSimilarBody;

  /// No description provided for @txnTheNew.
  ///
  /// In ar, this message translates to:
  /// **'الجديدة'**
  String get txnTheNew;

  /// No description provided for @txnNoClearMerchant.
  ///
  /// In ar, this message translates to:
  /// **'بدون تاجر واضح'**
  String get txnNoClearMerchant;

  /// No description provided for @txnTheExisting.
  ///
  /// In ar, this message translates to:
  /// **'الموجودة'**
  String get txnTheExisting;

  /// No description provided for @txnDismissDuplicate.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل التكرار'**
  String get txnDismissDuplicate;

  /// No description provided for @txnSaveAsNew.
  ///
  /// In ar, this message translates to:
  /// **'احفظ كجديدة'**
  String get txnSaveAsNew;

  /// No description provided for @txnEditTx.
  ///
  /// In ar, this message translates to:
  /// **'تعديل العملية'**
  String get txnEditTx;

  /// No description provided for @txnChangeCategory.
  ///
  /// In ar, this message translates to:
  /// **'تغيير التصنيف'**
  String get txnChangeCategory;

  /// No description provided for @txnTimeInSms.
  ///
  /// In ar, this message translates to:
  /// **'وقت العملية داخل SMS'**
  String get txnTimeInSms;

  /// No description provided for @txnTimeReceived.
  ///
  /// In ar, this message translates to:
  /// **'وقت استلام الرسالة'**
  String get txnTimeReceived;

  /// No description provided for @txnDupBannerReview.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية مشبوهة واحدة} =2{عمليتان مشبوهتان} few{{count} عمليات مشبوهة} many{{count} عملية مشبوهة} other{{count} عملية مشبوهة}} — اضغط للمراجعة'**
  String txnDupBannerReview(int count);

  /// No description provided for @txnDismissAllDupesBody.
  ///
  /// In ar, this message translates to:
  /// **'ستُزال كل تنبيهات التكرار المعروضة. العمليات نفسها لن تتأثر، لكن لا يمكن مراجعتها من هنا مرة أخرى.'**
  String get txnDismissAllDupesBody;

  /// No description provided for @txnTimeSource.
  ///
  /// In ar, this message translates to:
  /// **'مصدر الوقت: {source}'**
  String txnTimeSource(String source);

  /// No description provided for @txnRecurredMonths.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تكرر شهرًا واحدًا} =2{تكرر شهرين} few{تكرر {count} أشهر} many{تكرر {count} شهرًا} other{تكرر {count} شهرًا}} · اضغط للتفعيل'**
  String txnRecurredMonths(int count);

  /// No description provided for @txnConfirmAllBody.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سيتم تأكيد عملية واحدة بتصنيفها الحالي.} =2{سيتم تأكيد عمليتين بتصنيفيهما الحاليين.} few{سيتم تأكيد {count} عمليات بتصنيفاتها الحالية.} many{سيتم تأكيد {count} عملية بتصنيفاتها الحالية.} other{سيتم تأكيد {count} عملية بتصنيفاتها الحالية.}}'**
  String txnConfirmAllBody(int count);

  /// No description provided for @txnOverdueDays.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{متأخر يومًا واحدًا} =2{متأخر يومين} few{متأخر {days} أيام} many{متأخر {days} يومًا} other{متأخر {days} يومًا}}'**
  String txnOverdueDays(int days);

  /// No description provided for @txnInDays.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{بعد يوم واحد} =2{بعد يومين} few{بعد {days} أيام} many{بعد {days} يومًا} other{بعد {days} يومًا}}'**
  String txnInDays(int days);

  /// No description provided for @txnPerInstalment.
  ///
  /// In ar, this message translates to:
  /// **'{amount} / قسط'**
  String txnPerInstalment(String amount);

  /// No description provided for @txnPaidOfTotal.
  ///
  /// In ar, this message translates to:
  /// **'{paid} من {total} قسط مدفوع'**
  String txnPaidOfTotal(int paid, int total);

  /// No description provided for @txnRemainingInstalments.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{متبقٍ قسط واحد} =2{متبقٍ قسطان} few{متبقٍ {count} أقساط} many{متبقٍ {count} قسطًا} other{متبقٍ {count} قسط}}'**
  String txnRemainingInstalments(int count);

  /// No description provided for @txnInterestRate.
  ///
  /// In ar, this message translates to:
  /// **'فائدة {rate}%'**
  String txnInterestRate(String rate);

  /// No description provided for @txnNextInstalment.
  ///
  /// In ar, this message translates to:
  /// **'القسط القادم: {due}'**
  String txnNextInstalment(String due);

  /// No description provided for @txnEstPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'{amount} {currency}/شهر'**
  String txnEstPerMonth(String amount, String currency);

  /// No description provided for @txnSmartInboxCount.
  ///
  /// In ar, this message translates to:
  /// **'صندوق المراجعة الذكي · {count}'**
  String txnSmartInboxCount(int count);

  /// No description provided for @txnDismissNAlerts.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تجاهل تنبيهًا واحدًا؟} =2{تجاهل تنبيهين؟} few{تجاهل {count} تنبيهات؟} many{تجاهل {count} تنبيهًا؟} other{تجاهل {count} تنبيه؟}}'**
  String txnDismissNAlerts(int count);

  /// No description provided for @txnDismissAllCount.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل الكل ({count})'**
  String txnDismissAllCount(int count);

  /// No description provided for @subsOverdue.
  ///
  /// In ar, this message translates to:
  /// **'متأخر'**
  String get subsOverdue;

  /// No description provided for @subsToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get subsToday;

  /// No description provided for @subsTabSubs.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات ({count})'**
  String subsTabSubs(int count);

  /// No description provided for @subsTabInst.
  ///
  /// In ar, this message translates to:
  /// **'الأقساط ({count})'**
  String subsTabInst(int count);

  /// No description provided for @subsMonthlyScoped.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات الشهرية · {account}'**
  String subsMonthlyScoped(String account);

  /// No description provided for @subsPerYearApprox.
  ///
  /// In ar, this message translates to:
  /// **'≈ {amount}/سنة'**
  String subsPerYearApprox(String amount);

  /// No description provided for @subsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والفواتير'**
  String get subsTitle;

  /// No description provided for @subsMonthlyTotal.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات الشهرية'**
  String get subsMonthlyTotal;

  /// No description provided for @subsActiveSubs.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكات نشطة'**
  String get subsActiveSubs;

  /// No description provided for @subsRunningInst.
  ///
  /// In ar, this message translates to:
  /// **'أقساط جارية'**
  String get subsRunningInst;

  /// No description provided for @subsMonthlyInstCommit.
  ///
  /// In ar, this message translates to:
  /// **'التزام الأقساط شهريًا'**
  String get subsMonthlyInstCommit;

  /// No description provided for @subsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكاتك في مكان واحد'**
  String get subsEmptyTitle;

  /// No description provided for @subsAutoDetected.
  ///
  /// In ar, this message translates to:
  /// **'مكتشفة تلقائيًا'**
  String get subsAutoDetected;

  /// No description provided for @subsAddNewSub.
  ///
  /// In ar, this message translates to:
  /// **'إضافة اشتراك جديد'**
  String get subsAddNewSub;

  /// No description provided for @subsMaybeUnused.
  ///
  /// In ar, this message translates to:
  /// **'قد لا تستخدم هذا الاشتراك'**
  String get subsMaybeUnused;

  /// No description provided for @subsInstEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'أقساطك، واضحة قبل ميعادها'**
  String get subsInstEmptyTitle;

  /// No description provided for @subsInstEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط بالمبلغ والعدد وتاريخ الاستحقاق.'**
  String get subsInstEmptyBody;

  /// No description provided for @subsTotalInstDebt.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مديونية الأقساط'**
  String get subsTotalInstDebt;

  /// No description provided for @subsNearestInst.
  ///
  /// In ar, this message translates to:
  /// **'أقرب قسط'**
  String get subsNearestInst;

  /// No description provided for @subsAddNewInst.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسط جديد'**
  String get subsAddNewInst;

  /// No description provided for @rptAnomalyPrivate.
  ///
  /// In ar, this message translates to:
  /// **'في يوم {date} كان الصرف أعلى من نمطك المعتاد. راجعه إن أردت معرفة السبب.'**
  String rptAnomalyPrivate(String date);

  /// No description provided for @rptAnomalyDetail.
  ///
  /// In ar, this message translates to:
  /// **'في يوم {date} صرفت {amount}، وهو أعلى من متوسطك اليومي {ratio}×.'**
  String rptAnomalyDetail(String date, String amount, String ratio);

  /// No description provided for @rptSpendLower.
  ///
  /// In ar, this message translates to:
  /// **'صرفك أقل {percent}% من نفس الفترة السابقة.'**
  String rptSpendLower(int percent);

  /// No description provided for @rptSpendHigher.
  ///
  /// In ar, this message translates to:
  /// **'صرفك أعلى {percent}% من نفس الفترة السابقة.'**
  String rptSpendHigher(int percent);

  /// No description provided for @rptHighestDayBody.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم في الفترة وصل إلى {amount}.'**
  String rptHighestDayBody(String amount);

  /// No description provided for @rptTopCategoryHint.
  ///
  /// In ar, this message translates to:
  /// **'أكبر إنفاق لديك على {category}. راقب هذا التصنيف أولًا.'**
  String rptTopCategoryHint(String category);

  /// No description provided for @rptMerchantTxCount.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية واحدة} =2{عمليتان} few{{count} عمليات} many{{count} عملية} other{{count} عملية}}'**
  String rptMerchantTxCount(int count);

  /// No description provided for @rptVsLastWeek.
  ///
  /// In ar, this message translates to:
  /// **'{sign} {percent}% مقارنة بالأسبوع الماضي'**
  String rptVsLastWeek(String sign, String percent);

  /// No description provided for @rptTopCategoryWeek.
  ///
  /// In ar, this message translates to:
  /// **'أكثر فئة صرفًا: {category}'**
  String rptTopCategoryWeek(String category);

  /// No description provided for @rptBestSavingDay.
  ///
  /// In ar, this message translates to:
  /// **'أفضل يوم توفيرًا: {date} ({amount})'**
  String rptBestSavingDay(String date, String amount);

  /// No description provided for @rptTopMerchantWeek.
  ///
  /// In ar, this message translates to:
  /// **'أكثر متجر صرفًا: {name} ({amount})'**
  String rptTopMerchantWeek(String name, String amount);

  /// No description provided for @rptTabOverview.
  ///
  /// In ar, this message translates to:
  /// **'نظرة عامة'**
  String get rptTabOverview;

  /// No description provided for @rptTabTrends.
  ///
  /// In ar, this message translates to:
  /// **'الاتجاهات'**
  String get rptTabTrends;

  /// No description provided for @rptTabDetails.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get rptTabDetails;

  /// No description provided for @rptUnusualSpend.
  ///
  /// In ar, this message translates to:
  /// **'صرف غير معتاد'**
  String get rptUnusualSpend;

  /// No description provided for @rptVsPrevPeriod.
  ///
  /// In ar, this message translates to:
  /// **'مقارنة بنفس الفترة السابقة'**
  String get rptVsPrevPeriod;

  /// No description provided for @rptNeedPrevPeriod.
  ///
  /// In ar, this message translates to:
  /// **'ما زلنا نحتاج فترة سابقة فيها إنفاق لعرض الاتجاه بدقة.'**
  String get rptNeedPrevPeriod;

  /// No description provided for @rptHighestSpendDay.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم صرف'**
  String get rptHighestSpendDay;

  /// No description provided for @rptQuickTip.
  ///
  /// In ar, this message translates to:
  /// **'اقتراح سريع'**
  String get rptQuickTip;

  /// No description provided for @rptAddMoreTx.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ بإضافة عمليات أكثر لنقدّم اقتراحات أوضح.'**
  String get rptAddMoreTx;

  /// No description provided for @rptSelectedPeriod.
  ///
  /// In ar, this message translates to:
  /// **'الفترة المختارة'**
  String get rptSelectedPeriod;

  /// No description provided for @rptNetPeriodSpend.
  ///
  /// In ar, this message translates to:
  /// **'صافي مصروف الفترة'**
  String get rptNetPeriodSpend;

  /// No description provided for @rptSelectedPeriodSpend.
  ///
  /// In ar, this message translates to:
  /// **'مصروف الفترة المختارة'**
  String get rptSelectedPeriodSpend;

  /// No description provided for @rptTotalExpenses.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المصروفات'**
  String get rptTotalExpenses;

  /// No description provided for @rptRefunds.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات'**
  String get rptRefunds;

  /// No description provided for @rptNet.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get rptNet;

  /// No description provided for @rptThisWeekUsage.
  ///
  /// In ar, this message translates to:
  /// **'استهلاك الأسبوع الحالي'**
  String get rptThisWeekUsage;

  /// No description provided for @rptAverage.
  ///
  /// In ar, this message translates to:
  /// **'المتوسط'**
  String get rptAverage;

  /// No description provided for @rptHighest.
  ///
  /// In ar, this message translates to:
  /// **'الأعلى'**
  String get rptHighest;

  /// No description provided for @rptTotal.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي'**
  String get rptTotal;

  /// No description provided for @rptByCategory.
  ///
  /// In ar, this message translates to:
  /// **'استهلاكك بالتصنيفات'**
  String get rptByCategory;

  /// No description provided for @rptByMerchant.
  ///
  /// In ar, this message translates to:
  /// **'مصروفاتك في المتاجر'**
  String get rptByMerchant;

  /// No description provided for @rptTopMerchantsSub.
  ///
  /// In ar, this message translates to:
  /// **'أكبر أماكن الصرف في الفترة'**
  String get rptTopMerchantsSub;

  /// No description provided for @rptMerchantsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر هنا أكثر المتاجر صرفاً بعد إضافة عمليات مؤكدة.'**
  String get rptMerchantsEmpty;

  /// No description provided for @rptIncludesRefund.
  ///
  /// In ar, this message translates to:
  /// **' · شامل مرتجع '**
  String get rptIncludesRefund;

  /// No description provided for @rptInsightsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الرؤى والتقارير'**
  String get rptInsightsTitle;

  /// No description provided for @rptInsightsSub.
  ///
  /// In ar, this message translates to:
  /// **'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.'**
  String get rptInsightsSub;

  /// No description provided for @rptDailyAverage.
  ///
  /// In ar, this message translates to:
  /// **'متوسط يومي'**
  String get rptDailyAverage;

  /// No description provided for @rptHighestDay.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم'**
  String get rptHighestDay;

  /// No description provided for @rptWeekSummary.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الأسبوع'**
  String get rptWeekSummary;

  /// No description provided for @bdgPeriodSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية {period} · {date}'**
  String bdgPeriodSubtitle(String period, String date);

  /// No description provided for @bdgPeriodSubtitleLive.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية {period} · {date} · جارية'**
  String bdgPeriodSubtitleLive(String period, String date);

  /// No description provided for @bdgLatestOfTotal.
  ///
  /// In ar, this message translates to:
  /// **'أحدث {shown} من {total}'**
  String bdgLatestOfTotal(int shown, int total);

  /// No description provided for @bdgRemainingPrefix.
  ///
  /// In ar, this message translates to:
  /// **'باقي '**
  String get bdgRemainingPrefix;

  /// No description provided for @bdgToReachSuffix.
  ///
  /// In ar, this message translates to:
  /// **' {currency} للوصول'**
  String bdgToReachSuffix(String currency);

  /// No description provided for @setUnsyncedLedger.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تغيير واحد في المعاملات} =2{تغييران في المعاملات} few{{count} تغييرات في المعاملات} many{{count} تغييرًا في المعاملات} other{{count} تغيير في المعاملات}}'**
  String setUnsyncedLedger(int count);

  /// No description provided for @setUnsyncedPlanning.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تغيير واحد في الحسابات/الميزانيات/الأهداف/الفواتير} =2{تغييران في الحسابات/الميزانيات/الأهداف/الفواتير} few{{count} تغييرات في الحسابات/الميزانيات/الأهداف/الفواتير} many{{count} تغييرًا في الحسابات/الميزانيات/الأهداف/الفواتير} other{{count} تغيير في الحسابات/الميزانيات/الأهداف/الفواتير}}'**
  String setUnsyncedPlanning(int count);

  /// No description provided for @setUnsyncedInbox.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عنصر واحد في صندوق الوارد} =2{عنصران في صندوق الوارد} few{{count} عناصر في صندوق الوارد} many{{count} عنصرًا في صندوق الوارد} other{{count} عنصر في صندوق الوارد}}'**
  String setUnsyncedInbox(int count);

  /// No description provided for @setUnsyncedCards.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{بطاقة واحدة محفوظة على هذا الجهاز فقط} =2{بطاقتان محفوظتان على هذا الجهاز فقط} few{{count} بطاقات محفوظة على هذا الجهاز فقط} many{{count} بطاقة محفوظة على هذا الجهاز فقط} other{{count} بطاقة محفوظة على هذا الجهاز فقط}}'**
  String setUnsyncedCards(int count);

  /// No description provided for @setUnsyncedUnproven.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سجل مالي واحد لم يُرفع للسحابة بعد} =2{سجلان ماليان لم يُرفعا للسحابة بعد} few{{count} سجلات مالية لم تُرفع للسحابة بعد} many{{count} سجلًا ماليًا لم يُرفع للسحابة بعد} other{{count} سجل مالي لم يُرفع للسحابة بعد}}'**
  String setUnsyncedUnproven(int count);

  /// No description provided for @setUnsyncedConflicts.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سجل واحد به تعارض لم يُحلّ} =2{سجلان بهما تعارض لم يُحلّ} few{{count} سجلات بها تعارض لم يُحلّ} many{{count} سجلًا به تعارض لم يُحلّ} other{{count} سجل به تعارض لم يُحلّ}}'**
  String setUnsyncedConflicts(int count);

  /// No description provided for @setListSeparator.
  ///
  /// In ar, this message translates to:
  /// **'، '**
  String get setListSeparator;

  /// No description provided for @setUnsyncedSignOutBody.
  ///
  /// In ar, this message translates to:
  /// **'لديك بيانات لم تُرفع للسحابة وسيحذفها تسجيل الخروج: {list}. خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.'**
  String setUnsyncedSignOutBody(String list);

  /// No description provided for @setGapDays.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منذ يوم واحد} =2{منذ يومين} few{منذ {count} أيام} many{منذ {count} يومًا} other{منذ {count} يوم}}'**
  String setGapDays(int count);

  /// No description provided for @setGapHours.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منذ ساعة واحدة} =2{منذ ساعتين} few{منذ {count} ساعات} many{منذ {count} ساعة} other{منذ {count} ساعة}}'**
  String setGapHours(int count);

  /// No description provided for @setGapToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get setGapToday;

  /// No description provided for @setLastCapture.
  ///
  /// In ar, this message translates to:
  /// **'آخر عملية رصد: {gap}'**
  String setLastCapture(String gap);

  /// No description provided for @setApnsFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تسجيل APNs: {message}'**
  String setApnsFailed(String message);

  /// No description provided for @setCheckShortcutStillOn.
  ///
  /// In ar, this message translates to:
  /// **'{subtitle} — تأكد أن الاختصار لا يزال مفعّلًا'**
  String setCheckShortcutStillOn(String subtitle);

  /// No description provided for @goalDueToday.
  ///
  /// In ar, this message translates to:
  /// **'الموعد اليوم'**
  String get goalDueToday;

  /// No description provided for @goalDaysLeft.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{باقي يوم واحد} =2{باقي يومان} few{باقي {days} أيام} many{باقي {days} يومًا} other{باقي {days} يوم}}'**
  String goalDaysLeft(int days);

  /// No description provided for @goalMonthsLeft.
  ///
  /// In ar, this message translates to:
  /// **'{months, plural, =1{باقي شهر واحد} =2{باقي شهران} few{باقي {months} أشهر} many{باقي {months} شهرًا} other{باقي {months} شهر}}'**
  String goalMonthsLeft(int months);

  /// No description provided for @goalRemainingToReach.
  ///
  /// In ar, this message translates to:
  /// **'باقي {amount} {currency} للوصول'**
  String goalRemainingToReach(String amount, String currency);

  /// No description provided for @goalSavedAmount.
  ///
  /// In ar, this message translates to:
  /// **'مدخر {amount} {currency}'**
  String goalSavedAmount(String amount, String currency);

  /// No description provided for @goalTargetAmount.
  ///
  /// In ar, this message translates to:
  /// **'الهدف {amount} {currency}'**
  String goalTargetAmount(String amount, String currency);

  /// No description provided for @goalPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'/شهر'**
  String get goalPerMonth;

  /// No description provided for @goalOverdue.
  ///
  /// In ar, this message translates to:
  /// **'تجاوز الموعد المستهدف'**
  String get goalOverdue;

  /// No description provided for @goalTotalSavedAll.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المدخر لكل أحلامك'**
  String get goalTotalSavedAll;

  /// No description provided for @goalTargetLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستهدف'**
  String get goalTargetLabel;

  /// No description provided for @goalEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف هدفك الأول وابدأ تعبئة الخزنة.'**
  String get goalEmptyBody;

  /// No description provided for @cardLinkTxTo.
  ///
  /// In ar, this message translates to:
  /// **'اربط عملية بـ •••• {last4}'**
  String cardLinkTxTo(String last4);

  /// No description provided for @cardTxLinkedTo.
  ///
  /// In ar, this message translates to:
  /// **'تم ربط العملية بـ •••• {last4}'**
  String cardTxLinkedTo(String last4);

  /// No description provided for @cardAccountWord.
  ///
  /// In ar, this message translates to:
  /// **'حساب'**
  String get cardAccountWord;

  /// No description provided for @cardUnassigned.
  ///
  /// In ar, this message translates to:
  /// **'غير مخصّصة'**
  String get cardUnassigned;

  /// No description provided for @cardBack.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get cardBack;

  /// No description provided for @cardActivityTitle.
  ///
  /// In ar, this message translates to:
  /// **'حركة البطاقات'**
  String get cardActivityTitle;

  /// No description provided for @cardAllCards.
  ///
  /// In ar, this message translates to:
  /// **'كل البطاقات'**
  String get cardAllCards;

  /// No description provided for @cardLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل بطاقاتك'**
  String get cardLoadFailed;

  /// No description provided for @cardLoadFailedBody.
  ///
  /// In ar, this message translates to:
  /// **'حاول مجددًا لعرض بطاقاتك المحفوظة.'**
  String get cardLoadFailedBody;

  /// No description provided for @cardAddCard.
  ///
  /// In ar, this message translates to:
  /// **'إضافة بطاقة'**
  String get cardAddCard;

  /// No description provided for @cardEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات بعد'**
  String get cardEmptyTitle;

  /// No description provided for @cardEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافة بطاقة بتصميمك.'**
  String get cardEmptyBody;

  /// No description provided for @cardAddCardCta.
  ///
  /// In ar, this message translates to:
  /// **'أضف بطاقة'**
  String get cardAddCardCta;

  /// No description provided for @cardEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get cardEdit;

  /// No description provided for @cardIn.
  ///
  /// In ar, this message translates to:
  /// **'داخل'**
  String get cardIn;

  /// No description provided for @cardOut.
  ///
  /// In ar, this message translates to:
  /// **'خارج'**
  String get cardOut;

  /// No description provided for @cardAddTx.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عملية'**
  String get cardAddTx;

  /// No description provided for @cardLinkExistingTx.
  ///
  /// In ar, this message translates to:
  /// **'اربط عملية موجودة'**
  String get cardLinkExistingTx;

  /// No description provided for @cardSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو المبلغ'**
  String get cardSearchHint;

  /// No description provided for @cardNoTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات'**
  String get cardNoTx;

  /// No description provided for @accAddAccount.
  ///
  /// In ar, this message translates to:
  /// **'إضافة حساب'**
  String get accAddAccount;

  /// No description provided for @accTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والمحافظ'**
  String get accTitle;

  /// No description provided for @accSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'كل حساب بعملته الخاصة — نقدي، بنك، محفظة أو بطاقة.'**
  String get accSubtitle;

  /// No description provided for @accDefault.
  ///
  /// In ar, this message translates to:
  /// **'افتراضي'**
  String get accDefault;

  /// No description provided for @accUnassignedCards.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات غير مخصّصة'**
  String get accUnassignedCards;

  /// No description provided for @accUnassignedCardsBody.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات ظهرت في رسائلك لكنها غير مرتبطة بحساب بعد.'**
  String get accUnassignedCardsBody;

  /// No description provided for @achCurrentStreak.
  ///
  /// In ar, this message translates to:
  /// **'السلسلة الحالية: {days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}'**
  String achCurrentStreak(int days);

  /// No description provided for @achStreakDays.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}'**
  String achStreakDays(int days);

  /// No description provided for @annFromDate.
  ///
  /// In ar, this message translates to:
  /// **'من {date}'**
  String annFromDate(String date);

  /// No description provided for @pasteAnalysing.
  ///
  /// In ar, this message translates to:
  /// **'نحلّل {processed} من {total}'**
  String pasteAnalysing(int processed, int total);

  /// No description provided for @pasteSummaryLine.
  ///
  /// In ar, this message translates to:
  /// **'أُضيفت {added} · مكرر {duplicate} · يحتاج مراجعة {review} · غير مفهوم {failed}'**
  String pasteSummaryLine(int added, int duplicate, int review, int failed);

  /// No description provided for @pasteAnalysedCount.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تم تحليل رسالة واحدة من اللصق.} =2{تم تحليل رسالتين من اللصق.} few{تم تحليل {count} رسائل من اللصق.} many{تم تحليل {count} رسالة من اللصق.} other{تم تحليل {count} رسالة من اللصق.}}'**
  String pasteAnalysedCount(int count);

  /// No description provided for @achCurrentLevel.
  ///
  /// In ar, this message translates to:
  /// **'المستوى الحالي'**
  String get achCurrentLevel;

  /// No description provided for @achUnlocked.
  ///
  /// In ar, this message translates to:
  /// **'تم الفتح'**
  String get achUnlocked;

  /// No description provided for @achInProgress.
  ///
  /// In ar, this message translates to:
  /// **'قيد التقدّم'**
  String get achInProgress;

  /// No description provided for @achLevelOrganised.
  ///
  /// In ar, this message translates to:
  /// **'منظّم'**
  String get achLevelOrganised;

  /// No description provided for @achLevelSmartSaver.
  ///
  /// In ar, this message translates to:
  /// **'موفّر ذكي'**
  String get achLevelSmartSaver;

  /// No description provided for @achLevelExpert.
  ///
  /// In ar, this message translates to:
  /// **'خبير مالي'**
  String get achLevelExpert;

  /// No description provided for @achLevelLegend.
  ///
  /// In ar, this message translates to:
  /// **'أسطورة الادخار'**
  String get achLevelLegend;

  /// No description provided for @achLevelBeginner.
  ///
  /// In ar, this message translates to:
  /// **'مبتدئ'**
  String get achLevelBeginner;

  /// No description provided for @achTitle.
  ///
  /// In ar, this message translates to:
  /// **'الإنجازات'**
  String get achTitle;

  /// No description provided for @achSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'شارات ومستويات تشجعك تكمل عادة المتابعة.'**
  String get achSubtitle;

  /// No description provided for @achLevel.
  ///
  /// In ar, this message translates to:
  /// **'المستوى'**
  String get achLevel;

  /// No description provided for @achTotalXp.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الـ XP'**
  String get achTotalXp;

  /// No description provided for @achStreak.
  ///
  /// In ar, this message translates to:
  /// **'سلسلة المتابعة'**
  String get achStreak;

  /// No description provided for @annTitle.
  ///
  /// In ar, this message translates to:
  /// **'مركز رسائل قرش'**
  String get annTitle;

  /// No description provided for @annSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ إشعارات قرش، الحملات، والإعلانات في مكان واحد.'**
  String get annSubtitle;

  /// No description provided for @annClose.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get annClose;

  /// No description provided for @annLoading.
  ///
  /// In ar, this message translates to:
  /// **'تحميل مركز الرسائل...'**
  String get annLoading;

  /// No description provided for @annLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الرسائل'**
  String get annLoadFailed;

  /// No description provided for @annTryAgainSoon.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى بعد لحظات.'**
  String get annTryAgainSoon;

  /// No description provided for @annRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get annRetry;

  /// No description provided for @annEmpty.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد رسائل بعد'**
  String get annEmpty;

  /// No description provided for @annEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أي إشعار من قِرش أو إعلان من الإدارة سيظهر هنا تلقائيًا.'**
  String get annEmptyBody;

  /// No description provided for @annShortcutCaptured.
  ///
  /// In ar, this message translates to:
  /// **'تم التقاط عملية جديدة'**
  String get annShortcutCaptured;

  /// No description provided for @annShortcutReceived.
  ///
  /// In ar, this message translates to:
  /// **'تم استلام رسالة بنكية'**
  String get annShortcutReceived;

  /// No description provided for @annNotificationSent.
  ///
  /// In ar, this message translates to:
  /// **'إشعار مرسل'**
  String get annNotificationSent;

  /// No description provided for @annOpen.
  ///
  /// In ar, this message translates to:
  /// **'فتح'**
  String get annOpen;

  /// No description provided for @annInAppCampaign.
  ///
  /// In ar, this message translates to:
  /// **'حملة داخل التطبيق'**
  String get annInAppCampaign;

  /// No description provided for @annFromQirsh.
  ///
  /// In ar, this message translates to:
  /// **'إعلان من قرش'**
  String get annFromQirsh;

  /// No description provided for @privCloudProcessingBody.
  ///
  /// In ar, this message translates to:
  /// **'تتم مزامنة بياناتك ونسخها احتياطيًا على خوادم قِرش، وقد تُرسَل إليها رسائل البنك الملتقطة بعد حذف أرقام البطاقات والحسابات والهواتف والرموز لقراءتها، وقد يُرسَل اسم التاجر إلى Google Places لتصنيفه. عند الإيقاف يتوقف الإرسال: تُقرأ الرسائل بقواعد قِرش المحلية ولا تتم مزامنة أي بيانات جديدة، ويظل الإدخال اليدوي متاحًا.'**
  String get privCloudProcessingBody;

  /// No description provided for @privAiAnalysisBody.
  ///
  /// In ar, this message translates to:
  /// **'عند تشغيله مع المزامنة السحابية، قد تُحلَّل رسائل البنك الملتقطة — ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد — بعد حذف أرقام البطاقات والحسابات والهواتف والرموز وإخفاء ما يُتعرَّف عليه من أسماء وعناوين بريد إلكتروني وأرقام مرجعية، بواسطة Google Gemini لقراءة المبلغ والتاجر والبنك. يبقى في النص المبالغ والتجار والتواريخ والأرصدة. سحب الموافقة يقصر القراءة على قواعد قِرش داخل جهازك.'**
  String get privAiAnalysisBody;

  /// No description provided for @privDeleteAccountBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم جدولة حذف حسابك وكل بياناتك (العمليات، الأهداف، الميزانيات، النسخ الاحتياطي) نهائيًا بعد 30 يومًا. يمكنك التراجع عن الحذف خلال هذه المدة من نفس الشاشة قبل تسجيل الدخول مرة أخرى. سيتم تسجيل خروجك من هذا الجهاز الآن.'**
  String get privDeleteAccountBody;

  /// No description provided for @privScheduledForDeletion.
  ///
  /// In ar, this message translates to:
  /// **'حسابك مجدول للحذف بتاريخ {date}'**
  String privScheduledForDeletion(String date);

  /// No description provided for @privPolicy.
  ///
  /// In ar, this message translates to:
  /// **'سياسة الخصوصية'**
  String get privPolicy;

  /// No description provided for @privTerms.
  ///
  /// In ar, this message translates to:
  /// **'الشروط والأحكام'**
  String get privTerms;

  /// No description provided for @privTransferMyData.
  ///
  /// In ar, this message translates to:
  /// **'نقل واستيراد بياناتي'**
  String get privTransferMyData;

  /// No description provided for @privDataProcessing.
  ///
  /// In ar, this message translates to:
  /// **'معالجة البيانات'**
  String get privDataProcessing;

  /// No description provided for @privCloudProcessing.
  ///
  /// In ar, this message translates to:
  /// **'المعالجة السحابية والمزامنة'**
  String get privCloudProcessing;

  /// No description provided for @privAiAnalysis.
  ///
  /// In ar, this message translates to:
  /// **'التحليل بالذكاء الاصطناعي'**
  String get privAiAnalysis;

  /// No description provided for @privDangerZone.
  ///
  /// In ar, this message translates to:
  /// **'منطقة خطرة'**
  String get privDangerZone;

  /// No description provided for @privDeleteAccountAll.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب وكل بياناتي'**
  String get privDeleteAccountAll;

  /// No description provided for @privLinkFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر فتح الرابط الآن.'**
  String get privLinkFailed;

  /// No description provided for @privDeleteAccountTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب؟'**
  String get privDeleteAccountTitle;

  /// No description provided for @privDeleteAccount.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب'**
  String get privDeleteAccount;

  /// No description provided for @privScheduleFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر جدولة الحذف الآن. حاول مجدداً.'**
  String get privScheduleFailed;

  /// No description provided for @privCancelDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء حذف الحساب؟'**
  String get privCancelDeleteTitle;

  /// No description provided for @privCancelDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيبقى حسابك وبياناتك كما هي.'**
  String get privCancelDeleteBody;

  /// No description provided for @privKeepAccount.
  ///
  /// In ar, this message translates to:
  /// **'تراجع'**
  String get privKeepAccount;

  /// No description provided for @privCancelDeletion.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الحذف'**
  String get privCancelDeletion;

  /// No description provided for @privCancelFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إلغاء الحذف الآن. حاول مجدداً.'**
  String get privCancelFailed;

  /// No description provided for @privTitle.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية والبيانات'**
  String get privTitle;

  /// No description provided for @privIntro.
  ///
  /// In ar, this message translates to:
  /// **'عند تفعيل «التحليل الذكي والمزامنة السحابية»، قد تُعالَج رسائل البنك التي يلتقطها قِرش — رسائل SMS التي تُقرأ تلقائيًا على أندرويد، أو الرسائل التي تشاركها أو ترسلها عبر اختصار iOS — كنص مُنقّى على خوادم قِرش وبواسطة Google Gemini. عند إيقافه تُحلَّل الرسائل على هذا الجهاز. ويمكنك تصدير بياناتك المالية أو استيرادها من شاشة نقل البيانات.'**
  String get privIntro;

  /// No description provided for @dtxPreviewRows.
  ///
  /// In ar, this message translates to:
  /// **'{rows} سجل • {format}'**
  String dtxPreviewRows(int rows, String format);

  /// No description provided for @dtxQirshPackage.
  ///
  /// In ar, this message translates to:
  /// **'حزمة قِرش'**
  String get dtxQirshPackage;

  /// No description provided for @dtxImportDupesAsNew.
  ///
  /// In ar, this message translates to:
  /// **'استيراد {count} عملية مشابهة كعمليات جديدة'**
  String dtxImportDupesAsNew(int count);

  /// No description provided for @dtxAdded.
  ///
  /// In ar, this message translates to:
  /// **'تمت الإضافة: {count}'**
  String dtxAdded(int count);

  /// No description provided for @dtxDuplicates.
  ///
  /// In ar, this message translates to:
  /// **'مكرر: {count}'**
  String dtxDuplicates(int count);

  /// No description provided for @dtxQuarantined.
  ///
  /// In ar, this message translates to:
  /// **'معزول للحماية: {count}'**
  String dtxQuarantined(int count);

  /// No description provided for @dtxFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل: {count}'**
  String dtxFailed(int count);

  /// No description provided for @dtxScanFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر فحص الملف. تأكد أنه CSV أو ZIP صالح.'**
  String get dtxScanFailed;

  /// No description provided for @dtxImportFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر إكمال الاستيراد. لم تُحذف أي بيانات غير مؤكدة.'**
  String get dtxImportFailed;

  /// No description provided for @dtxReadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة البيانات وتجهيز ملف التصدير.'**
  String get dtxReadFailed;

  /// No description provided for @dtxSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ ملف التصدير مؤقتًا على الجهاز.'**
  String get dtxSaveFailed;

  /// No description provided for @dtxZipShareText.
  ///
  /// In ar, this message translates to:
  /// **'ملف بيانات قرش المالية. احتفظ به في مكان خاص.'**
  String get dtxZipShareText;

  /// No description provided for @dtxCsvShareText.
  ///
  /// In ar, this message translates to:
  /// **'تصدير عمليات قرش بصيغة CSV.'**
  String get dtxCsvShareText;

  /// No description provided for @dtxShareSheetFailed.
  ///
  /// In ar, this message translates to:
  /// **'تم تجهيز الملف، لكن تعذر فتح نافذة المشاركة. حاول مرة أخرى.'**
  String get dtxShareSheetFailed;

  /// No description provided for @dtxTitle.
  ///
  /// In ar, this message translates to:
  /// **'نقل البيانات'**
  String get dtxTitle;

  /// No description provided for @dtxSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'استورد بياناتك أو احتفظ بنسخة قابلة للنقل. تتم معاينة الملف على جهازك قبل أي كتابة.'**
  String get dtxSubtitle;

  /// No description provided for @dtxImportFile.
  ///
  /// In ar, this message translates to:
  /// **'استيراد ملف'**
  String get dtxImportFile;

  /// No description provided for @dtxImportFileSub.
  ///
  /// In ar, this message translates to:
  /// **'CSV من أي تطبيق أو ZIP صادر من قرش'**
  String get dtxImportFileSub;

  /// No description provided for @dtxExportCsv.
  ///
  /// In ar, this message translates to:
  /// **'تصدير العمليات CSV'**
  String get dtxExportCsv;

  /// No description provided for @dtxExportCsvSub.
  ///
  /// In ar, this message translates to:
  /// **'ملف واحد متوافق مع Excel وتطبيقات الميزانية'**
  String get dtxExportCsvSub;

  /// No description provided for @dtxExportZip.
  ///
  /// In ar, this message translates to:
  /// **'تصدير كل بيانات قرش ZIP'**
  String get dtxExportZip;

  /// No description provided for @dtxExportZipSub.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والعمليات والميزانيات والخطط المالية'**
  String get dtxExportZipSub;

  /// No description provided for @dtxRestoreOld.
  ///
  /// In ar, this message translates to:
  /// **'استعادة نسخة قديمة'**
  String get dtxRestoreOld;

  /// No description provided for @dtxRestoreOldSub.
  ///
  /// In ar, this message translates to:
  /// **'متاح مؤقتاً للنسخ المشفرة التي أنشأتها سابقاً'**
  String get dtxRestoreOldSub;

  /// No description provided for @dtxExportNotice.
  ///
  /// In ar, this message translates to:
  /// **'ملفات التصدير لا تحتوي رسائل البنك الخام أو بيانات الدخول أو رموز الأجهزة. ملف ZIP غير محمي بكلمة مرور؛ خزّنه في مكان خاص.'**
  String get dtxExportNotice;

  /// No description provided for @dtxReplace.
  ///
  /// In ar, this message translates to:
  /// **'استبدال'**
  String get dtxReplace;

  /// No description provided for @dtxReplaceGuestOnly.
  ///
  /// In ar, this message translates to:
  /// **'الاستبدال متاح فقط للبيانات المحفوظة على هذا الجهاز. لأن بياناتك مزامَنة مع حسابك، الدمج هو الخيار الوحيد: يضيف محتوى الحزمة ويُبقي ما لديك.'**
  String get dtxReplaceGuestOnly;

  /// No description provided for @dtxConfirmReplace.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الاستبدال'**
  String get dtxConfirmReplace;

  /// No description provided for @dtxReplaceBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم إخفاء بياناتك المالية الحالية واستبدالها بمحتوى حزمة قِرش. اكتب «{word}» للمتابعة.'**
  String dtxReplaceBody(String word);

  /// No description provided for @dtxTypeReplace.
  ///
  /// In ar, this message translates to:
  /// **'اكتب {word}'**
  String dtxTypeReplace(String word);

  /// No description provided for @dtxImportPreview.
  ///
  /// In ar, this message translates to:
  /// **'معاينة الاستيراد'**
  String get dtxImportPreview;

  /// No description provided for @dtxColDate.
  ///
  /// In ar, this message translates to:
  /// **'عمود التاريخ'**
  String get dtxColDate;

  /// No description provided for @dtxColAmount.
  ///
  /// In ar, this message translates to:
  /// **'عمود المبلغ'**
  String get dtxColAmount;

  /// No description provided for @dtxDefaultAccount.
  ///
  /// In ar, this message translates to:
  /// **'الحساب الافتراضي'**
  String get dtxDefaultAccount;

  /// No description provided for @dtxDebit.
  ///
  /// In ar, this message translates to:
  /// **'الخصم (Debit)'**
  String get dtxDebit;

  /// No description provided for @dtxCredit.
  ///
  /// In ar, this message translates to:
  /// **'الإيداع (Credit)'**
  String get dtxCredit;

  /// No description provided for @dtxCurrency.
  ///
  /// In ar, this message translates to:
  /// **'العملة'**
  String get dtxCurrency;

  /// No description provided for @dtxMerchantDesc.
  ///
  /// In ar, this message translates to:
  /// **'التاجر / الوصف'**
  String get dtxMerchantDesc;

  /// No description provided for @dtxNotes.
  ///
  /// In ar, this message translates to:
  /// **'الملاحظات'**
  String get dtxNotes;

  /// No description provided for @dtxTxType.
  ///
  /// In ar, this message translates to:
  /// **'نوع العملية'**
  String get dtxTxType;

  /// No description provided for @dtxDateFormat.
  ///
  /// In ar, this message translates to:
  /// **'صيغة التاريخ'**
  String get dtxDateFormat;

  /// No description provided for @dtxDateAuto.
  ///
  /// In ar, this message translates to:
  /// **'تلقائية'**
  String get dtxDateAuto;

  /// No description provided for @dtxDateDMY.
  ///
  /// In ar, this message translates to:
  /// **'يوم / شهر / سنة'**
  String get dtxDateDMY;

  /// No description provided for @dtxDateMDY.
  ///
  /// In ar, this message translates to:
  /// **'شهر / يوم / سنة'**
  String get dtxDateMDY;

  /// No description provided for @dtxDateYMD.
  ///
  /// In ar, this message translates to:
  /// **'سنة / شهر / يوم'**
  String get dtxDateYMD;

  /// No description provided for @dtxWillCreate.
  ///
  /// In ar, this message translates to:
  /// **'عند التأكيد، سيُنشئ قرش الحسابات والتصنيفات غير الموجودة الواردة في الملف.'**
  String get dtxWillCreate;

  /// No description provided for @dtxMerge.
  ///
  /// In ar, this message translates to:
  /// **'دمج'**
  String get dtxMerge;

  /// No description provided for @dtxConfirmImport.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الاستيراد'**
  String get dtxConfirmImport;

  /// No description provided for @dtxImportDone.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل الاستيراد'**
  String get dtxImportDone;

  /// No description provided for @dtxCacheRepair.
  ///
  /// In ar, this message translates to:
  /// **'تم الحفظ على الخادم، وسيُصلح قرش الكاش المحلي تلقائياً.'**
  String get dtxCacheRepair;

  /// No description provided for @pasteTitle.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة البنك'**
  String get pasteTitle;

  /// No description provided for @pasteAlreadyExists.
  ///
  /// In ar, this message translates to:
  /// **'العملية موجودة بالفعل، فتحناها للمراجعة.'**
  String get pasteAlreadyExists;

  /// No description provided for @pasteAlreadyRecorded.
  ///
  /// In ar, this message translates to:
  /// **'هذه العملية مسجّلة بالفعل.'**
  String get pasteAlreadyRecorded;

  /// No description provided for @pasteSimilarNeedsReview.
  ///
  /// In ar, this message translates to:
  /// **'عملية مشابهة موجودة وتحتاج مراجعة.'**
  String get pasteSimilarNeedsReview;

  /// No description provided for @pasteAiOffline.
  ///
  /// In ar, this message translates to:
  /// **'تحليل الذكاء الاصطناعي غير متاح. لم تُضَف عملية. يمكنك إضافتها يدويًا.'**
  String get pasteAiOffline;

  /// No description provided for @pasteUnreadableOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت قراءة الرسالة على الجهاز — أضِفها يدويًا.'**
  String get pasteUnreadableOnDevice;

  /// No description provided for @pasteNotATransaction.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت قراءتها كعملية — أضِفها يدويًا.'**
  String get pasteNotATransaction;

  /// No description provided for @pasteNothingToOpen.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عملية لفتحها لهذه الرسالة.'**
  String get pasteNothingToOpen;

  /// No description provided for @pasteHint.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك لصق رسالة واحدة أو عدة رسائل، وسيجري تحليل كل رسالة على حدة.'**
  String get pasteHint;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In ar, this message translates to:
  /// **'لصق من الحافظة'**
  String get pasteFromClipboard;

  /// No description provided for @pasteAnalyse.
  ///
  /// In ar, this message translates to:
  /// **'حلّل الرسائل'**
  String get pasteAnalyse;

  /// No description provided for @pasteNeedsReview.
  ///
  /// In ar, this message translates to:
  /// **'يحتاج مراجعة'**
  String get pasteNeedsReview;

  /// No description provided for @pasteAdded.
  ///
  /// In ar, this message translates to:
  /// **'أُضيفت'**
  String get pasteAdded;

  /// No description provided for @pasteDuplicate.
  ///
  /// In ar, this message translates to:
  /// **'مكرر'**
  String get pasteDuplicate;

  /// No description provided for @pasteSimilar.
  ///
  /// In ar, this message translates to:
  /// **'مشابهة للمراجعة'**
  String get pasteSimilar;

  /// No description provided for @pasteNotUnderstood.
  ///
  /// In ar, this message translates to:
  /// **'غير مفهوم'**
  String get pasteNotUnderstood;

  /// No description provided for @pasteSummary.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الرسائل'**
  String get pasteSummary;

  /// No description provided for @pasteReview.
  ///
  /// In ar, this message translates to:
  /// **'راجع'**
  String get pasteReview;

  /// No description provided for @accTypeCash.
  ///
  /// In ar, this message translates to:
  /// **'نقدي'**
  String get accTypeCash;

  /// No description provided for @accTypeBank.
  ///
  /// In ar, this message translates to:
  /// **'بنك'**
  String get accTypeBank;

  /// No description provided for @accTypeWallet.
  ///
  /// In ar, this message translates to:
  /// **'محفظة'**
  String get accTypeWallet;

  /// No description provided for @accTypeCreditCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة ائتمانية'**
  String get accTypeCreditCard;

  /// No description provided for @txdValueIn.
  ///
  /// In ar, this message translates to:
  /// **'القيمة بـ {currency}'**
  String txdValueIn(String currency);

  /// No description provided for @txdAmountIn.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ بـ {currency}'**
  String txdAmountIn(String currency);

  /// No description provided for @txdAddValueIn.
  ///
  /// In ar, this message translates to:
  /// **'أضف القيمة بـ {currency}'**
  String txdAddValueIn(String currency);

  /// No description provided for @txdPendingToday.
  ///
  /// In ar, this message translates to:
  /// **'غير مؤكدة · اليوم'**
  String get txdPendingToday;

  /// No description provided for @txdPendingDays.
  ///
  /// In ar, this message translates to:
  /// **'غير مؤكدة · {days, plural, =1{منذ يوم} =2{منذ يومين} few{منذ {days} أيام} many{منذ {days} يومًا} other{منذ {days} يوم}}'**
  String txdPendingDays(int days);

  /// No description provided for @txdLinkedToCard.
  ///
  /// In ar, this message translates to:
  /// **'رُبطت بالبطاقة •••• {last4}. الحساب كما هو.'**
  String txdLinkedToCard(String last4);

  /// No description provided for @txdTypePurchase.
  ///
  /// In ar, this message translates to:
  /// **'شراء'**
  String get txdTypePurchase;

  /// No description provided for @txdTypeCashWithdrawal.
  ///
  /// In ar, this message translates to:
  /// **'سحب نقدي'**
  String get txdTypeCashWithdrawal;

  /// No description provided for @txdTypeTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويل'**
  String get txdTypeTransfer;

  /// No description provided for @txdTypeRefund.
  ///
  /// In ar, this message translates to:
  /// **'استرداد'**
  String get txdTypeRefund;

  /// No description provided for @txdTypeUnknown.
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get txdTypeUnknown;

  /// No description provided for @txdSourceCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة'**
  String get txdSourceCard;

  /// No description provided for @txdSourceAi.
  ///
  /// In ar, this message translates to:
  /// **'ذكاء اصطناعي'**
  String get txdSourceAi;

  /// No description provided for @txdSourceImport.
  ///
  /// In ar, this message translates to:
  /// **'ملف مستورد'**
  String get txdSourceImport;

  /// No description provided for @txdNotFound.
  ///
  /// In ar, this message translates to:
  /// **'العملية غير موجودة'**
  String get txdNotFound;

  /// No description provided for @txdConfirmed.
  ///
  /// In ar, this message translates to:
  /// **'مؤكدة'**
  String get txdConfirmed;

  /// No description provided for @txdNeedsReview.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج مراجعة'**
  String get txdNeedsReview;

  /// No description provided for @txdIgnored.
  ///
  /// In ar, this message translates to:
  /// **'متجاهلة'**
  String get txdIgnored;

  /// No description provided for @txdUncategorised.
  ///
  /// In ar, this message translates to:
  /// **'غير مصنّف'**
  String get txdUncategorised;

  /// No description provided for @txdType.
  ///
  /// In ar, this message translates to:
  /// **'النوع'**
  String get txdType;

  /// No description provided for @txdSource.
  ///
  /// In ar, this message translates to:
  /// **'المصدر'**
  String get txdSource;

  /// No description provided for @txdCard.
  ///
  /// In ar, this message translates to:
  /// **'البطاقة'**
  String get txdCard;

  /// No description provided for @txdNoCard.
  ///
  /// In ar, this message translates to:
  /// **'بدون بطاقة'**
  String get txdNoCard;

  /// No description provided for @txdChange.
  ///
  /// In ar, this message translates to:
  /// **'تغيير'**
  String get txdChange;

  /// No description provided for @txdOriginalCurrency.
  ///
  /// In ar, this message translates to:
  /// **'بالعملة الأصلية'**
  String get txdOriginalCurrency;

  /// No description provided for @txdBalanceAfter.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد بعد'**
  String get txdBalanceAfter;

  /// No description provided for @txdNote.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة'**
  String get txdNote;

  /// No description provided for @txdStatus.
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get txdStatus;

  /// No description provided for @txdOriginalText.
  ///
  /// In ar, this message translates to:
  /// **'النص الأصلي'**
  String get txdOriginalText;

  /// No description provided for @txdConfirmIgnored.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد العملية المتجاهلة'**
  String get txdConfirmIgnored;

  /// No description provided for @txdConfirmTx.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد العملية'**
  String get txdConfirmTx;

  /// No description provided for @txdDeleteTx.
  ///
  /// In ar, this message translates to:
  /// **'حذف العملية'**
  String get txdDeleteTx;

  /// No description provided for @txdTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل العملية'**
  String get txdTitle;

  /// No description provided for @txdCardSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة العملية'**
  String get txdCardSheetTitle;

  /// No description provided for @txdCardSheetNote.
  ///
  /// In ar, this message translates to:
  /// **'تغيير البطاقة لا ينقل العملية إلى حساب آخر.'**
  String get txdCardSheetNote;

  /// No description provided for @txdNoCardsOnAccount.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات مسجّلة على هذا الحساب.'**
  String get txdNoCardsOnAccount;

  /// No description provided for @txdStaysInAccount.
  ///
  /// In ar, this message translates to:
  /// **'العملية تظل في نفس الحساب وفي كل تقاريرك.'**
  String get txdStaysInAccount;

  /// No description provided for @txdCardRemoved.
  ///
  /// In ar, this message translates to:
  /// **'أُزيلت البطاقة. ما زالت العملية في الحساب نفسه.'**
  String get txdCardRemoved;

  /// No description provided for @txdConfirmedToast.
  ///
  /// In ar, this message translates to:
  /// **'تم تأكيد العملية.'**
  String get txdConfirmedToast;

  /// No description provided for @txdDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف العملية؟'**
  String get txdDeleteTitle;

  /// No description provided for @txdDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'ستُحذف من تقاريرك ورصيدك. لا يمكن التراجع عن ذلك.'**
  String get txdDeleteBody;

  /// No description provided for @txdSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get txdSave;

  /// No description provided for @accWillDetachTx.
  ///
  /// In ar, this message translates to:
  /// **'ستُفصل {count, plural, =1{عملية واحدة} =2{عمليتان} few{{count} عمليات} many{{count} عملية} other{{count} عملية}}'**
  String accWillDetachTx(int count);

  /// No description provided for @accWillArchiveCards.
  ///
  /// In ar, this message translates to:
  /// **'تُؤرشف {count, plural, =1{بطاقة واحدة} =2{بطاقتان} few{{count} بطاقات} many{{count} بطاقة} other{{count} بطاقة}}'**
  String accWillArchiveCards(int count);

  /// No description provided for @accWillArchiveBudgets.
  ///
  /// In ar, this message translates to:
  /// **'تُؤرشف {count, plural, =1{ميزانية واحدة} =2{ميزانيتان} few{{count} ميزانيات} many{{count} ميزانية} other{{count} ميزانية}}'**
  String accWillArchiveBudgets(int count);

  /// No description provided for @accDetachedTx.
  ///
  /// In ar, this message translates to:
  /// **'فُصلت {count, plural, =1{عملية واحدة} =2{عمليتان} few{{count} عمليات} many{{count} عملية} other{{count} عملية}}'**
  String accDetachedTx(int count);

  /// No description provided for @accArchivedCards.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{بطاقة واحدة مؤرشفة} =2{بطاقتان مؤرشفتان} few{{count} بطاقات مؤرشفة} many{{count} بطاقة مؤرشفة} other{{count} بطاقة مؤرشفة}}'**
  String accArchivedCards(int count);

  /// No description provided for @accReassignedGoals.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{هدف واحد مُنقول} =2{هدفان مُنقولان} few{{count} أهداف مُنقولة} many{{count} هدفًا مُنقولًا} other{{count} هدف مُنقول}}'**
  String accReassignedGoals(int count);

  /// No description provided for @accArchivedGoals.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{هدف واحد مؤرشف} =2{هدفان مؤرشفان} few{{count} أهداف مؤرشفة} many{{count} هدفًا مؤرشفًا} other{{count} هدف مؤرشف}}'**
  String accArchivedGoals(int count);

  /// No description provided for @accReassignedSubs.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{اشتراك واحد مُنقول} =2{اشتراكان مُنقولان} few{{count} اشتراكات مُنقولة} many{{count} اشتراكًا مُنقولًا} other{{count} اشتراك مُنقول}}'**
  String accReassignedSubs(int count);

  /// No description provided for @accArchivedSubs.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{اشتراك واحد مؤرشف} =2{اشتراكان مؤرشفان} few{{count} اشتراكات مؤرشفة} many{{count} اشتراكًا مؤرشفًا} other{{count} اشتراك مؤرشف}}'**
  String accArchivedSubs(int count);

  /// No description provided for @accDeletedSummary.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف الحساب — {summary}.'**
  String accDeletedSummary(String summary);

  /// No description provided for @pasteFieldHint.
  ///
  /// In ar, this message translates to:
  /// **'الصق نص رسالة البنك هنا...\nيمكنك لصق عدة رسائل متتالية.'**
  String get pasteFieldHint;

  /// No description provided for @commonAccountDefinite.
  ///
  /// In ar, this message translates to:
  /// **'الحساب'**
  String get commonAccountDefinite;

  /// No description provided for @commonOpenImperative.
  ///
  /// In ar, this message translates to:
  /// **'افتح'**
  String get commonOpenImperative;

  /// No description provided for @homeVsLastWeek.
  ///
  /// In ar, this message translates to:
  /// **'{percent}% عن الأسبوع الماضي'**
  String homeVsLastWeek(int percent);

  /// No description provided for @homePendingReviewTitle.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية واحدة في انتظار مراجعتك} =2{عمليتان في انتظار مراجعتك} few{{count} عمليات في انتظار مراجعتك} many{{count} عملية في انتظار مراجعتك} other{{count} عملية في انتظار مراجعتك}}'**
  String homePendingReviewTitle(int count);

  /// No description provided for @homeWeekSpentMore.
  ///
  /// In ar, this message translates to:
  /// **'انتبه — إنفاقك أعلى بـ{percent}% عن الأسبوع الماضي. راجع أكثر فئة تنفق فيها.'**
  String homeWeekSpentMore(int percent);

  /// No description provided for @homeWeekSpentLess.
  ///
  /// In ar, this message translates to:
  /// **'أحسنت — إنفاقك أقل بـ{percent}% عن الأسبوع الماضي. واصل على هذا النحو لتوفّر أكثر.'**
  String homeWeekSpentLess(int percent);

  /// No description provided for @homeShownTx.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية واحدة معروضة} =2{عمليتان معروضتان} few{{count} عمليات معروضة} many{{count} عملية معروضة} other{{count} عملية معروضة}}'**
  String homeShownTx(int count);

  /// No description provided for @homePendingSuffix.
  ///
  /// In ar, this message translates to:
  /// **'{count} قيد المراجعة'**
  String homePendingSuffix(String count);

  /// No description provided for @homeGoalSaved.
  ///
  /// In ar, this message translates to:
  /// **'تم توفير {amount}'**
  String homeGoalSaved(String amount);

  /// No description provided for @homeGoalRemaining.
  ///
  /// In ar, this message translates to:
  /// **'باقي {amount}'**
  String homeGoalRemaining(String amount);

  /// No description provided for @homeNeedPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'يلزمك {amount} شهريًا'**
  String homeNeedPerMonth(String amount);

  /// No description provided for @homeArrivesOn.
  ///
  /// In ar, this message translates to:
  /// **'بمعدلك الحالي ستصل {date}'**
  String homeArrivesOn(String date);

  /// No description provided for @homeLateBy.
  ///
  /// In ar, this message translates to:
  /// **'متأخر {months, plural, =1{شهرًا واحدًا} =2{شهرين} few{{months} أشهر} many{{months} شهرًا} other{{months} شهرًا}}'**
  String homeLateBy(int months);

  /// No description provided for @homeSessionExpiredTitle.
  ///
  /// In ar, this message translates to:
  /// **'الرجاء تسجيل الدخول مرة أخرى'**
  String get homeSessionExpiredTitle;

  /// No description provided for @homeSessionExpiredBody.
  ///
  /// In ar, this message translates to:
  /// **'انتهت صلاحية الجلسة، سجّل دخولك للمتابعة.'**
  String get homeSessionExpiredBody;

  /// No description provided for @homeSignIn.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get homeSignIn;

  /// No description provided for @homeLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل لوحة التحكم الآن'**
  String get homeLoadFailed;

  /// No description provided for @homeLoadFailedBody.
  ///
  /// In ar, this message translates to:
  /// **'تحقق من البيانات أو حاول التحديث مرة أخرى.'**
  String get homeLoadFailedBody;

  /// No description provided for @homeDailySpend.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات اليومية'**
  String get homeDailySpend;

  /// No description provided for @homeAllAccounts.
  ///
  /// In ar, this message translates to:
  /// **'كل الحسابات'**
  String get homeAllAccounts;

  /// No description provided for @homeSetMonthlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'حدّد ميزانية شهرية لتتابع المتاح'**
  String get homeSetMonthlyBudget;

  /// No description provided for @homeOverMonthBudget.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت ميزانية الشهر'**
  String get homeOverMonthBudget;

  /// No description provided for @homeSpendAboveUsual.
  ///
  /// In ar, this message translates to:
  /// **'مصروفك أعلى من المعتاد'**
  String get homeSpendAboveUsual;

  /// No description provided for @homeSteady.
  ///
  /// In ar, this message translates to:
  /// **'وضعك مستقر'**
  String get homeSteady;

  /// No description provided for @homeReviewToStayAccurate.
  ///
  /// In ar, this message translates to:
  /// **'راجعها لتبقى أرصدتك دقيقة'**
  String get homeReviewToStayAccurate;

  /// No description provided for @homeAvailableFromMonthBudget.
  ///
  /// In ar, this message translates to:
  /// **'متاح من ميزانية الشهر'**
  String get homeAvailableFromMonthBudget;

  /// No description provided for @homeNoTxTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مضافة'**
  String get homeNoTxTitle;

  /// No description provided for @homeNoTxBody.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة الخصم أو الإيداع من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائيًا على جهازك.'**
  String get homeNoTxBody;

  /// No description provided for @homeMoneyFriend.
  ///
  /// In ar, this message translates to:
  /// **'صديق مالي'**
  String get homeMoneyFriend;

  /// No description provided for @homeTodaySpend.
  ///
  /// In ar, this message translates to:
  /// **'مصروف اليوم'**
  String get homeTodaySpend;

  /// No description provided for @homeWeekSpend.
  ///
  /// In ar, this message translates to:
  /// **'مصروف الأسبوع'**
  String get homeWeekSpend;

  /// No description provided for @homeMonthSpend.
  ///
  /// In ar, this message translates to:
  /// **'مصروف الشهر'**
  String get homeMonthSpend;

  /// No description provided for @homeVsYesterday.
  ///
  /// In ar, this message translates to:
  /// **'عن أمس'**
  String get homeVsYesterday;

  /// No description provided for @homeVsLastWeekShort.
  ///
  /// In ar, this message translates to:
  /// **'عن الأسبوع الماضي'**
  String get homeVsLastWeekShort;

  /// No description provided for @homeGreeting.
  ///
  /// In ar, this message translates to:
  /// **'مرحباً 👋'**
  String get homeGreeting;

  /// No description provided for @homeTodayIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل اليوم'**
  String get homeTodayIncome;

  /// No description provided for @homeWeek.
  ///
  /// In ar, this message translates to:
  /// **'الأسبوع'**
  String get homeWeek;

  /// No description provided for @homeMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر'**
  String get homeMonth;

  /// No description provided for @homeMonthlySpend.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات الشهرية'**
  String get homeMonthlySpend;

  /// No description provided for @homeBudget.
  ///
  /// In ar, this message translates to:
  /// **'الميزانية'**
  String get homeBudget;

  /// No description provided for @homeManage.
  ///
  /// In ar, this message translates to:
  /// **'إدارة'**
  String get homeManage;

  /// No description provided for @homeSubsAndInstalments.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والأقساط'**
  String get homeSubsAndInstalments;

  /// No description provided for @homeNoBillsOnAccount.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد اشتراكات ولا أقساط على هذا الحساب.'**
  String get homeNoBillsOnAccount;

  /// No description provided for @homeNoGoalsOnAccount.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أهداف على هذا الحساب.'**
  String get homeNoGoalsOnAccount;

  /// No description provided for @homeFinishSetup.
  ///
  /// In ar, this message translates to:
  /// **'أكمل إعداد قِرش ✨'**
  String get homeFinishSetup;

  /// No description provided for @homeEnableBiometrics.
  ///
  /// In ar, this message translates to:
  /// **'فعّل قفل البصمة'**
  String get homeEnableBiometrics;

  /// No description provided for @homeAddSavingsGoal.
  ///
  /// In ar, this message translates to:
  /// **'أضف هدف ادخار'**
  String get homeAddSavingsGoal;

  /// No description provided for @homePlans.
  ///
  /// In ar, this message translates to:
  /// **'الخطط'**
  String get homePlans;

  /// No description provided for @homeNoActivePlans.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خطط نشطة'**
  String get homeNoActivePlans;

  /// No description provided for @homeCreatePlanHint.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ خطة ميزانية للسفر أو المناسبات'**
  String get homeCreatePlanHint;

  /// No description provided for @homeNewPlan.
  ///
  /// In ar, this message translates to:
  /// **'خطة جديدة'**
  String get homeNewPlan;

  /// No description provided for @homeSavingsCorner.
  ///
  /// In ar, this message translates to:
  /// **'ركن التوفير'**
  String get homeSavingsCorner;

  /// No description provided for @homeCouponExpires.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي {date}'**
  String homeCouponExpires(String date);

  /// No description provided for @homeDayAmountSemantics.
  ///
  /// In ar, this message translates to:
  /// **'{day}، {amount}'**
  String homeDayAmountSemantics(String day, String amount);

  /// No description provided for @homeVsYesterdayValue.
  ///
  /// In ar, this message translates to:
  /// **'{value} عن أمس'**
  String homeVsYesterdayValue(String value);

  /// No description provided for @homeExpectedPctOfMonth.
  ///
  /// In ar, this message translates to:
  /// **'المتوقع {percent}% من الشهر'**
  String homeExpectedPctOfMonth(int percent);

  /// No description provided for @homeAheadPct.
  ///
  /// In ar, this message translates to:
  /// **'مسبّق {percent}%'**
  String homeAheadPct(int percent);

  /// No description provided for @homeBehindPct.
  ///
  /// In ar, this message translates to:
  /// **'متأخر {percent}%'**
  String homeBehindPct(int percent);

  /// No description provided for @homeAtThisRatePrefix.
  ///
  /// In ar, this message translates to:
  /// **'بهذا المعدل ستنهي الشهر على '**
  String get homeAtThisRatePrefix;

  /// No description provided for @homeOverBudgetBy.
  ///
  /// In ar, this message translates to:
  /// **'أعلى بـ{amount} عن ميزانيتك.'**
  String homeOverBudgetBy(String amount);

  /// No description provided for @homeNofM.
  ///
  /// In ar, this message translates to:
  /// **'{shown} من {total}'**
  String homeNofM(int shown, int total);

  /// No description provided for @homeInDaysShort.
  ///
  /// In ar, this message translates to:
  /// **'بعد {days} ي'**
  String homeInDaysShort(int days);

  /// No description provided for @homePerYearAmount.
  ///
  /// In ar, this message translates to:
  /// **'{amount} {currency} سنويًا'**
  String homePerYearAmount(String amount, String currency);

  /// No description provided for @homeNoBudgetsOnAccount.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ميزانيات على هذا الحساب.'**
  String get homeNoBudgetsOnAccount;

  /// No description provided for @homeActiveBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية نشطة'**
  String get homeActiveBudget;

  /// No description provided for @homeAvailableCoupons.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد كوبونات متاحة} =1{كوبون واحد متاح} =2{كوبونان متاحان} few{{count} كوبونات متاحة} many{{count} كوبونًا متاحًا} other{{count} كوبون متاح}}'**
  String homeAvailableCoupons(int count);

  /// No description provided for @homePartnerOffers.
  ///
  /// In ar, this message translates to:
  /// **'عروض من شركاء قرش'**
  String get homePartnerOffers;

  /// No description provided for @homeAllCoupons.
  ///
  /// In ar, this message translates to:
  /// **'عرض كل الكوبونات'**
  String get homeAllCoupons;

  /// No description provided for @homeSpentToday.
  ///
  /// In ar, this message translates to:
  /// **'صرفت اليوم'**
  String get homeSpentToday;

  /// No description provided for @homeSevenDayAverage.
  ///
  /// In ar, this message translates to:
  /// **'متوسط ٧ أيام'**
  String get homeSevenDayAverage;

  /// No description provided for @homeSetMonthlyBudgetShort.
  ///
  /// In ar, this message translates to:
  /// **'حدّد ميزانية شهرية'**
  String get homeSetMonthlyBudgetShort;

  /// No description provided for @homeAvailableToday.
  ///
  /// In ar, this message translates to:
  /// **'متاح لليوم'**
  String get homeAvailableToday;

  /// No description provided for @homeTodayTransactions.
  ///
  /// In ar, this message translates to:
  /// **'عمليات اليوم'**
  String get homeTodayTransactions;

  /// No description provided for @homeTopThreeToday.
  ///
  /// In ar, this message translates to:
  /// **'أعلى ٣ اليوم'**
  String get homeTopThreeToday;

  /// No description provided for @homeUncategorised.
  ///
  /// In ar, this message translates to:
  /// **'غير مصنّفة'**
  String get homeUncategorised;

  /// No description provided for @homeNoMonthlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ميزانية شهرية — حدّدها لتعرف المتاح'**
  String get homeNoMonthlyBudget;

  /// No description provided for @homeTopCategories.
  ///
  /// In ar, this message translates to:
  /// **'أكبر التصنيفات'**
  String get homeTopCategories;

  /// No description provided for @homeSubsPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكات شهريًا'**
  String get homeSubsPerMonth;

  /// No description provided for @homeInstalmentsPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'أقساط شهريًا'**
  String get homeInstalmentsPerMonth;

  /// No description provided for @homeNextCharge.
  ///
  /// In ar, this message translates to:
  /// **'أقرب خصم'**
  String get homeNextCharge;

  /// No description provided for @homeChargeDatesThisMonth.
  ///
  /// In ar, this message translates to:
  /// **'مواعيد الخصم خلال الشهر'**
  String get homeChargeDatesThisMonth;

  /// No description provided for @homeInstalmentWord.
  ///
  /// In ar, this message translates to:
  /// **'قسط'**
  String get homeInstalmentWord;

  /// No description provided for @homeNoTxInPeriod.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات في هذه الفترة.'**
  String get homeNoTxInPeriod;

  /// No description provided for @homeSwipeForMore.
  ///
  /// In ar, this message translates to:
  /// **'اسحب لباقي العمليات · أو «الكل» لصفحة العمليات'**
  String get homeSwipeForMore;

  /// No description provided for @gdSavedOfTarget.
  ///
  /// In ar, this message translates to:
  /// **'وفّرت {saved} من {target} {currency}'**
  String gdSavedOfTarget(String saved, String target, String currency);

  /// No description provided for @gdRemaining.
  ///
  /// In ar, this message translates to:
  /// **'باقي {amount} {currency}'**
  String gdRemaining(String amount, String currency);

  /// No description provided for @gdRemainingWithDays.
  ///
  /// In ar, this message translates to:
  /// **'باقي {amount} · {days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}'**
  String gdRemainingWithDays(String amount, int days);

  /// No description provided for @gdRecommendedDaily.
  ///
  /// In ar, this message translates to:
  /// **'موصى: {amount} {currency} يوميًا'**
  String gdRecommendedDaily(String amount, String currency);

  /// No description provided for @cdCardTitle.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة •••• {last4}'**
  String cdCardTitle(String last4);

  /// No description provided for @gdTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الهدف'**
  String get gdTitle;

  /// No description provided for @gdAddToGoal.
  ///
  /// In ar, this message translates to:
  /// **'أضف للهدف'**
  String get gdAddToGoal;

  /// No description provided for @gdNotFound.
  ///
  /// In ar, this message translates to:
  /// **'الهدف غير موجود'**
  String get gdNotFound;

  /// No description provided for @gdDeleteGoal.
  ///
  /// In ar, this message translates to:
  /// **'حذف الهدف'**
  String get gdDeleteGoal;

  /// No description provided for @gdContributions.
  ///
  /// In ar, this message translates to:
  /// **'المساهمات'**
  String get gdContributions;

  /// No description provided for @gdNoContributions.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مساهمات بعد.'**
  String get gdNoContributions;

  /// No description provided for @gdDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الهدف؟'**
  String get gdDeleteTitle;

  /// No description provided for @gdDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف الهدف ومساهماته نهائياً.'**
  String get gdDeleteBody;

  /// No description provided for @gdSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ المساهمة الآن.'**
  String get gdSaveFailed;

  /// No description provided for @gdAddContribution.
  ///
  /// In ar, this message translates to:
  /// **'إضافة مساهمة'**
  String get gdAddContribution;

  /// No description provided for @bdgAmount.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get bdgAmount;

  /// No description provided for @gdSaveContribution.
  ///
  /// In ar, this message translates to:
  /// **'حفظ المساهمة'**
  String get gdSaveContribution;

  /// No description provided for @cdCardTransactions.
  ///
  /// In ar, this message translates to:
  /// **'عمليات هذه البطاقة'**
  String get cdCardTransactions;

  /// No description provided for @cdNoTxYet.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات بعد'**
  String get cdNoTxYet;

  /// No description provided for @bfInvalidAmount.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ غير صالح'**
  String get bfInvalidAmount;

  /// No description provided for @bfPickFutureDue.
  ///
  /// In ar, this message translates to:
  /// **'اختر تاريخ استحقاق قادمًا أو اليوم.'**
  String get bfPickFutureDue;

  /// No description provided for @bfPaidFromForm.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع يدويًا من النموذج'**
  String get bfPaidFromForm;

  /// No description provided for @bfSavedButPaymentFailed.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الفاتورة، لكن فشل تسجيل الدفعة — أعد المحاولة بنفس البيانات.'**
  String get bfSavedButPaymentFailed;

  /// No description provided for @bfSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع أثناء الحفظ. حاول مجددًا.'**
  String get bfSaveFailed;

  /// No description provided for @bfAddBill.
  ///
  /// In ar, this message translates to:
  /// **'إضافة فاتورة'**
  String get bfAddBill;

  /// No description provided for @bfEditBill.
  ///
  /// In ar, this message translates to:
  /// **'تعديل فاتورة'**
  String get bfEditBill;

  /// No description provided for @bfSubscription.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك'**
  String get bfSubscription;

  /// No description provided for @bfInstalment.
  ///
  /// In ar, this message translates to:
  /// **'قسط'**
  String get bfInstalment;

  /// No description provided for @bfBillName.
  ///
  /// In ar, this message translates to:
  /// **'اسم الفاتورة'**
  String get bfBillName;

  /// No description provided for @bfEnterName.
  ///
  /// In ar, this message translates to:
  /// **'اكتب الاسم'**
  String get bfEnterName;

  /// No description provided for @bfEnterValidAmount.
  ///
  /// In ar, this message translates to:
  /// **'اكتب مبلغ صحيح'**
  String get bfEnterValidAmount;

  /// No description provided for @bfManuallyPaidAmount.
  ///
  /// In ar, this message translates to:
  /// **'مبلغ مدفوع يدويًا'**
  String get bfManuallyPaidAmount;

  /// No description provided for @bfPaidManuallyFromSub.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع من الاشتراك يدويًا'**
  String get bfPaidManuallyFromSub;

  /// No description provided for @bfRecordManualHint.
  ///
  /// In ar, this message translates to:
  /// **'إذا دفعت مبلغًا ولم يظهر كعملية، سجّله هنا'**
  String get bfRecordManualHint;

  /// No description provided for @bfAmountAboveZero.
  ///
  /// In ar, this message translates to:
  /// **'اكتب مبلغ أكبر من صفر'**
  String get bfAmountAboveZero;

  /// No description provided for @bfAccountCurrency.
  ///
  /// In ar, this message translates to:
  /// **'عملة الحساب'**
  String get bfAccountCurrency;

  /// No description provided for @bfLender.
  ///
  /// In ar, this message translates to:
  /// **'المقرض / الجهة (Tamara, بنك...)'**
  String get bfLender;

  /// No description provided for @bfTotalInstalments.
  ///
  /// In ar, this message translates to:
  /// **'عدد الأقساط الكلي'**
  String get bfTotalInstalments;

  /// No description provided for @bfPaidSoFar.
  ///
  /// In ar, this message translates to:
  /// **'المدفوع منها'**
  String get bfPaidSoFar;

  /// No description provided for @bfPurchaseValue.
  ///
  /// In ar, this message translates to:
  /// **'قيمة الشراء / القرض'**
  String get bfPurchaseValue;

  /// No description provided for @bfInterestOptional.
  ///
  /// In ar, this message translates to:
  /// **'الفائدة % (اختياري)'**
  String get bfInterestOptional;

  /// No description provided for @bfHowOften.
  ///
  /// In ar, this message translates to:
  /// **'كل كم؟'**
  String get bfHowOften;

  /// No description provided for @bfEveryHowManyDays.
  ///
  /// In ar, this message translates to:
  /// **'كل كم يوم؟'**
  String get bfEveryHowManyDays;

  /// No description provided for @bfEnterValidDays.
  ///
  /// In ar, this message translates to:
  /// **'اكتب عدد أيام صحيح'**
  String get bfEnterValidDays;

  /// No description provided for @bfNextDueDate.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستحقاق القادم'**
  String get bfNextDueDate;

  /// No description provided for @bfEnableReminder.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل التذكير'**
  String get bfEnableReminder;

  /// No description provided for @bfConfirmedBill.
  ///
  /// In ar, this message translates to:
  /// **'فاتورة مؤكدة'**
  String get bfConfirmedBill;

  /// No description provided for @bfPresetCarInstalment.
  ///
  /// In ar, this message translates to:
  /// **'قسط سيارة'**
  String get bfPresetCarInstalment;

  /// No description provided for @bfPresetRent.
  ///
  /// In ar, this message translates to:
  /// **'إيجار'**
  String get bfPresetRent;

  /// No description provided for @bfPresetPhone.
  ///
  /// In ar, this message translates to:
  /// **'جوال'**
  String get bfPresetPhone;

  /// No description provided for @bfPresetLaptop.
  ///
  /// In ar, this message translates to:
  /// **'لابتوب'**
  String get bfPresetLaptop;

  /// No description provided for @bfPresetFurniture.
  ///
  /// In ar, this message translates to:
  /// **'أثاث'**
  String get bfPresetFurniture;

  /// No description provided for @bfPresetEducation.
  ///
  /// In ar, this message translates to:
  /// **'تعليم'**
  String get bfPresetEducation;

  /// No description provided for @bfPresetTravel.
  ///
  /// In ar, this message translates to:
  /// **'سفر'**
  String get bfPresetTravel;

  /// No description provided for @bfPresetMedical.
  ///
  /// In ar, this message translates to:
  /// **'علاج'**
  String get bfPresetMedical;

  /// No description provided for @bfPresetWedding.
  ///
  /// In ar, this message translates to:
  /// **'زواج'**
  String get bfPresetWedding;

  /// No description provided for @bfPresetGold.
  ///
  /// In ar, this message translates to:
  /// **'ذهب'**
  String get bfPresetGold;

  /// No description provided for @bfPresetAppliances.
  ///
  /// In ar, this message translates to:
  /// **'أجهزة منزلية'**
  String get bfPresetAppliances;

  /// No description provided for @bfPresetComputer.
  ///
  /// In ar, this message translates to:
  /// **'كمبيوتر'**
  String get bfPresetComputer;

  /// No description provided for @bfSearchService.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن خدمة...'**
  String get bfSearchService;

  /// No description provided for @bfSearchInstalment.
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن قسط...'**
  String get bfSearchInstalment;

  /// No description provided for @bfCustomSub.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك مخصص'**
  String get bfCustomSub;

  /// No description provided for @bfCustomInstalment.
  ///
  /// In ar, this message translates to:
  /// **'قسط مخصص'**
  String get bfCustomInstalment;

  /// No description provided for @bfAddManuallyHint.
  ///
  /// In ar, this message translates to:
  /// **'أضف الاسم والمبلغ والتكرار يدويًا'**
  String get bfAddManuallyHint;

  /// No description provided for @bfMostUsed.
  ///
  /// In ar, this message translates to:
  /// **'الأكثر استخدامًا'**
  String get bfMostUsed;

  /// No description provided for @afVodafoneCash.
  ///
  /// In ar, this message translates to:
  /// **'فودافون كاش'**
  String get afVodafoneCash;

  /// No description provided for @afOrangeCash.
  ///
  /// In ar, this message translates to:
  /// **'أورنج كاش'**
  String get afOrangeCash;

  /// No description provided for @afEtisalatCash.
  ///
  /// In ar, this message translates to:
  /// **'e& كاش'**
  String get afEtisalatCash;

  /// No description provided for @afWePay.
  ///
  /// In ar, this message translates to:
  /// **'وي باي'**
  String get afWePay;

  /// No description provided for @afCurrencyLockedInUse.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن تغيير عملة حساب يحتوي على رصيد أو عمليات.'**
  String get afCurrencyLockedInUse;

  /// No description provided for @afUsageCheckFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر التحقق من استخدام الحساب؛ لم يتم تغيير العملة.'**
  String get afUsageCheckFailed;

  /// No description provided for @afEnterAccountName.
  ///
  /// In ar, this message translates to:
  /// **'الرجاء إدخال اسم الحساب'**
  String get afEnterAccountName;

  /// No description provided for @afPaymentDayRange.
  ///
  /// In ar, this message translates to:
  /// **'يوم السداد يجب أن يكون بين 1 و31'**
  String get afPaymentDayRange;

  /// No description provided for @afSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع — بياناتك محفوظة، حاول مجددًا.'**
  String get afSaveFailed;

  /// No description provided for @afDeleteAccount.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب'**
  String get afDeleteAccount;

  /// No description provided for @afDeletePrepFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحضير الحذف — حاول مجددًا.'**
  String get afDeletePrepFailed;

  /// No description provided for @afCannotDeleteLast.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن حذف آخر حساب.'**
  String get afCannotDeleteLast;

  /// No description provided for @afNeedsExplicitDecision.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الحذف — بعض العناصر تحتاج قرارًا صريحًا.'**
  String get afNeedsExplicitDecision;

  /// No description provided for @afDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الحساب — حاول مجددًا.'**
  String get afDeleteFailed;

  /// No description provided for @afEditAccount.
  ///
  /// In ar, this message translates to:
  /// **'تعديل حساب'**
  String get afEditAccount;

  /// No description provided for @afNewAccount.
  ///
  /// In ar, this message translates to:
  /// **'حساب جديد'**
  String get afNewAccount;

  /// No description provided for @afAccountName.
  ///
  /// In ar, this message translates to:
  /// **'اسم الحساب'**
  String get afAccountName;

  /// No description provided for @afAccountNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: كاش مصر، بنك الراجحي، محفظة USD'**
  String get afAccountNameHint;

  /// No description provided for @afCurrencyLockedShort.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكن تغيير عملة حساب مستخدم'**
  String get afCurrencyLockedShort;

  /// No description provided for @afDefaultAccountHint.
  ///
  /// In ar, this message translates to:
  /// **'العمليات الجديدة تتسجّل هنا تلقائيًا'**
  String get afDefaultAccountHint;

  /// No description provided for @afExcludeFromTotals.
  ///
  /// In ar, this message translates to:
  /// **'استبعاد من الإجماليات'**
  String get afExcludeFromTotals;

  /// No description provided for @afOpeningBalance.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد الافتتاحي (اختياري)'**
  String get afOpeningBalance;

  /// No description provided for @afBankAccountNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم الحساب البنكي (اختياري)'**
  String get afBankAccountNumber;

  /// No description provided for @afHelpsMatching.
  ///
  /// In ar, this message translates to:
  /// **'يساعد مطابقة الرسائل'**
  String get afHelpsMatching;

  /// No description provided for @afCreditLimit.
  ///
  /// In ar, this message translates to:
  /// **'الحد الائتماني (اختياري)'**
  String get afCreditLimit;

  /// No description provided for @afAvailableBalance.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد المتاح (اختياري)'**
  String get afAvailableBalance;

  /// No description provided for @afPaymentDay.
  ///
  /// In ar, this message translates to:
  /// **'يوم السداد (1–31، اختياري)'**
  String get afPaymentDay;

  /// No description provided for @afProvider.
  ///
  /// In ar, this message translates to:
  /// **'المزوّد'**
  String get afProvider;

  /// No description provided for @afUnspecified.
  ///
  /// In ar, this message translates to:
  /// **'غير محدَّد'**
  String get afUnspecified;

  /// No description provided for @afAdvancedOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات متقدمة'**
  String get afAdvancedOptions;

  /// No description provided for @gfRecommendedFor.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ الموصى به: {amount} {currency} يوميًا لـ {days, plural, =1{يوم واحد} =2{يومين} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}.'**
  String gfRecommendedFor(String amount, String currency, int days);

  /// No description provided for @bfsSuggestAfterMoreTx.
  ///
  /// In ar, this message translates to:
  /// **'بعد إضافة عمليات أكثر، سنقترح ميزانية {period} مناسبة.'**
  String bfsSuggestAfterMoreTx(String period);

  /// No description provided for @bfsSuggestion.
  ///
  /// In ar, this message translates to:
  /// **'اقتراح ميزانية {period}: {value}'**
  String bfsSuggestion(String period, String value);

  /// No description provided for @cfDeleteCardBody.
  ///
  /// In ar, this message translates to:
  /// **'حذف البطاقة لن يحذف عملياتها — تبقى محفوظة بأرقامها. قد تظهر بطاقة تلقائية بنفس الأرقام إذا وصلت رسالة جديدة.'**
  String get cfDeleteCardBody;

  /// No description provided for @mtEnterValidAmount.
  ///
  /// In ar, this message translates to:
  /// **'اكتب مبلغًا صحيحًا.'**
  String get mtEnterValidAmount;

  /// No description provided for @mtPickCategory.
  ///
  /// In ar, this message translates to:
  /// **'اختر تصنيف العملية.'**
  String get mtPickCategory;

  /// No description provided for @mtSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ العملية الآن.'**
  String get mtSaveFailed;

  /// No description provided for @mtDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف العملية من التقارير والميزانيات.'**
  String get mtDeleteBody;

  /// No description provided for @mtDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حذف العملية الآن.'**
  String get mtDeleteFailed;

  /// No description provided for @mtConfirmFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تأكيد العملية الآن.'**
  String get mtConfirmFailed;

  /// No description provided for @mtAddManually.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عملية يدويًا'**
  String get mtAddManually;

  /// No description provided for @mtCategoriesFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل التصنيفات'**
  String get mtCategoriesFailed;

  /// No description provided for @mtMerchantOptional.
  ///
  /// In ar, this message translates to:
  /// **'المتجر أو المصدر (اختياري)'**
  String get mtMerchantOptional;

  /// No description provided for @mtNoteOptional.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة (اختياري)'**
  String get mtNoteOptional;

  /// No description provided for @mtSaveEdits.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديلات'**
  String get mtSaveEdits;

  /// No description provided for @mtAddTransaction.
  ///
  /// In ar, this message translates to:
  /// **'إضافة العملية'**
  String get mtAddTransaction;

  /// No description provided for @mtTxConfirmed.
  ///
  /// In ar, this message translates to:
  /// **'العملية مؤكدة'**
  String get mtTxConfirmed;

  /// No description provided for @cfEnterValidLast4.
  ///
  /// In ar, this message translates to:
  /// **'أدخل آخر 4 أرقام صحيحة'**
  String get cfEnterValidLast4;

  /// No description provided for @cfDuplicateCard.
  ///
  /// In ar, this message translates to:
  /// **'توجد بطاقة بنفس الأرقام في هذا الحساب'**
  String get cfDuplicateCard;

  /// No description provided for @cfSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ البطاقة — حاول مجددًا.'**
  String get cfSaveFailed;

  /// No description provided for @cfDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف البطاقة؟'**
  String get cfDeleteTitle;

  /// No description provided for @cfDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف البطاقة — حاول مجددًا.'**
  String get cfDeleteFailed;

  /// No description provided for @cfEditCard.
  ///
  /// In ar, this message translates to:
  /// **'تعديل بطاقة'**
  String get cfEditCard;

  /// No description provided for @cfNewCard.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة جديدة'**
  String get cfNewCard;

  /// No description provided for @cfAutoDetected.
  ///
  /// In ar, this message translates to:
  /// **'مكتشفة تلقائيًا من رسائلك'**
  String get cfAutoDetected;

  /// No description provided for @cfShortNameOptional.
  ///
  /// In ar, this message translates to:
  /// **'اسم مختصر (اختياري)'**
  String get cfShortNameOptional;

  /// No description provided for @cfShortNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثال: راتب، سفر'**
  String get cfShortNameHint;

  /// No description provided for @cfLast4.
  ///
  /// In ar, this message translates to:
  /// **'آخر 4 أرقام'**
  String get cfLast4;

  /// No description provided for @cfNetwork.
  ///
  /// In ar, this message translates to:
  /// **'الشبكة'**
  String get cfNetwork;

  /// Shown when the card network could not be detected. Visa, Mastercard and Amex are brand names and are not translated.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة'**
  String get cardNetworkGeneric;

  /// No description provided for @cfDesign.
  ///
  /// In ar, this message translates to:
  /// **'التصميم'**
  String get cfDesign;

  /// No description provided for @cfAccentOptional.
  ///
  /// In ar, this message translates to:
  /// **'لون مميّز (اختياري)'**
  String get cfAccentOptional;

  /// No description provided for @cfAccentNone.
  ///
  /// In ar, this message translates to:
  /// **'بدون لون مميّز'**
  String get cfAccentNone;

  /// No description provided for @cfAccentColourName.
  ///
  /// In ar, this message translates to:
  /// **'{colour, select, amber{كهرماني} red{أحمر} pink{وردي} purple{بنفسجي} blue{أزرق} cyan{سماوي} emerald{زمردي} lime{أخضر ليموني} orange{برتقالي} teal{فيروزي} other{لون مميّز}}'**
  String cfAccentColourName(String colour);

  /// No description provided for @cfLinkedAccount.
  ///
  /// In ar, this message translates to:
  /// **'الحساب المرتبط'**
  String get cfLinkedAccount;

  /// No description provided for @cfDeleteCard.
  ///
  /// In ar, this message translates to:
  /// **'حذف البطاقة'**
  String get cfDeleteCard;

  /// No description provided for @cfNoAccount.
  ///
  /// In ar, this message translates to:
  /// **'بدون حساب'**
  String get cfNoAccount;

  /// No description provided for @gfNewGoal.
  ///
  /// In ar, this message translates to:
  /// **'هدف جديد'**
  String get gfNewGoal;

  /// No description provided for @gfEditGoal.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الهدف'**
  String get gfEditGoal;

  /// No description provided for @gfGoalName.
  ///
  /// In ar, this message translates to:
  /// **'اسم الهدف'**
  String get gfGoalName;

  /// No description provided for @gfEnterGoalName.
  ///
  /// In ar, this message translates to:
  /// **'اكتب اسم الهدف'**
  String get gfEnterGoalName;

  /// No description provided for @gfTargetAmount.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستهدف'**
  String get gfTargetAmount;

  /// No description provided for @gfEnterValidAmount.
  ///
  /// In ar, this message translates to:
  /// **'أدخل مبلغًا صحيحًا'**
  String get gfEnterValidAmount;

  /// No description provided for @gfDeadline.
  ///
  /// In ar, this message translates to:
  /// **'الموعد النهائي'**
  String get gfDeadline;

  /// No description provided for @gfOptional.
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get gfOptional;

  /// No description provided for @gfRecommendedAfterDate.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ الموصى به يظهر بعد اختيار التاريخ.'**
  String get gfRecommendedAfterDate;

  /// No description provided for @gfAutoSaving.
  ///
  /// In ar, this message translates to:
  /// **'ادخار تلقائي'**
  String get gfAutoSaving;

  /// No description provided for @gfAutoSavingHint.
  ///
  /// In ar, this message translates to:
  /// **'يضيف قِرش المبلغ للهدف كل فترة تلقائيًا'**
  String get gfAutoSavingHint;

  /// No description provided for @gfFrequency.
  ///
  /// In ar, this message translates to:
  /// **'التكرار'**
  String get gfFrequency;

  /// No description provided for @gfCreateGoal.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ الهدف'**
  String get gfCreateGoal;

  /// No description provided for @gfSaveEdit.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديل'**
  String get gfSaveEdit;

  /// No description provided for @gfPickFutureDeadline.
  ///
  /// In ar, this message translates to:
  /// **'اختر موعدًا نهائيًا قادمًا أو اليوم.'**
  String get gfPickFutureDeadline;

  /// No description provided for @bfsNewBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية جديدة'**
  String get bfsNewBudget;

  /// No description provided for @bfsPickCategory.
  ///
  /// In ar, this message translates to:
  /// **'اختر تصنيفًا'**
  String get bfsPickCategory;

  /// No description provided for @bfsSaveBudget.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الميزانية'**
  String get bfsSaveBudget;

  /// No description provided for @bfsDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف هذه الميزانية نهائياً.'**
  String get bfsDeleteBody;

  /// No description provided for @bfsPeriodDaily.
  ///
  /// In ar, this message translates to:
  /// **'يومية'**
  String get bfsPeriodDaily;

  /// No description provided for @bfsPeriodWeekly.
  ///
  /// In ar, this message translates to:
  /// **'أسبوعية'**
  String get bfsPeriodWeekly;

  /// No description provided for @bfsPeriodMonthly.
  ///
  /// In ar, this message translates to:
  /// **'شهرية'**
  String get bfsPeriodMonthly;

  /// No description provided for @bfsPeriodYearly.
  ///
  /// In ar, this message translates to:
  /// **'سنوية'**
  String get bfsPeriodYearly;

  /// No description provided for @bfsComputingSuggestion.
  ///
  /// In ar, this message translates to:
  /// **'نحسب اقتراحًا من آخر 30 يومًا...'**
  String get bfsComputingSuggestion;

  /// No description provided for @bfsUseIt.
  ///
  /// In ar, this message translates to:
  /// **'استخدمه'**
  String get bfsUseIt;

  /// No description provided for @bfsBudgetPeriod.
  ///
  /// In ar, this message translates to:
  /// **'دورية الميزانية'**
  String get bfsBudgetPeriod;

  /// No description provided for @bdgDeleteBudget.
  ///
  /// In ar, this message translates to:
  /// **'حذف الميزانية'**
  String get bdgDeleteBudget;

  /// No description provided for @mtKindExpense.
  ///
  /// In ar, this message translates to:
  /// **'مصروف'**
  String get mtKindExpense;

  /// No description provided for @bdsIncludesLegacyManual.
  ///
  /// In ar, this message translates to:
  /// **'يشمل {amount} {currency} مدفوعة يدويًا قديمة.'**
  String bdsIncludesLegacyManual(String amount, String currency);

  /// No description provided for @bdsPayAllRemaining.
  ///
  /// In ar, this message translates to:
  /// **'سداد كل الأقساط المتبقية ({count}) دفعة واحدة'**
  String bdsPayAllRemaining(int count);

  /// No description provided for @bdsPaymentForPeriod.
  ///
  /// In ar, this message translates to:
  /// **'هذه الدفعة عن الفترة {from} - {to}'**
  String bdsPaymentForPeriod(String from, String to);

  /// No description provided for @bdsPaymentForInstalment.
  ///
  /// In ar, this message translates to:
  /// **'هذه الدفعة عن قسط رقم {index} للفترة {from} - {to}'**
  String bdsPaymentForInstalment(int index, String from, String to);

  /// No description provided for @bdsPayRemainingInFull.
  ///
  /// In ar, this message translates to:
  /// **'سدّد المتبقي بالكامل ({amount} {currency})'**
  String bdsPayRemainingInFull(String amount, String currency);

  /// No description provided for @bdsInstalmentNamed.
  ///
  /// In ar, this message translates to:
  /// **'قسط {name}'**
  String bdsInstalmentNamed(String name);

  /// No description provided for @bdsSubscriptionNamed.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك {name}'**
  String bdsSubscriptionNamed(String name);

  /// No description provided for @bdsDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم حذف «{name}» من الاشتراكات والأقساط.'**
  String bdsDeleteBody(String name);

  /// No description provided for @bdsDeleted.
  ///
  /// In ar, this message translates to:
  /// **'حُذف {name}'**
  String bdsDeleted(String name);

  /// No description provided for @bdsInstalmentNumber.
  ///
  /// In ar, this message translates to:
  /// **'قسط رقم {index}'**
  String bdsInstalmentNumber(int index);

  /// No description provided for @bdsPaymentNamed.
  ///
  /// In ar, this message translates to:
  /// **'دفعة {name}'**
  String bdsPaymentNamed(String name);

  /// No description provided for @plCardShort.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة ••{last4}'**
  String plCardShort(String last4);

  /// No description provided for @plPerDayLeft.
  ///
  /// In ar, this message translates to:
  /// **'/يوم · {days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}'**
  String plPerDayLeft(int days);

  /// No description provided for @plDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'ستُحذف خطة «{name}». لن تتأثر العمليات نفسها.'**
  String plDeleteBody(String name);

  /// No description provided for @plOfBudget.
  ///
  /// In ar, this message translates to:
  /// **'من {amount} {currency}'**
  String plOfBudget(String amount, String currency);

  /// No description provided for @bdsInstalmentValue.
  ///
  /// In ar, this message translates to:
  /// **'قيمة القسط'**
  String get bdsInstalmentValue;

  /// No description provided for @bdsTotalPaid.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مدفوع'**
  String get bdsTotalPaid;

  /// No description provided for @bdsRecordedPayments.
  ///
  /// In ar, this message translates to:
  /// **'دفعات مسجّلة'**
  String get bdsRecordedPayments;

  /// No description provided for @bdsPaid.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع'**
  String get bdsPaid;

  /// No description provided for @bdsRemaining.
  ///
  /// In ar, this message translates to:
  /// **'متبقي'**
  String get bdsRemaining;

  /// No description provided for @bdsProgress.
  ///
  /// In ar, this message translates to:
  /// **'تقدم'**
  String get bdsProgress;

  /// No description provided for @bdsRecordInstalmentPayment.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفع قسط'**
  String get bdsRecordInstalmentPayment;

  /// No description provided for @bdsRecordPayment.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل دفعة'**
  String get bdsRecordPayment;

  /// No description provided for @bdsPaymentHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل الدفعات'**
  String get bdsPaymentHistory;

  /// No description provided for @bdsNoManualInstalmentPayments.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بعد دفعات أقساط مسجّلة يدويًا.'**
  String get bdsNoManualInstalmentPayments;

  /// No description provided for @bdsNoManualSubPayments.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بعد دفعات اشتراك مسجّلة يدويًا.'**
  String get bdsNoManualSubPayments;

  /// No description provided for @bdsSuggestedToLink.
  ///
  /// In ar, this message translates to:
  /// **'عمليات مقترحة للربط'**
  String get bdsSuggestedToLink;

  /// No description provided for @bdsNameMatchNote.
  ///
  /// In ar, this message translates to:
  /// **'مطابقة بالاسم — لا تُحتسب ضمن المدفوع حتى تربطها كدفعة.'**
  String get bdsNameMatchNote;

  /// No description provided for @bdsNoSuggestions.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مقترحة للربط.'**
  String get bdsNoSuggestions;

  /// No description provided for @bdsOptionalNote.
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة اختيارية'**
  String get bdsOptionalNote;

  /// No description provided for @bdsRecordFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدفعة الآن. حاول مجددًا.'**
  String get bdsRecordFailed;

  /// No description provided for @bdsSavedButNotLinked.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ العملية، لكن تعذّر ربط الدفعة. أعد المحاولة ولن تتكرر العملية.'**
  String get bdsSavedButNotLinked;

  /// No description provided for @bdsRecord.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل'**
  String get bdsRecord;

  /// No description provided for @bdsPaymentRecorded.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل الدفعة وأضيفت للعمليات.'**
  String get bdsPaymentRecorded;

  /// No description provided for @bdsDeleteBillTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الفاتورة؟'**
  String get bdsDeleteBillTitle;

  /// No description provided for @bdsDeleteBillFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الفاتورة الآن.'**
  String get bdsDeleteBillFailed;

  /// No description provided for @bdsDeletePaymentTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الدفعة؟'**
  String get bdsDeletePaymentTitle;

  /// No description provided for @bdsDeletePaymentBody.
  ///
  /// In ar, this message translates to:
  /// **'سيُحذف سجل الدفع اليدوي هذا نهائيًا.'**
  String get bdsDeletePaymentBody;

  /// No description provided for @bdsDeletePaymentFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الدفعة الآن.'**
  String get bdsDeletePaymentFailed;

  /// No description provided for @plSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية لكل مناسبة، تتابع نفسها'**
  String get plSubtitle;

  /// No description provided for @plLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحميل'**
  String get plLoadFailed;

  /// No description provided for @plNoPlans.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد خطط بعد'**
  String get plNoPlans;

  /// No description provided for @plEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ خطة لرحلة أو مناسبة: ميزانية وفترة والبطاقات التي ستصرف منها، ويتابعها قِرش لك.'**
  String get plEmptyBody;

  /// No description provided for @plAllSpendInPeriod.
  ///
  /// In ar, this message translates to:
  /// **'كل المصروفات في الفترة'**
  String get plAllSpendInPeriod;

  /// No description provided for @plSpecificAccounts.
  ///
  /// In ar, this message translates to:
  /// **'حسابات محددة'**
  String get plSpecificAccounts;

  /// No description provided for @plEnded.
  ///
  /// In ar, this message translates to:
  /// **'منتهية'**
  String get plEnded;

  /// No description provided for @plPlanOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات الخطة'**
  String get plPlanOptions;

  /// No description provided for @plDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الخطة؟'**
  String get plDeleteTitle;

  /// No description provided for @plDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الخطة الآن.'**
  String get plDeleteFailed;

  /// No description provided for @plDetails.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الخطة'**
  String get plDetails;

  /// No description provided for @plNotFound.
  ///
  /// In ar, this message translates to:
  /// **'الخطة غير موجودة'**
  String get plNotFound;

  /// No description provided for @plLinkTransaction.
  ///
  /// In ar, this message translates to:
  /// **'ربط عملية'**
  String get plLinkTransaction;

  /// No description provided for @plHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل الخطة'**
  String get plHistory;

  /// No description provided for @plTxLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل العمليات'**
  String get plTxLoadFailed;

  /// No description provided for @plNoLinkedTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مرتبطة'**
  String get plNoLinkedTx;

  /// No description provided for @plLinkHint.
  ///
  /// In ar, this message translates to:
  /// **'اربط عملية موجودة أو اختر حسابًا أو بطاقة للخطة.'**
  String get plLinkHint;

  /// No description provided for @plLinkToPlan.
  ///
  /// In ar, this message translates to:
  /// **'ربط عملية بالخطة'**
  String get plLinkToPlan;

  /// No description provided for @plNoSuitableTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مناسبة'**
  String get plNoSuitableTx;

  /// No description provided for @plAllLinkedAlready.
  ///
  /// In ar, this message translates to:
  /// **'كل العمليات المناسبة مرتبطة بالفعل أو غير مؤكدة.'**
  String get plAllLinkedAlready;

  /// No description provided for @pcrWhyBody.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات والأهداف القديمة لا تحفظ عملة مع المبلغ. لذلك لن يخمّن قِرش عملتها، بل تختار أنت كيف تريد معاملتها. لن يتغيّر أي مبلغ ولن تُحذف أي بيانات. مساهمات الأهداف تتبع عملة الهدف تلقائيًا.'**
  String get pcrWhyBody;

  /// No description provided for @pcrNoCurrencySet.
  ///
  /// In ar, this message translates to:
  /// **'{amount} · بدون عملة محددة'**
  String pcrNoCurrencySet(String amount);

  /// No description provided for @pcrConfirmedFor.
  ///
  /// In ar, this message translates to:
  /// **'تم تأكيد {currency} لكل الميزانيات والأهداف الحالية.'**
  String pcrConfirmedFor(String currency);

  /// No description provided for @bkLastBackup.
  ///
  /// In ar, this message translates to:
  /// **'آخر نسخة: {date} · {time}'**
  String bkLastBackup(String date, String time);

  /// No description provided for @pcrTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد عملة التخطيط'**
  String get pcrTitle;

  /// No description provided for @pcrListChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغيّرت الميزانيات أو الأهداف'**
  String get pcrListChanged;

  /// No description provided for @pcrListChangedBody.
  ///
  /// In ar, this message translates to:
  /// **'القرار السابق لم يعد يطابق القائمة الحالية. حدّث القائمة ثم أكّد العملات مرة أخرى.'**
  String get pcrListChangedBody;

  /// No description provided for @pcrRefreshList.
  ///
  /// In ar, this message translates to:
  /// **'تحديث القائمة'**
  String get pcrRefreshList;

  /// No description provided for @pcrWhyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لماذا نحتاج تأكيدك؟'**
  String get pcrWhyTitle;

  /// No description provided for @pcrDefaultSuggestion.
  ///
  /// In ar, this message translates to:
  /// **'الاقتراح الافتراضي'**
  String get pcrDefaultSuggestion;

  /// No description provided for @pcrSuggestionNote.
  ///
  /// In ar, this message translates to:
  /// **'هذا اقتراح من عملتك الحالية فقط، وليس قراراً محفوظاً حتى تؤكده.'**
  String get pcrSuggestionNote;

  /// No description provided for @pcrHowToConfirm.
  ///
  /// In ar, this message translates to:
  /// **'طريقة التأكيد'**
  String get pcrHowToConfirm;

  /// No description provided for @pcrOneCurrencyForAll.
  ///
  /// In ar, this message translates to:
  /// **'عملة واحدة للجميع'**
  String get pcrOneCurrencyForAll;

  /// No description provided for @pcrOneCurrencyHint.
  ///
  /// In ar, this message translates to:
  /// **'كل الميزانيات والأهداف الحالية تستخدم نفس العملة'**
  String get pcrOneCurrencyHint;

  /// No description provided for @pcrPerItem.
  ///
  /// In ar, this message translates to:
  /// **'تحديد عملة لكل عنصر'**
  String get pcrPerItem;

  /// No description provided for @pcrPerItemHint.
  ///
  /// In ar, this message translates to:
  /// **'اختر عملة مختلفة لكل ميزانية أو هدف عند الحاجة'**
  String get pcrPerItemHint;

  /// No description provided for @pcrSaveSelected.
  ///
  /// In ar, this message translates to:
  /// **'حفظ العملات المحددة'**
  String get pcrSaveSelected;

  /// No description provided for @pcrNotNow.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن — سأكمل لاحقاً'**
  String get pcrNotNow;

  /// No description provided for @pcrAllOneCurrency.
  ///
  /// In ar, this message translates to:
  /// **'كل العناصر بعملة واحدة'**
  String get pcrAllOneCurrency;

  /// No description provided for @pcrCurrencyCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز العملة'**
  String get pcrCurrencyCode;

  /// No description provided for @pcrWillRecord.
  ///
  /// In ar, this message translates to:
  /// **'سيسجل التأكيد أن كل الميزانيات والأهداف الحالية تستخدم هذا الرمز.'**
  String get pcrWillRecord;

  /// No description provided for @pcrUnsupportedCodeLong.
  ///
  /// In ar, this message translates to:
  /// **'رمز العملة غير مدعوم. استخدم رمزاً من ثلاث حروف مثل EGP أو SAR.'**
  String get pcrUnsupportedCodeLong;

  /// No description provided for @pcrUnsupportedCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز العملة غير مدعوم.'**
  String get pcrUnsupportedCode;

  /// No description provided for @pcrSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر حفظ التأكيد الآن. لم تتغير أي من بياناتك المالية.'**
  String get pcrSaveFailed;

  /// No description provided for @pcrTreatAsCurrency.
  ///
  /// In ar, this message translates to:
  /// **'اعتبرها بهذه العملة'**
  String get pcrTreatAsCurrency;

  /// No description provided for @pcrNothingToFix.
  ///
  /// In ar, this message translates to:
  /// **'لا يوجد شيء يحتاج إلى إصلاح'**
  String get pcrNothingToFix;

  /// No description provided for @pcrNothingToFixBody.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ميزانيات أو أهداف قديمة تحتاج إلى تأكيد عملتها.'**
  String get pcrNothingToFixBody;

  /// No description provided for @pcrPerItemSaved.
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ عملة مستقلة لكل ميزانية وهدف حالي.'**
  String get pcrPerItemSaved;

  /// No description provided for @pcrConfirmed.
  ///
  /// In ar, this message translates to:
  /// **'تم تأكيد العملات'**
  String get pcrConfirmed;

  /// No description provided for @pcrBackToSettings.
  ///
  /// In ar, this message translates to:
  /// **'العودة إلى الإعدادات'**
  String get pcrBackToSettings;

  /// No description provided for @pcrReadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة بيانات التخطيط. لم يتغير أي شيء.'**
  String get pcrReadFailed;

  /// No description provided for @rcTitle.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء تقرير مالي'**
  String get rcTitle;

  /// No description provided for @rcPeriod.
  ///
  /// In ar, this message translates to:
  /// **'الفترة'**
  String get rcPeriod;

  /// No description provided for @rcCustom.
  ///
  /// In ar, this message translates to:
  /// **'مخصّص'**
  String get rcCustom;

  /// No description provided for @rcPickRange.
  ///
  /// In ar, this message translates to:
  /// **'اختر المدى'**
  String get rcPickRange;

  /// No description provided for @accTitleShort.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات'**
  String get accTitleShort;

  /// No description provided for @rcLanguage.
  ///
  /// In ar, this message translates to:
  /// **'اللغة'**
  String get rcLanguage;

  /// No description provided for @rcArabic.
  ///
  /// In ar, this message translates to:
  /// **'العربية'**
  String get rcArabic;

  /// No description provided for @rcTxDetails.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل العمليات'**
  String get rcTxDetails;

  /// No description provided for @rcMerchantNames.
  ///
  /// In ar, this message translates to:
  /// **'أسماء المتاجر'**
  String get rcMerchantNames;

  /// No description provided for @rcAccountNames.
  ///
  /// In ar, this message translates to:
  /// **'أسماء الحسابات'**
  String get rcAccountNames;

  /// No description provided for @rcBalances.
  ///
  /// In ar, this message translates to:
  /// **'الأرصدة'**
  String get rcBalances;

  /// No description provided for @rcNotes.
  ///
  /// In ar, this message translates to:
  /// **'الملاحظات'**
  String get rcNotes;

  /// No description provided for @rcPrivacyMode.
  ///
  /// In ar, this message translates to:
  /// **'وضع الخصوصية (إخفاء المبالغ)'**
  String get rcPrivacyMode;

  /// No description provided for @rcCreateReport.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء التقرير'**
  String get rcCreateReport;

  /// No description provided for @rcNoDataInPeriod.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بيانات في هذه الفترة'**
  String get rcNoDataInPeriod;

  /// No description provided for @rcFontsFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الخطوط'**
  String get rcFontsFailed;

  /// No description provided for @rcPdfFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إنشاء ملف PDF'**
  String get rcPdfFailed;

  /// No description provided for @rcSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الملف'**
  String get rcSaveFailed;

  /// No description provided for @rcCancelled.
  ///
  /// In ar, this message translates to:
  /// **'أُلغي'**
  String get rcCancelled;

  /// No description provided for @rcUnexpectedError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع'**
  String get rcUnexpectedError;

  /// No description provided for @rcGenerating.
  ///
  /// In ar, this message translates to:
  /// **'جاري إنشاء التقرير…'**
  String get rcGenerating;

  /// No description provided for @rcStepCollect.
  ///
  /// In ar, this message translates to:
  /// **'جمع البيانات'**
  String get rcStepCollect;

  /// No description provided for @rcStepMetrics.
  ///
  /// In ar, this message translates to:
  /// **'حساب المؤشرات'**
  String get rcStepMetrics;

  /// No description provided for @rcStepDraw.
  ///
  /// In ar, this message translates to:
  /// **'رسم الصفحات'**
  String get rcStepDraw;

  /// No description provided for @rcStepSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ الملف'**
  String get rcStepSave;

  /// No description provided for @rcStepDone.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل'**
  String get rcStepDone;

  /// No description provided for @bkTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي والاستعادة'**
  String get bkTitle;

  /// No description provided for @bkSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'احفظ بياناتك المالية واسترجعها بأمان وسرية تامة في أي وقت.'**
  String get bkSubtitle;

  /// No description provided for @bkCreateAccountTitle.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ حسابًا لتفعيل النسخ الاحتياطي'**
  String get bkCreateAccountTitle;

  /// No description provided for @bkCreateAccountBody.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك استخدام قِرش محليًا بدون حساب. النسخ الاحتياطي يحتاج تسجيل دخول حتى نربط النسخة المشفّرة بك.'**
  String get bkCreateAccountBody;

  /// No description provided for @bkNoBackupYet.
  ///
  /// In ar, this message translates to:
  /// **'لم تُنشأ نسخة بعد'**
  String get bkNoBackupYet;

  /// No description provided for @bkBackupNow.
  ///
  /// In ar, this message translates to:
  /// **'نسخ احتياطي الآن'**
  String get bkBackupNow;

  /// No description provided for @bkTurnOff.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف النسخ الاحتياطي'**
  String get bkTurnOff;

  /// No description provided for @bkLocalDataStays.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك المحلية تبقى عند الإيقاف.'**
  String get bkLocalDataStays;

  /// No description provided for @bkEnableFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تفعيل النسخ الاحتياطي. حاول مرة أخرى.'**
  String get bkEnableFailed;

  /// No description provided for @bkEncryptedWeCannotRead.
  ///
  /// In ar, this message translates to:
  /// **'نسخة مشفّرة لا يمكننا قراءتها'**
  String get bkEncryptedWeCannotRead;

  /// No description provided for @bkOptionalOffByDefault.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي اختياري ومطفأ افتراضياً. عند تفعيله تُشفّر بياناتك end-to-end وترجع على أي جهاز.'**
  String get bkOptionalOffByDefault;

  /// No description provided for @bkPassphrase.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور التشفير (passphrase)'**
  String get bkPassphrase;

  /// No description provided for @bkContinue.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get bkContinue;

  /// No description provided for @bkRecoveryCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز الاسترداد (Recovery Code)'**
  String get bkRecoveryCode;

  /// No description provided for @bkCopyCode.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الرمز'**
  String get bkCopyCode;

  /// No description provided for @bkLoseBothWarning.
  ///
  /// In ar, this message translates to:
  /// **'إذا فقدت كلمة المرور والرمز معًا لن نتمكّن من استعادة نسختك.'**
  String get bkLoseBothWarning;

  /// No description provided for @bkSavedTheCode.
  ///
  /// In ar, this message translates to:
  /// **'حفظت الرمز وأفهم ذلك'**
  String get bkSavedTheCode;

  /// No description provided for @bkEnable.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل'**
  String get bkEnable;

  /// No description provided for @bkRestoreFromBackup.
  ///
  /// In ar, this message translates to:
  /// **'استعادة من نسخة احتياطية'**
  String get bkRestoreFromBackup;

  /// No description provided for @pcrOldAmount.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ القديم'**
  String get pcrOldAmount;

  /// No description provided for @pcrOldTarget.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستهدف القديم'**
  String get pcrOldTarget;

  /// No description provided for @cesTitle.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عملية جديدة'**
  String get cesTitle;

  /// No description provided for @cesPasteBankMessage.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة بنك'**
  String get cesPasteBankMessage;

  /// No description provided for @cesPasteHint.
  ///
  /// In ar, this message translates to:
  /// **'نقرأ الرسالة ونجهّز العملية للمراجعة.'**
  String get cesPasteHint;

  /// No description provided for @cesManualEntry.
  ///
  /// In ar, this message translates to:
  /// **'إضافة يدوية'**
  String get cesManualEntry;

  /// No description provided for @cesManualHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب تفاصيل العملية بنفسك.'**
  String get cesManualHint;

  /// No description provided for @bkStateDisabled.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي متوقف'**
  String get bkStateDisabled;

  /// No description provided for @bkStateEnabling.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التفعيل…'**
  String get bkStateEnabling;

  /// No description provided for @bkStatePreparing.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحضير…'**
  String get bkStatePreparing;

  /// No description provided for @bkStateEncrypting.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التشفير…'**
  String get bkStateEncrypting;

  /// No description provided for @bkStateUploading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الرفع…'**
  String get bkStateUploading;

  /// No description provided for @bkStateVerifying.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحقق…'**
  String get bkStateVerifying;

  /// No description provided for @bkStateDownloading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التنزيل…'**
  String get bkStateDownloading;

  /// No description provided for @bkStateProtected.
  ///
  /// In ar, this message translates to:
  /// **'محمي'**
  String get bkStateProtected;

  /// No description provided for @bkStateWaitingForConnection.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الاتصال'**
  String get bkStateWaitingForConnection;

  /// No description provided for @bkStateWillRetry.
  ///
  /// In ar, this message translates to:
  /// **'ستتم إعادة المحاولة'**
  String get bkStateWillRetry;

  /// No description provided for @bkStateNeedsSignIn.
  ///
  /// In ar, this message translates to:
  /// **'يلزم تسجيل الدخول'**
  String get bkStateNeedsSignIn;

  /// No description provided for @bkStateNeedsCloudSync.
  ///
  /// In ar, this message translates to:
  /// **'يلزم تفعيل المزامنة السحابية'**
  String get bkStateNeedsCloudSync;

  /// No description provided for @bkStateFailedRetryable.
  ///
  /// In ar, this message translates to:
  /// **'فشل — أعد المحاولة'**
  String get bkStateFailedRetryable;

  /// No description provided for @bkStateFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل'**
  String get bkStateFailed;

  /// No description provided for @bkStateDeleting.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ حذف النسخة عن بُعد'**
  String get bkStateDeleting;

  /// No description provided for @bkStateCancelled.
  ///
  /// In ar, this message translates to:
  /// **'أُلغيت'**
  String get bkStateCancelled;

  /// No description provided for @iosStep1.
  ///
  /// In ar, this message translates to:
  /// **'افتح تطبيق الاختصارات'**
  String get iosStep1;

  /// No description provided for @iosStep1Body.
  ///
  /// In ar, this message translates to:
  /// **'ادخل على Shortcuts ثم تبويب Automation من الأسفل.'**
  String get iosStep1Body;

  /// No description provided for @iosStep2.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ Automation جديد'**
  String get iosStep2;

  /// No description provided for @iosStep2Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط New Automation أو علامة +، ثم اختر Message.'**
  String get iosStep2Body;

  /// No description provided for @iosStep3.
  ///
  /// In ar, this message translates to:
  /// **'حدّد رسائل البنك'**
  String get iosStep3;

  /// No description provided for @iosStep4.
  ///
  /// In ar, this message translates to:
  /// **'اجعله يعمل فورًا'**
  String get iosStep4;

  /// No description provided for @iosStep4Body.
  ///
  /// In ar, this message translates to:
  /// **'اختَر Run Immediately. إذا ظهر Notify When Run فأغلقه، ثم اضغط Next.'**
  String get iosStep4Body;

  /// No description provided for @iosStep5.
  ///
  /// In ar, this message translates to:
  /// **'اختَر اختصار قِرش'**
  String get iosStep5;

  /// No description provided for @iosStep5Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط New Blank Automation، وابحث عن Process Bank SMS.'**
  String get iosStep5Body;

  /// No description provided for @iosStep6.
  ///
  /// In ar, this message translates to:
  /// **'مرّر نص الرسالة'**
  String get iosStep6;

  /// No description provided for @iosStep6Body.
  ///
  /// In ar, this message translates to:
  /// **'اضبط SMS Text على Shortcut Input وسيب Sender على مرسل الرسالة. قرش بيسجّل وقت الالتقاط تلقائيًا.'**
  String get iosStep6Body;

  /// No description provided for @iosStep7.
  ///
  /// In ar, this message translates to:
  /// **'طابق الشكل النهائي'**
  String get iosStep7;

  /// No description provided for @iosStep7Body.
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يكون: Receive messages as input ثم Process Bank SMS وفيها SMS Text = Shortcut Input. افتح تفاصيل الأكشن وأغلق Show When Run إذا ظهر.'**
  String get iosStep7Body;

  /// No description provided for @iosStep8.
  ///
  /// In ar, this message translates to:
  /// **'احفظ الاختصار'**
  String get iosStep8;

  /// No description provided for @iosStep8Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط Done. بعدها أي رسالة بنك مطابقة ستتحول لعملية داخل قِرش.'**
  String get iosStep8Body;

  /// No description provided for @countrySA.
  ///
  /// In ar, this message translates to:
  /// **'السعودية'**
  String get countrySA;

  /// No description provided for @countryAE.
  ///
  /// In ar, this message translates to:
  /// **'الإمارات'**
  String get countryAE;

  /// No description provided for @countryEG.
  ///
  /// In ar, this message translates to:
  /// **'مصر'**
  String get countryEG;

  /// No description provided for @countryKW.
  ///
  /// In ar, this message translates to:
  /// **'الكويت'**
  String get countryKW;

  /// No description provided for @countryQA.
  ///
  /// In ar, this message translates to:
  /// **'قطر'**
  String get countryQA;

  /// No description provided for @countryBH.
  ///
  /// In ar, this message translates to:
  /// **'البحرين'**
  String get countryBH;

  /// No description provided for @countryOM.
  ///
  /// In ar, this message translates to:
  /// **'عُمان'**
  String get countryOM;

  /// No description provided for @countryJO.
  ///
  /// In ar, this message translates to:
  /// **'الأردن'**
  String get countryJO;

  /// No description provided for @setupSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ الإعدادات. حاول مرة أخرى.'**
  String get setupSaveFailed;

  /// No description provided for @setupFinishFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إنهاء الإعداد. حاول مرة أخرى.'**
  String get setupFinishFailed;

  /// No description provided for @iosStep3Body.
  ///
  /// In ar, this message translates to:
  /// **'في Message Contents اكتب رمز العملة مثل {currency}، وكرّر لاحقًا لأي عملة إضافية.'**
  String iosStep3Body(String currency);

  /// No description provided for @pfCurrencyOnly.
  ///
  /// In ar, this message translates to:
  /// **'تحسب الخطة عمليات {currency} فقط — ولا يُحتسب فيها أي حساب بعملة أخرى.'**
  String pfCurrencyOnly(String currency);

  /// No description provided for @pfCardNamed.
  ///
  /// In ar, this message translates to:
  /// **'بطاقة {last4}'**
  String pfCardNamed(String last4);

  /// No description provided for @obPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'{amount} {currency} شهريًا'**
  String obPerMonth(String amount, String currency);

  /// No description provided for @aiTitle.
  ///
  /// In ar, this message translates to:
  /// **'وزّع دخلك'**
  String get aiTitle;

  /// No description provided for @aiSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اكتب دخلك، ووزّعه على المظاريف — يمكنك تعديل أي رقم.'**
  String get aiSubtitle;

  /// No description provided for @aiSaving.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الحفظ...'**
  String get aiSaving;

  /// No description provided for @aiSaveSplit.
  ///
  /// In ar, this message translates to:
  /// **'احفظ التوزيع'**
  String get aiSaveSplit;

  /// No description provided for @aiMonthlyIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخلك الشهري'**
  String get aiMonthlyIncome;

  /// No description provided for @aiSuggestSplit.
  ///
  /// In ar, this message translates to:
  /// **'اقترح توزيع تلقائي'**
  String get aiSuggestSplit;

  /// No description provided for @aiSavings.
  ///
  /// In ar, this message translates to:
  /// **'الادخار'**
  String get aiSavings;

  /// No description provided for @aiCreateGoalHint.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ هدف ادخار لنحوّله تلقائيًا كل شهر.'**
  String get aiCreateGoalHint;

  /// No description provided for @aiAutoToGoal.
  ///
  /// In ar, this message translates to:
  /// **'يتحوّل تلقائيًا لهدف'**
  String get aiAutoToGoal;

  /// No description provided for @aiAllocated.
  ///
  /// In ar, this message translates to:
  /// **'موزّع على المظاريف'**
  String get aiAllocated;

  /// No description provided for @aiUnallocated.
  ///
  /// In ar, this message translates to:
  /// **'متبقي غير موزّع'**
  String get aiUnallocated;

  /// No description provided for @aiOverIncomeBy.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت دخلك بـ'**
  String get aiOverIncomeBy;

  /// No description provided for @pfEditPlan.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الخطة'**
  String get pfEditPlan;

  /// No description provided for @pfSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سفر، عُرس، رمضان… ميزانية لفترة محددة تتابع نفسها.'**
  String get pfSubtitle;

  /// No description provided for @pfSavePlan.
  ///
  /// In ar, this message translates to:
  /// **'احفظ الخطة'**
  String get pfSavePlan;

  /// No description provided for @pfPlanName.
  ///
  /// In ar, this message translates to:
  /// **'اسم الخطة'**
  String get pfPlanName;

  /// No description provided for @pfPlanNameHint.
  ///
  /// In ar, this message translates to:
  /// **'مثلاً: رحلة دبي'**
  String get pfPlanNameHint;

  /// No description provided for @pfPlanBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية الخطة'**
  String get pfPlanBudget;

  /// No description provided for @pfAccountsToSpendFrom.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات التي ستصرف منها'**
  String get pfAccountsToSpendFrom;

  /// No description provided for @pfCardsOptional.
  ///
  /// In ar, this message translates to:
  /// **'البطاقات (اختياري)'**
  String get pfCardsOptional;

  /// No description provided for @pfNoScopeHint.
  ///
  /// In ar, this message translates to:
  /// **'إذا لم تختر حسابًا أو بطاقة، ستحسب الخطة كل المصاريف في الفترة.'**
  String get pfNoScopeHint;

  /// No description provided for @ctsFeeAlsoAdded.
  ///
  /// In ar, this message translates to:
  /// **'وجدنا عمليتين في الرسالة: أضفنا أيضًا الرسوم/الضريبة {amount} {currency} (بعملة مختلفة).'**
  String ctsFeeAlsoAdded(String amount, String currency);

  /// No description provided for @ctsForeignCurrencyHint.
  ///
  /// In ar, this message translates to:
  /// **'عملية بعملة مختلفة ({amount} {foreign}). اكتب قيمتها بـ {home} لتُحتسب — أو اتركها وعدّلها لاحقًا عند وصول المبلغ المخصوم.'**
  String ctsForeignCurrencyHint(String amount, String foreign, String home);

  /// No description provided for @pcsIntro.
  ///
  /// In ar, this message translates to:
  /// **'عُدِّل هذا العنصر على جهاز آخر أيضًا. اختر النسخة التي تريد الاحتفاظ بها.'**
  String get pcsIntro;

  /// No description provided for @ctsNeedsCategory.
  ///
  /// In ar, this message translates to:
  /// **'محتاجة تصنيف — اختَر التصنيف المناسب بالأسفل.'**
  String get ctsNeedsCategory;

  /// No description provided for @ctsAiParsed.
  ///
  /// In ar, this message translates to:
  /// **'حلّلها الذكاء الاصطناعي — أكّد المبلغ والتصنيف.'**
  String get ctsAiParsed;

  /// No description provided for @ctsLowConfidence.
  ///
  /// In ar, this message translates to:
  /// **'القراءة غير مؤكدة تمامًا — راجع التفاصيل قبل التأكيد.'**
  String get ctsLowConfidence;

  /// No description provided for @ctsReviewBeforeConfirm.
  ///
  /// In ar, this message translates to:
  /// **'راجِع التفاصيل قبل التأكيد.'**
  String get ctsReviewBeforeConfirm;

  /// No description provided for @ctsTitle.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة العملية'**
  String get ctsTitle;

  /// No description provided for @ctsCategoryLabel.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف:'**
  String get ctsCategoryLabel;

  /// No description provided for @ctsCategoryUpdateFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحديث التصنيف.'**
  String get ctsCategoryUpdateFailed;

  /// No description provided for @ctsConfirmFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تأكيد العملية. حاول مرة أخرى.'**
  String get ctsConfirmFailed;

  /// No description provided for @ctsEditDetails.
  ///
  /// In ar, this message translates to:
  /// **'تعديل التفاصيل'**
  String get ctsEditDetails;

  /// No description provided for @adTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحساب'**
  String get adTitle;

  /// No description provided for @adNotFound.
  ///
  /// In ar, this message translates to:
  /// **'الحساب غير موجود'**
  String get adNotFound;

  /// No description provided for @adCards.
  ///
  /// In ar, this message translates to:
  /// **'البطاقات'**
  String get adCards;

  /// No description provided for @adNoCards.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات بعد — تظهر تلقائيًا من رسائلك أو أضفها يدويًا.'**
  String get adNoCards;

  /// No description provided for @adRecentTx.
  ///
  /// In ar, this message translates to:
  /// **'آخر العمليات'**
  String get adRecentTx;

  /// No description provided for @pcsLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل التعارضات — حاول مجددًا.'**
  String get pcsLoadFailed;

  /// No description provided for @pcsNoConflicts.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تعارضات'**
  String get pcsNoConflicts;

  /// No description provided for @pcsAllSynced.
  ///
  /// In ar, this message translates to:
  /// **'كل بيانات التخطيط متزامنة.'**
  String get pcsAllSynced;

  /// No description provided for @pcsTitle.
  ///
  /// In ar, this message translates to:
  /// **'حل تعارضات المزامنة'**
  String get pcsTitle;

  /// No description provided for @pcsKeptMine.
  ///
  /// In ar, this message translates to:
  /// **'تم الاحتفاظ بنسختك.'**
  String get pcsKeptMine;

  /// No description provided for @pcsKeptTheirs.
  ///
  /// In ar, this message translates to:
  /// **'تم اعتماد نسخة الجهاز الآخر.'**
  String get pcsKeptTheirs;

  /// No description provided for @pcsKeepMine.
  ///
  /// In ar, this message translates to:
  /// **'احتفظ بنسختي'**
  String get pcsKeepMine;

  /// No description provided for @pcsKeepTheirs.
  ///
  /// In ar, this message translates to:
  /// **'نسخة الجهاز الآخر'**
  String get pcsKeepTheirs;

  /// No description provided for @rprUnsupportedCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز عملة غير مدعوم'**
  String get rprUnsupportedCode;

  /// No description provided for @rprTitle.
  ///
  /// In ar, this message translates to:
  /// **'عملة بيانات النسخة الاحتياطية'**
  String get rprTitle;

  /// No description provided for @rprPerItem.
  ///
  /// In ar, this message translates to:
  /// **'عملة لكل عنصر'**
  String get rprPerItem;

  /// No description provided for @rprTreatAllAs.
  ///
  /// In ar, this message translates to:
  /// **'اعتبر كل العناصر بهذه العملة'**
  String get rprTreatAllAs;

  /// No description provided for @rprContinueRestore.
  ///
  /// In ar, this message translates to:
  /// **'متابعة الاستعادة'**
  String get rprContinueRestore;

  /// No description provided for @rprCancelRestore.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الاستعادة'**
  String get rprCancelRestore;

  /// No description provided for @rprGoal.
  ///
  /// In ar, this message translates to:
  /// **'هدف'**
  String get rprGoal;

  /// No description provided for @rprBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية'**
  String get rprBudget;

  /// No description provided for @psrTitle.
  ///
  /// In ar, this message translates to:
  /// **'بنود بانتظار تحديد العملة (من المزامنة)'**
  String get psrTitle;

  /// No description provided for @psrUnsupported.
  ///
  /// In ar, this message translates to:
  /// **'عملة غير مدعومة'**
  String get psrUnsupported;

  /// No description provided for @psrConfirmed.
  ///
  /// In ar, this message translates to:
  /// **'تم التأكيد'**
  String get psrConfirmed;

  /// No description provided for @psrConfirmFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التأكيد — حاول مرة أخرى'**
  String get psrConfirmFailed;

  /// No description provided for @psrCurrencyExample.
  ///
  /// In ar, this message translates to:
  /// **'العملة (مثال: KWD)'**
  String get psrCurrencyExample;

  /// No description provided for @adsSubsAndBills.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والفواتير'**
  String get adsSubsAndBills;

  /// No description provided for @adsPickDestination.
  ///
  /// In ar, this message translates to:
  /// **'اختر وجهة كل اشتراك نشط — لن يُحذف تلقائيًا.'**
  String get adsPickDestination;

  /// No description provided for @adsChoose.
  ///
  /// In ar, this message translates to:
  /// **'اختر…'**
  String get adsChoose;

  /// No description provided for @adsArchive.
  ///
  /// In ar, this message translates to:
  /// **'أرشفة'**
  String get adsArchive;

  /// No description provided for @rpTitle.
  ///
  /// In ar, this message translates to:
  /// **'معاينة التقرير'**
  String get rpTitle;

  /// No description provided for @rpShare.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة'**
  String get rpShare;

  /// No description provided for @rpPrint.
  ///
  /// In ar, this message translates to:
  /// **'طباعة'**
  String get rpPrint;

  /// No description provided for @rpShareFinancialData.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة بيانات مالية'**
  String get rpShareFinancialData;

  /// No description provided for @rpShareWarning.
  ///
  /// In ar, this message translates to:
  /// **'يحتوي هذا التقرير على أرصدة وأسماء متاجر. هل تريد مشاركته؟'**
  String get rpShareWarning;

  /// No description provided for @rpFinancialReport.
  ///
  /// In ar, this message translates to:
  /// **'التقرير المالي'**
  String get rpFinancialReport;

  /// No description provided for @psrIntro.
  ///
  /// In ar, this message translates to:
  /// **'وصلت هذه الصفوف من المزامنة بدون عملة. اختر العملة الصحيحة لكل صف — لن يُخمّن قِرش عملتها، ولن يتغيّر أي مبلغ.'**
  String get psrIntro;

  /// No description provided for @psrAmount.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ: {amount}'**
  String psrAmount(String amount);

  /// No description provided for @adsWillDetach.
  ///
  /// In ar, this message translates to:
  /// **'ستُفصل {count, plural, =1{عملية واحدة} =2{عمليتان} few{{count} عمليات} many{{count} عملية} other{{count} عملية}} (يبقى سجلها كاملًا).'**
  String adsWillDetach(int count);

  /// No description provided for @adsMoveTo.
  ///
  /// In ar, this message translates to:
  /// **'نقل إلى {account}'**
  String adsMoveTo(String account);

  /// No description provided for @rprIntro.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية لا تحفظ عملة الميزانيات والأهداف. اختر كيف تريد معاملة هذه العناصر عند الاستعادة.'**
  String get rprIntro;

  /// No description provided for @rprLegacyAmount.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ القديم: {amount} · العملة غير محددة'**
  String rprLegacyAmount(String amount);

  /// No description provided for @dpeCsvTooLarge.
  ///
  /// In ar, this message translates to:
  /// **'حجم ملف CSV أكبر من 25MB.'**
  String get dpeCsvTooLarge;

  /// No description provided for @dpeCsvEmpty.
  ///
  /// In ar, this message translates to:
  /// **'ملف CSV فارغ.'**
  String get dpeCsvEmpty;

  /// No description provided for @dpeCsvTooManyRows.
  ///
  /// In ar, this message translates to:
  /// **'ملف CSV يتجاوز 100,000 صف.'**
  String get dpeCsvTooManyRows;

  /// No description provided for @dpeCsvBadHeaders.
  ///
  /// In ar, this message translates to:
  /// **'عناوين أعمدة CSV غير صالحة.'**
  String get dpeCsvBadHeaders;

  /// No description provided for @dpeCsvDuplicateColumns.
  ///
  /// In ar, this message translates to:
  /// **'ملف CSV يحتوي أعمدة مكررة.'**
  String get dpeCsvDuplicateColumns;

  /// No description provided for @dpeFileTooLarge.
  ///
  /// In ar, this message translates to:
  /// **'حجم الملف أكبر من 25MB.'**
  String get dpeFileTooLarge;

  /// No description provided for @dpeZipInvalid.
  ///
  /// In ar, this message translates to:
  /// **'ملف ZIP غير صالح أو تالف.'**
  String get dpeZipInvalid;

  /// No description provided for @dpePickCsvOrZip.
  ///
  /// In ar, this message translates to:
  /// **'اختر ملف CSV أو ZIP.'**
  String get dpePickCsvOrZip;

  /// No description provided for @dpeFixErrorsFirst.
  ///
  /// In ar, this message translates to:
  /// **'أصلح أخطاء الملف قبل الاستيراد.'**
  String get dpeFixErrorsFirst;

  /// No description provided for @dpeExternalCsvMergeOnly.
  ///
  /// In ar, this message translates to:
  /// **'CSV الخارجي يدعم الدمج فقط.'**
  String get dpeExternalCsvMergeOnly;

  /// No description provided for @dpeReplaceUnavailableMixed.
  ///
  /// In ar, this message translates to:
  /// **'الاستبدال غير متاح أثناء تشغيل مصادر بيانات مختلطة.'**
  String get dpeReplaceUnavailableMixed;

  /// No description provided for @dpeReplaceUnavailableCloud.
  ///
  /// In ar, this message translates to:
  /// **'الاستبدال متاح فقط للبيانات المحفوظة على هذا الجهاز. لأن بياناتك مزامَنة مع حسابك، استخدم «دمج» بدلًا من ذلك.'**
  String get dpeReplaceUnavailableCloud;

  /// No description provided for @dpeReselectFile.
  ///
  /// In ar, this message translates to:
  /// **'أعد اختيار الملف ثم حاول مرة أخرى.'**
  String get dpeReselectFile;

  /// No description provided for @dpeCsvMappingIncomplete.
  ///
  /// In ar, this message translates to:
  /// **'مطابقة أعمدة CSV غير مكتملة.'**
  String get dpeCsvMappingIncomplete;

  /// No description provided for @dpeExportTooLarge.
  ///
  /// In ar, this message translates to:
  /// **'حجم التصدير تجاوز الحد المسموح (100MB).'**
  String get dpeExportTooLarge;

  /// No description provided for @dpePackageAlreadyImported.
  ///
  /// In ar, this message translates to:
  /// **'تم استيراد هذه الحزمة سابقًا بوضع مختلف.'**
  String get dpePackageAlreadyImported;

  /// No description provided for @dpeForeignPairRequired.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ والعملة الأجنبية يجب أن يوجدا معًا.'**
  String get dpeForeignPairRequired;

  /// No description provided for @dpeUnsupportedTable.
  ///
  /// In ar, this message translates to:
  /// **'جدول غير مدعوم: {value}'**
  String dpeUnsupportedTable(String value);

  /// No description provided for @dpeOtherCategoryMissing.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف «أخرى» غير موجود.'**
  String get dpeOtherCategoryMissing;

  /// No description provided for @dpeMissingValue.
  ///
  /// In ar, this message translates to:
  /// **'قيمة {value} مفقودة.'**
  String dpeMissingValue(String value);

  /// No description provided for @dpeInvalidCurrencyCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز عملة غير صالح: {value}'**
  String dpeInvalidCurrencyCode(String value);

  /// No description provided for @dpeInvalidMinorAmount.
  ///
  /// In ar, this message translates to:
  /// **'قيمة مالية دقيقة غير صالحة: {value}'**
  String dpeInvalidMinorAmount(String value);

  /// No description provided for @dpeInvalidAmount.
  ///
  /// In ar, this message translates to:
  /// **'قيمة مالية غير صالحة: {value}'**
  String dpeInvalidAmount(String value);

  /// No description provided for @dpeInvalidDate.
  ///
  /// In ar, this message translates to:
  /// **'تاريخ غير صالح: {value}'**
  String dpeInvalidDate(String value);

  /// No description provided for @dpeExportFileMissing.
  ///
  /// In ar, this message translates to:
  /// **'ملف {value} مفقود من التصدير.'**
  String dpeExportFileMissing(String value);

  /// No description provided for @dpeZipTooLarge.
  ///
  /// In ar, this message translates to:
  /// **'حجم ملف ZIP أكبر من 25MB.'**
  String get dpeZipTooLarge;

  /// No description provided for @dpePackageUnsafePath.
  ///
  /// In ar, this message translates to:
  /// **'حزمة قِرش تحتوي مسارًا أو ملفًا غير مسموح.'**
  String get dpePackageUnsafePath;

  /// No description provided for @dpePackageInflatedTooLarge.
  ///
  /// In ar, this message translates to:
  /// **'حجم الحزمة بعد الفك أكبر من 100MB.'**
  String get dpePackageInflatedTooLarge;

  /// No description provided for @dpeEntryUnreadable.
  ///
  /// In ar, this message translates to:
  /// **'تعذر قراءة {value}.'**
  String dpeEntryUnreadable(String value);

  /// No description provided for @dpeEntrySizeMismatch.
  ///
  /// In ar, this message translates to:
  /// **'حجم {value} لا يطابق ترويسة ZIP.'**
  String dpeEntrySizeMismatch(String value);

  /// No description provided for @dpeManifestMissing.
  ///
  /// In ar, this message translates to:
  /// **'manifest.json مفقود.'**
  String get dpeManifestMissing;

  /// No description provided for @dpeManifestInvalid.
  ///
  /// In ar, this message translates to:
  /// **'manifest.json غير صالح.'**
  String get dpeManifestInvalid;

  /// No description provided for @dpeNotAQirshExport.
  ///
  /// In ar, this message translates to:
  /// **'هذا ليس ملف تصدير قِرش.'**
  String get dpeNotAQirshExport;

  /// No description provided for @dpeNewerVersion.
  ///
  /// In ar, this message translates to:
  /// **'الملف من إصدار أحدث. حدّث قِرش ثم أعد المحاولة.'**
  String get dpeNewerVersion;

  /// No description provided for @dpeUnsupportedVersion.
  ///
  /// In ar, this message translates to:
  /// **'إصدار ملف قِرش غير مدعوم.'**
  String get dpeUnsupportedVersion;

  /// No description provided for @dpePackageMetaIncomplete.
  ///
  /// In ar, this message translates to:
  /// **'بيانات تعريف الحزمة ناقصة.'**
  String get dpePackageMetaIncomplete;

  /// No description provided for @dpePackageEntryMissing.
  ///
  /// In ar, this message translates to:
  /// **'{value} مفقود من الحزمة.'**
  String dpePackageEntryMissing(String value);

  /// No description provided for @dpeIntegrityCheckFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل التحقق من سلامة {value}.'**
  String dpeIntegrityCheckFailed(String value);

  /// No description provided for @dpePackageTooManyRows.
  ///
  /// In ar, this message translates to:
  /// **'الحزمة تتجاوز 100,000 صف إجمالي.'**
  String get dpePackageTooManyRows;

  /// No description provided for @repoErrNetwork.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر الاتصال بالخادم — تحقّق من الإنترنت وحاول مجددًا.'**
  String get repoErrNetwork;

  /// No description provided for @repoErrAuth.
  ///
  /// In ar, this message translates to:
  /// **'الرجاء تسجيل الدخول للمتابعة.'**
  String get repoErrAuth;

  /// No description provided for @repoErrValidation.
  ///
  /// In ar, this message translates to:
  /// **'بيانات غير صالحة: {detail}'**
  String repoErrValidation(String detail);

  /// No description provided for @repoErrForbidden.
  ///
  /// In ar, this message translates to:
  /// **'لا تملك صلاحية تنفيذ هذه العملية.'**
  String get repoErrForbidden;

  /// No description provided for @repoErrDuplicate.
  ///
  /// In ar, this message translates to:
  /// **'هذا العنصر موجود بالفعل.'**
  String get repoErrDuplicate;

  /// No description provided for @repoErrNotFound.
  ///
  /// In ar, this message translates to:
  /// **'العنصر غير موجود أو تم حذفه.'**
  String get repoErrNotFound;

  /// No description provided for @repoErrServer.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ في الخادم — حاول لاحقًا.'**
  String get repoErrServer;

  /// No description provided for @repoErrUnknown.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ غير متوقع — حاول مجددًا.'**
  String get repoErrUnknown;

  /// No description provided for @cardThemeNavy.
  ///
  /// In ar, this message translates to:
  /// **'كحلي'**
  String get cardThemeNavy;

  /// No description provided for @cardThemeEmerald.
  ///
  /// In ar, this message translates to:
  /// **'زمرّدي'**
  String get cardThemeEmerald;

  /// No description provided for @cardThemePlum.
  ///
  /// In ar, this message translates to:
  /// **'برقوقي'**
  String get cardThemePlum;

  /// No description provided for @cardThemeSunset.
  ///
  /// In ar, this message translates to:
  /// **'غروب'**
  String get cardThemeSunset;

  /// No description provided for @cardThemeGraphite.
  ///
  /// In ar, this message translates to:
  /// **'جرافيت'**
  String get cardThemeGraphite;

  /// No description provided for @cardThemeOcean.
  ///
  /// In ar, this message translates to:
  /// **'محيط'**
  String get cardThemeOcean;

  /// No description provided for @authGoogleUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول بجوجل غير متاح في هذه النسخة. استخدم طريقة أخرى.'**
  String get authGoogleUnavailable;

  /// No description provided for @authGoogleCancelled.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء تسجيل الدخول بجوجل.'**
  String get authGoogleCancelled;

  /// No description provided for @authGoogleTokenUnreadable.
  ///
  /// In ar, this message translates to:
  /// **'لم نستطع قراءة رمز دخول جوجل.'**
  String get authGoogleTokenUnreadable;

  /// No description provided for @authAppleCancelled.
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء تسجيل الدخول بـ Apple.'**
  String get authAppleCancelled;

  /// No description provided for @authAppleFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدخول بـ Apple.'**
  String get authAppleFailed;

  /// No description provided for @authAppleTokenUnreadable.
  ///
  /// In ar, this message translates to:
  /// **'لم نستطع قراءة رمز دخول Apple.'**
  String get authAppleTokenUnreadable;

  /// No description provided for @navHome.
  ///
  /// In ar, this message translates to:
  /// **'الرئيسية'**
  String get navHome;

  /// No description provided for @navTransactions.
  ///
  /// In ar, this message translates to:
  /// **'العمليات'**
  String get navTransactions;

  /// No description provided for @navBudgets.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات'**
  String get navBudgets;

  /// No description provided for @navMore.
  ///
  /// In ar, this message translates to:
  /// **'المزيد'**
  String get navMore;

  /// No description provided for @navAnalytics.
  ///
  /// In ar, this message translates to:
  /// **'التحليلات'**
  String get navAnalytics;

  /// No description provided for @navExpandBar.
  ///
  /// In ar, this message translates to:
  /// **'فتح شريط التنقل — {tab}'**
  String navExpandBar(String tab);

  /// No description provided for @bkeNoLocalBackup.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نسخة احتياطية على هذا الجهاز.'**
  String get bkeNoLocalBackup;

  /// No description provided for @bkeNeedsReenable.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي يحتاج تفعيلًا جديدًا.'**
  String get bkeNeedsReenable;

  /// No description provided for @bkeSignInRequired.
  ///
  /// In ar, this message translates to:
  /// **'سجّل الدخول أولًا لتفعيل النسخ الاحتياطي.'**
  String get bkeSignInRequired;

  /// No description provided for @bkeStateSaveFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ حالة النسخ الاحتياطي. أعد المحاولة.'**
  String get bkeStateSaveFailed;

  /// No description provided for @bkeBucketMissing.
  ///
  /// In ar, this message translates to:
  /// **'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups في Supabase ثم أعد المحاولة.'**
  String get bkeBucketMissing;

  /// No description provided for @bkeUploadFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل رفع النسخة الاحتياطية: {value}'**
  String bkeUploadFailed(String value);

  /// No description provided for @bkeWrongPassphrase.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور النسخة الاحتياطية غير صحيحة.'**
  String get bkeWrongPassphrase;

  /// No description provided for @bkeInvalidBackupFile.
  ///
  /// In ar, this message translates to:
  /// **'ملف النسخة الاحتياطية غير صالح.'**
  String get bkeInvalidBackupFile;

  /// No description provided for @bkeDecryptFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فك النسخة الاحتياطية: كلمة المرور غير صحيحة أو الملف تالف.'**
  String get bkeDecryptFailed;

  /// No description provided for @bkeUnsupportedEnvelopeVersion.
  ///
  /// In ar, this message translates to:
  /// **'هذه النسخة الاحتياطية من إصدار غير مدعوم. حدّث التطبيق ثم أعد المحاولة.'**
  String get bkeUnsupportedEnvelopeVersion;

  /// No description provided for @bkeBackupFromNewerApp.
  ///
  /// In ar, this message translates to:
  /// **'هذه النسخة الاحتياطية من إصدار أحدث من التطبيق. حدّث التطبيق ثم أعد المحاولة.'**
  String get bkeBackupFromNewerApp;

  /// No description provided for @bkeUnsupportedBackupVersion.
  ///
  /// In ar, this message translates to:
  /// **'هذه النسخة الاحتياطية من إصدار غير مدعوم ({value}). حدّث التطبيق.'**
  String bkeUnsupportedBackupVersion(String value);

  /// No description provided for @bkeBackupCorrupt.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية تالفة أو غير مكتملة. تعذّرت الاستعادة.'**
  String get bkeBackupCorrupt;

  /// No description provided for @bkeTableCorrupt.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية تالفة عند الجدول «{value}». تعذّرت الاستعادة.'**
  String bkeTableCorrupt(String value);

  /// No description provided for @bkeRequiredTableMissing.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية غير مكتملة — الجدول «{value}» مفقود. تعذّرت الاستعادة.'**
  String bkeRequiredTableMissing(String value);

  /// No description provided for @bkeUnsupportedTable.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية تحتوي على جدول غير مدعوم «{value}». تعذّرت الاستعادة.'**
  String bkeUnsupportedTable(String value);

  /// No description provided for @bkeUnexpectedSensitiveField.
  ///
  /// In ar, this message translates to:
  /// **'النسخة الاحتياطية تحتوي على حقل حسّاس غير متوقع «{value}». تعذّرت الاستعادة.'**
  String bkeUnexpectedSensitiveField(String value);

  /// No description provided for @bkeInvalidMoneyValue.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة: قيمة نقدية غير صالحة «{value}».'**
  String bkeInvalidMoneyValue(String value);

  /// No description provided for @bkeAccountChanged.
  ///
  /// In ar, this message translates to:
  /// **'تغيّر الحساب أثناء تجهيز الاستعادة. أعد المحاولة.'**
  String get bkeAccountChanged;

  /// No description provided for @bkeRelationalIntegrity.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة: النسخة الاحتياطية تنتهك سلامة العلاقات بين البيانات.'**
  String get bkeRelationalIntegrity;

  /// No description provided for @bkePlanningInconsistent.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة: بيانات التخطيط غير متسقة بعد الاستعادة.'**
  String get bkePlanningInconsistent;

  /// No description provided for @bkeForeignKeys.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إعادة تفعيل قيود العلاقات بعد الاستعادة.'**
  String get bkeForeignKeys;

  /// No description provided for @bkeOrphanGoalContribution.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة: مساهمة هدف يتيمة «{value}».'**
  String bkeOrphanGoalContribution(String value);

  /// No description provided for @bkePrepareFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تجهيز الاستعادة. تحقّق من الملف وكلمة المرور.'**
  String get bkePrepareFailed;

  /// No description provided for @bkeRestoreFailedNoChanges.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.'**
  String get bkeRestoreFailedNoChanges;

  /// No description provided for @bkeCommittedPendingBackupState.
  ///
  /// In ar, this message translates to:
  /// **'اكتملت استعادة البيانات، لكن تعذّر إكمال حماية النسخة الاحتياطية. أعد المحاولة.'**
  String get bkeCommittedPendingBackupState;

  /// No description provided for @bkeRestoredDbNotReady.
  ///
  /// In ar, this message translates to:
  /// **'اكتملت الاستعادة لكن تعذّر تجهيز قاعدة البيانات. أعد تشغيل التطبيق.'**
  String get bkeRestoredDbNotReady;

  /// No description provided for @bkeNeedsDatabaseRepair.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت الاستعادة وتحتاج قاعدة البيانات إلى إصلاح.'**
  String get bkeNeedsDatabaseRepair;

  /// No description provided for @startPreparing.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ تجهيز التطبيق...'**
  String get startPreparing;

  /// No description provided for @startTookLonger.
  ///
  /// In ar, this message translates to:
  /// **'استغرق التجهيز وقتًا أطول من المتوقع'**
  String get startTookLonger;

  /// No description provided for @startFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تجهيز التطبيق'**
  String get startFailed;

  /// No description provided for @startCheckConnection.
  ///
  /// In ar, this message translates to:
  /// **'تأكد من اتصالك بالإنترنت وحاول مرة أخرى.'**
  String get startCheckConnection;

  /// No description provided for @startStepId.
  ///
  /// In ar, this message translates to:
  /// **'معرّف: {step}'**
  String startStepId(String step);

  /// No description provided for @startRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get startRetry;

  /// No description provided for @dbRecoveryTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح بياناتك'**
  String get dbRecoveryTitle;

  /// No description provided for @dbRecoveryBody.
  ///
  /// In ar, this message translates to:
  /// **'ملف البيانات تالف أو مشفّر بمفتاح غير متطابق ولا يمكن فتحه. يمكنك إعادة تعيين بيانات التطبيق للبدء من جديد (ستُحذف العمليات المحفوظة محليًا فقط).'**
  String get dbRecoveryBody;

  /// No description provided for @dbRecoveryReset.
  ///
  /// In ar, this message translates to:
  /// **'إعادة تعيين البيانات'**
  String get dbRecoveryReset;

  /// No description provided for @lockTitle.
  ///
  /// In ar, this message translates to:
  /// **'قِرش مقفل'**
  String get lockTitle;

  /// No description provided for @lockBody.
  ///
  /// In ar, this message translates to:
  /// **'افتح التطبيق للتحقق من هويتك وعرض بياناتك المالية.'**
  String get lockBody;

  /// No description provided for @lockVerifying.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحقق...'**
  String get lockVerifying;

  /// No description provided for @lockUnlock.
  ///
  /// In ar, this message translates to:
  /// **'فتح قِرش'**
  String get lockUnlock;

  /// No description provided for @lockPrompt.
  ///
  /// In ar, this message translates to:
  /// **'افتح قِرش لحماية بياناتك المالية.'**
  String get lockPrompt;

  /// No description provided for @bdConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد البنك'**
  String get bdConfirmTitle;

  /// No description provided for @bdIsSenderFrom.
  ///
  /// In ar, this message translates to:
  /// **'هل هذا المرسل من {bank}؟'**
  String bdIsSenderFrom(String bank);

  /// No description provided for @bdSender.
  ///
  /// In ar, this message translates to:
  /// **'المرسل'**
  String get bdSender;

  /// No description provided for @bdCountry.
  ///
  /// In ar, this message translates to:
  /// **'الدولة'**
  String get bdCountry;

  /// No description provided for @bdConfidence.
  ///
  /// In ar, this message translates to:
  /// **'الثقة'**
  String get bdConfidence;

  /// No description provided for @bdKey.
  ///
  /// In ar, this message translates to:
  /// **'المفتاح'**
  String get bdKey;

  /// No description provided for @bdReason.
  ///
  /// In ar, this message translates to:
  /// **'السبب: {reason}'**
  String bdReason(String reason);

  /// No description provided for @bdReasonDefault.
  ///
  /// In ar, this message translates to:
  /// **'السبب: {bank} يطابق هذا المرسل ونمط الرسائل بدرجة عالية.'**
  String bdReasonDefault(String bank);

  /// No description provided for @bdConfirmThis.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد هذا البنك'**
  String get bdConfirmThis;

  /// No description provided for @bdNotThis.
  ///
  /// In ar, this message translates to:
  /// **'ليس هذا البنك'**
  String get bdNotThis;

  /// No description provided for @bdAskLater.
  ///
  /// In ar, this message translates to:
  /// **'اسألني لاحقًا'**
  String get bdAskLater;

  /// No description provided for @smsShareTitle.
  ///
  /// In ar, this message translates to:
  /// **'شارك رسالة البنك مع قِرش'**
  String get smsShareTitle;

  /// No description provided for @smsShareBody.
  ///
  /// In ar, this message translates to:
  /// **'بدون إذن قراءة الرسائل: افتح رسالة البنك، اضغط «مشاركة»، واختر قِرش. عند إيقاف التحليل الذكي نحلّل النص على جهازك فقط.'**
  String get smsShareBody;

  /// No description provided for @smsShareExample.
  ///
  /// In ar, this message translates to:
  /// **'مثال: «شراء 45 ريالًا لدى BURGER BOUTIQUE»'**
  String get smsShareExample;

  /// No description provided for @smsShareFallback.
  ///
  /// In ar, this message translates to:
  /// **'إن لم يظهر زر المشاركة في تطبيق الرسائل، استخدم اللصق اليدوي كبديل سريع.'**
  String get smsShareFallback;

  /// No description provided for @smsPasteManually.
  ///
  /// In ar, this message translates to:
  /// **'لصق رسالة يدويًا'**
  String get smsPasteManually;

  /// No description provided for @smsPasteLater.
  ///
  /// In ar, this message translates to:
  /// **'لاحقًا، ألصق يدويًا'**
  String get smsPasteLater;

  /// No description provided for @rngPickAccount.
  ///
  /// In ar, this message translates to:
  /// **'اختر الحساب'**
  String get rngPickAccount;

  /// No description provided for @rngPickPeriod.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة العرض'**
  String get rngPickPeriod;

  /// No description provided for @rngFrom.
  ///
  /// In ar, this message translates to:
  /// **'من'**
  String get rngFrom;

  /// No description provided for @rngTo.
  ///
  /// In ar, this message translates to:
  /// **'إلى'**
  String get rngTo;

  /// No description provided for @rngApplyCustom.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الفترة المخصصة'**
  String get rngApplyCustom;

  /// No description provided for @ccTitle.
  ///
  /// In ar, this message translates to:
  /// **'غيّر التصنيف'**
  String get ccTitle;

  /// No description provided for @ccScope.
  ///
  /// In ar, this message translates to:
  /// **'نطاق التعديل'**
  String get ccScope;

  /// No description provided for @ccThisOnly.
  ///
  /// In ar, this message translates to:
  /// **'هذه العملية فقط'**
  String get ccThisOnly;

  /// No description provided for @ccAllMerchant.
  ///
  /// In ar, this message translates to:
  /// **'كل عمليات هذا المتجر'**
  String get ccAllMerchant;

  /// No description provided for @ccSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديل'**
  String get ccSave;

  /// No description provided for @commonClose.
  ///
  /// In ar, this message translates to:
  /// **'إغلاق'**
  String get commonClose;

  /// No description provided for @commonHide.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء'**
  String get commonHide;

  /// No description provided for @commonSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّى'**
  String get commonSkip;

  /// No description provided for @commonDefault.
  ///
  /// In ar, this message translates to:
  /// **'افتراضي'**
  String get commonDefault;

  /// No description provided for @commonReview.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة'**
  String get commonReview;

  /// No description provided for @commonSmart.
  ///
  /// In ar, this message translates to:
  /// **'ذكاء'**
  String get commonSmart;

  /// No description provided for @commonPending.
  ///
  /// In ar, this message translates to:
  /// **'معلّقة'**
  String get commonPending;

  /// No description provided for @commonTransaction.
  ///
  /// In ar, this message translates to:
  /// **'عملية'**
  String get commonTransaction;

  /// No description provided for @commonUnderReview.
  ///
  /// In ar, this message translates to:
  /// **'قيد المراجعة'**
  String get commonUnderReview;

  /// No description provided for @chartCategories.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get chartCategories;

  /// No description provided for @chartCategoriesEmpty.
  ///
  /// In ar, this message translates to:
  /// **'أضف عمليات مؤكدة ليظهر توزيع التصنيفات هنا.'**
  String get chartCategoriesEmpty;

  /// No description provided for @chartRefund.
  ///
  /// In ar, this message translates to:
  /// **'مرتجع'**
  String get chartRefund;

  /// No description provided for @chartTotal.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي'**
  String get chartTotal;

  /// No description provided for @prgTitle.
  ///
  /// In ar, this message translates to:
  /// **'التخطيط غير متاح مؤقتًا'**
  String get prgTitle;

  /// No description provided for @prgBody.
  ///
  /// In ar, this message translates to:
  /// **'قبل استخدام الميزانيات والأهداف، نحتاج تأكيد العملة التي تُعامَل بها بيانات التخطيط الحالية. لن نغيّر أي مبلغ.'**
  String get prgBody;

  /// No description provided for @prgConfirmNow.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد العملة الآن'**
  String get prgConfirmNow;

  /// No description provided for @prgNotNow.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get prgNotNow;

  /// No description provided for @fuTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحديث مطلوب'**
  String get fuTitle;

  /// No description provided for @fuBody.
  ///
  /// In ar, this message translates to:
  /// **'يرجى تحديث التطبيق للاستمرار في الاستخدام.'**
  String get fuBody;

  /// No description provided for @fuNow.
  ///
  /// In ar, this message translates to:
  /// **'تحديث الآن'**
  String get fuNow;

  /// No description provided for @rpConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الاستعادة'**
  String get rpConfirmTitle;

  /// No description provided for @rpConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'ستحل النسخة الاحتياطية محل بياناتك الحالية على هذا الجهاز. لا يمكن التراجع بعد التأكيد. هل تريد المتابعة؟'**
  String get rpConfirmBody;

  /// No description provided for @rpCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get rpCancel;

  /// No description provided for @rpRestore.
  ///
  /// In ar, this message translates to:
  /// **'استعادة'**
  String get rpRestore;

  /// No description provided for @rpPrivacyNote.
  ///
  /// In ar, this message translates to:
  /// **'الاستعادة تحتاج كلمة المرور أو رمز الاسترداد فقط. قِرش لا يقرأ محتوى النسخة بدونهما.'**
  String get rpPrivacyNote;

  /// No description provided for @adNoticeTitle.
  ///
  /// In ar, this message translates to:
  /// **'إعلان قبل إنشاء التقرير'**
  String get adNoticeTitle;

  /// No description provided for @adNoticeBody.
  ///
  /// In ar, this message translates to:
  /// **'قد يظهر إعلان قصير قبل إنشاء التقرير.'**
  String get adNoticeBody;

  /// No description provided for @adNoticeCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get adNoticeCancel;

  /// No description provided for @adNoticeContinue.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get adNoticeContinue;

  /// No description provided for @plansFrom.
  ///
  /// In ar, this message translates to:
  /// **'من'**
  String get plansFrom;

  /// No description provided for @plansOverBudget.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت الميزانية بـ'**
  String get plansOverBudget;

  /// No description provided for @plansRemaining.
  ///
  /// In ar, this message translates to:
  /// **'باقٍ'**
  String get plansRemaining;

  /// No description provided for @pcrConfirmAll.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد أن كل الميزانيات والأهداف الحالية تستخدم'**
  String get pcrConfirmAll;

  /// No description provided for @cardNetworkMada.
  ///
  /// In ar, this message translates to:
  /// **'مدى'**
  String get cardNetworkMada;

  /// No description provided for @budgetsAllAccounts.
  ///
  /// In ar, this message translates to:
  /// **'كل الحسابات'**
  String get budgetsAllAccounts;

  /// No description provided for @txnCountSuffix.
  ///
  /// In ar, this message translates to:
  /// **'· {count} عملية'**
  String txnCountSuffix(String count);

  /// No description provided for @a11yDebit.
  ///
  /// In ar, this message translates to:
  /// **'خصم'**
  String get a11yDebit;

  /// No description provided for @a11yCredit.
  ///
  /// In ar, this message translates to:
  /// **'إيداع'**
  String get a11yCredit;

  /// No description provided for @a11yPending.
  ///
  /// In ar, this message translates to:
  /// **'معلق'**
  String get a11yPending;

  /// No description provided for @a11yAi.
  ///
  /// In ar, this message translates to:
  /// **'ذكاء اصطناعي'**
  String get a11yAi;

  /// No description provided for @chartSliceCount.
  ///
  /// In ar, this message translates to:
  /// **'{count} عملية'**
  String chartSliceCount(String count);

  /// No description provided for @planSpent.
  ///
  /// In ar, this message translates to:
  /// **'المصروف: {amount}'**
  String planSpent(String amount);

  /// No description provided for @planEnds.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي: {date}'**
  String planEnds(String date);

  /// No description provided for @planPerDayLeft.
  ///
  /// In ar, this message translates to:
  /// **'متاح {amount} في اليوم لباقي الخطة'**
  String planPerDayLeft(String amount);

  /// No description provided for @iiUnreadableDate.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر قراءة التاريخ.'**
  String get iiUnreadableDate;

  /// No description provided for @iiCurrencyNotIso.
  ///
  /// In ar, this message translates to:
  /// **'العملة يجب أن تكون رمز ISO من ثلاثة أحرف.'**
  String get iiCurrencyNotIso;

  /// No description provided for @iiAmountInvalidOrZero.
  ///
  /// In ar, this message translates to:
  /// **'المبلغ غير صالح أو يساوي صفرًا.'**
  String get iiAmountInvalidOrZero;

  /// No description provided for @iiCsvNeedsTwoColumns.
  ///
  /// In ar, this message translates to:
  /// **'ملف CSV يحتاج عمودين على الأقل: التاريخ والمبلغ.'**
  String get iiCsvNeedsTwoColumns;

  /// No description provided for @iiHeadersNotRecognised.
  ///
  /// In ar, this message translates to:
  /// **'لم نتعرّف على العناوين تلقائيًا. راجع مطابقة الأعمدة.'**
  String get iiHeadersNotRecognised;

  /// No description provided for @iiDuplicatesFound.
  ///
  /// In ar, this message translates to:
  /// **'{value} عملية مشابهة موجودة وستُعرض قبل الحفظ.'**
  String iiDuplicatesFound(String value);

  /// No description provided for @iiRowPrefix.
  ///
  /// In ar, this message translates to:
  /// **'صف {row}: '**
  String iiRowPrefix(String row);

  /// No description provided for @conflictBudgetLabel.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية {amount}'**
  String conflictBudgetLabel(String amount);

  /// No description provided for @cardSourceAuto.
  ///
  /// In ar, this message translates to:
  /// **'اتُعرِّفت من رسائل البنك'**
  String get cardSourceAuto;

  /// No description provided for @cardSourceManual.
  ///
  /// In ar, this message translates to:
  /// **'أضفتها بنفسك'**
  String get cardSourceManual;

  /// No description provided for @smartConsentTitle.
  ///
  /// In ar, this message translates to:
  /// **'التحليل الذكي والمزامنة السحابية'**
  String get smartConsentTitle;

  /// No description provided for @smartConsentBullet1.
  ///
  /// In ar, this message translates to:
  /// **'تُرسل الرسائل البنكية الملتقطة، ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد، إلى خوادم قرش بعد إزالة أرقام البطاقات والحسابات والهواتف والرموز. قد تعالج خدمة Google Gemini هذا النص لتحديد المبلغ والتاجر والبنك، وقد تتلقى Google Places أسماء التجار. تبقى فيه المبالغ والتجار والأرصدة، لذا فهو ليس مجهول الهوية.'**
  String get smartConsentBullet1;

  /// No description provided for @smartConsentBullet2.
  ///
  /// In ar, this message translates to:
  /// **'كما تتم مزامنة معاملاتك وحساباتك وميزانياتك وأهدافك وإعداداتك ونسخها احتياطيًا في حسابك السحابي على قِرش.'**
  String get smartConsentBullet2;

  /// No description provided for @smartConsentBullet3.
  ///
  /// In ar, this message translates to:
  /// **'بعد الموافقة، تعمل المزامنة والتحليلات المسموح بها تلقائيًا عند توفر الخدمة. يمكنك سحب أي موافقة من الإعدادات ← الخصوصية. المتابعة محليًا لا ترسل هذه البيانات.'**
  String get smartConsentBullet3;

  /// No description provided for @smartConsentEnable.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل التحليل الذكي والمزامنة السحابية'**
  String get smartConsentEnable;

  /// No description provided for @smartConsentNotNow.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get smartConsentNotNow;

  /// No description provided for @smartConsentPrivacyLink.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الخصوصية'**
  String get smartConsentPrivacyLink;

  /// No description provided for @smartConsentStatusConnecting.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الاتصال…'**
  String get smartConsentStatusConnecting;

  /// No description provided for @smartConsentStatusConnected.
  ///
  /// In ar, this message translates to:
  /// **'التحليل الذكي متصل'**
  String get smartConsentStatusConnected;

  /// No description provided for @smartConsentStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'التحليل الذكي غير متصل، لذا تُقرأ رسائل البنك على هذا الجهاز فقط حتى يتم الاتصال.'**
  String get smartConsentStatusFailed;

  /// No description provided for @smartConsentRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get smartConsentRetry;

  /// No description provided for @txnAwaitingPrice.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار السعر'**
  String get txnAwaitingPrice;

  /// No description provided for @onbCloudTitle.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية'**
  String get onbCloudTitle;

  /// No description provided for @onbCloudBullet1.
  ///
  /// In ar, this message translates to:
  /// **'تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش لقراءتها بعد حذف أرقام البطاقات والحسابات والهواتف والرموز، وتتم مزامنة معاملاتك وحساباتك وميزانياتك وأهدافك وإعداداتك ونسخها احتياطيًا في حسابك السحابي على قِرش.'**
  String get onbCloudBullet1;

  /// No description provided for @onbCloudBullet2.
  ///
  /// In ar, this message translates to:
  /// **'بدونها تبقى بياناتك على هذا الهاتف فقط ولا يُحتفظ لها بنسخة احتياطية.'**
  String get onbCloudBullet2;

  /// No description provided for @onbCloudBullet3.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك إيقافها في أي وقت من الإعدادات ← الخصوصية.'**
  String get onbCloudBullet3;

  /// No description provided for @onbCloudEnable.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل المزامنة السحابية'**
  String get onbCloudEnable;

  /// No description provided for @onbAiTitle.
  ///
  /// In ar, this message translates to:
  /// **'التحليل الذكي'**
  String get onbAiTitle;

  /// No description provided for @onbAiBullet1.
  ///
  /// In ar, this message translates to:
  /// **'عند تشغيل التحليل الذكي، قد تُحلَّل رسائل البنك الملتقطة — بعد حذف أرقام البطاقات والحسابات والهواتف والرموز — بواسطة مزوّد ذكاء اصطناعي لقراءة المبلغ والتاجر والبنك.'**
  String get onbAiBullet1;

  /// No description provided for @onbAiBullet2.
  ///
  /// In ar, this message translates to:
  /// **'يمكنك إيقافه في أي وقت من الإعدادات ← الخصوصية.'**
  String get onbAiBullet2;

  /// No description provided for @onbAiEnable.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل التحليل الذكي'**
  String get onbAiEnable;

  /// No description provided for @onbAiNeedsCloud.
  ///
  /// In ar, this message translates to:
  /// **'يحتاج التحليل الذكي إلى المزامنة السحابية، وهي متوقفة الآن. يمكنك تفعيل الاثنين معًا:'**
  String get onbAiNeedsCloud;

  /// No description provided for @onbAiEnableBoth.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل المزامنة السحابية والتحليل الذكي'**
  String get onbAiEnableBoth;

  /// No description provided for @onbReadyTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة الاتصال'**
  String get onbReadyTitle;

  /// No description provided for @onbReadyBodyOn.
  ///
  /// In ar, this message translates to:
  /// **'يربط قِرش هذا الجهاز بالخدمات السحابية. يمكنك المتابعة بينما ينتهي الاتصال.'**
  String get onbReadyBodyOn;

  /// No description provided for @onbReadyBodyOff.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية والتحليل الذكي متوقفان، لذا تبقى بياناتك على هذا الهاتف. يمكنك تفعيلهما في أي وقت من الإعدادات ← الخصوصية.'**
  String get onbReadyBodyOff;

  /// No description provided for @onbAccountTitle.
  ///
  /// In ar, this message translates to:
  /// **'جهّز حسابك'**
  String get onbAccountTitle;

  /// No description provided for @onbAccountBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف الحساب الذي تحتفظ فيه بأموالك، مثل حساب بنكي أو نقد أو محفظة. يمكنك إضافة المزيد لاحقًا.'**
  String get onbAccountBody;

  /// No description provided for @onbAccountExistingTitle.
  ///
  /// In ar, this message translates to:
  /// **'حساباتك'**
  String get onbAccountExistingTitle;

  /// No description provided for @onbAccountExistingBody.
  ///
  /// In ar, this message translates to:
  /// **'لديك هذه الحسابات بالفعل. يمكنك المتابعة أو إضافة حساب آخر.'**
  String get onbAccountExistingBody;

  /// No description provided for @onbAccountAddAnother.
  ///
  /// In ar, this message translates to:
  /// **'إضافة حساب آخر'**
  String get onbAccountAddAnother;

  /// No description provided for @onbAccountContinue.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get onbAccountContinue;

  /// No description provided for @onbAccountRequired.
  ///
  /// In ar, this message translates to:
  /// **'أضف حسابًا لإنهاء الإعداد.'**
  String get onbAccountRequired;

  /// No description provided for @syncStatusAllSynced.
  ///
  /// In ar, this message translates to:
  /// **'تمت مزامنة كل البيانات'**
  String get syncStatusAllSynced;

  /// No description provided for @syncStatusSyncing.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ المزامنة…'**
  String get syncStatusSyncing;

  /// No description provided for @syncStatusWaiting.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{بانتظار المزامنة} =1{تغيير واحد بانتظار المزامنة} =2{تغييران بانتظار المزامنة} few{{count} تغييرات بانتظار المزامنة} many{{count} تغييرًا بانتظار المزامنة} other{{count} تغيير بانتظار المزامنة}}'**
  String syncStatusWaiting(int count);

  /// No description provided for @syncStatusConsentOff.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية متوقفة — بياناتك تبقى على هذا الجهاز'**
  String get syncStatusConsentOff;

  /// No description provided for @syncStatusSignedOut.
  ///
  /// In ar, this message translates to:
  /// **'لم تسجّل الدخول — بياناتك تبقى على هذا الجهاز'**
  String get syncStatusSignedOut;

  /// No description provided for @syncStatusFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشلت المزامنة — إعادة المحاولة'**
  String get syncStatusFailed;

  /// No description provided for @syncStatusNeedsAttention.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج إلى انتباهك'**
  String get syncStatusNeedsAttention;

  /// No description provided for @syncSheetTitle.
  ///
  /// In ar, this message translates to:
  /// **'حالة المزامنة'**
  String get syncSheetTitle;

  /// No description provided for @syncSheetKeptOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =0{لا توجد تغييرات معلّقة} =1{تغيير واحد محفوظ على هذا الجهاز} =2{تغييران محفوظان على هذا الجهاز} few{{count} تغييرات محفوظة على هذا الجهاز} many{{count} تغييرًا محفوظًا على هذا الجهاز} other{{count} تغيير محفوظ على هذا الجهاز}}'**
  String syncSheetKeptOnDevice(int count);

  /// No description provided for @syncSheetWaitingConnection.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار الاتصال'**
  String get syncSheetWaitingConnection;

  /// No description provided for @syncSheetWaitingServer.
  ///
  /// In ar, this message translates to:
  /// **'بانتظار تحديث الخادم'**
  String get syncSheetWaitingServer;

  /// No description provided for @syncSheetNeedsAttention.
  ///
  /// In ar, this message translates to:
  /// **'تحتاج إلى انتباه'**
  String get syncSheetNeedsAttention;

  /// No description provided for @syncSheetStayFailed.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عنصر واحد لا يمكن إعادة محاولته ويبقى فاشلًا} =2{عنصران لا يمكن إعادة محاولتهما ويبقيان فاشلين} few{{count} عناصر لا يمكن إعادة محاولتها وتبقى فاشلة} many{{count} عنصرًا لا يمكن إعادة محاولتها وتبقى فاشلة} other{{count} عنصر لا يمكن إعادة محاولتها وتبقى فاشلة}}'**
  String syncSheetStayFailed(int count);

  /// No description provided for @syncSheetLastSync.
  ///
  /// In ar, this message translates to:
  /// **'آخر مزامنة ناجحة: {time}'**
  String syncSheetLastSync(String time);

  /// No description provided for @syncSheetNeverSynced.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مزامنة ناجحة بعد'**
  String get syncSheetNeverSynced;

  /// No description provided for @syncSheetRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get syncSheetRetry;

  /// No description provided for @signOutKeepData.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج مع الاحتفاظ بالبيانات المشفّرة'**
  String get signOutKeepData;

  /// No description provided for @signOutKeepDataHint.
  ///
  /// In ar, this message translates to:
  /// **'تبقى بياناتك مشفّرة على هذا الجهاز. سجّل الدخول مجددًا لفتحها.'**
  String get signOutKeepDataHint;

  /// No description provided for @signOutRemoveData.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج وحذف البيانات من هذا الجهاز'**
  String get signOutRemoveData;

  /// No description provided for @signOutRemoveDataHint.
  ///
  /// In ar, this message translates to:
  /// **'يحذف بيانات هذا الحساب من هذا الجهاز فقط. لا تتأثر البيانات المحفوظة بالفعل في السحابة.'**
  String get signOutRemoveDataHint;

  /// No description provided for @signOutUnsyncedKeepBody.
  ///
  /// In ar, this message translates to:
  /// **'بعض البيانات لم تصل إلى السحابة بعد: {list}. تبقى على هذا الجهاز وتُزامَن عند تسجيل دخولك مجددًا.'**
  String signOutUnsyncedKeepBody(String list);

  /// No description provided for @removeDataTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف البيانات من هذا الجهاز؟'**
  String get removeDataTitle;

  /// No description provided for @removeDataBody.
  ///
  /// In ar, this message translates to:
  /// **'سيُحذف نهائيًا كل ما يخص هذا الحساب على هذا الجهاز. يمكنك تنزيل البيانات المحفوظة في السحابة مجددًا بتسجيل الدخول.'**
  String get removeDataBody;

  /// No description provided for @removeDataUnsyncedBody.
  ///
  /// In ar, this message translates to:
  /// **'هذه البيانات لم تصل إلى السحابة وستُفقد: {list}.'**
  String removeDataUnsyncedBody(String list);

  /// No description provided for @removeDataAction.
  ///
  /// In ar, this message translates to:
  /// **'حذف البيانات'**
  String get removeDataAction;

  /// No description provided for @captureUnboundTitle.
  ///
  /// In ar, this message translates to:
  /// **'رسائل وصلت أثناء تسجيل الخروج'**
  String get captureUnboundTitle;

  /// No description provided for @captureUnboundBody.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{وصلت رسالة بنكية واحدة} =2{وصلت رسالتان بنكيتان} few{وصلت {count} رسائل بنكية} other{وصلت {count} رسالة بنكية}} أثناء تسجيل خروجك.'**
  String captureUnboundBody(int count);

  /// No description provided for @captureUnboundSenders.
  ///
  /// In ar, this message translates to:
  /// **'من: {senders}'**
  String captureUnboundSenders(String senders);

  /// No description provided for @captureUnboundAdd.
  ///
  /// In ar, this message translates to:
  /// **'أضفها إلى حسابي'**
  String get captureUnboundAdd;

  /// No description provided for @captureUnboundDiscard.
  ///
  /// In ar, this message translates to:
  /// **'تجاهلها'**
  String get captureUnboundDiscard;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الإبقاء على نسختي'**
  String get conflictKeepMine;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الإبقاء على نسختي كنسخة جديدة'**
  String get conflictKeepMineAsNew;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الإبقاء على نسخة السحابة'**
  String get conflictKeepCloud;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'تم الإبقاء على نسخة السحابة.'**
  String get conflictKeptCloud;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'هذا الجهاز'**
  String get conflictThisDevice;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'السحابة'**
  String get conflictCloud;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'محذوف في السحابة'**
  String get conflictDeletedInCloud;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'محذوف على هذا الجهاز'**
  String get conflictDeletedHere;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get conflictNotSet;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'المبلغ'**
  String get conflictFieldAmount;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'العملة'**
  String get conflictFieldCurrency;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'التاجر'**
  String get conflictFieldMerchant;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة'**
  String get conflictFieldNote;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'التاريخ'**
  String get conflictFieldDate;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get conflictFieldStatus;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الفئة'**
  String get conflictFieldCategory;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get conflictFieldName;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'النوع'**
  String get conflictFieldType;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الرصيد'**
  String get conflictFieldBalance;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الرصيد الابتدائي'**
  String get conflictFieldInitialBalance;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الحد الائتماني'**
  String get conflictFieldCreditLimit;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الفترة'**
  String get conflictFieldPeriod;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'تاريخ البداية'**
  String get conflictFieldStartDate;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'تاريخ النهاية'**
  String get conflictFieldEndDate;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'التكرار'**
  String get conflictFieldFrequency;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الاستحقاق القادم'**
  String get conflictFieldNextDue;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستهدف'**
  String get conflictFieldTargetAmount;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'الموعد النهائي'**
  String get conflictFieldDeadline;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'اسم البطاقة'**
  String get conflictFieldNickname;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'آخر 4 أرقام'**
  String get conflictFieldLast4;

  /// PROPOSED (WP-5, SYNC-Q5): awaiting user approval
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get conflictFieldActive;

  /// No description provided for @startupCoordinatorTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر بدء التطبيق بأمان'**
  String get startupCoordinatorTitle;

  /// No description provided for @startupCoordinatorBody.
  ///
  /// In ar, this message translates to:
  /// **'لم يتمكن قِرش من التأكد أن أي جزء آخر من التطبيق لا يستخدم بياناتك، فلم يفتح شيئًا. لم تتغير بياناتك. حاول مرة أخرى، وإن تكررت المشكلة فأعد تشغيل التطبيق.'**
  String get startupCoordinatorBody;

  /// No description provided for @startupCoordinatorRetry.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى'**
  String get startupCoordinatorRetry;

  /// No description provided for @sessionRecoveryTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إكمال فتح قرش'**
  String get sessionRecoveryTitle;

  /// No description provided for @sessionRecoveryBody.
  ///
  /// In ar, this message translates to:
  /// **'تأكد من اتصالك وأعد المحاولة، أو سجّل الدخول من جديد للمتابعة. بياناتك المحفوظة باقية على هذا الجهاز.'**
  String get sessionRecoveryBody;

  /// No description provided for @sessionRecoverySignIn.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول من جديد'**
  String get sessionRecoverySignIn;

  /// No description provided for @localReadBannerTitle.
  ///
  /// In ar, this message translates to:
  /// **'بدون اتصال — للعرض فقط'**
  String get localReadBannerTitle;

  /// No description provided for @localReadBannerBody.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك على هذا الجهاز معروضة للاطّلاع فقط. سجّل الدخول من جديد لإضافة العمليات أو تعديلها أو مزامنتها.'**
  String get localReadBannerBody;

  /// No description provided for @localReadReconnect.
  ///
  /// In ar, this message translates to:
  /// **'إعادة الاتصال'**
  String get localReadReconnect;

  /// No description provided for @localReadLogout.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get localReadLogout;

  /// No description provided for @localReadBalancesTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأرصدة'**
  String get localReadBalancesTitle;

  /// No description provided for @localReadTransactionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'العمليات'**
  String get localReadTransactionsTitle;

  /// No description provided for @localReadNoTransactions.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات على هذا الجهاز.'**
  String get localReadNoTransactions;

  /// No description provided for @localReadNoAccounts.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد حسابات على هذا الجهاز.'**
  String get localReadNoAccounts;

  /// No description provided for @localReadLoadError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت قراءة بياناتك على هذا الجهاز.'**
  String get localReadLoadError;

  /// No description provided for @localReadLogoutFailed.
  ///
  /// In ar, this message translates to:
  /// **'لم يكتمل تسجيل الخروج. حاول مرة أخرى.'**
  String get localReadLogoutFailed;

  /// No description provided for @signOutCleanupIncompleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل خروجك على هذا الجهاز، لكن تعذّر إكمال قفل بياناتك دون اتصال، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.'**
  String get signOutCleanupIncompleteMessage;

  /// No description provided for @signOutCleanupRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get signOutCleanupRetry;

  /// No description provided for @signOutCleanupStillIncomplete.
  ///
  /// In ar, this message translates to:
  /// **'ما زال تعذّر قفل بياناتك دون اتصال، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.'**
  String get signOutCleanupStillIncomplete;

  /// No description provided for @removeDataDenyIncompleteMessage.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إكمال إلغاء الوصول دون اتصال إلى البيانات على هذا الجهاز، وقد تُفتح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.'**
  String get removeDataDenyIncompleteMessage;

  /// No description provided for @removeDataDenyStillIncomplete.
  ///
  /// In ar, this message translates to:
  /// **'ما زال تعذّر إلغاء الوصول دون اتصال، وقد يُتاح من جديد بعد إعادة تشغيل التطبيق. أعد المحاولة.'**
  String get removeDataDenyStillIncomplete;

  /// No description provided for @cloudEnableIncomplete.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تشغيل المعالجة السحابية. ستبقى متوقفة. حاول مرة أخرى.'**
  String get cloudEnableIncomplete;

  /// No description provided for @cloudEnableWithdrawFirst.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكننا التأكد من الحالة الحالية، لذلك لم يتغيّر شيء. أوقفها أولًا ثم فعّلها من جديد.'**
  String get cloudEnableWithdrawFirst;

  /// No description provided for @cloudEnableChoiceNotSaved.
  ///
  /// In ar, this message translates to:
  /// **'اكتملت المعالجة السحابية باختيارك السابق، ولم يُحفظ اختيارك الجديد. راجِع الخيارات واختر من جديد لإضافته.'**
  String get cloudEnableChoiceNotSaved;

  /// No description provided for @initialConsentAccept.
  ///
  /// In ar, this message translates to:
  /// **'أوافق على المزامنة والتحليل الذكي'**
  String get initialConsentAccept;

  /// No description provided for @initialConsentDecline.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة محليًا'**
  String get initialConsentDecline;

  /// No description provided for @consentMgmtTitle.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية والتحليل الذكي'**
  String get consentMgmtTitle;

  /// No description provided for @consentStatusActive.
  ///
  /// In ar, this message translates to:
  /// **'مفعّلة'**
  String get consentStatusActive;

  /// No description provided for @consentStatusPartial.
  ///
  /// In ar, this message translates to:
  /// **'مفعّلة جزئيًا'**
  String get consentStatusPartial;

  /// No description provided for @consentStatusOff.
  ///
  /// In ar, this message translates to:
  /// **'متوقفة'**
  String get consentStatusOff;

  /// No description provided for @consentStatusUnknown.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التأكد'**
  String get consentStatusUnknown;

  /// No description provided for @consentStatusTurningOn.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التفعيل…'**
  String get consentStatusTurningOn;

  /// No description provided for @consentStatusTurningOff.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ الإيقاف…'**
  String get consentStatusTurningOff;

  /// No description provided for @consentStatusActiveBody.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية والتحليل الذكي مفعّلان معًا.'**
  String get consentStatusActiveBody;

  /// No description provided for @consentStatusPartialBody.
  ///
  /// In ar, this message translates to:
  /// **'جزء فقط من هذه الموافقة مفعّل. فعّلها لمراجعتها واتخاذ قرارك من جديد، أو أوقفها.'**
  String get consentStatusPartialBody;

  /// No description provided for @consentStatusOffBody.
  ///
  /// In ar, this message translates to:
  /// **'لا يُرسل أي شيء إلى خوادم قرش ولا يحلله الذكاء الاصطناعي. تبقى بياناتك على هذا الجهاز، ويظل الإدخال اليدوي متاحًا.'**
  String get consentStatusOffBody;

  /// No description provided for @consentStatusUnknownBody.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكننا التأكد من الحالة الحالية الآن، لذا تبقى المزامنة والتحليل متوقفين إلى أن يتم التأكد.'**
  String get consentStatusUnknownBody;

  /// No description provided for @consentStatusUnknownRecovery.
  ///
  /// In ar, this message translates to:
  /// **'لاستعادتها، أوقفها أولًا ثم فعّلها من جديد.'**
  String get consentStatusUnknownRecovery;

  /// No description provided for @consentStatusTurningOnBody.
  ///
  /// In ar, this message translates to:
  /// **'لم نتمكن من التأكد من اكتمال التفعيل. تبقى المزامنة والتحليل متوقفين إلى أن يكتمل.'**
  String get consentStatusTurningOnBody;

  /// No description provided for @consentStatusTurningOffBody.
  ///
  /// In ar, this message translates to:
  /// **'تم إيقاف المزامنة والتحليل بالفعل. نُنهي الإجراء الآن.'**
  String get consentStatusTurningOffBody;

  /// No description provided for @consentTurnOn.
  ///
  /// In ar, this message translates to:
  /// **'مراجعة وتفعيل'**
  String get consentTurnOn;

  /// No description provided for @consentTurnOff.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف'**
  String get consentTurnOff;

  /// No description provided for @consentRefresh.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق مجددًا'**
  String get consentRefresh;

  /// No description provided for @consentWithdrawTitle.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف المزامنة السحابية والتحليل الذكي؟'**
  String get consentWithdrawTitle;

  /// No description provided for @consentWithdrawBody.
  ///
  /// In ar, this message translates to:
  /// **'تتوقف المزامنة والتحليل فورًا معًا. تبقى بياناتك على هذا الجهاز، ويمكنك تفعيلهما مجددًا من هنا في أي وقت.'**
  String get consentWithdrawBody;

  /// No description provided for @consentWithdrawConfirm.
  ///
  /// In ar, this message translates to:
  /// **'إيقاف'**
  String get consentWithdrawConfirm;

  /// No description provided for @consentWithdrawFailed.
  ///
  /// In ar, this message translates to:
  /// **'لم نتمكن من التأكد من إيقاف هذه الميزة. يبقى الإرسال متوقفًا. حاول مجددًا.'**
  String get consentWithdrawFailed;

  /// No description provided for @signOutDataStays.
  ///
  /// In ar, this message translates to:
  /// **'تبقى بياناتك على هذا الجهاز وتعود إليك عند تسجيل الدخول مجددًا.'**
  String get signOutDataStays;

  /// No description provided for @deleteAccountTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب'**
  String get deleteAccountTitle;

  /// No description provided for @deleteAccountIntro.
  ///
  /// In ar, this message translates to:
  /// **'احذف حساب قرش والبيانات المحفوظة فيه نهائيًا وعلى الفور. ستؤكد هويتك أولًا عبر Apple أو طريقة الدخول التي تستخدمها.'**
  String get deleteAccountIntro;

  /// No description provided for @deleteAccountAction.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب'**
  String get deleteAccountAction;

  /// No description provided for @deleteAccountConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف حسابك؟'**
  String get deleteAccountConfirmTitle;

  /// No description provided for @deleteAccountConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'سيُحذف حسابك وبياناته نهائيًا وعلى الفور. أكّد هويتك عبر Apple أو طريقة الدخول التي تستخدمها للمتابعة. لا يمكن التراجع عن الحذف.'**
  String get deleteAccountConfirmBody;

  /// No description provided for @deleteAccountConfirmAction.
  ///
  /// In ar, this message translates to:
  /// **'حذف نهائي'**
  String get deleteAccountConfirmAction;

  /// No description provided for @deleteAccountProgress.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ حذف حسابك…'**
  String get deleteAccountProgress;

  /// No description provided for @deleteAccountSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف حسابك.'**
  String get deleteAccountSuccess;

  /// No description provided for @deleteAccountAcceptedBody.
  ///
  /// In ar, this message translates to:
  /// **'استلمنا طلب الحذف، لكن حسابك لم يُحذف بعد. يمكنك متابعته أو إلغاؤه من الخصوصية والبيانات.'**
  String get deleteAccountAcceptedBody;

  /// No description provided for @deleteAccountFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إكمال حذف حسابك. حاول مجددًا.'**
  String get deleteAccountFailed;

  /// No description provided for @deleteAccountFailedFinal.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكننا حذف حسابك من هنا الآن. حاول لاحقًا أو تواصل مع الدعم.'**
  String get deleteAccountFailedFinal;

  /// No description provided for @deleteAccountUnconfirmed.
  ///
  /// In ar, this message translates to:
  /// **'لم نتمكن من التأكد من حذف حسابك بعد.'**
  String get deleteAccountUnconfirmed;

  /// No description provided for @deleteAccountRetry.
  ///
  /// In ar, this message translates to:
  /// **'حاول مجددًا'**
  String get deleteAccountRetry;

  /// No description provided for @deleteAccountRejected.
  ///
  /// In ar, this message translates to:
  /// **'فشل التأكيد أو انتهت صلاحيته. حاول مجددًا.'**
  String get deleteAccountRejected;

  /// No description provided for @deleteAccountDone.
  ///
  /// In ar, this message translates to:
  /// **'تم'**
  String get deleteAccountDone;

  /// No description provided for @deleteAccountConfirmBodyScheduled.
  ///
  /// In ar, this message translates to:
  /// **'سيُرسل طلب الحذف، ثم يحذف الخادم حسابك وكل بياناتك نهائيًا لاحقًا، ولا يمكن التراجع عن ذلك.'**
  String get deleteAccountConfirmBodyScheduled;

  /// No description provided for @deleteAccountPendingBody.
  ///
  /// In ar, this message translates to:
  /// **'حذف حسابك قيد التنفيذ، وحسابك لم يُحذف بعد. تحقق مرة أخرى بعد قليل.'**
  String get deleteAccountPendingBody;

  /// No description provided for @deleteAccountCheckStatus.
  ///
  /// In ar, this message translates to:
  /// **'تحقق من الحالة'**
  String get deleteAccountCheckStatus;

  /// No description provided for @deleteAccountUnconfirmedStale.
  ///
  /// In ar, this message translates to:
  /// **'تغيّرت جلسة الدخول قبل أن نتأكد من النتيجة. افتح هذه الشاشة مجددًا للتحقق.'**
  String get deleteAccountUnconfirmedStale;

  /// No description provided for @deleteAccountAdminBlocked.
  ///
  /// In ar, this message translates to:
  /// **'هذا حساب مشرف ولا يمكن حذفه قبل إزالة صلاحيات الإشراف عنه. تواصل مع الفريق لإزالتها أولًا.'**
  String get deleteAccountAdminBlocked;

  /// No description provided for @deleteAccountRateLimited.
  ///
  /// In ar, this message translates to:
  /// **'محاولات كثيرة. انتظر بضع دقائق ثم حاول مجددًا.'**
  String get deleteAccountRateLimited;

  /// No description provided for @deleteAccountLocalCleanupPending.
  ///
  /// In ar, this message translates to:
  /// **'تم حذف حسابك من خوادمنا، لكن تعذّر إنهاء مسح البيانات على هذا الجهاز. أغلق التطبيق وافتحه مجددًا.'**
  String get deleteAccountLocalCleanupPending;

  /// No description provided for @pasteAnalysisHowItWorks.
  ///
  /// In ar, this message translates to:
  /// **'لما السحابة والتحليل الذكي يكونوا مفعّلين، الذكاء الاصطناعي بيقرأ الرسائل. عند إيقافهم، قرش بيحلل على الجهاز.'**
  String get pasteAnalysisHowItWorks;

  /// No description provided for @pasteReadOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت على جهازك — لم نحتج إلى الذكاء الاصطناعي.'**
  String get pasteReadOnDevice;

  /// No description provided for @pasteReadWithAi.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت باستخدام الذكاء الاصطناعي.'**
  String get pasteReadWithAi;

  /// No description provided for @pasteAiOff.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت على جهازك — الذكاء الاصطناعي متوقف. فعّل السحابة وتحليل الذكاء الاصطناعي من الإعدادات.'**
  String get pasteAiOff;

  /// No description provided for @pasteAiUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت على جهازك — الذكاء الاصطناعي غير متاح في هذه النسخة.'**
  String get pasteAiUnavailable;

  /// No description provided for @pasteAiMismatch.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت على جهازك — إجابة الذكاء الاصطناعي لم تطابق الرسالة فلم تُستخدم.'**
  String get pasteAiMismatch;

  /// No description provided for @pasteAiFailed.
  ///
  /// In ar, this message translates to:
  /// **'قُرئت على جهازك — تعذّر الوصول إلى الذكاء الاصطناعي ({code}).'**
  String pasteAiFailed(String code);

  /// No description provided for @pasteAiConsentOff.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت قراءة هذه الرسالة على جهازك. فعّل السحابة والتحليل الذكي من الخصوصية للسماح بمساعدة الذكاء الاصطناعي.'**
  String get pasteAiConsentOff;

  /// No description provided for @homeGoodMorning.
  ///
  /// In ar, this message translates to:
  /// **'صباح الخير'**
  String get homeGoodMorning;

  /// No description provided for @homeGoodEvening.
  ///
  /// In ar, this message translates to:
  /// **'مساء الخير'**
  String get homeGoodEvening;

  /// No description provided for @homeQuickAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get homeQuickAdd;

  /// No description provided for @homeQuickPaste.
  ///
  /// In ar, this message translates to:
  /// **'لصق رسالة'**
  String get homeQuickPaste;

  /// No description provided for @homeQuickBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية'**
  String get homeQuickBudget;

  /// No description provided for @homeQuickGoals.
  ///
  /// In ar, this message translates to:
  /// **'أهداف'**
  String get homeQuickGoals;

  /// No description provided for @homeBudgetLeft.
  ///
  /// In ar, this message translates to:
  /// **'من ميزانية {limit} · متبقي {left}'**
  String homeBudgetLeft(String limit, String left);

  /// No description provided for @homeBudgetOverBy.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت ميزانية {limit} بـ {over}'**
  String homeBudgetOverBy(String limit, String over);

  /// No description provided for @homeProjectedMonthEnd.
  ///
  /// In ar, this message translates to:
  /// **'المتوقع نهاية الشهر {amount}'**
  String homeProjectedMonthEnd(String amount);

  /// No description provided for @homeLastWeekWas.
  ///
  /// In ar, this message translates to:
  /// **'الأسبوع الماضي {amount}'**
  String homeLastWeekWas(String amount);

  /// No description provided for @homeTodayTxCount.
  ///
  /// In ar, this message translates to:
  /// **'عمليات اليوم: {count}'**
  String homeTodayTxCount(int count);

  /// No description provided for @homeLeftTodayShort.
  ///
  /// In ar, this message translates to:
  /// **'متاح لليوم {amount}'**
  String homeLeftTodayShort(String amount);

  /// No description provided for @homePaceUnder.
  ///
  /// In ar, this message translates to:
  /// **'أقل من وتيرة الميزانية بـ {percent}%'**
  String homePaceUnder(int percent);

  /// No description provided for @homePaceOver.
  ///
  /// In ar, this message translates to:
  /// **'أعلى من وتيرة الميزانية بـ {percent}%'**
  String homePaceOver(int percent);

  /// No description provided for @homePaceOnTrack.
  ///
  /// In ar, this message translates to:
  /// **'على وتيرة الميزانية'**
  String get homePaceOnTrack;

  /// No description provided for @homePaceSetBudget.
  ///
  /// In ar, this message translates to:
  /// **'حدّد ميزانية لتتابع الوتيرة'**
  String get homePaceSetBudget;

  /// No description provided for @homeWeekMoreThan.
  ///
  /// In ar, this message translates to:
  /// **'أعلى من الأسبوع الماضي بـ {percent}%'**
  String homeWeekMoreThan(int percent);

  /// No description provided for @homeWeekLessThan.
  ///
  /// In ar, this message translates to:
  /// **'أقل من الأسبوع الماضي بـ {percent}%'**
  String homeWeekLessThan(int percent);

  /// No description provided for @homeDayMoreThan.
  ///
  /// In ar, this message translates to:
  /// **'أعلى من أمس بـ {percent}%'**
  String homeDayMoreThan(int percent);

  /// No description provided for @homeDayLessThan.
  ///
  /// In ar, this message translates to:
  /// **'أقل من أمس بـ {percent}%'**
  String homeDayLessThan(int percent);

  /// No description provided for @homeToReview.
  ///
  /// In ar, this message translates to:
  /// **'للمراجعة'**
  String get homeToReview;

  /// No description provided for @homeReviewNow.
  ///
  /// In ar, this message translates to:
  /// **'راجعها'**
  String get homeReviewNow;

  /// No description provided for @homeSpentOfAllowance.
  ///
  /// In ar, this message translates to:
  /// **'صرفت {spent} من {allowance}'**
  String homeSpentOfAllowance(String spent, String allowance);

  /// No description provided for @homeLastSevenDays.
  ///
  /// In ar, this message translates to:
  /// **'آخر ٧ أيام'**
  String get homeLastSevenDays;

  /// No description provided for @homeDailyAverage.
  ///
  /// In ar, this message translates to:
  /// **'المتوسط {amount} يوميًا'**
  String homeDailyAverage(String amount);

  /// No description provided for @homeWhereMoneyWent.
  ///
  /// In ar, this message translates to:
  /// **'أين ذهبت أموالك'**
  String get homeWhereMoneyWent;

  /// No description provided for @homeDetails.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get homeDetails;

  /// No description provided for @homeUpcoming.
  ///
  /// In ar, this message translates to:
  /// **'مدفوعات قادمة'**
  String get homeUpcoming;

  /// No description provided for @homeInstalmentProgress.
  ///
  /// In ar, this message translates to:
  /// **'الدفعة {n} من {total}'**
  String homeInstalmentProgress(int n, int total);

  /// No description provided for @homeGoalsAndPlans.
  ///
  /// In ar, this message translates to:
  /// **'أهدافي وخططي'**
  String get homeGoalsAndPlans;

  /// No description provided for @homeNewGoal.
  ///
  /// In ar, this message translates to:
  /// **'هدف جديد'**
  String get homeNewGoal;

  /// No description provided for @homeRecentTx.
  ///
  /// In ar, this message translates to:
  /// **'آخر العمليات'**
  String get homeRecentTx;

  /// No description provided for @homeSeeAll.
  ///
  /// In ar, this message translates to:
  /// **'عرض الكل'**
  String get homeSeeAll;

  /// No description provided for @homeWelcomeTo.
  ///
  /// In ar, this message translates to:
  /// **'أهلاً بك في قِرش'**
  String get homeWelcomeTo;

  /// No description provided for @homeWelcomeTitle.
  ///
  /// In ar, this message translates to:
  /// **'أضف أول عملية،\nوقِرش يرتّب الباقي'**
  String get homeWelcomeTitle;

  /// No description provided for @homeWelcomeBody.
  ///
  /// In ar, this message translates to:
  /// **'صرفك اليومي، المتاح لك، وأين تذهب أموالك. كلها تظهر هنا بعد أول عملية.'**
  String get homeWelcomeBody;

  /// No description provided for @homeStartSteps.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ في ٣ خطوات'**
  String get homeStartSteps;

  /// No description provided for @homeStartStepsHint.
  ///
  /// In ar, this message translates to:
  /// **'أقل من دقيقتين'**
  String get homeStartStepsHint;

  /// No description provided for @homeStepAddTitle.
  ///
  /// In ar, this message translates to:
  /// **'أضف أول عملية'**
  String get homeStepAddTitle;

  /// No description provided for @homeStepAddBody.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة البنك أو أدخلها يدويًا'**
  String get homeStepAddBody;

  /// No description provided for @homeStepAddCta.
  ///
  /// In ar, this message translates to:
  /// **'أضف عملية'**
  String get homeStepAddCta;

  /// No description provided for @homeStepBudgetTitle.
  ///
  /// In ar, this message translates to:
  /// **'حدّد ميزانية الشهر'**
  String get homeStepBudgetTitle;

  /// No description provided for @homeStepBudgetBody.
  ///
  /// In ar, this message translates to:
  /// **'لتعرف كم يتاح لك كل يوم'**
  String get homeStepBudgetBody;

  /// No description provided for @homeStepBudgetCta.
  ///
  /// In ar, this message translates to:
  /// **'حدّد الميزانية'**
  String get homeStepBudgetCta;

  /// No description provided for @homeStepCaptureTitle.
  ///
  /// In ar, this message translates to:
  /// **'فعّل التقاط رسائل البنك'**
  String get homeStepCaptureTitle;

  /// No description provided for @homeStepCaptureBody.
  ///
  /// In ar, this message translates to:
  /// **'لتُضاف العمليات بدون لصق'**
  String get homeStepCaptureBody;

  /// No description provided for @homeStepCaptureCta.
  ///
  /// In ar, this message translates to:
  /// **'طريقة التفعيل'**
  String get homeStepCaptureCta;

  /// No description provided for @homeOnDeviceTitle.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك محفوظة على جهازك'**
  String get homeOnDeviceTitle;

  /// No description provided for @homeOnDeviceBody.
  ///
  /// In ar, this message translates to:
  /// **'قاعدة بياناتك مشفّرة على هذا الجهاز.'**
  String get homeOnDeviceBody;

  /// No description provided for @homeCreateYourself.
  ///
  /// In ar, this message translates to:
  /// **'أو أنشئ بنفسك'**
  String get homeCreateYourself;

  /// No description provided for @homeTileBudgetSub.
  ///
  /// In ar, this message translates to:
  /// **'شهرية أو لتصنيف'**
  String get homeTileBudgetSub;

  /// No description provided for @homeTileGoal.
  ///
  /// In ar, this message translates to:
  /// **'هدف ادخار'**
  String get homeTileGoal;

  /// No description provided for @homeTileGoalSub.
  ///
  /// In ar, this message translates to:
  /// **'سفر، سيارة، طوارئ'**
  String get homeTileGoalSub;

  /// No description provided for @homeTileBill.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك أو قسط'**
  String get homeTileBill;

  /// No description provided for @homeTileBillSub.
  ///
  /// In ar, this message translates to:
  /// **'ونذكّرك قبل الخصم'**
  String get homeTileBillSub;

  /// No description provided for @homeTilePlan.
  ///
  /// In ar, this message translates to:
  /// **'خطة'**
  String get homeTilePlan;

  /// No description provided for @homeTilePlanSub.
  ///
  /// In ar, this message translates to:
  /// **'للسفر أو المناسبات'**
  String get homeTilePlanSub;

  /// No description provided for @homePrivacyToggle.
  ///
  /// In ar, this message translates to:
  /// **'إظهار المبالغ أو إخفاؤها'**
  String get homePrivacyToggle;

  /// No description provided for @accTotalBalance.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الأرصدة'**
  String get accTotalBalance;

  /// No description provided for @achBadges.
  ///
  /// In ar, this message translates to:
  /// **'الشارات'**
  String get achBadges;

  /// No description provided for @achEarnedCount.
  ///
  /// In ar, this message translates to:
  /// **'{earned} من {total} مكتملة'**
  String achEarnedCount(int earned, int total);

  /// No description provided for @achNextLevelXp.
  ///
  /// In ar, this message translates to:
  /// **'باقي {remaining} للمستوى التالي'**
  String achNextLevelXp(int remaining);

  /// No description provided for @gdSavedLabel.
  ///
  /// In ar, this message translates to:
  /// **'ادّخرت'**
  String get gdSavedLabel;

  /// No description provided for @homeSavingsGrowing.
  ///
  /// In ar, this message translates to:
  /// **'نمو مدخراتك'**
  String get homeSavingsGrowing;

  /// No description provided for @homeSavingsSurplus.
  ///
  /// In ar, this message translates to:
  /// **'دخلك سبق صرفك بـ {amount} هذا الشهر'**
  String homeSavingsSurplus(String amount);

  /// No description provided for @homeSavingsMotivation.
  ///
  /// In ar, this message translates to:
  /// **'حوّل جزء منه لأهدافك وخلّيه يكبر.'**
  String get homeSavingsMotivation;

  /// No description provided for @homeAddToGoal.
  ///
  /// In ar, this message translates to:
  /// **'أضف لهدف'**
  String get homeAddToGoal;

  /// No description provided for @rptPhotoKicker.
  ///
  /// In ar, this message translates to:
  /// **'صورة أوضح لأموالك'**
  String get rptPhotoKicker;

  /// No description provided for @rptPhotoTitle.
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل صرفك في مكان واحد'**
  String get rptPhotoTitle;

  /// No description provided for @homeSpendingAhead.
  ///
  /// In ar, this message translates to:
  /// **'صرفك سبق دخلك بـ {amount} هذا الشهر'**
  String homeSpendingAhead(String amount);

  /// No description provided for @goalCoverLabel.
  ///
  /// In ar, this message translates to:
  /// **'صورة الهدف'**
  String get goalCoverLabel;

  /// No description provided for @goalCoverTravel.
  ///
  /// In ar, this message translates to:
  /// **'سفر'**
  String get goalCoverTravel;

  /// No description provided for @goalCoverCar.
  ///
  /// In ar, this message translates to:
  /// **'عربية'**
  String get goalCoverCar;

  /// No description provided for @goalCoverHome.
  ///
  /// In ar, this message translates to:
  /// **'بيت'**
  String get goalCoverHome;

  /// No description provided for @goalCoverEducation.
  ///
  /// In ar, this message translates to:
  /// **'تعليم'**
  String get goalCoverEducation;

  /// No description provided for @goalCoverGadgets.
  ///
  /// In ar, this message translates to:
  /// **'أجهزة'**
  String get goalCoverGadgets;

  /// No description provided for @goalCoverEmergency.
  ///
  /// In ar, this message translates to:
  /// **'طوارئ'**
  String get goalCoverEmergency;

  /// No description provided for @bdgOverviewSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'حدودك وأهدافك في مكان واحد'**
  String get bdgOverviewSubtitle;

  /// No description provided for @rptExpenseCountLabel.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الصرف'**
  String get rptExpenseCountLabel;

  /// No description provided for @rptDailySpending.
  ///
  /// In ar, this message translates to:
  /// **'الصرف اليومي'**
  String get rptDailySpending;

  /// No description provided for @dtxExportSection.
  ///
  /// In ar, this message translates to:
  /// **'تصدير'**
  String get dtxExportSection;

  /// No description provided for @dtxImportSection.
  ///
  /// In ar, this message translates to:
  /// **'استيراد'**
  String get dtxImportSection;

  /// No description provided for @dtxPdfReport.
  ///
  /// In ar, this message translates to:
  /// **'تقرير مالي PDF'**
  String get dtxPdfReport;

  /// No description provided for @dtxPdfReportSub.
  ///
  /// In ar, this message translates to:
  /// **'ملخص مصمم للمشاركة'**
  String get dtxPdfReportSub;

  /// No description provided for @captureAutomaticTitle.
  ///
  /// In ar, this message translates to:
  /// **'الالتقاط التلقائي'**
  String get captureAutomaticTitle;

  /// No description provided for @captureAutomaticBody.
  ///
  /// In ar, this message translates to:
  /// **'إعداد اختصار آبل أو التقاط رسائل البنك'**
  String get captureAutomaticBody;

  /// No description provided for @homeHeroIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل'**
  String get homeHeroIncome;

  /// No description provided for @homeHeroSpent.
  ///
  /// In ar, this message translates to:
  /// **'مصروف'**
  String get homeHeroSpent;

  /// No description provided for @homeHeroNet.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get homeHeroNet;

  /// No description provided for @homePaceUsed.
  ///
  /// In ar, this message translates to:
  /// **'استخدمت {percent}%'**
  String homePaceUsed(int percent);

  /// No description provided for @homePaceExpected.
  ///
  /// In ar, this message translates to:
  /// **'المتوقع حتى الآن {percent}%'**
  String homePaceExpected(int percent);

  /// No description provided for @introWelcomeTitle.
  ///
  /// In ar, this message translates to:
  /// **'فلوسك واضحة… من غير مجهود'**
  String get introWelcomeTitle;

  /// No description provided for @introWelcomeBody.
  ///
  /// In ar, this message translates to:
  /// **'قِرش يحوّل رسائل البنك لصورة واضحة لصرفك وميزانياتك وأهدافك.'**
  String get introWelcomeBody;

  /// No description provided for @introCaptureTitle.
  ///
  /// In ar, this message translates to:
  /// **'عملياتك من رسائل البنك'**
  String get introCaptureTitle;

  /// No description provided for @introCaptureBody.
  ///
  /// In ar, this message translates to:
  /// **'اختصار آبل يرسل رسالة البنك لقِرش. تُقرأ على جهازك، وتراجع النتيجة قبل حفظها.'**
  String get introCaptureBody;

  /// No description provided for @introBudgetTitle.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية تنبهك قبل التجاوز'**
  String get introBudgetTitle;

  /// No description provided for @introBudgetBody.
  ///
  /// In ar, this message translates to:
  /// **'شوف وتيرة صرفك يوم بيوم، واعرف إمتى تهدّي.'**
  String get introBudgetBody;

  /// No description provided for @introPrivacyTitle.
  ///
  /// In ar, this message translates to:
  /// **'خصوصيتك قبل أي حاجة'**
  String get introPrivacyTitle;

  /// No description provided for @introPrivacyBody.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك مشفّرة على جهازك. المعالجة السحابية اختيارية، وتتحكم فيها من الإعدادات.'**
  String get introPrivacyBody;

  /// No description provided for @introPageSemantic.
  ///
  /// In ar, this message translates to:
  /// **'الصفحة {page} من {total}'**
  String introPageSemantic(int page, int total);

  /// No description provided for @introPrivacyLocalBody.
  ///
  /// In ar, this message translates to:
  /// **'تُحفظ سجلاتك مشفّرة على هذا الجهاز.'**
  String get introPrivacyLocalBody;

  /// No description provided for @introPrivacyCloudBody.
  ///
  /// In ar, this message translates to:
  /// **'اختياري. اختر تفعيله أثناء الإعداد أو لاحقًا من الإعدادات.'**
  String get introPrivacyCloudBody;

  /// No description provided for @annPreferencesTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر الإشعارات التي تهمك'**
  String get annPreferencesTitle;

  /// No description provided for @annPreferencesAction.
  ///
  /// In ar, this message translates to:
  /// **'إعدادات الإشعارات'**
  String get annPreferencesAction;

  /// No description provided for @couponsAvailableLabel.
  ///
  /// In ar, this message translates to:
  /// **'العروض المتاحة'**
  String get couponsAvailableLabel;

  /// No description provided for @setCategoryIconName.
  ///
  /// In ar, this message translates to:
  /// **'{icon, select, restaurants{مطاعم} groceries{بقالة} shopping{تسوق} transport{مواصلات} bills{فواتير} cards{بطاقات} cash{نقود} cafes{مقاهٍ} gifts{هدايا} home{منزل} travel{سفر} health{صحة} education{تعليم} transfers{تحويلات} other{أيقونة أخرى}}'**
  String setCategoryIconName(String icon);

  /// No description provided for @setCategoryColourName.
  ///
  /// In ar, this message translates to:
  /// **'{colour, select, grey{رمادي} coral{مرجاني} green{أخضر} blue{أزرق} purple{بنفسجي} brightGreen{أخضر زاهٍ} teal{أخضر مزرق} pink{وردي} blueGrey{رمادي مزرق} orange{برتقالي} other{لون مخصص}}'**
  String setCategoryColourName(String colour);

  /// No description provided for @rptPreviousPeriod.
  ///
  /// In ar, this message translates to:
  /// **'الفترة السابقة'**
  String get rptPreviousPeriod;

  /// No description provided for @cloudResumeTitle.
  ///
  /// In ar, this message translates to:
  /// **'شغّل الخدمات السحابية من جديد'**
  String get cloudResumeTitle;

  /// No description provided for @cloudResumeBody.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة والتحليل الذكي متوقفان بعد تسجيل الخروج. فعّلهما من جديد لاستئناف الخدمة.'**
  String get cloudResumeBody;

  /// No description provided for @languageFirstTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر لغتك'**
  String get languageFirstTitle;

  /// No description provided for @languageFirstBody.
  ///
  /// In ar, this message translates to:
  /// **'اختار اللغة اللي تحب تستخدم بيها قِرش. تقدر تغيّرها بعدين.'**
  String get languageFirstBody;

  /// No description provided for @coachPasteTitle.
  ///
  /// In ar, this message translates to:
  /// **'اقرأ رسالة البنك'**
  String get coachPasteTitle;

  /// No description provided for @coachPasteBody.
  ///
  /// In ar, this message translates to:
  /// **'الصق رسالة البنك هنا، أو اختر «لصق رسالة» من قائمة الإضافة لكي يحلّلها قرش.'**
  String get coachPasteBody;

  /// No description provided for @coachAccountTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختار الحساب'**
  String get coachAccountTitle;

  /// No description provided for @coachAccountBody.
  ///
  /// In ar, this message translates to:
  /// **'من هنا اختار الحساب اللي تحب تتابعه. الأرقام والعملة بتتغيّر حسب اختيارك.'**
  String get coachAccountBody;

  /// No description provided for @coachBudgetTitle.
  ///
  /// In ar, this message translates to:
  /// **'حدّد أول ميزانية'**
  String get coachBudgetTitle;

  /// No description provided for @coachBudgetBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط + وحدّد مبلغ الميزانية والفترة والحساب. تقدر تعدّلها في أي وقت.'**
  String get coachBudgetBody;

  /// No description provided for @coachBillsTitle.
  ///
  /// In ar, this message translates to:
  /// **'تابع مدفوعاتك'**
  String get coachBillsTitle;

  /// No description provided for @coachBillsBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط + لإضافة اشتراك أو قسط، وحدّد المبلغ وموعد الدفع. ثم سجّل الدفعات من صفحة التفاصيل.'**
  String get coachBillsBody;

  /// No description provided for @pasteSavedForAnalysis.
  ///
  /// In ar, this message translates to:
  /// **'الرسالة محفوظة في الوارد الذكي وبانتظار التحليل.'**
  String get pasteSavedForAnalysis;

  /// No description provided for @retryBankAnalysis.
  ///
  /// In ar, this message translates to:
  /// **'أعد التحليل بالذكاء الاصطناعي'**
  String get retryBankAnalysis;

  /// No description provided for @onboardingAccountCheckFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحقق من إعداد حسابك. تحقّق من اتصالك ثم أعد المحاولة.'**
  String get onboardingAccountCheckFailed;

  /// No description provided for @shortcutVisualInstallTitle.
  ///
  /// In ar, this message translates to:
  /// **'أضف اختصار قرش'**
  String get shortcutVisualInstallTitle;

  /// No description provided for @shortcutVisualInstallBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط «إضافة اختصار قرش»، ثم Add Shortcut في iOS. احتفظ باسم القالب الجديد QIRSH ليتمكّن اختبار الاتصال من فتحه.'**
  String get shortcutVisualInstallBody;

  /// No description provided for @shortcutVisualFilterTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختار الرسائل البنكية المطلوبة'**
  String get shortcutVisualFilterTitle;

  /// No description provided for @shortcutVisualFilterBody.
  ///
  /// In ar, this message translates to:
  /// **'القالب المشترك بيبدأ بـ EGP. اضبط Message contains على {currencyCode}؛ لو هي نفس الكلمة سيبها زي ما هي. سيب Shortcut Input وSender في Process.'**
  String shortcutVisualFilterBody(String currencyCode);

  /// No description provided for @shortcutVisualAutomationTitle.
  ///
  /// In ar, this message translates to:
  /// **'فعّل الالتقاط التلقائي'**
  String get shortcutVisualAutomationTitle;

  /// No description provided for @shortcutVisualAutomationBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط السهم جنب When I receive a message. شغّل Automation واقفل Confirm Before Run، ثم احفظ.\n\nلو إصدار iOS عندك بيعرض Run Immediately اختاره.'**
  String get shortcutVisualAutomationBody;

  /// No description provided for @shortcutVisualTestTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختبر الاتصال بقرش'**
  String get shortcutVisualTestTitle;

  /// No description provided for @shortcutVisualTestBody.
  ///
  /// In ar, this message translates to:
  /// **'اختبار الاتصال بيشغّل QIRSH من غير إضافة معاملة. نجاحه بيأكد الاتصال.\n\nوللتأكد من الالتقاط التلقائي، استقبل رسالة بنكية تطابق الفلتر اللي اخترته.'**
  String get shortcutVisualTestBody;

  /// No description provided for @shortcutVisualImageCaption.
  ///
  /// In ar, this message translates to:
  /// **'مرجع من iOS · اضغط للتكبير. اسم الاختصار المستخدم في الاختبار QIRSH.'**
  String get shortcutVisualImageCaption;

  /// No description provided for @shortcutVisualEnlarge.
  ///
  /// In ar, this message translates to:
  /// **'تكبير صورة إعداد الاختصار في iOS'**
  String get shortcutVisualEnlarge;

  /// No description provided for @shortcutVisualReviewed.
  ///
  /// In ar, this message translates to:
  /// **'راجعت الخطوات. يتطلّب الالتقاط التلقائي تفعيل Automation داخل الاختصارات.'**
  String get shortcutVisualReviewed;

  /// No description provided for @shortcutCatalogTitle.
  ///
  /// In ar, this message translates to:
  /// **'رسائل البنك'**
  String get shortcutCatalogTitle;

  /// No description provided for @shortcutCatalogBody.
  ///
  /// In ar, this message translates to:
  /// **'اختار الكلمة اللي بنكك بيستخدمها، وهنظبط معاك الفلتر والالتقاط التلقائي خطوة بخطوة.'**
  String get shortcutCatalogBody;

  /// No description provided for @shortcutCatalogSearch.
  ///
  /// In ar, this message translates to:
  /// **'كلمة أو عملة'**
  String get shortcutCatalogSearch;

  /// No description provided for @shortcutCatalogOther.
  ///
  /// In ar, this message translates to:
  /// **'كلمات وعملات أخرى'**
  String get shortcutCatalogOther;

  /// No description provided for @shortcutCatalogKeyword.
  ///
  /// In ar, this message translates to:
  /// **'رسائل فيها «{keyword}»'**
  String shortcutCatalogKeyword(String keyword);

  /// No description provided for @shortcutCatalogExample.
  ///
  /// In ar, this message translates to:
  /// **'تم خصم {keyword} 450.00 عند Talabat.'**
  String shortcutCatalogExample(String keyword);

  /// No description provided for @shortcutCatalogSetUp.
  ///
  /// In ar, this message translates to:
  /// **'إعداد'**
  String get shortcutCatalogSetUp;

  /// No description provided for @shortcutCatalogReviewed.
  ///
  /// In ar, this message translates to:
  /// **'راجعت الخطوات'**
  String get shortcutCatalogReviewed;

  /// No description provided for @shortcutCatalogNoMatches.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نتائج. جرّب رمز عملة مثل EGP أو USD.'**
  String get shortcutCatalogNoMatches;

  /// No description provided for @shortcutCatalogSingleTemplate.
  ///
  /// In ar, this message translates to:
  /// **'كل الاختيارات بتستخدم قالب QIRSH نفسه. هتغيّر الفلتر الحالي داخل الاختصارات. مراجعة الخطوات مش تأكيد إن Automation اتفعّل في iOS.'**
  String get shortcutCatalogSingleTemplate;

  /// No description provided for @shortcutVisualInstallDedicatedBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط «إضافة اختصار قرش»، ثم Add Shortcut في iOS. هذا الاختصار مُعدّ مسبقًا لالتقاط الرسائل التي تحتوي على {keyword}، فلا حاجة إلى كتابة أي شيء.'**
  String shortcutVisualInstallDedicatedBody(String keyword);

  /// No description provided for @shortcutCatalogDedicated.
  ///
  /// In ar, this message translates to:
  /// **'الكلمة {keyword} لها اختصار جاهز أُضيفت فيه مسبقًا. ما زال iOS يطلب منك تفعيل Automation بنفسك، ولا يستطيع قرش معرفة ما إذا كانت مفعّلة.'**
  String shortcutCatalogDedicated(String keyword);

  /// No description provided for @shortcutConfirmAutomation.
  ///
  /// In ar, this message translates to:
  /// **'فعّلتُ Automation'**
  String get shortcutConfirmAutomation;

  /// No description provided for @shortcutStateConfirmed.
  ///
  /// In ar, this message translates to:
  /// **'أكّدتَ أن Automation مفعّلة. لا يستطيع قرش التحقق من ذلك داخل iOS.'**
  String get shortcutStateConfirmed;

  /// No description provided for @shortcutStateTested.
  ///
  /// In ar, this message translates to:
  /// **'تم اختبار الاتصال. فعّل Automation لالتقاط الرسائل تلقائيًا.'**
  String get shortcutStateTested;

  /// No description provided for @shortcutOverlapWarning.
  ///
  /// In ar, this message translates to:
  /// **'سبق أن أعددت {keyword} لهذه العملة. استخدم كلمة واحدة لكل عملة حتى لا تُلتقط الرسالة نفسها مرتين.'**
  String shortcutOverlapWarning(String keyword);

  /// No description provided for @shortcutOpenEditor.
  ///
  /// In ar, this message translates to:
  /// **'افتح {name} في الاختصارات'**
  String shortcutOpenEditor(String name);

  /// No description provided for @shortcutVisualArrowTitle.
  ///
  /// In ar, this message translates to:
  /// **'افتح إعدادات التشغيل التلقائي'**
  String get shortcutVisualArrowTitle;

  /// No description provided for @shortcutVisualArrowBody.
  ///
  /// In ar, this message translates to:
  /// **'افتح {name} في الاختصارات. اضغط السهم الأزرق الصغير جنب where تحت When I receive a message.'**
  String shortcutVisualArrowBody(String name);

  /// No description provided for @shortcutVisualStep.
  ///
  /// In ar, this message translates to:
  /// **'الخطوة {current} من {total}'**
  String shortcutVisualStep(int current, int total);

  /// No description provided for @shortcutStudioTitle.
  ///
  /// In ar, this message translates to:
  /// **'رسائلك مع قرش'**
  String get shortcutStudioTitle;

  /// No description provided for @shortcutStudioBody.
  ///
  /// In ar, this message translates to:
  /// **'وصلة بسيطة بين رسائل بنكك وقرش. اختار الفلتر، جهّز الربط، وبعدها اختبره.'**
  String get shortcutStudioBody;

  /// No description provided for @shortcutRouteMessage.
  ///
  /// In ar, this message translates to:
  /// **'رسالة'**
  String get shortcutRouteMessage;

  /// No description provided for @shortcutRouteAutomation.
  ///
  /// In ar, this message translates to:
  /// **'اختصار'**
  String get shortcutRouteAutomation;

  /// No description provided for @shortcutStudioCurrency.
  ///
  /// In ar, this message translates to:
  /// **'١ · عملة الرسائل'**
  String get shortcutStudioCurrency;

  /// No description provided for @shortcutStudioWord.
  ///
  /// In ar, this message translates to:
  /// **'٢ · الكلمة المطلوبة'**
  String get shortcutStudioWord;

  /// No description provided for @shortcutStudioPreview.
  ///
  /// In ar, this message translates to:
  /// **'فلتر الالتقاط الخاص بك'**
  String get shortcutStudioPreview;

  /// No description provided for @shortcutStudioBegin.
  ///
  /// In ar, this message translates to:
  /// **'ربط رسائل «{keyword}»'**
  String shortcutStudioBegin(String keyword);

  /// No description provided for @authEmailExplanation.
  ///
  /// In ar, this message translates to:
  /// **'أدخل البريد المرتبط بحساب قرش لاستلام رمز دخول يُستخدم مرة واحدة.'**
  String get authEmailExplanation;

  /// No description provided for @authEmailLinkExplanation.
  ///
  /// In ar, this message translates to:
  /// **'أضف بريدًا لحسابك الحالي. عملياتك وإعداداتك هتفضل في نفس الحساب. تغيير البريد بيتطلب تأكيد البريد الحالي والجديد.'**
  String get authEmailLinkExplanation;

  /// No description provided for @authInvalidEmail.
  ///
  /// In ar, this message translates to:
  /// **'اكتب بريدًا إلكترونيًا صحيحًا.'**
  String get authInvalidEmail;

  /// No description provided for @authCodeSendFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الكود. تأكد من اتصالك وحاول تاني بعد دقيقة.'**
  String get authCodeSendFailed;

  /// No description provided for @authCodeVerifyFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تأكيد الكود. راجعه وحاول تاني.'**
  String get authCodeVerifyFailed;

  /// No description provided for @authResendCode.
  ///
  /// In ar, this message translates to:
  /// **'إرسال الكود مرة تانية'**
  String get authResendCode;

  /// No description provided for @authChangeEmail.
  ///
  /// In ar, this message translates to:
  /// **'استخدام بريد آخر'**
  String get authChangeEmail;

  /// No description provided for @authConfirmBothEmails.
  ///
  /// In ar, this message translates to:
  /// **'تم تأكيد البريد الجديد. أدخل الرمز المُرسل إلى بريدك الحالي للمتابعة.'**
  String get authConfirmBothEmails;

  /// No description provided for @authCurrentEmailCode.
  ///
  /// In ar, this message translates to:
  /// **'كود البريد الحالي'**
  String get authCurrentEmailCode;

  /// No description provided for @authSignInMethods.
  ///
  /// In ar, this message translates to:
  /// **'طرق تسجيل الدخول'**
  String get authSignInMethods;

  /// No description provided for @authSignInMethodsDescription.
  ///
  /// In ar, this message translates to:
  /// **'أضف طريقة دخول لنفس الحساب، واحتفظ بكل بياناتك مع بعض.'**
  String get authSignInMethodsDescription;

  /// No description provided for @authLinked.
  ///
  /// In ar, this message translates to:
  /// **'مرتبط'**
  String get authLinked;

  /// No description provided for @authLinkGoogle.
  ///
  /// In ar, this message translates to:
  /// **'ربط حساب Google'**
  String get authLinkGoogle;

  /// No description provided for @authLinkEmail.
  ///
  /// In ar, this message translates to:
  /// **'ربط البريد الإلكتروني'**
  String get authLinkEmail;

  /// No description provided for @authLinkSuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم ربط طريقة الدخول بحسابك.'**
  String get authLinkSuccess;

  /// No description provided for @authLinkFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر ربط طريقة الدخول. لو مرتبطة بحساب قرش تاني، استخدم غيرها.'**
  String get authLinkFailed;

  /// No description provided for @authExistingAccountHint.
  ///
  /// In ar, this message translates to:
  /// **'تستخدم Apple؟ سجّل الدخول به أولًا لربط طريقة دخول جديدة.'**
  String get authExistingAccountHint;

  /// No description provided for @authCreateAccount.
  ///
  /// In ar, this message translates to:
  /// **'إنشاء حساب'**
  String get authCreateAccount;

  /// No description provided for @authBackToSignIn.
  ///
  /// In ar, this message translates to:
  /// **'عندك حساب بالفعل؟ سجّل الدخول'**
  String get authBackToSignIn;

  /// No description provided for @authCreateAccountSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اختار طريقة الدخول لحساب قرش الجديد.'**
  String get authCreateAccountSubtitle;

  /// No description provided for @authCreateEmailExplanation.
  ///
  /// In ar, this message translates to:
  /// **'اكتب بريدك الإلكتروني وأكّد الكود لإكمال إنشاء حساب قرش.'**
  String get authCreateEmailExplanation;

  /// No description provided for @deleteAccountEmailProofTitle.
  ///
  /// In ar, this message translates to:
  /// **'كود تأكيد البريد'**
  String get deleteAccountEmailProofTitle;

  /// No description provided for @deleteAccountEmailProofBody.
  ///
  /// In ar, this message translates to:
  /// **'بعتنا كود لمرة واحدة على البريد المؤكّد لحساب قرش ده. أدخل الكود لتأكيد الحذف.'**
  String get deleteAccountEmailProofBody;

  /// No description provided for @authGoogleSignupRequired.
  ///
  /// In ar, this message translates to:
  /// **'حساب Google هذا جديد على قرش. اختر «إنشاء حساب» للتسجيل.'**
  String get authGoogleSignupRequired;

  /// No description provided for @accV2Balance.
  ///
  /// In ar, this message translates to:
  /// **'الرصيد'**
  String get accV2Balance;

  /// No description provided for @accV2YourAccounts.
  ///
  /// In ar, this message translates to:
  /// **'حساباتك'**
  String get accV2YourAccounts;

  /// No description provided for @subsV2Upcoming.
  ///
  /// In ar, this message translates to:
  /// **'قادمة'**
  String get subsV2Upcoming;

  /// No description provided for @subsV2AllSubs.
  ///
  /// In ar, this message translates to:
  /// **'كل الاشتراكات'**
  String get subsV2AllSubs;

  /// No description provided for @gfV2Preview.
  ///
  /// In ar, this message translates to:
  /// **'معاينة'**
  String get gfV2Preview;

  /// No description provided for @gdV2DaysCount.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{يوم واحد} =2{يومان} few{{days} أيام} many{{days} يومًا} other{{days} يوم}}'**
  String gdV2DaysCount(int days);

  /// No description provided for @gdV2MoreActions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات الهدف'**
  String get gdV2MoreActions;

  /// No description provided for @setV2Tools.
  ///
  /// In ar, this message translates to:
  /// **'أدوات'**
  String get setV2Tools;

  /// No description provided for @setV2Version.
  ///
  /// In ar, this message translates to:
  /// **'قِرش {version}'**
  String setV2Version(String version);

  /// No description provided for @setV2AppearanceLead.
  ///
  /// In ar, this message translates to:
  /// **'اختار شكل قِرش — بيتغير فورًا.'**
  String get setV2AppearanceLead;

  /// No description provided for @setV2CaptureNeedsCheck.
  ///
  /// In ar, this message translates to:
  /// **'يحتاج مراجعة'**
  String get setV2CaptureNeedsCheck;

  /// No description provided for @bdgV2YourBudgets.
  ///
  /// In ar, this message translates to:
  /// **'ميزانياتك'**
  String get bdgV2YourBudgets;

  /// No description provided for @bdgV2WorstFirst.
  ///
  /// In ar, this message translates to:
  /// **'الأسوأ أولًا'**
  String get bdgV2WorstFirst;

  /// No description provided for @bfsV2ShowAll.
  ///
  /// In ar, this message translates to:
  /// **'عرض الكل'**
  String get bfsV2ShowAll;

  /// No description provided for @bfsV2ShowLess.
  ///
  /// In ar, this message translates to:
  /// **'عرض أقل'**
  String get bfsV2ShowLess;

  /// No description provided for @couponsV2BrowseOffers.
  ///
  /// In ar, this message translates to:
  /// **'تصفّح العروض'**
  String get couponsV2BrowseOffers;

  /// No description provided for @txnV2EndOfList.
  ///
  /// In ar, this message translates to:
  /// **'— دي كل عمليات الفترة —'**
  String get txnV2EndOfList;

  /// No description provided for @txnV2Filters.
  ///
  /// In ar, this message translates to:
  /// **'الفلاتر'**
  String get txnV2Filters;

  /// No description provided for @pasteV2DetectedCount.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{رسالة واحدة مكتشفة} =2{رسالتين مكتشفتين} few{{count} رسائل مكتشفة} many{{count} رسالة مكتشفة} other{{count} رسالة مكتشفة}}'**
  String pasteV2DetectedCount(int count);

  /// No description provided for @pasteV2Clear.
  ///
  /// In ar, this message translates to:
  /// **'مسح النص'**
  String get pasteV2Clear;

  /// No description provided for @smsV2Step1.
  ///
  /// In ar, this message translates to:
  /// **'افتح رسالة البنك'**
  String get smsV2Step1;

  /// No description provided for @smsV2Step2.
  ///
  /// In ar, this message translates to:
  /// **'اضغط «مشاركة»'**
  String get smsV2Step2;

  /// No description provided for @smsV2Step3.
  ///
  /// In ar, this message translates to:
  /// **'اختر قِرش'**
  String get smsV2Step3;

  /// No description provided for @smsV2PrivacyLine.
  ///
  /// In ar, this message translates to:
  /// **'بدون إذن قراءة الرسائل · عند إيقاف التحليل الذكي نحلّل النص على جهازك فقط.'**
  String get smsV2PrivacyLine;

  /// No description provided for @insV3Report.
  ///
  /// In ar, this message translates to:
  /// **'تقرير'**
  String get insV3Report;

  /// No description provided for @txnV3NetThisMonth.
  ///
  /// In ar, this message translates to:
  /// **'صافي الشهر'**
  String get txnV3NetThisMonth;

  /// No description provided for @txnV3NetThisPeriod.
  ///
  /// In ar, this message translates to:
  /// **'صافي الفترة'**
  String get txnV3NetThisPeriod;

  /// No description provided for @billsV3Counts.
  ///
  /// In ar, this message translates to:
  /// **'{subs} اشتراك · {instalments} أقساط'**
  String billsV3Counts(int subs, int instalments);

  /// No description provided for @captureQueueNotSaved.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حفظ رسالة بنكية واحدة أو أكثر على هذا الجهاز. أعد مشاركتها أو أضف العملية يدوياً.'**
  String get captureQueueNotSaved;

  /// No description provided for @captureQueueReadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّرت قراءة الرسائل البنكية المحفوظة على هذا الجهاز. لم يُحذف شيء، وسنعيد المحاولة تلقائياً.'**
  String get captureQueueReadFailed;

  /// No description provided for @smsAutoCaptureRestoredNotice.
  ///
  /// In ar, this message translates to:
  /// **'تمت إعادة تشغيل الالتقاط التلقائي للرسائل لهذا الحساب.'**
  String get smsAutoCaptureRestoredNotice;
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppL10nAr();
    case 'en':
      return AppL10nEn();
  }

  throw FlutterError(
      'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
