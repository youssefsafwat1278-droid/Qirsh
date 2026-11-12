// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get shortcutAddReady => 'Add Qirsh shortcut';

  @override
  String get shortcutQuickHelp =>
      'Add the QIRSH template, review the bank-message filter, then enable its Message automation. On older iOS versions, create a Message automation that runs this shortcut with Shortcut Input.';

  @override
  String get shortcutTestConnection => 'Test connection';

  @override
  String get shortcutProbeWaiting =>
      'Run the shortcut, then return to Qirsh. This test does not add a transaction.';

  @override
  String get shortcutProbePassed =>
      'Connection verified. Automatic capture still needs the Message automation enabled.';

  @override
  String get shortcutOpenFailed =>
      'Couldn’t open Shortcuts. Make sure the Shortcuts app is installed and try again.';

  @override
  String get shortcutManualSteps => 'Detailed setup instructions';

  @override
  String get appTitle => 'Qirsh';

  @override
  String get setupHeaderTitle => 'Let\'s set up Qirsh';

  @override
  String get setupHeaderSubtitle => 'A few quick steps and you\'re ready.';

  @override
  String setupStepLabel(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get setupCountryTitle => 'Your country and currency';

  @override
  String get setupCountryBody =>
      'We\'ll use it as the base currency for your accounts.';

  @override
  String get setupNotificationsTitle => 'Turn on notifications';

  @override
  String get setupNotificationsBody =>
      'So every transaction reaches you the moment it happens.';

  @override
  String get setupNotificationsCta => 'Enable';

  @override
  String get setupCloudTitle => 'Smart processing';

  @override
  String get setupCloudBody =>
      'Qirsh processes bank messages you share through its server and AI to turn them into transactions and reports without storing your full numbers.';

  @override
  String get setupCloudCta => 'Continue';

  @override
  String get setupShortcutTitle => 'Install the Qirsh Shortcut';

  @override
  String get setupShortcutBody =>
      'It\'s what sends us your bank messages automatically.';

  @override
  String get setupShortcutStep1Title => 'Remove the old one';

  @override
  String get setupShortcutStep1Body =>
      'Open the Shortcuts app, go to the Automation tab, and delete any old automation for the app.';

  @override
  String get setupShortcutStep2Title => 'New (+)';

  @override
  String get setupShortcutStep2Body =>
      'Tap New Automation (+) and scroll down until you find \"Message\".';

  @override
  String get setupShortcutStep3Title => 'Filter messages';

  @override
  String setupShortcutStep3Body(String currency) {
    return 'Tap \"Message Contents\" and type your currency code, like $currency.';
  }

  @override
  String get setupShortcutStep4Title => 'No confirmation';

  @override
  String get setupShortcutStep4Body =>
      'Turn on \"Run Immediately\" and turn off \"Notify When Run\" if it appears, then Next.';

  @override
  String get setupShortcutStep5Title => 'Send to the app';

  @override
  String get setupShortcutStep5Body =>
      'Choose New Blank Automation, search for “Process Bank SMS”, and set SMS Text to Shortcut Input.';

  @override
  String get setupShortcutStep6Title => 'Save';

  @override
  String get setupShortcutStep6Body =>
      'Turn off \"Show When Run\" if it appears, and tap Save.';

  @override
  String get setupShortcutCta => 'Installed';

  @override
  String get setupFinishCta => 'Start';

  @override
  String get brandTagline => 'Your money, clearer. Your decisions, smarter.';

  @override
  String get brandContinueCta => 'Let\'s get started';

  @override
  String get authTitle => 'Sign in to Qirsh';

  @override
  String get authSubtitle => 'Choose how you’d like to sign in.';

  @override
  String get authTrustLocalEncryption => 'Local encryption';

  @override
  String get authTrustOnDevice => 'Encrypted on your device, synced securely';

  @override
  String get authTermsNotice =>
      'By continuing, you agree to the Terms of Service and Privacy Policy.';

  @override
  String get authAppleCta => 'Continue with Apple';

  @override
  String get authGoogleCta => 'Continue with Google';

  @override
  String get authSignInError => 'Couldn\'t sign in. Please try again.';

  @override
  String get authBackupFoundTitle => 'We found a backup for your account';

  @override
  String get authBackupFoundBody =>
      'Want to restore your data from the latest backup, or start fresh?';

  @override
  String get authBackupStartFresh => 'Start fresh';

  @override
  String get authBackupRestore => 'Restore it';

  @override
  String get storyPromiseTitle => 'Excited\nto start with you';

  @override
  String get storyPromiseSubtitle =>
      'We\'ll be your partner on your financial journey.';

  @override
  String get storyPromiseHighlight =>
      'At Qirsh, we believe financial stability starts with simple habits.';

  @override
  String get storyPromiseBody =>
      'We built an app that helps you manage your money with ease — from logging expenses and setting budgets, to subscription alerts and smart reports.';

  @override
  String get storyPromiseSectionTitle => 'Our goal?';

  @override
  String get storyPromiseSectionBody =>
      'To help you know where your money goes, save more, and live with greater ease.';

  @override
  String get storyPromiseClosing =>
      'Qirsh...\nYour partner on your financial journey.';

  @override
  String get storySpendingTitle => 'Small expenses add up';

  @override
  String get storySpendingBody =>
      'Daily expenses can seem small,\nbut over time they make a big difference.';

  @override
  String get storySpendingHighlight =>
      'What you don\'t track... is hard to control';

  @override
  String get storySpendingSupporting =>
      'Qirsh helps you see the full picture,\nand understand where your money goes.';

  @override
  String get storyContinueCta => 'Continue';

  @override
  String get storyStartCta => 'Start with Qirsh';

  @override
  String get storySkip => 'Skip';

  @override
  String get storyPageOneSemanticLabel => 'Page 1 of 2';

  @override
  String get storyPageTwoSemanticLabel => 'Page 2 of 2';

  @override
  String get next => 'Next';

  @override
  String get skip => 'Skip';

  @override
  String get registerAndStart => 'Register and Start';

  @override
  String get welcomeTitle => 'Your Daily Financial Companion';

  @override
  String get welcomeSubtitle => 'Your buddy with your money';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get welcomeDescription =>
      'Know where your money went, and save automatically in a smart and easy way.';

  @override
  String get secureOnDevice => 'Secure · On your device';

  @override
  String get effortless => 'Effortless';

  @override
  String get noTyping => 'No typing — we understand it for you';

  @override
  String get smsReadingDesc =>
      'Share a bank message with Qirsh; we extract amount and merchant on your device.';

  @override
  String get now => 'Now';

  @override
  String get snbSmsText => 'Mada purchase of ';

  @override
  String get snbSmsSuffix => ' at Half Million.';

  @override
  String get alrajhi => 'Al Rajhi';

  @override
  String get oneMinuteAgo => '1 minute ago';

  @override
  String get alrajhiSmsText => 'Debited ';

  @override
  String get alrajhiSmsSuffix => ' at Hamburgini restaurant.';

  @override
  String get localProcessing => 'Fully local processing';

  @override
  String get privacyFirst => 'Privacy first';

  @override
  String get howItWorks => 'How it works?';

  @override
  String get smsToTx => 'From bank message to a clear transaction';

  @override
  String get howItWorksDesc =>
      'Qirsh captures the meaning of the message and converts it into a category, amount, and merchant without manual entry.';

  @override
  String get howItWorksNote1 =>
      'No need to select your bank — Qirsh recognizes it from the message text.';

  @override
  String get howItWorksNote2 =>
      'If a new card appears, Qirsh adds it automatically from the last 4 digits.';

  @override
  String get howItWorksNote3 =>
      'You can review and edit any transaction or card inside the app.';

  @override
  String get messageFromBank => 'Message from bank';

  @override
  String get burgerBoutiqueSms => 'Purchase 45 SAR at BURGER BOUTIQUE';

  @override
  String get burgerBoutiqueSub => 'Restaurants · Now · Mada';

  @override
  String get burgerBoutiqueAmount => '-45 SAR';

  @override
  String get financialMotivation => 'Financial motivation';

  @override
  String get saveLikeGame => 'Save like a daily game';

  @override
  String get saveLikeGameDesc =>
      'Set your financial goals and save the differences day after day with a smart encouraging style.';

  @override
  String get totalSavings => 'Total accumulated savings';

  @override
  String get sar => 'SAR';

  @override
  String get travelVault => 'Travel Vault';

  @override
  String get completedPercent => '75% completed';

  @override
  String get goalLimit => 'Goal: 15,000 SAR';

  @override
  String get remainingAmount => 'Remaining: 3,750 SAR';

  @override
  String get easyToUse => 'Easy to use';

  @override
  String get selectCountryCurrency => 'Select your country and currency';

  @override
  String get selectCountryDesc =>
      'We display official flags, set the base currency, and you can add secondary currencies for external cards or subscriptions.';

  @override
  String get mainCountryCurrency => 'Country and Base Currency';

  @override
  String get additionalCurrencies => 'Additional Currencies';

  @override
  String get activeSubscriptions => 'Active Subscriptions';

  @override
  String get none => 'None';

  @override
  String get noActiveSubs => 'No active subscriptions';

  @override
  String get selectCountryTitle => 'Choose your country and base currency';

  @override
  String get searchCountryPlaceholder => 'Search for country or currency...';

  @override
  String get additionalCurrenciesTitle => 'Additional Currencies';

  @override
  String get additionalCurrenciesDesc =>
      'Optional, select currencies you deal with beside your base currency.';

  @override
  String get expectedSubscriptions => 'Expected Subscriptions';

  @override
  String get expectedSubscriptionsDesc =>
      'Select your active subscriptions and we will recognize them automatically.';

  @override
  String get completePrivacy => 'Complete Privacy';

  @override
  String get dataStaysOnDevice => 'Your data stays on your device';

  @override
  String get privacyPrinciples =>
      'Our security and privacy principles mean you are the sole controller of your financial data.';

  @override
  String get privacyRule1 =>
      'Qirsh processes bank messages you share through its server and AI';

  @override
  String get privacyRule2 =>
      'We only process bank messages you share or paste yourself';

  @override
  String get privacyRule3 =>
      'We never sell your data, and you have full freedom to delete it';

  @override
  String get enableAutoTracking => 'Share bank messages with Qirsh';

  @override
  String get setupAppleShortcut => 'Setup Apple Shortcut';

  @override
  String get autoTrackingSubtitleAndroid =>
      'From Messages, share a bank SMS to Qirsh. We parse it on your device and add the transaction.';

  @override
  String get autoTrackingSubtitleIos =>
      'Follow the steps once, and your iPhone will forward bank messages to Qirsh securely.';

  @override
  String get smsActivationSnack =>
      'You can share a bank SMS with Qirsh or paste it manually.';

  @override
  String get howWillActivationWork => 'How will it work?';

  @override
  String get allowSmsReading => 'Got it';

  @override
  String get gotIt => 'Got it';

  @override
  String get laterAddManually => 'Later, I will add manually';

  @override
  String get shortcutSetupGuide => 'Shortcut Setup Guide';

  @override
  String get doStepsOnceFromShortcuts =>
      'Perform these steps once from Apple Shortcuts app.';

  @override
  String get signInToStart => 'Sign In to Start';

  @override
  String get signInSubtitle =>
      'Sign in only to identify you and sync your settings. Your financial data stays secure on your device.';

  @override
  String get noPassword => 'No Password';

  @override
  String get continueWithApple => 'Continue with Apple';

  @override
  String get continueWithGoogle => 'Continue with Google';

  @override
  String get or => 'Or';

  @override
  String get continueWithEmail => 'Continue with Email';

  @override
  String get email => 'Email';

  @override
  String get sendOtpCode => 'Send Secure Login Code';

  @override
  String get byContinuingAgree =>
      'By continuing, you agree to Qirsh\'s Terms of Service and Privacy Policy.';

  @override
  String get enterOtpCode => 'Enter Verification Code';

  @override
  String get otpSentTo => 'Enter the code sent to this email. Check Spam too.';

  @override
  String get verifyCode => 'Verify Code';

  @override
  String get demoOtpCode => 'For testing: use code 123456';

  @override
  String get invalidOtpCode => 'Invalid Code';

  @override
  String get enterPasswordOrRecoveryCodeError =>
      'Type the backup password or recovery code.';

  @override
  String get recoveryCodeIncorrect =>
      'The recovery code is incorrect or doesn\'t match the backup.';

  @override
  String get backupPasswordIncorrect => 'The backup password is incorrect.';

  @override
  String get backupFound => 'We found a backup for your account';

  @override
  String get restoreDesc =>
      'Restoring your encrypted data happens on your device only. Your password never leaves your phone.';

  @override
  String get recoveryCodeLabel => 'Recovery Code';

  @override
  String get backupPasswordLabel => 'Backup Password';

  @override
  String get recoveryCodeHint => 'XXXX-XXXX-XXXX';

  @override
  String get backupPasswordHint => 'Enter the password you chose';

  @override
  String get useBackupPassword => 'Use Backup Password';

  @override
  String get useRecoveryCode => 'Use Recovery Code';

  @override
  String get restore => 'Restore';

  @override
  String get startFresh => 'Start Fresh';

  @override
  String get notNow => 'Not Now';

  @override
  String get restoreNotEnabled => 'Cloud restore is not enabled in this build.';

  @override
  String get appleSecuritySteps => 'Apple Security Steps';

  @override
  String get iosShortcutSubtitle =>
      'Due to iOS limitations, we use Apple\'s official Shortcuts app to pass bank messages to Qirsh automatically and securely.';

  @override
  String get stepsLabel => 'Steps:';

  @override
  String get multipleCurrenciesQuestion => 'Deal with multiple currencies?';

  @override
  String get multipleCurrenciesDesc =>
      'If you receive bank messages in different currencies, repeat the same steps for each currency.';

  @override
  String get continueWithoutAccount => 'Continue without account';

  @override
  String get continueWithoutAccountSub =>
      'Your data stays local on your device.';

  @override
  String get smsPermissionRationaleTitle =>
      'We just need permission to read bank messages';

  @override
  String get smsPermissionRationaleBody =>
      'Qirsh reads incoming bank SMS on your device to log your transactions automatically. It does not read personal messages, and parsing happens on your device by default — nothing leaves it unless you turn on cloud processing yourself.';

  @override
  String get listeningTitle => 'Armed — waiting for your first message';

  @override
  String get listeningSubtitle =>
      'Make any card purchase and it will appear here automatically.';

  @override
  String get pasteMessageInstead => 'Paste a bank message instead';

  @override
  String get skipForNow => 'Skip for now';

  @override
  String get shortcutVerifyTitle => 'Let\'s confirm the Shortcut works';

  @override
  String get shortcutVerifyBody =>
      'Go back to the Shortcuts app, send yourself a message with your currency keyword, then come back here.';

  @override
  String get shortcutVerifyWaiting => 'Waiting for a message...';

  @override
  String get recheckSetup => 'Re-check setup';

  @override
  String get filterKeywordsLabel => 'Keyword:';

  @override
  String get firstTxTitle => 'First transaction — captured automatically!';

  @override
  String get firstTxTrustLine =>
      'You did nothing — Qirsh read your bank\'s SMS and logged it.';

  @override
  String get firstTxContinue => 'Continue';

  @override
  String get firstTxNeedsCheck => 'Needs a quick check';

  @override
  String get firstTxNeedsCheckSub =>
      'Qirsh isn\'t 100% sure — review it quickly.';

  @override
  String get wrongCategoryTap => 'Wrong category? Tap to change it';

  @override
  String get couponsTitle => 'Offers';

  @override
  String get couponsSubtitle =>
      'Partner offers that help you save on everyday spending.';

  @override
  String get couponsFilterAll => 'All';

  @override
  String get couponsFeaturedSection => 'Featured offers';

  @override
  String get couponsEmptyTitle => 'No offers right now';

  @override
  String get couponsEmptyBody =>
      'Partner offers will appear here as soon as they are available.';

  @override
  String get couponsFilterEmptyTitle => 'No offers match this filter';

  @override
  String get couponsFilterEmptyBody => 'Try a different category or tag.';

  @override
  String get couponsErrorTitle => 'Couldn\'t load offers';

  @override
  String get couponsErrorBody => 'Please try again in a moment.';

  @override
  String get couponsRetry => 'Try again';

  @override
  String get couponsLoading => 'Loading offers...';

  @override
  String get couponsCopyCode => 'Copy code';

  @override
  String couponsCodeCopied(String code) {
    return 'Code $code copied';
  }

  @override
  String get couponsOpenPartner => 'Open partner site';

  @override
  String get couponsUseOffer => 'Get the offer';

  @override
  String get couponsOpenFailed => 'Couldn\'t open the link';

  @override
  String get couponsOfferUnavailable => 'This offer isn\'t available anymore';

  @override
  String get couponsTerms => 'Terms';

  @override
  String couponsValidUntil(String date) {
    return 'Ends $date';
  }

  @override
  String get couponsOpenEnded => 'Open-ended';

  @override
  String get couponsExpiresToday => 'Ends today';

  @override
  String couponsExpiresInDays(int days) {
    return '$days days';
  }

  @override
  String get couponsAvailableGlobally => 'Available everywhere';

  @override
  String couponsAvailableIn(String countries) {
    return 'Available in $countries';
  }

  @override
  String couponsCardSemantics(String partner, String title) {
    return 'Offer from $partner: $title';
  }

  @override
  String couponsCodeSemantics(String code) {
    return 'Discount code $code';
  }

  @override
  String get couponsOffline => 'These are the latest offers available offline.';

  @override
  String get referralTitle => 'Invite Friends';

  @override
  String get referralSubtitle =>
      'Invite friends with your code. When they join and verify, you earn ad-free reports.';

  @override
  String get referralYourCodeLabel => 'Your invite code';

  @override
  String get referralCopyAction => 'Copy';

  @override
  String get referralCopiedToast => 'Code copied.';

  @override
  String get referralShareAction => 'Share';

  @override
  String referralShareMessage(String code) {
    return 'Try Qirsh! Use invite code $code when you sign up. Download the app to start.';
  }

  @override
  String referralProgressLabel(int progress, int required) {
    return '$progress / $required valid invites';
  }

  @override
  String referralCycleLabel(int cycle) {
    return 'Cycle $cycle';
  }

  @override
  String get referralRewardTitle => 'Reward';

  @override
  String referralRewardDays(int days) {
    return 'Ad-free reports for $days days';
  }

  @override
  String get referralRewardScopeNote =>
      'The reward removes ads on report export only — not a whole-app ad-free subscription.';

  @override
  String referralRewardActiveUntil(String date) {
    return 'Ad-free reports until $date';
  }

  @override
  String get referralEntitlementInactive => 'No active reward right now.';

  @override
  String get referralApplyTitle => 'Have an invite code?';

  @override
  String get referralApplyHint => 'Enter a friend\'s code once.';

  @override
  String get referralApplyPlaceholder => 'Invite code';

  @override
  String get referralApplyAction => 'Apply code';

  @override
  String get referralApplySuccess => 'Code accepted.';

  @override
  String get referralQualifiedToast => 'Your invite was counted.';

  @override
  String get referralAlreadyReferredNote =>
      'An invite code is already applied to your account.';

  @override
  String get referralLoading => 'Loading…';

  @override
  String get referralErrorTitle => 'Couldn\'t load invites';

  @override
  String get referralErrorBody => 'Please try again in a moment.';

  @override
  String get referralRetry => 'Retry';

  @override
  String get referralUnavailableTitle => 'Invites aren\'t available right now';

  @override
  String get referralUnavailableBody =>
      'We\'ll show Invite Friends here as soon as it\'s available.';

  @override
  String get referralErrorInvalidCode => 'That code isn\'t valid.';

  @override
  String get referralErrorSelfReferral => 'You can\'t use your own code.';

  @override
  String get referralErrorAlreadyReferred =>
      'You\'ve already used an invite code.';

  @override
  String get referralErrorNoActiveRule =>
      'Invites aren\'t available right now.';

  @override
  String get referralErrorIdentityUnverified =>
      'Finish verifying your account so your invite counts.';

  @override
  String get referralErrorGeneric => 'Something went wrong. Please try again.';

  @override
  String get smsDisclosureTitle => 'Reading bank messages automatically';

  @override
  String get smsDisclosureIntro =>
      'To record your expenses automatically, Qirsh needs permission to read incoming messages on your device.';

  @override
  String get smsDisclosureDetect =>
      'Qirsh scans incoming messages to identify financial transactions (purchase, transfer, withdrawal, deposit).';

  @override
  String get smsDisclosureFilter =>
      'Messages that don\'t look financial — such as personal messages and verification codes — are dropped on your device and not stored. The check is automatic and may occasionally keep a message by mistake; you can delete it in Qirsh. Kept messages are stored encrypted on your device and may be processed in the background.';

  @override
  String get smsDisclosureOnDevice =>
      'With Smart Analysis & Cloud Sync off, messages are read only on your device. If you turn it on, captured bank messages are sent to Qirsh\'s servers and may be analysed by Google Gemini, after card, account and phone numbers, IBANs and codes are removed and recognised names, e-mail addresses and reference numbers are masked. The amount, merchant, date, balance and last card digits stay in the text, so it is still your personal financial information.';

  @override
  String get smsDisclosureCloud =>
      'Smart Analysis & Cloud Sync is a separate choice from this permission. It stays off unless you accept it, and you can withdraw it at any time in Settings → Privacy.';

  @override
  String get smsDisclosureControl =>
      'You can turn automatic reading off in Qirsh settings, or revoke the permission in device settings, at any time.';

  @override
  String get smsDisclosureDecline => 'Not now';

  @override
  String get smsDisclosureAccept => 'Agree, request permission';

  @override
  String get couponsForYouSection => 'For places you shop';

  @override
  String get couponsForYouSubtitle =>
      'Matched on this device from your own spending. Nothing about it is sent anywhere.';

  @override
  String get couponsStoresSection => 'Stores';

  @override
  String get couponsStoresSubtitle => 'Merchants with live offers.';

  @override
  String couponsMerchantOffers(String merchant) {
    return 'Offers at $merchant';
  }

  @override
  String get couponsMerchantEmptyTitle => 'No live offers here right now';

  @override
  String get couponsMerchantEmptyBody =>
      'This store has no offers at the moment. Check back later.';

  @override
  String get couponsPersonalizationTitle => 'Order offers by where you shop';

  @override
  String get couponsPersonalizationBody =>
      'Qirsh matches your transactions to stores on this device and puts their offers first. Your spending never leaves your phone for this, and it is not sent to the stores.';

  @override
  String get couponsPersonalizationOff =>
      'Off — offers are ordered the same way for everyone.';

  @override
  String get couponsPersonalizationOn =>
      'On — offers at stores you use appear first.';

  @override
  String couponsValuePercent(String percent) {
    return '$percent% off';
  }

  @override
  String couponsValueFixed(String amount) {
    return '$amount off';
  }

  @override
  String get couponsValueFreeShipping => 'Free delivery';

  @override
  String couponsValueMinSpend(String amount) {
    return 'on $amount or more';
  }

  @override
  String couponsValueUpTo(String amount) {
    return 'up to $amount';
  }

  @override
  String get couponsVerifiedByUs => 'Checked by Qirsh';

  @override
  String get couponsVerifiedByProvider => 'Confirmed by the provider';

  @override
  String get couponsUnverified => 'Not checked';

  @override
  String get savingsTitle => 'What you saved';

  @override
  String get savingsEmptyTitle => 'Nothing saved yet';

  @override
  String get savingsEmptyBody =>
      'When you use an offer and confirm it, it will show up here.';

  @override
  String get savingsVerifiedLabel => 'Confirmed by the store';

  @override
  String get savingsEstimatedLabel => 'Estimated';

  @override
  String get savingsSelfReportedLabel => 'You told us';

  @override
  String get savingsBreakdownNote =>
      'These are kept apart because they are not equally certain. Only the confirmed figure is one the store reported to us.';

  @override
  String get savingsCurrencyNote => 'Currencies are never added together.';

  @override
  String get savingsConfirmTitle => 'Did you use this offer?';

  @override
  String get savingsConfirmBody =>
      'Enter your order total and we will work out what you saved. It is calculated on your phone and sent nowhere.';

  @override
  String get savingsConfirmAmountLabel => 'Order total';

  @override
  String get savingsConfirmAction => 'Calculate';

  @override
  String get savingsCannotCompute =>
      'We cannot work out an exact figure for this offer, so we will not show one.';

  @override
  String get savingsReversedNote =>
      'This was reversed after the store cancelled the purchase.';

  @override
  String get adLabel => 'Advertisement';

  @override
  String get smsAutoCaptureTitle => 'Automatic bank-SMS capture';

  @override
  String get smsAutoCaptureSubtitleOff =>
      'Off — add transactions manually or by sharing';

  @override
  String get smsAutoCaptureSubtitleOn =>
      'On — incoming bank messages are read on your device';

  @override
  String get smsAutoCaptureSubtitleOnSmart =>
      'On — with sensitive numbers removed, bank messages are sent to Qirsh servers and may be analysed by Google Gemini';

  @override
  String get smsAutoCaptureSubtitleBlocked =>
      'Permission denied — open system settings to allow';

  @override
  String get smsAutoCaptureOpenSettings => 'Open system settings';

  @override
  String get smsAutoCaptureDeniedTitle => 'Permission not granted';

  @override
  String get smsAutoCaptureDeniedBody =>
      'Automatic capture needs permission to receive messages. You can still add transactions manually or by sharing a message with Qirsh.';

  @override
  String get smsCaptureTrustNotice =>
      'On Android, Qirsh reads incoming messages only after you turn on automatic capture and grant permission. It does not read bank app notifications, and it never opens your message history.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get helpTitle => 'How to use Qirsh';

  @override
  String get helpSubtitle =>
      'A short guide to the most useful things you can do.';

  @override
  String get helpSettingsTile => 'How to use Qirsh';

  @override
  String get helpSettingsSubtitle => 'Usage guide and common questions';

  @override
  String get helpSectionBasics => 'Basics';

  @override
  String get helpSectionReports => 'Reports and insights';

  @override
  String get helpSectionPlanning => 'Planning';

  @override
  String get helpSectionPrivacy => 'Privacy and data';

  @override
  String get helpAddTransactionTitle => 'Record a transaction';

  @override
  String get helpAddTransactionBody =>
      'Tap the add button on the home screen, then choose manual entry or paste your bank message. Qirsh reads the message and extracts the amount, merchant and date — you always confirm before anything is saved.';

  @override
  String get helpSmartInboxTitle => 'Smart Inbox';

  @override
  String get helpSmartInboxBody =>
      'Transactions Qirsh captures from bank messages arrive here first. Review and confirm them, or correct the category, and they move into your transaction history.';

  @override
  String get helpCategoriesTitle => 'Categories';

  @override
  String get helpCategoriesBody =>
      'Every transaction has a category, which decides where it appears in reports and budgets. Change it from the transaction details, and Qirsh remembers your choice for that merchant.';

  @override
  String get helpPeriodTitle => 'Changing the period';

  @override
  String get helpPeriodBody =>
      'At the top of the transactions and reports screens you\'ll find the period selector: day, week, month, year, or a custom range. Every figure on the screen follows the period you pick.';

  @override
  String get helpAnnualTitle => 'The annual report';

  @override
  String get helpAnnualBody =>
      'Choose “This year” or “Last year” in the period selector to read a full year of financial behaviour: the total, categories, trends, and where you spent most.';

  @override
  String get helpAccountsTitle => 'Accounts and cards';

  @override
  String get helpAccountsBody =>
      'Add an account for each wallet or bank, each with its own currency. Cards appear automatically from bank messages, and you can add them yourself.';

  @override
  String get helpBudgetsTitle => 'Budgets';

  @override
  String get helpBudgetsBody =>
      'Set a cap for a category or for all spending, and choose how often it resets. Qirsh warns you at 80% and again when you go over.';

  @override
  String get helpGoalsTitle => 'Goals';

  @override
  String get helpGoalsBody =>
      'Create a savings goal with an amount and a date, then add contributions. Qirsh works out the daily amount that keeps the goal on track.';

  @override
  String get helpPrivacyTitle => 'You control your data';

  @override
  String get helpPrivacyBody =>
      'Your financial data is stored encrypted on your device. From the privacy screen you control cloud processing and AI analysis, and you can withdraw consent at any time.';

  @override
  String get helpBackupTitle => 'Backup and restore';

  @override
  String get helpBackupBody =>
      'Export an encrypted copy of your data and keep it safe, or restore it on another device. The file is previewed on your device before anything is written, and your passphrase never leaves it.';

  @override
  String get helpFooter => 'Still stuck? Contact us from the settings screen.';

  @override
  String get coachMarkNext => 'Next';

  @override
  String get coachMarkDone => 'Got it';

  @override
  String get coachMarkSkip => 'Skip';

  @override
  String get coachDashboardAddTitle => 'Record your first transaction';

  @override
  String get coachDashboardAddBody =>
      'The add button lets you enter a transaction yourself, or paste a bank message for Qirsh to read for you.';

  @override
  String get coachDashboardPeriodTitle => 'Pick the period';

  @override
  String get coachDashboardPeriodBody =>
      'Choose day, week, or month to change the financial summary shown above.';

  @override
  String get coachDashboardInboxTitle => 'Smart Inbox';

  @override
  String get coachDashboardInboxBody =>
      'Whatever Qirsh captures from your bank messages waits here for review before it reaches your history.';

  @override
  String get coachDashboardHelpTitle => 'The guide is always there';

  @override
  String get coachDashboardHelpBody =>
      '“How to use Qirsh” lives in Settings, and you can replay this tour from there whenever you like.';

  @override
  String get helpReplayTour => 'Replay the guided tour';

  @override
  String get helpReplayTourDone => 'The guided tour will appear again.';

  @override
  String get setLoadingCountries => 'Loading countries…';

  @override
  String get setLoadingCurrencies => 'Loading currencies…';

  @override
  String get setCountry => 'Country';

  @override
  String get setBaseCurrency => 'Base currency';

  @override
  String get bfBudgetAlert => 'Budget alert';

  @override
  String get bfBudgetAlertHint =>
      'We will warn you when your spending reaches this much of the budget.';

  @override
  String bfBudgetAlertValue(String percent) {
    return '$percent% of the budget';
  }

  @override
  String get setLanguage => 'Language';

  @override
  String get setName => 'Name';

  @override
  String get setNameInApp => 'Your name in the app';

  @override
  String get setAccountData => 'Your account details';

  @override
  String get setMobileNumber => 'Mobile number';

  @override
  String get setAddYourNumber => 'Add your number';

  @override
  String get setAppearance => 'Appearance';

  @override
  String get setAppearanceSub => 'Light, dark, or match the system';

  @override
  String get setAccountsAndDues => 'Your accounts and commitments';

  @override
  String get setSyncConflicts => 'Sync conflicts';

  @override
  String get setSyncConflictsSub =>
      'Items edited on more than one device — they need your decision';

  @override
  String get setAccountsWallets => 'Accounts and wallets';

  @override
  String get setAccountsWalletsSub =>
      'Multiple accounts, each in its own currency';

  @override
  String get setAllCards => 'All cards';

  @override
  String get setAllCardsSub => 'An overview of your cards grouped by account';

  @override
  String get setSubsAndBills => 'Subscriptions and bills';

  @override
  String get setSubsAndBillsSub => 'Your recurring commitments and due dates';

  @override
  String get setPlans => 'Plans';

  @override
  String get setPlansSub =>
      'A budget for a trip or occasion that tracks itself';

  @override
  String get setToolsAndSettings => 'Tools and settings';

  @override
  String get setCategories => 'Categories';

  @override
  String get setCategoriesSub => 'Organise expenses, income and transfers';

  @override
  String get setAchievements => 'Achievements and level';

  @override
  String get setAchievementsSub =>
      'Badges and levels that encourage the habit of tracking';

  @override
  String get setCurrencyRepair => 'Confirm the currency for budgets and goals';

  @override
  String get setCurrencyRepairSub =>
      'Safely review the currency of older planning data';

  @override
  String get setAppleShortcut => 'Apple Shortcut';

  @override
  String get setAppleShortcutSub =>
      'Pass bank messages to Qirsh through Shortcuts';

  @override
  String get setRewardsAndSupport => 'Rewards and support';

  @override
  String get setInviteFriends => 'Invite friends';

  @override
  String get setInviteFriendsSub =>
      'Share your invite code and earn ad-free reports';

  @override
  String get setAdPrivacyOptions => 'Ad privacy options';

  @override
  String get setAdPrivacyOptionsSub => 'Manage your advertising consent';

  @override
  String get setContactUs => 'Contact us';

  @override
  String get setContactUsSub =>
      'Technical support and answers to your questions';

  @override
  String get setAboutQirsh => 'About Qirsh';

  @override
  String get setAboutQirshSub => 'App information and version';

  @override
  String get setCaptureStatus => 'Transaction capture';

  @override
  String get setCaptureStatusSub =>
      'The status of bank messages and the Apple Shortcut';

  @override
  String get setConfirmCaptured => 'Confirm captured transactions';

  @override
  String get setNotifyOnCapture => 'Notify me when a transaction is captured';

  @override
  String get setHideOnLockScreen => 'Hide sensitive details on the lock screen';

  @override
  String get setYourAlerts => 'Your alerts';

  @override
  String get setQirshMessages => 'Qirsh messages and tips';

  @override
  String get setBudgetAlerts => 'Budget alerts';

  @override
  String get setBudgetOverAlert => 'Alert when a budget is exceeded';

  @override
  String get setDailyReminder => 'Daily reminder';

  @override
  String get setDailyReminderTime => 'Every day at 10 PM';

  @override
  String get setWeeklyReport => 'Weekly report';

  @override
  String get setBillReminders => 'Subscription and bill reminders';

  @override
  String get setGoalCelebrations => 'Goal celebrations';

  @override
  String get setAchievementAlerts => 'Achievement alerts';

  @override
  String get setQuietHours => 'Quiet hours';

  @override
  String get setDisabled => 'Off';

  @override
  String get setEditQuietHours => 'Edit quiet hours';

  @override
  String get setNotificationTools => 'Notification tools';

  @override
  String get setTestNotifications => 'Test Qirsh notifications';

  @override
  String get setTestNotificationsSub =>
      'Send a test notification to this device';

  @override
  String get setMessageCentre => 'Qirsh message centre';

  @override
  String get setMessageCentreSub =>
      'Past notifications, campaigns and announcements';

  @override
  String get setDataTransfer => 'Data transfer';

  @override
  String get setDataTransferSub =>
      'Your financial data stays under your control';

  @override
  String get setImportFile => 'Import a file';

  @override
  String get setImportFileSub =>
      'A CSV from any app, or a ZIP exported by Qirsh';

  @override
  String get setExportCsv => 'Export transactions as CSV';

  @override
  String get setExportCsvSub => 'A simple file with all your transactions';

  @override
  String get setExportAll => 'Export all Qirsh data';

  @override
  String get setExportAllSub => 'A ZIP package you can move and restore';

  @override
  String get setSecurityPrivacy => 'Security and privacy';

  @override
  String get setEncryptedDbPart1 =>
      'Your data on this device is kept in an encrypted database, ';

  @override
  String get setEncryptedDbPart2 =>
      'and its key is stored in the system keychain';

  @override
  String get setPrivacyAndData => 'Privacy and data';

  @override
  String get setPrivacyAndDataSub =>
      'Your data security and the privacy policy';

  @override
  String get setHideAmounts => 'Hide amounts in the interface';

  @override
  String get setExitAndErase => 'Sign out and erase data';

  @override
  String get setExitAndEraseSub => 'Some of these actions cannot be undone';

  @override
  String get setStartOver => 'Start over';

  @override
  String get setStartOverSub => 'Erase local data but keep the account active';

  @override
  String get setSignOut => 'Sign out';

  @override
  String get setDeleteAccount => 'Delete my account and all my data';

  @override
  String get setDeleteAccountSub =>
      'A final action that needs your confirmation';

  @override
  String get setTestNotificationSent =>
      'We sent a test notification from Qirsh.';

  @override
  String get setTestNotificationFailed =>
      'We could not send the test notification.';

  @override
  String get setUnsyncedData => 'Data not saved to the cloud';

  @override
  String get setCancel => 'Cancel';

  @override
  String get setSignOutDiscard => 'Sign out and discard unsaved data';

  @override
  String get setUnsyncedCheckFailed =>
      'We could not check for unsaved data. Please try again.';

  @override
  String get rebootUpdatingData => 'Updating your data…';

  @override
  String get setDataRemovedNotice => 'Data removed from this device';

  @override
  String get smartConsentAiNeedsCloud =>
      'Turn on Cloud Sync first to use Smart Analysis.';

  @override
  String get setSignOutFailed =>
      'We could not sign out safely. Please try again.';

  @override
  String get setPhotoUpdated => 'Photo updated.';

  @override
  String get setSave => 'Save';

  @override
  String get setCategoriesSheetIntro =>
      'Add or edit the categories that appear in transactions and reports.';

  @override
  String get setAddCategory => 'Add a category';

  @override
  String get setExpenses => 'Expenses';

  @override
  String get setIncome => 'Income';

  @override
  String get setTransfers => 'Transfers';

  @override
  String get setEditCategory => 'Edit category';

  @override
  String get setCategoryName => 'Category name';

  @override
  String get setIncomeCategory => 'Income category';

  @override
  String get setIcon => 'Icon';

  @override
  String get setColor => 'Colour';

  @override
  String get setEnterCategoryName => 'Enter a category name.';

  @override
  String get setSaveChanges => 'Save changes';

  @override
  String get setAdd => 'Add';

  @override
  String get setDeleteCategoryQ => 'Delete this category?';

  @override
  String get setDeleteCategoryBody =>
      'Its transactions move to “Other” or “Income”, and any linked budget is deleted.';

  @override
  String get setDelete => 'Delete';

  @override
  String get setQuietHoursNote =>
      'We defer scheduled notifications during this period to the first allowed time.';

  @override
  String get setStarts => 'Starts';

  @override
  String get setEnds => 'Ends';

  @override
  String get setAboutApp => 'About the app';

  @override
  String get setAboutBody =>
      'Qirsh tracks spending from bank messages and manual entry. You can move your financial data as CSV files or a ZIP package from the data and privacy section.';

  @override
  String get setOk => 'OK';

  @override
  String get setSupportBody =>
      'For support or feedback, copy the email and send us the problem details, your device type, and the steps to reproduce it.';

  @override
  String get setCopyEmail => 'Copy email';

  @override
  String get setEraseAllQ => 'Erase all data?';

  @override
  String get setEraseAllBody =>
      'All your local data will be erased. This cannot be undone.';

  @override
  String get setErase => 'Erase';

  @override
  String get setSettingsLoadFailed =>
      'We could not load settings. Please try again shortly.';

  @override
  String get setSettings => 'Settings';

  @override
  String get setBack => 'Back';

  @override
  String get setThemeAuto => 'Auto';

  @override
  String get setThemeLight => 'Light';

  @override
  String get setThemeDark => 'Dark';

  @override
  String get setEdit => 'Edit';

  @override
  String get setAppLockFailed =>
      'We could not turn on the lock. Make sure a passcode or biometric is set up on your device.';

  @override
  String get setAppLock => 'App lock';

  @override
  String get setNoBankMessageYet => 'We have not detected a bank message yet';

  @override
  String get setCaptureEnableFailed =>
      'We could not turn on bank capture notifications';

  @override
  String get setNoBankMessagesRecently =>
      'We have not received bank messages for a while';

  @override
  String get setBankCaptureStatus => 'Bank message capture status';

  @override
  String get setCheck => 'Check';

  @override
  String get setBackupFirst => 'Take a backup first if you want to keep it.';

  @override
  String get setToday => 'Today';

  @override
  String get bdgError => 'Something went wrong';

  @override
  String get bdgTabBudgets => 'Budgets';

  @override
  String get bdgTabHistory => 'Budget history';

  @override
  String get bdgTabGoals => 'Goals';

  @override
  String get bdgEmptyBudgetsTitle => 'No budgets yet';

  @override
  String get bdgEmptyBudgetsBody =>
      'Create your first daily, weekly or monthly budget to start tracking.';

  @override
  String get bdgEmptyGoalsTitle => 'No goals yet';

  @override
  String get bdgEmptyGoalsBody =>
      'Add a savings goal so Qirsh can track your progress alongside your budgets.';

  @override
  String get bdgAddGoal => 'Add goal';

  @override
  String get bdgEmptyHistoryTitle => 'The history is empty';

  @override
  String get bdgEmptyHistoryBody =>
      'Pick a period that has budgets, or add a new budget — each day, week or month then appears here as its own record.';

  @override
  String get bdgAddBudget => 'Add budget';

  @override
  String get bdgDeleteTitle => 'Delete this budget?';

  @override
  String get bdgDeleteBody =>
      'The budget limit will be deleted. Your transactions are not affected.';

  @override
  String get bdgDeleteFailed => 'The budget could not be deleted right now.';

  @override
  String get bdgFilterAll => 'All';

  @override
  String get bdgFilterDaily => 'Daily';

  @override
  String get bdgFilterWeekly => 'Weekly';

  @override
  String get bdgFilterMonthly => 'Monthly';

  @override
  String get bdgFilterYearly => 'Yearly';

  @override
  String get bdgStatHistoryCount => 'Budgets on record';

  @override
  String get bdgStatTargetSavings => 'Total target savings';

  @override
  String get bdgStatTotalBudgeted => 'Total budgeted';

  @override
  String get bdgStatActiveGoals => 'Active goals';

  @override
  String get bdgStatProgress => 'Progress';

  @override
  String get bdgStatTotalSaved => 'Total saved';

  @override
  String get bdgStateSafeF => 'On track';

  @override
  String get bdgStateNear => 'Close to limit';

  @override
  String get bdgStateOverF => 'Over limit';

  @override
  String get bdgBudgetsWord => 'Budgets';

  @override
  String get bdgUsageRate => 'Usage';

  @override
  String get bdgActualSpend => 'Actual spend';

  @override
  String get bdgBudgetWord => 'Budget';

  @override
  String get bdgOver => 'Over';

  @override
  String get bdgSafe => 'On track';

  @override
  String get bdgAllExpenses => 'All expenses';

  @override
  String get bdgCategory => 'Category';

  @override
  String get bdgSpent => 'Spent';

  @override
  String get bdgRemaining => 'Left';

  @override
  String get bdgLimit => 'Limit';

  @override
  String get bdgSaved => 'Saved';

  @override
  String get bdgPeriodCurrent => 'Current period';

  @override
  String get bdgPeriodOver => 'Period went over';

  @override
  String get bdgPeriodEnded => 'Period ended';

  @override
  String get bdgRecordLive =>
      'This record keeps updating until the period ends.';

  @override
  String get bdgRecordFinal =>
      'This record is calculated from the actual transactions in this period.';

  @override
  String get bdgEditBudget => 'Edit budget';

  @override
  String get bdgPeriodTransactions => 'Transactions in this period';

  @override
  String get bdgNoConfirmedTx =>
      'No confirmed transactions were recorded in this period.';

  @override
  String get bdgCountedOpenAll =>
      'Included in the total — open Transactions to see them all.';

  @override
  String get bdgDailyBudget => 'Daily budget';

  @override
  String get bdgWeeklyBudget => 'Weekly budget';

  @override
  String get bdgYearlyBudget => 'Yearly budget';

  @override
  String get bdgMonthlyBudget => 'Monthly budget';

  @override
  String get bdgTransactionWord => 'transaction';

  @override
  String get bdgGoalDone => 'Goal reached';

  @override
  String get bdgEnvelopeTitle => 'Split your income into envelopes';

  @override
  String get bdgEnvelopeBody =>
      'Enter your salary and split it in one tap — Qirsh works out what you can spend each day';

  @override
  String bdgMoreTxCounted(int count) {
    return '$count more transactions are included in the total — open Transactions to see them all.';
  }

  @override
  String get txnError => 'Something went wrong';

  @override
  String get txnTransactionWord => 'transaction';

  @override
  String get txnFilterPending => 'Filter: pending review';

  @override
  String get txnConfirmAll => 'Confirm all';

  @override
  String get txnTabTransactions => 'Transactions';

  @override
  String get txnTabBills => 'Bills';

  @override
  String get txnPendingEmptyTitle => 'No pending transactions in this view';

  @override
  String get txnPendingEmptyBody =>
      'Try another period or change the filters to review other transactions.';

  @override
  String get txnEmptyPeriodTitle => 'No transactions in this period';

  @override
  String get txnEmptyPeriodBody =>
      'Change the period, or add a new bank message with the + button.';

  @override
  String get txnConfirmAllTitle => 'Confirm every pending transaction?';

  @override
  String get txnConfirm => 'Confirm';

  @override
  String get txnPickAccount => 'Choose account';

  @override
  String get txnSearchHint =>
      'Search by merchant, category, amount or currency';

  @override
  String get txnClearSearch => 'Clear search';

  @override
  String get txnRangeToday => 'Today';

  @override
  String get txnRangeThisWeek => 'This week';

  @override
  String get txnRangeThisMonth => 'This month';

  @override
  String get txnRangeLastMonth => 'Last month';

  @override
  String get txnRange7 => 'Last 7 days';

  @override
  String get txnRange30 => 'Last 30 days';

  @override
  String get txnRange90 => 'Last 90 days';

  @override
  String get txnRangeThisYear => 'This year';

  @override
  String get txnRangeLastYear => 'Last year';

  @override
  String get txnRangeCustom => 'Custom';

  @override
  String get txnPickRange => 'Choose a period';

  @override
  String get txnFrom => 'From';

  @override
  String get txnTo => 'To';

  @override
  String get txnApplyCustomRange => 'Apply custom period';

  @override
  String get txnKindAll => 'All';

  @override
  String get txnKindExpense => 'Expenses';

  @override
  String get txnKindIncome => 'Income';

  @override
  String get txnKindTransfer => 'Transfers';

  @override
  String get txnPendingReview => 'Pending review';

  @override
  String get txnCategory => 'Category';

  @override
  String get txnFilterByCategory => 'Filter by category';

  @override
  String get txnAllCategories => 'All categories';

  @override
  String get txnBillsSubs => 'Subscriptions';

  @override
  String get txnBillsInstalments => 'Instalments';

  @override
  String get txnAddSub => 'Add subscription';

  @override
  String get txnAddInstalment => 'Add instalment';

  @override
  String get txnLearnBills => 'Learn more about bills';

  @override
  String get txnSubsEmptyTitle => 'Your subscriptions, tracked automatically';

  @override
  String get txnInstEmptyTitle => 'Your instalments, clear every month';

  @override
  String get txnSubsEmptyBody =>
      'Add a subscription yourself, or let it be detected automatically from recurring transactions.';

  @override
  String get txnInstEmptyBody =>
      'Add the instalment with its date and reminder so it appears in Bills before it is due.';

  @override
  String get txnSuggestionsTitle => 'Suggestions from recurring transactions';

  @override
  String get txnHowSubsTitle => 'How does Qirsh track subscriptions?';

  @override
  String get txnHowInstTitle => 'How does Qirsh track instalments?';

  @override
  String get txnHowSubsBody =>
      'Qirsh follows recurring patterns automatically, and you can also add a subscription yourself with its amount, renewal date and reminder.';

  @override
  String get txnHowInstBody =>
      'Add the instalment yourself with its amount, due date and reminder. Remaining balance and instalment count come later.';

  @override
  String get txnTotalMonthlySubs => 'Total monthly subscriptions';

  @override
  String get txnTotalMonthlyInst => 'Total monthly instalments';

  @override
  String get txnActive => 'Active';

  @override
  String get txnPerYear => 'per year';

  @override
  String get txnDueToday => 'Due today';

  @override
  String get txnPaused => 'Paused';

  @override
  String get txnCancelled => 'Cancelled';

  @override
  String get txnCycleWeekly => 'Weekly';

  @override
  String get txnCycleMonthly => 'Monthly';

  @override
  String get txnCycleYearly => 'Yearly';

  @override
  String get txnTotalValueLabel => 'Total value: ';

  @override
  String get txnPaidManuallyLabel => 'Paid manually: ';

  @override
  String get txnAdd => 'Add';

  @override
  String get txnBillsAndSubs => 'Bills & subscriptions';

  @override
  String get txnPeriodSpendTotal => 'Total spend this period';

  @override
  String get txnActiveMonthlySpend => 'Total active monthly spend';

  @override
  String get txnTxForPeriod => 'transactions this period';

  @override
  String get txnTotalSpent => 'Total spent';

  @override
  String get txnActiveSub => 'active subscription';

  @override
  String get txnRunningInst => 'running instalment';

  @override
  String get txnYearlyTotal => 'Yearly total';

  @override
  String get txnSmartInbox => 'Smart review inbox';

  @override
  String get txnReviewTx => 'Review transaction';

  @override
  String get txnHide => 'Hide';

  @override
  String get txnSuspectTxPlural => 'Possible duplicates';

  @override
  String get txnDismissAll => 'Dismiss all';

  @override
  String get txnNoSuspectTx => 'No possible duplicates';

  @override
  String get txnSimilarExists => 'A similar transaction already exists';

  @override
  String get txnSimilarBody =>
      'This transaction matches an existing one in amount, merchant and time.';

  @override
  String get txnTheNew => 'New';

  @override
  String get txnNoClearMerchant => 'No clear merchant';

  @override
  String get txnTheExisting => 'Existing';

  @override
  String get txnDismissDuplicate => 'Dismiss duplicate';

  @override
  String get txnSaveAsNew => 'Save as new';

  @override
  String get txnEditTx => 'Edit transaction';

  @override
  String get txnChangeCategory => 'Change category';

  @override
  String get txnTimeInSms => 'Transaction time in the SMS';

  @override
  String get txnTimeReceived => 'Time the message arrived';

  @override
  String txnDupBannerReview(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count possible duplicates',
      one: '1 possible duplicate',
    );
    return '$_temp0 — tap to review';
  }

  @override
  String get txnDismissAllDupesBody =>
      'Every duplicate alert shown here will be removed. The transactions themselves are not affected, but you will not be able to review them from here again.';

  @override
  String txnTimeSource(String source) {
    return 'Time source: $source';
  }

  @override
  String txnRecurredMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Recurred for $count months',
      one: 'Recurred for 1 month',
    );
    return '$_temp0 · tap to enable';
  }

  @override
  String txnConfirmAllBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count transactions will be confirmed with their current categories.',
      one: '1 transaction will be confirmed with its current category.',
    );
    return '$_temp0';
  }

  @override
  String txnOverdueDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days overdue',
      one: '1 day overdue',
    );
    return '$_temp0';
  }

  @override
  String txnInDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'in $days days',
      one: 'in 1 day',
    );
    return '$_temp0';
  }

  @override
  String txnPerInstalment(String amount) {
    return '$amount / instalment';
  }

  @override
  String txnPaidOfTotal(int paid, int total) {
    return '$paid of $total instalments paid';
  }

  @override
  String txnRemainingInstalments(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count left',
      one: '1 left',
    );
    return '$_temp0';
  }

  @override
  String txnInterestRate(String rate) {
    return 'Interest $rate%';
  }

  @override
  String txnNextInstalment(String due) {
    return 'Next instalment: $due';
  }

  @override
  String txnEstPerMonth(String amount, String currency) {
    return '$amount $currency/mo';
  }

  @override
  String txnSmartInboxCount(int count) {
    return 'Smart review inbox · $count';
  }

  @override
  String txnDismissNAlerts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Dismiss $count alerts?',
      one: 'Dismiss 1 alert?',
    );
    return '$_temp0';
  }

  @override
  String txnDismissAllCount(int count) {
    return 'Dismiss all ($count)';
  }

  @override
  String get subsOverdue => 'Overdue';

  @override
  String get subsToday => 'Today';

  @override
  String subsTabSubs(int count) {
    return 'Subscriptions ($count)';
  }

  @override
  String subsTabInst(int count) {
    return 'Instalments ($count)';
  }

  @override
  String subsMonthlyScoped(String account) {
    return 'Monthly subscriptions · $account';
  }

  @override
  String subsPerYearApprox(String amount) {
    return '≈ $amount/yr';
  }

  @override
  String get subsTitle => 'Subscriptions & bills';

  @override
  String get subsMonthlyTotal => 'Monthly subscriptions';

  @override
  String get subsActiveSubs => 'Active subscriptions';

  @override
  String get subsRunningInst => 'Running instalments';

  @override
  String get subsMonthlyInstCommit => 'Monthly instalment commitment';

  @override
  String get subsEmptyTitle => 'All your subscriptions in one place';

  @override
  String get subsAutoDetected => 'Detected automatically';

  @override
  String get subsAddNewSub => 'Add a new subscription';

  @override
  String get subsMaybeUnused => 'You may not be using this subscription';

  @override
  String get subsInstEmptyTitle =>
      'Your instalments, clear before they fall due';

  @override
  String get subsInstEmptyBody =>
      'Add the instalment with its amount, count and due date.';

  @override
  String get subsTotalInstDebt => 'Total instalment debt';

  @override
  String get subsNearestInst => 'Next instalment due';

  @override
  String get subsAddNewInst => 'Add a new instalment';

  @override
  String rptAnomalyPrivate(String date) {
    return 'Spending on $date was higher than your usual pattern. Review it if you want to know why.';
  }

  @override
  String rptAnomalyDetail(String date, String amount, String ratio) {
    return 'On $date you spent $amount, which is above your daily average by $ratio×.';
  }

  @override
  String rptSpendLower(int percent) {
    return 'You spent $percent% less than the same period before.';
  }

  @override
  String rptSpendHigher(int percent) {
    return 'You spent $percent% more than the same period before.';
  }

  @override
  String rptHighestDayBody(String amount) {
    return 'The highest day in this period reached $amount.';
  }

  @override
  String rptTopCategoryHint(String category) {
    return 'Your biggest spend is on $category. Watch that category first.';
  }

  @override
  String rptMerchantTxCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions',
      one: '1 transaction',
    );
    return '$_temp0';
  }

  @override
  String rptVsLastWeek(String sign, String percent) {
    return '$sign $percent% compared with last week';
  }

  @override
  String rptTopCategoryWeek(String category) {
    return 'Top category: $category';
  }

  @override
  String rptBestSavingDay(String date, String amount) {
    return 'Best saving day: $date ($amount)';
  }

  @override
  String rptTopMerchantWeek(String name, String amount) {
    return 'Top merchant: $name ($amount)';
  }

  @override
  String get rptTabOverview => 'Overview';

  @override
  String get rptTabTrends => 'Trends';

  @override
  String get rptTabDetails => 'Details';

  @override
  String get rptUnusualSpend => 'Unusual spending';

  @override
  String get rptVsPrevPeriod => 'Compared with the same period before';

  @override
  String get rptNeedPrevPeriod =>
      'We still need an earlier period with spending in it to show the trend accurately.';

  @override
  String get rptHighestSpendDay => 'Highest spending day';

  @override
  String get rptQuickTip => 'Quick tip';

  @override
  String get rptAddMoreTx =>
      'Add a few more transactions and the suggestions get sharper.';

  @override
  String get rptSelectedPeriod => 'Selected period';

  @override
  String get rptNetPeriodSpend => 'Net spend this period';

  @override
  String get rptSelectedPeriodSpend => 'Spend in the selected period';

  @override
  String get rptTotalExpenses => 'Total expenses';

  @override
  String get rptRefunds => 'Refunds';

  @override
  String get rptNet => 'Net';

  @override
  String get rptThisWeekUsage => 'This week so far';

  @override
  String get rptAverage => 'Average';

  @override
  String get rptHighest => 'Highest';

  @override
  String get rptTotal => 'Total';

  @override
  String get rptByCategory => 'Your spending by category';

  @override
  String get rptByMerchant => 'Your spending at merchants';

  @override
  String get rptTopMerchantsSub => 'Where most of your money went this period';

  @override
  String get rptMerchantsEmpty =>
      'The merchants you spend most at appear here once you have confirmed transactions.';

  @override
  String get rptIncludesRefund => ' · includes refund ';

  @override
  String get rptInsightsTitle => 'Insights & reports';

  @override
  String get rptInsightsSub =>
      'Read your spending as daily trends, categories and merchants.';

  @override
  String get rptDailyAverage => 'Daily average';

  @override
  String get rptHighestDay => 'Highest day';

  @override
  String get rptWeekSummary => 'This week in summary';

  @override
  String bdgPeriodSubtitle(String period, String date) {
    return '$period budget · $date';
  }

  @override
  String bdgPeriodSubtitleLive(String period, String date) {
    return '$period budget · $date · running';
  }

  @override
  String bdgLatestOfTotal(int shown, int total) {
    return 'Latest $shown of $total';
  }

  @override
  String get bdgRemainingPrefix => 'Left ';

  @override
  String bdgToReachSuffix(String currency) {
    return ' $currency to go';
  }

  @override
  String setUnsyncedLedger(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transaction changes',
      one: '1 transaction change',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedPlanning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes to accounts/budgets/goals/bills',
      one: '1 change to accounts/budgets/goals/bills',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedInbox(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items in your inbox',
      one: '1 item in your inbox',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cards saved on this device only',
      one: '1 card saved on this device only',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedUnproven(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count financial records not yet uploaded to the cloud',
      one: '1 financial record not yet uploaded to the cloud',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records with unresolved conflicts',
      one: '1 record with an unresolved conflict',
    );
    return '$_temp0';
  }

  @override
  String get setListSeparator => ', ';

  @override
  String setUnsyncedSignOutBody(String list) {
    return 'You have data that was never uploaded to the cloud, and signing out will delete it: $list. Take a backup first if you want to keep it.';
  }

  @override
  String setGapDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String setGapHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String get setGapToday => 'Today';

  @override
  String setLastCapture(String gap) {
    return 'Last capture: $gap';
  }

  @override
  String setApnsFailed(String message) {
    return 'APNs registration failed: $message';
  }

  @override
  String setCheckShortcutStillOn(String subtitle) {
    return '$subtitle — check the shortcut is still enabled';
  }

  @override
  String get goalDueToday => 'Due today';

  @override
  String goalDaysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days left',
      one: '1 day left',
    );
    return '$_temp0';
  }

  @override
  String goalMonthsLeft(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months months left',
      one: '1 month left',
    );
    return '$_temp0';
  }

  @override
  String goalRemainingToReach(String amount, String currency) {
    return '$amount $currency to go';
  }

  @override
  String goalSavedAmount(String amount, String currency) {
    return 'Saved $amount $currency';
  }

  @override
  String goalTargetAmount(String amount, String currency) {
    return 'Target $amount $currency';
  }

  @override
  String get goalPerMonth => '/mo';

  @override
  String get goalOverdue => 'Past its target date';

  @override
  String get goalTotalSavedAll => 'Total saved across all your goals';

  @override
  String get goalTargetLabel => 'Target';

  @override
  String get goalEmptyBody => 'Add your first goal and start filling the jar.';

  @override
  String cardLinkTxTo(String last4) {
    return 'Link a transaction to •••• $last4';
  }

  @override
  String cardTxLinkedTo(String last4) {
    return 'Transaction linked to •••• $last4';
  }

  @override
  String get cardAccountWord => 'Account';

  @override
  String get cardUnassigned => 'Unassigned';

  @override
  String get cardBack => 'Back';

  @override
  String get cardActivityTitle => 'Card activity';

  @override
  String get cardAllCards => 'All cards';

  @override
  String get cardLoadFailed => 'Your cards could not be loaded';

  @override
  String get cardLoadFailedBody => 'Try again to see your saved cards.';

  @override
  String get cardAddCard => 'Add card';

  @override
  String get cardEmptyTitle => 'No cards yet';

  @override
  String get cardEmptyBody =>
      'Cards appear automatically from your bank messages, and you can add one of your own design.';

  @override
  String get cardAddCardCta => 'Add a card';

  @override
  String get cardEdit => 'Edit';

  @override
  String get cardIn => 'In';

  @override
  String get cardOut => 'Out';

  @override
  String get cardAddTx => 'Add transaction';

  @override
  String get cardLinkExistingTx => 'Link a transaction';

  @override
  String get cardSearchHint => 'Search by name or amount';

  @override
  String get cardNoTx => 'No transactions';

  @override
  String get accAddAccount => 'Add account';

  @override
  String get accTitle => 'Accounts & wallets';

  @override
  String get accSubtitle =>
      'Each account in its own currency — cash, bank, wallet or card.';

  @override
  String get accDefault => 'Default';

  @override
  String get accUnassignedCards => 'Unassigned cards';

  @override
  String get accUnassignedCardsBody =>
      'Cards that showed up in your messages but are not linked to an account yet.';

  @override
  String achCurrentStreak(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return 'Current streak: $_temp0';
  }

  @override
  String achStreakDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String annFromDate(String date) {
    return 'From $date';
  }

  @override
  String pasteAnalysing(int processed, int total) {
    return 'Analysing $processed of $total';
  }

  @override
  String pasteSummaryLine(int added, int duplicate, int review, int failed) {
    return 'Added $added · duplicate $duplicate · needs review $review · not understood $failed';
  }

  @override
  String pasteAnalysedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Analysed $count pasted messages.',
      one: 'Analysed 1 pasted message.',
    );
    return '$_temp0';
  }

  @override
  String get achCurrentLevel => 'Current level';

  @override
  String get achUnlocked => 'Unlocked';

  @override
  String get achInProgress => 'In progress';

  @override
  String get achLevelOrganised => 'Organised';

  @override
  String get achLevelSmartSaver => 'Smart saver';

  @override
  String get achLevelExpert => 'Money expert';

  @override
  String get achLevelLegend => 'Savings legend';

  @override
  String get achLevelBeginner => 'Beginner';

  @override
  String get achTitle => 'Achievements';

  @override
  String get achSubtitle =>
      'Badges and levels to keep the tracking habit going.';

  @override
  String get achLevel => 'Level';

  @override
  String get achTotalXp => 'Total XP';

  @override
  String get achStreak => 'Streak';

  @override
  String get annTitle => 'Qirsh message centre';

  @override
  String get annSubtitle =>
      'Your Qirsh notifications, campaigns and announcements in one place.';

  @override
  String get annClose => 'Close';

  @override
  String get annLoading => 'Loading the message centre…';

  @override
  String get annLoadFailed => 'Could not load your messages';

  @override
  String get annTryAgainSoon => 'Try again in a moment.';

  @override
  String get annRetry => 'Try again';

  @override
  String get annEmpty => 'No messages yet';

  @override
  String get annEmptyBody =>
      'Any notification from Qirsh, or announcement from us, shows up here automatically.';

  @override
  String get annShortcutCaptured => 'New transaction captured';

  @override
  String get annShortcutReceived => 'Bank message received';

  @override
  String get annNotificationSent => 'Notification sent';

  @override
  String get annOpen => 'Open';

  @override
  String get annInAppCampaign => 'In-app campaign';

  @override
  String get annFromQirsh => 'Announcement from Qirsh';

  @override
  String get privCloudProcessingBody =>
      'Your data is synced and backed up on Qirsh servers, and captured bank messages may be sent there, with card, account and phone numbers and codes removed, to be read; a merchant name may be sent to Google Places to categorise it. Turning it off stops sending: messages are read by Qirsh\'s on-device rules and nothing new is synced. Manual entry keeps working.';

  @override
  String get privAiAnalysisBody =>
      'With Cloud Sync on, captured bank messages — including bank SMS read automatically on Android — with card, account and phone numbers and codes removed and recognised names, e-mails and reference numbers masked, may be analysed by Google Gemini to read the amount, merchant and bank. The text still contains amounts, merchants, dates and balances. Withdrawing consent limits reading to Qirsh\'s on-device rules.';

  @override
  String get privDeleteAccountBody =>
      'Your account and all your data (transactions, goals, budgets, backups) will be scheduled for permanent deletion after 30 days. You can undo the deletion from this same screen at any point before then, by signing in again. You will be signed out on this device now.';

  @override
  String privScheduledForDeletion(String date) {
    return 'Your account is scheduled for deletion on $date';
  }

  @override
  String get privPolicy => 'Privacy policy';

  @override
  String get privTerms => 'Terms & conditions';

  @override
  String get privTransferMyData => 'Move or import my data';

  @override
  String get privDataProcessing => 'Data processing';

  @override
  String get privCloudProcessing => 'Cloud processing & sync';

  @override
  String get privAiAnalysis => 'AI analysis';

  @override
  String get privDangerZone => 'Danger zone';

  @override
  String get privDeleteAccountAll => 'Delete my account and all my data';

  @override
  String get privLinkFailed => 'That link could not be opened right now.';

  @override
  String get privDeleteAccountTitle => 'Delete your account?';

  @override
  String get privDeleteAccount => 'Delete account';

  @override
  String get privScheduleFailed =>
      'The deletion could not be scheduled right now. Please try again.';

  @override
  String get privCancelDeleteTitle => 'Cancel the account deletion?';

  @override
  String get privCancelDeleteBody =>
      'Your account and data stay exactly as they are.';

  @override
  String get privKeepAccount => 'Go back';

  @override
  String get privCancelDeletion => 'Cancel deletion';

  @override
  String get privCancelFailed =>
      'The deletion could not be cancelled right now. Please try again.';

  @override
  String get privTitle => 'Privacy & data';

  @override
  String get privIntro =>
      'With Smart Analysis & Cloud Sync on, bank messages captured by Qirsh — SMS read automatically on Android, or messages you share or send through the iOS shortcut — may be processed as sanitised text on Qirsh servers and by Google Gemini. With it off, messages are parsed on this device. You can export or import your financial data from Data transfer.';

  @override
  String dtxPreviewRows(int rows, String format) {
    return '$rows records • $format';
  }

  @override
  String get dtxQirshPackage => 'Qirsh package';

  @override
  String dtxImportDupesAsNew(int count) {
    return 'Import $count similar transactions as new ones';
  }

  @override
  String dtxAdded(int count) {
    return 'Added: $count';
  }

  @override
  String dtxDuplicates(int count) {
    return 'Duplicates: $count';
  }

  @override
  String dtxQuarantined(int count) {
    return 'Quarantined for safety: $count';
  }

  @override
  String dtxFailed(int count) {
    return 'Failed: $count';
  }

  @override
  String get dtxScanFailed =>
      'The file could not be scanned. Check that it is a valid CSV or ZIP.';

  @override
  String get dtxImportFailed =>
      'The import could not be completed. No unconfirmed data was deleted.';

  @override
  String get dtxReadFailed =>
      'Your data could not be read to prepare the export file.';

  @override
  String get dtxSaveFailed =>
      'The export file could not be saved temporarily on this device.';

  @override
  String get dtxZipShareText =>
      'Your Qirsh financial data file. Keep it somewhere private.';

  @override
  String get dtxCsvShareText => 'Qirsh transactions exported as CSV.';

  @override
  String get dtxShareSheetFailed =>
      'The file is ready, but the share sheet could not be opened. Please try again.';

  @override
  String get dtxTitle => 'Data transfer';

  @override
  String get dtxSubtitle =>
      'Import your data, or keep a portable copy. The file is previewed on your device before anything is written.';

  @override
  String get dtxImportFile => 'Import a file';

  @override
  String get dtxImportFileSub =>
      'A CSV from any app, or a ZIP exported by Qirsh';

  @override
  String get dtxExportCsv => 'Export transactions (CSV)';

  @override
  String get dtxExportCsvSub =>
      'One file that works with Excel and budgeting apps';

  @override
  String get dtxExportZip => 'Export all Qirsh data (ZIP)';

  @override
  String get dtxExportZipSub =>
      'Accounts, transactions, budgets and financial plans';

  @override
  String get dtxRestoreOld => 'Restore an older backup';

  @override
  String get dtxRestoreOldSub =>
      'Temporarily available for encrypted backups you made earlier';

  @override
  String get dtxExportNotice =>
      'Export files contain no raw bank messages, no credentials and no device tokens. The ZIP is not password-protected, so store it somewhere private.';

  @override
  String get dtxReplace => 'Replace';

  @override
  String get dtxReplaceGuestOnly =>
      'Replace is only available for data kept on this device. Because your data is synced to your account, Merge is the only option: it adds the package contents and keeps what you already have.';

  @override
  String get dtxConfirmReplace => 'Confirm the replacement';

  @override
  String dtxReplaceBody(String word) {
    return 'Your current financial data will be hidden and replaced by the contents of the Qirsh package. Type «$word» to continue.';
  }

  @override
  String dtxTypeReplace(String word) {
    return 'Type $word';
  }

  @override
  String get dtxImportPreview => 'Import preview';

  @override
  String get dtxColDate => 'Date column';

  @override
  String get dtxColAmount => 'Amount column';

  @override
  String get dtxDefaultAccount => 'Default account';

  @override
  String get dtxDebit => 'Debit';

  @override
  String get dtxCredit => 'Credit';

  @override
  String get dtxCurrency => 'Currency';

  @override
  String get dtxMerchantDesc => 'Merchant / description';

  @override
  String get dtxNotes => 'Notes';

  @override
  String get dtxTxType => 'Transaction type';

  @override
  String get dtxDateFormat => 'Date format';

  @override
  String get dtxDateAuto => 'Automatic';

  @override
  String get dtxDateDMY => 'Day / month / year';

  @override
  String get dtxDateMDY => 'Month / day / year';

  @override
  String get dtxDateYMD => 'Year / month / day';

  @override
  String get dtxWillCreate =>
      'On confirmation, Qirsh will create any accounts and categories in the file that do not exist yet.';

  @override
  String get dtxMerge => 'Merge';

  @override
  String get dtxConfirmImport => 'Confirm the import';

  @override
  String get dtxImportDone => 'Import complete';

  @override
  String get dtxCacheRepair =>
      'Saved on the server; Qirsh will repair the local cache automatically.';

  @override
  String get pasteTitle => 'Paste a bank message';

  @override
  String get pasteAlreadyExists =>
      'That transaction already exists — we opened it for review.';

  @override
  String get pasteAlreadyRecorded => 'This transaction is already recorded.';

  @override
  String get pasteSimilarNeedsReview =>
      'A similar transaction exists and needs reviewing.';

  @override
  String get pasteAiOffline =>
      'AI analysis is unavailable. No transaction was added. You can add it manually.';

  @override
  String get pasteUnreadableOnDevice =>
      'The message could not be read on this device — add it manually.';

  @override
  String get pasteNotATransaction =>
      'It could not be read as a transaction — add it manually.';

  @override
  String get pasteNothingToOpen =>
      'There is no transaction to open for this message.';

  @override
  String get pasteHint =>
      'You can paste one message or several — each is analysed on its own.';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get pasteAnalyse => 'Analyse messages';

  @override
  String get pasteNeedsReview => 'Needs review';

  @override
  String get pasteAdded => 'Added';

  @override
  String get pasteDuplicate => 'Duplicate';

  @override
  String get pasteSimilar => 'Similar — review';

  @override
  String get pasteNotUnderstood => 'Not understood';

  @override
  String get pasteSummary => 'Message summary';

  @override
  String get pasteReview => 'Review';

  @override
  String get accTypeCash => 'Cash';

  @override
  String get accTypeBank => 'Bank';

  @override
  String get accTypeWallet => 'Wallet';

  @override
  String get accTypeCreditCard => 'Credit card';

  @override
  String txdValueIn(String currency) {
    return 'Value in $currency';
  }

  @override
  String txdAmountIn(String currency) {
    return 'Amount in $currency';
  }

  @override
  String txdAddValueIn(String currency) {
    return 'Add the value in $currency';
  }

  @override
  String get txdPendingToday => 'Unconfirmed · today';

  @override
  String txdPendingDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days ago',
      one: '1 day ago',
    );
    return 'Unconfirmed · $_temp0';
  }

  @override
  String txdLinkedToCard(String last4) {
    return 'Linked to card •••• $last4. The account is unchanged.';
  }

  @override
  String get txdTypePurchase => 'Purchase';

  @override
  String get txdTypeCashWithdrawal => 'Cash withdrawal';

  @override
  String get txdTypeTransfer => 'Transfer';

  @override
  String get txdTypeRefund => 'Refund';

  @override
  String get txdTypeUnknown => 'Unspecified';

  @override
  String get txdSourceCard => 'Card';

  @override
  String get txdSourceAi => 'AI';

  @override
  String get txdSourceImport => 'Imported file';

  @override
  String get txdNotFound => 'That transaction no longer exists';

  @override
  String get txdConfirmed => 'Confirmed';

  @override
  String get txdNeedsReview => 'Needs review';

  @override
  String get txdIgnored => 'Ignored';

  @override
  String get txdUncategorised => 'Uncategorised';

  @override
  String get txdType => 'Type';

  @override
  String get txdSource => 'Source';

  @override
  String get txdCard => 'Card';

  @override
  String get txdNoCard => 'No card';

  @override
  String get txdChange => 'Change';

  @override
  String get txdOriginalCurrency => 'In the original currency';

  @override
  String get txdBalanceAfter => 'Balance after';

  @override
  String get txdNote => 'Note';

  @override
  String get txdStatus => 'Status';

  @override
  String get txdOriginalText => 'Original text';

  @override
  String get txdConfirmIgnored => 'Confirm this ignored transaction';

  @override
  String get txdConfirmTx => 'Confirm transaction';

  @override
  String get txdDeleteTx => 'Delete transaction';

  @override
  String get txdTitle => 'Transaction details';

  @override
  String get txdCardSheetTitle => 'Card on this transaction';

  @override
  String get txdCardSheetNote =>
      'Changing the card does not move the transaction to another account.';

  @override
  String get txdNoCardsOnAccount => 'No cards are registered on this account.';

  @override
  String get txdStaysInAccount =>
      'The transaction stays in the same account, and in all your reports.';

  @override
  String get txdCardRemoved =>
      'Card removed. The transaction is still in the same account.';

  @override
  String get txdConfirmedToast => 'Transaction confirmed.';

  @override
  String get txdDeleteTitle => 'Delete this transaction?';

  @override
  String get txdDeleteBody =>
      'It will be removed from your reports and your balance. This cannot be undone.';

  @override
  String get txdSave => 'Save';

  @override
  String accWillDetachTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions will be detached',
      one: '1 transaction will be detached',
    );
    return '$_temp0';
  }

  @override
  String accWillArchiveCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cards will be archived',
      one: '1 card will be archived',
    );
    return '$_temp0';
  }

  @override
  String accWillArchiveBudgets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count budgets will be archived',
      one: '1 budget will be archived',
    );
    return '$_temp0';
  }

  @override
  String accDetachedTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions detached',
      one: '1 transaction detached',
    );
    return '$_temp0';
  }

  @override
  String accArchivedCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cards archived',
      one: '1 card archived',
    );
    return '$_temp0';
  }

  @override
  String accReassignedGoals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count goals moved',
      one: '1 goal moved',
    );
    return '$_temp0';
  }

  @override
  String accArchivedGoals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count goals archived',
      one: '1 goal archived',
    );
    return '$_temp0';
  }

  @override
  String accReassignedSubs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count subscriptions moved',
      one: '1 subscription moved',
    );
    return '$_temp0';
  }

  @override
  String accArchivedSubs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count subscriptions archived',
      one: '1 subscription archived',
    );
    return '$_temp0';
  }

  @override
  String accDeletedSummary(String summary) {
    return 'Account deleted — $summary.';
  }

  @override
  String get pasteFieldHint =>
      'Paste the bank message text here…\nYou can paste several messages in a row.';

  @override
  String get commonAccountDefinite => 'Account';

  @override
  String get commonOpenImperative => 'Open';

  @override
  String homeVsLastWeek(int percent) {
    return '$percent% vs last week';
  }

  @override
  String homePendingReviewTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions are waiting for your review',
      one: '1 transaction is waiting for your review',
    );
    return '$_temp0';
  }

  @override
  String homeWeekSpentMore(int percent) {
    return 'Heads up — you spent $percent% more than last week. Check the category you spend most on.';
  }

  @override
  String homeWeekSpentLess(int percent) {
    return 'Nicely done — you spent $percent% less than last week. Keep it up and you will save more.';
  }

  @override
  String homeShownTx(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions shown',
      one: '1 transaction shown',
    );
    return '$_temp0';
  }

  @override
  String homePendingSuffix(String count) {
    return '$count pending review';
  }

  @override
  String homeGoalSaved(String amount) {
    return 'Saved $amount';
  }

  @override
  String homeGoalRemaining(String amount) {
    return '$amount to go';
  }

  @override
  String homeNeedPerMonth(String amount) {
    return 'You need $amount a month';
  }

  @override
  String homeArrivesOn(String date) {
    return 'At your current rate you will get there $date';
  }

  @override
  String homeLateBy(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months months late',
      one: '1 month late',
    );
    return '$_temp0';
  }

  @override
  String get homeSessionExpiredTitle => 'Please sign in again';

  @override
  String get homeSessionExpiredBody =>
      'Your session has expired. Sign in to continue.';

  @override
  String get homeSignIn => 'Sign in';

  @override
  String get homeLoadFailed => 'The dashboard could not be loaded right now';

  @override
  String get homeLoadFailedBody =>
      'Check your data, or pull to refresh and try again.';

  @override
  String get homeDailySpend => 'Daily spending';

  @override
  String get homeAllAccounts => 'All accounts';

  @override
  String get homeSetMonthlyBudget =>
      'Set a monthly budget to track what is left';

  @override
  String get homeOverMonthBudget => 'You are over this month’s budget';

  @override
  String get homeSpendAboveUsual => 'Your spending is above usual';

  @override
  String get homeSteady => 'You are steady';

  @override
  String get homeReviewToStayAccurate =>
      'Review them to keep your balances accurate';

  @override
  String get homeAvailableFromMonthBudget =>
      'available from this month’s budget';

  @override
  String get homeNoTxTitle => 'No transactions yet';

  @override
  String get homeNoTxBody =>
      'Paste the debit or deposit message from your bank and the AI will categorise it automatically, on your device.';

  @override
  String get homeMoneyFriend => 'Your money companion';

  @override
  String get homeTodaySpend => 'Spent today';

  @override
  String get homeWeekSpend => 'Spent this week';

  @override
  String get homeMonthSpend => 'Spent this month';

  @override
  String get homeVsYesterday => 'vs yesterday';

  @override
  String get homeVsLastWeekShort => 'vs last week';

  @override
  String get homeGreeting => 'Welcome 👋';

  @override
  String get homeTodayIncome => 'Income today';

  @override
  String get homeWeek => 'Week';

  @override
  String get homeMonth => 'Month';

  @override
  String get homeMonthlySpend => 'Monthly spending';

  @override
  String get homeBudget => 'Budget';

  @override
  String get homeManage => 'Manage';

  @override
  String get homeSubsAndInstalments => 'Subscriptions & instalments';

  @override
  String get homeNoBillsOnAccount =>
      'No subscriptions or instalments on this account.';

  @override
  String get homeNoGoalsOnAccount => 'No goals on this account.';

  @override
  String get homeFinishSetup => 'Finish setting up Qirsh ✨';

  @override
  String get homeEnableBiometrics => 'Turn on biometric lock';

  @override
  String get homeAddSavingsGoal => 'Add a savings goal';

  @override
  String get homePlans => 'Plans';

  @override
  String get homeNoActivePlans => 'No active plans';

  @override
  String get homeCreatePlanHint =>
      'Create a budget plan for a trip or an occasion';

  @override
  String get homeNewPlan => 'New plan';

  @override
  String get homeSavingsCorner => 'Savings corner';

  @override
  String homeCouponExpires(String date) {
    return 'Expires $date';
  }

  @override
  String homeDayAmountSemantics(String day, String amount) {
    return '$day, $amount';
  }

  @override
  String homeVsYesterdayValue(String value) {
    return '$value vs yesterday';
  }

  @override
  String homeExpectedPctOfMonth(int percent) {
    return '$percent% of the month expected';
  }

  @override
  String homeAheadPct(int percent) {
    return '$percent% ahead';
  }

  @override
  String homeBehindPct(int percent) {
    return '$percent% behind';
  }

  @override
  String get homeAtThisRatePrefix =>
      'At this rate you will finish the month at ';

  @override
  String homeOverBudgetBy(String amount) {
    return '$amount over your budget.';
  }

  @override
  String homeNofM(int shown, int total) {
    return '$shown of $total';
  }

  @override
  String homeInDaysShort(int days) {
    return 'in ${days}d';
  }

  @override
  String homePerYearAmount(String amount, String currency) {
    return '$amount $currency a year';
  }

  @override
  String get homeNoBudgetsOnAccount => 'No budgets on this account.';

  @override
  String get homeActiveBudget => 'active budget';

  @override
  String homeAvailableCoupons(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count coupons available',
      one: '1 coupon available',
    );
    return '$_temp0';
  }

  @override
  String get homePartnerOffers => 'Offers from Qirsh partners';

  @override
  String get homeAllCoupons => 'See all coupons';

  @override
  String get homeSpentToday => 'Spent today';

  @override
  String get homeSevenDayAverage => '7-day average';

  @override
  String get homeSetMonthlyBudgetShort => 'Set a monthly budget';

  @override
  String get homeAvailableToday => 'available today';

  @override
  String get homeTodayTransactions => 'Today’s transactions';

  @override
  String get homeTopThreeToday => 'Top 3 today';

  @override
  String get homeUncategorised => 'Uncategorised';

  @override
  String get homeNoMonthlyBudget =>
      'No monthly budget — set one to see what you can spend';

  @override
  String get homeTopCategories => 'Top categories';

  @override
  String get homeSubsPerMonth => 'subscriptions a month';

  @override
  String get homeInstalmentsPerMonth => 'instalments a month';

  @override
  String get homeNextCharge => 'Next charge';

  @override
  String get homeChargeDatesThisMonth => 'Charge dates this month';

  @override
  String get homeInstalmentWord => 'instalment';

  @override
  String get homeNoTxInPeriod => 'No transactions in this period.';

  @override
  String get homeSwipeForMore =>
      'Swipe for more · or “All” for the Transactions page';

  @override
  String gdSavedOfTarget(String saved, String target, String currency) {
    return 'Saved $saved of $target $currency';
  }

  @override
  String gdRemaining(String amount, String currency) {
    return '$amount $currency to go';
  }

  @override
  String gdRemainingWithDays(String amount, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$amount to go · $_temp0';
  }

  @override
  String gdRecommendedDaily(String amount, String currency) {
    return 'Suggested: $amount $currency a day';
  }

  @override
  String cdCardTitle(String last4) {
    return 'Card •••• $last4';
  }

  @override
  String get gdTitle => 'Goal details';

  @override
  String get gdAddToGoal => 'Add to goal';

  @override
  String get gdNotFound => 'That goal no longer exists';

  @override
  String get gdDeleteGoal => 'Delete goal';

  @override
  String get gdContributions => 'Contributions';

  @override
  String get gdNoContributions => 'No contributions yet.';

  @override
  String get gdDeleteTitle => 'Delete this goal?';

  @override
  String get gdDeleteBody =>
      'The goal and all its contributions will be permanently deleted.';

  @override
  String get gdSaveFailed => 'The contribution could not be saved right now.';

  @override
  String get gdAddContribution => 'Add a contribution';

  @override
  String get bdgAmount => 'Amount';

  @override
  String get gdSaveContribution => 'Save contribution';

  @override
  String get cdCardTransactions => 'Transactions on this card';

  @override
  String get cdNoTxYet => 'No transactions yet';

  @override
  String get bfInvalidAmount => 'Invalid amount';

  @override
  String get bfPickFutureDue => 'Pick a due date that is today or later.';

  @override
  String get bfPaidFromForm => 'Paid manually from the form';

  @override
  String get bfSavedButPaymentFailed =>
      'The bill was saved, but the payment could not be recorded — try again with the same details.';

  @override
  String get bfSaveFailed =>
      'Something unexpected went wrong while saving. Please try again.';

  @override
  String get bfAddBill => 'Add bill';

  @override
  String get bfEditBill => 'Edit bill';

  @override
  String get bfSubscription => 'Subscription';

  @override
  String get bfInstalment => 'Instalment';

  @override
  String get bfBillName => 'Bill name';

  @override
  String get bfEnterName => 'Enter a name';

  @override
  String get bfEnterValidAmount => 'Enter a valid amount';

  @override
  String get bfManuallyPaidAmount => 'Amount paid manually';

  @override
  String get bfPaidManuallyFromSub => 'Paid manually against the subscription';

  @override
  String get bfRecordManualHint =>
      'If you paid something and it never showed up as a transaction, record it here';

  @override
  String get bfAmountAboveZero => 'Enter an amount greater than zero';

  @override
  String get bfAccountCurrency => 'Account currency';

  @override
  String get bfLender => 'Lender / provider (Tamara, a bank…)';

  @override
  String get bfTotalInstalments => 'Total number of instalments';

  @override
  String get bfPaidSoFar => 'Paid so far';

  @override
  String get bfPurchaseValue => 'Purchase / loan value';

  @override
  String get bfInterestOptional => 'Interest % (optional)';

  @override
  String get bfHowOften => 'How often?';

  @override
  String get bfEveryHowManyDays => 'Every how many days?';

  @override
  String get bfEnterValidDays => 'Enter a valid number of days';

  @override
  String get bfNextDueDate => 'Next due date';

  @override
  String get bfEnableReminder => 'Turn on the reminder';

  @override
  String get bfConfirmedBill => 'Confirmed bill';

  @override
  String get bfPresetCarInstalment => 'Car instalment';

  @override
  String get bfPresetRent => 'Rent';

  @override
  String get bfPresetPhone => 'Phone';

  @override
  String get bfPresetLaptop => 'Laptop';

  @override
  String get bfPresetFurniture => 'Furniture';

  @override
  String get bfPresetEducation => 'Education';

  @override
  String get bfPresetTravel => 'Travel';

  @override
  String get bfPresetMedical => 'Medical';

  @override
  String get bfPresetWedding => 'Wedding';

  @override
  String get bfPresetGold => 'Gold';

  @override
  String get bfPresetAppliances => 'Home appliances';

  @override
  String get bfPresetComputer => 'Computer';

  @override
  String get bfSearchService => 'Search for a service…';

  @override
  String get bfSearchInstalment => 'Search for an instalment…';

  @override
  String get bfCustomSub => 'Custom subscription';

  @override
  String get bfCustomInstalment => 'Custom instalment';

  @override
  String get bfAddManuallyHint => 'Add the name, amount and frequency yourself';

  @override
  String get bfMostUsed => 'Most used';

  @override
  String get afVodafoneCash => 'Vodafone Cash';

  @override
  String get afOrangeCash => 'Orange Cash';

  @override
  String get afEtisalatCash => 'e& Cash';

  @override
  String get afWePay => 'WE Pay';

  @override
  String get afCurrencyLockedInUse =>
      'The currency cannot be changed on an account that has a balance or transactions.';

  @override
  String get afUsageCheckFailed =>
      'We could not check whether the account is in use, so the currency was not changed.';

  @override
  String get afEnterAccountName => 'Please enter an account name';

  @override
  String get afPaymentDayRange => 'The payment day must be between 1 and 31';

  @override
  String get afSaveFailed =>
      'Something unexpected went wrong — your data is safe, please try again.';

  @override
  String get afDeleteAccount => 'Delete account';

  @override
  String get afDeletePrepFailed =>
      'The deletion could not be prepared — please try again.';

  @override
  String get afCannotDeleteLast => 'You cannot delete your last account.';

  @override
  String get afNeedsExplicitDecision =>
      'The deletion could not proceed — some items need an explicit decision first.';

  @override
  String get afDeleteFailed =>
      'The account could not be deleted — please try again.';

  @override
  String get afEditAccount => 'Edit account';

  @override
  String get afNewAccount => 'New account';

  @override
  String get afAccountName => 'Account name';

  @override
  String get afAccountNameHint =>
      'For example: Cash Egypt, Al Rajhi Bank, USD wallet';

  @override
  String get afCurrencyLockedShort =>
      'The currency cannot be changed on an account in use';

  @override
  String get afDefaultAccountHint =>
      'New transactions are recorded here automatically';

  @override
  String get afExcludeFromTotals => 'Exclude from totals';

  @override
  String get afOpeningBalance => 'Opening balance (optional)';

  @override
  String get afBankAccountNumber => 'Bank account number (optional)';

  @override
  String get afHelpsMatching => 'Helps match your bank messages';

  @override
  String get afCreditLimit => 'Credit limit (optional)';

  @override
  String get afAvailableBalance => 'Available balance (optional)';

  @override
  String get afPaymentDay => 'Payment day (1–31, optional)';

  @override
  String get afProvider => 'Provider';

  @override
  String get afUnspecified => 'Not set';

  @override
  String get afAdvancedOptions => 'Advanced options';

  @override
  String gfRecommendedFor(String amount, String currency, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return 'Suggested: $amount $currency a day for $_temp0.';
  }

  @override
  String bfsSuggestAfterMoreTx(String period) {
    return 'Once you have added more transactions, we will suggest a $period budget that fits.';
  }

  @override
  String bfsSuggestion(String period, String value) {
    return 'Suggested $period budget: $value';
  }

  @override
  String get cfDeleteCardBody =>
      'Deleting the card does not delete its transactions — they stay, with their card number. A card with the same digits may reappear automatically if a new message arrives.';

  @override
  String get mtEnterValidAmount => 'Enter a valid amount.';

  @override
  String get mtPickCategory => 'Choose a category for the transaction.';

  @override
  String get mtSaveFailed => 'The transaction could not be saved right now.';

  @override
  String get mtDeleteBody =>
      'It will be removed from your reports and budgets.';

  @override
  String get mtDeleteFailed =>
      'The transaction could not be deleted right now.';

  @override
  String get mtConfirmFailed =>
      'The transaction could not be confirmed right now.';

  @override
  String get mtAddManually => 'Add a transaction manually';

  @override
  String get mtCategoriesFailed => 'Categories could not be loaded';

  @override
  String get mtMerchantOptional => 'Merchant or source (optional)';

  @override
  String get mtNoteOptional => 'Note (optional)';

  @override
  String get mtSaveEdits => 'Save changes';

  @override
  String get mtAddTransaction => 'Add transaction';

  @override
  String get mtTxConfirmed => 'Transaction confirmed';

  @override
  String get cfEnterValidLast4 => 'Enter a valid last 4 digits';

  @override
  String get cfDuplicateCard =>
      'A card with the same digits already exists on this account';

  @override
  String get cfSaveFailed => 'The card could not be saved — please try again.';

  @override
  String get cfDeleteTitle => 'Delete this card?';

  @override
  String get cfDeleteFailed =>
      'The card could not be deleted — please try again.';

  @override
  String get cfEditCard => 'Edit card';

  @override
  String get cfNewCard => 'New card';

  @override
  String get cfAutoDetected => 'Detected automatically from your messages';

  @override
  String get cfShortNameOptional => 'Short name (optional)';

  @override
  String get cfShortNameHint => 'For example: Salary, Travel';

  @override
  String get cfLast4 => 'Last 4 digits';

  @override
  String get cfNetwork => 'Network';

  @override
  String get cardNetworkGeneric => 'Card';

  @override
  String get cfDesign => 'Design';

  @override
  String get cfAccentOptional => 'Accent colour (optional)';

  @override
  String get cfAccentNone => 'No accent colour';

  @override
  String cfAccentColourName(String colour) {
    String _temp0 = intl.Intl.selectLogic(
      colour,
      {
        'amber': 'Amber',
        'red': 'Red',
        'pink': 'Pink',
        'purple': 'Purple',
        'blue': 'Blue',
        'cyan': 'Cyan',
        'emerald': 'Emerald',
        'lime': 'Lime',
        'orange': 'Orange',
        'teal': 'Teal',
        'other': 'Accent colour',
      },
    );
    return '$_temp0';
  }

  @override
  String get cfLinkedAccount => 'Linked account';

  @override
  String get cfDeleteCard => 'Delete card';

  @override
  String get cfNoAccount => 'No account';

  @override
  String get gfNewGoal => 'New goal';

  @override
  String get gfEditGoal => 'Edit goal';

  @override
  String get gfGoalName => 'Goal name';

  @override
  String get gfEnterGoalName => 'Enter a goal name';

  @override
  String get gfTargetAmount => 'Target amount';

  @override
  String get gfEnterValidAmount => 'Enter a valid amount';

  @override
  String get gfDeadline => 'Deadline';

  @override
  String get gfOptional => 'Optional';

  @override
  String get gfRecommendedAfterDate =>
      'The suggested amount appears once you pick a date.';

  @override
  String get gfAutoSaving => 'Automatic saving';

  @override
  String get gfAutoSavingHint =>
      'Qirsh adds the amount to the goal automatically, every period';

  @override
  String get gfFrequency => 'Frequency';

  @override
  String get gfCreateGoal => 'Create goal';

  @override
  String get gfSaveEdit => 'Save changes';

  @override
  String get gfPickFutureDeadline => 'Pick a deadline that is today or later.';

  @override
  String get bfsNewBudget => 'New budget';

  @override
  String get bfsPickCategory => 'Choose a category';

  @override
  String get bfsSaveBudget => 'Save budget';

  @override
  String get bfsDeleteBody => 'This budget will be permanently deleted.';

  @override
  String get bfsPeriodDaily => 'Daily';

  @override
  String get bfsPeriodWeekly => 'Weekly';

  @override
  String get bfsPeriodMonthly => 'Monthly';

  @override
  String get bfsPeriodYearly => 'Yearly';

  @override
  String get bfsComputingSuggestion =>
      'Working out a suggestion from the last 30 days…';

  @override
  String get bfsUseIt => 'Use it';

  @override
  String get bfsBudgetPeriod => 'Budget period';

  @override
  String get bdgDeleteBudget => 'Delete budget';

  @override
  String get mtKindExpense => 'Expense';

  @override
  String bdsIncludesLegacyManual(String amount, String currency) {
    return 'Includes $amount $currency recorded manually earlier.';
  }

  @override
  String bdsPayAllRemaining(int count) {
    return 'Pay all $count remaining instalments at once';
  }

  @override
  String bdsPaymentForPeriod(String from, String to) {
    return 'This payment covers $from - $to';
  }

  @override
  String bdsPaymentForInstalment(int index, String from, String to) {
    return 'This payment covers instalment $index, $from - $to';
  }

  @override
  String bdsPayRemainingInFull(String amount, String currency) {
    return 'Pay the rest in full ($amount $currency)';
  }

  @override
  String bdsInstalmentNamed(String name) {
    return '$name instalment';
  }

  @override
  String bdsSubscriptionNamed(String name) {
    return '$name subscription';
  }

  @override
  String bdsDeleteBody(String name) {
    return '“$name” will be removed from subscriptions and instalments.';
  }

  @override
  String bdsDeleted(String name) {
    return 'Deleted $name';
  }

  @override
  String bdsInstalmentNumber(int index) {
    return 'Instalment $index';
  }

  @override
  String bdsPaymentNamed(String name) {
    return '$name payment';
  }

  @override
  String plCardShort(String last4) {
    return 'Card ••$last4';
  }

  @override
  String plPerDayLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '/day · $_temp0 left';
  }

  @override
  String plDeleteBody(String name) {
    return 'The “$name” plan will be deleted. Its transactions are not affected.';
  }

  @override
  String plOfBudget(String amount, String currency) {
    return 'of $amount $currency';
  }

  @override
  String get bdsInstalmentValue => 'Instalment amount';

  @override
  String get bdsTotalPaid => 'Total paid';

  @override
  String get bdsRecordedPayments => 'Recorded payments';

  @override
  String get bdsPaid => 'Paid';

  @override
  String get bdsRemaining => 'Remaining';

  @override
  String get bdsProgress => 'Progress';

  @override
  String get bdsRecordInstalmentPayment => 'Record an instalment payment';

  @override
  String get bdsRecordPayment => 'Record a payment';

  @override
  String get bdsPaymentHistory => 'Payment history';

  @override
  String get bdsNoManualInstalmentPayments =>
      'No instalment payments have been recorded manually yet.';

  @override
  String get bdsNoManualSubPayments =>
      'No subscription payments have been recorded manually yet.';

  @override
  String get bdsSuggestedToLink => 'Transactions you could link';

  @override
  String get bdsNameMatchNote =>
      'Matched by name — not counted as paid until you link it as a payment.';

  @override
  String get bdsNoSuggestions => 'No transactions to suggest for linking.';

  @override
  String get bdsOptionalNote => 'Optional note';

  @override
  String get bdsRecordFailed =>
      'The payment could not be recorded right now. Please try again.';

  @override
  String get bdsSavedButNotLinked =>
      'The transaction was saved but the payment could not be linked. Try again — it will not be duplicated.';

  @override
  String get bdsRecord => 'Record';

  @override
  String get bdsPaymentRecorded =>
      'The payment was recorded and added to your transactions.';

  @override
  String get bdsDeleteBillTitle => 'Delete this bill?';

  @override
  String get bdsDeleteBillFailed => 'The bill could not be deleted right now.';

  @override
  String get bdsDeletePaymentTitle => 'Delete this payment?';

  @override
  String get bdsDeletePaymentBody =>
      'This manual payment record will be permanently deleted.';

  @override
  String get bdsDeletePaymentFailed =>
      'The payment could not be deleted right now.';

  @override
  String get plSubtitle => 'A budget for every occasion, tracking itself';

  @override
  String get plLoadFailed => 'Could not load';

  @override
  String get plNoPlans => 'No plans yet';

  @override
  String get plEmptyBody =>
      'Create a plan for a trip or an occasion: a budget, a period, and the cards you will spend from — Qirsh tracks it for you.';

  @override
  String get plAllSpendInPeriod => 'All spending in the period';

  @override
  String get plSpecificAccounts => 'Specific accounts';

  @override
  String get plEnded => 'Ended';

  @override
  String get plPlanOptions => 'Plan options';

  @override
  String get plDeleteTitle => 'Delete this plan?';

  @override
  String get plDeleteFailed => 'The plan could not be deleted right now.';

  @override
  String get plDetails => 'Plan details';

  @override
  String get plNotFound => 'That plan no longer exists';

  @override
  String get plLinkTransaction => 'Link a transaction';

  @override
  String get plHistory => 'Plan history';

  @override
  String get plTxLoadFailed => 'Transactions could not be loaded';

  @override
  String get plNoLinkedTx => 'No linked transactions';

  @override
  String get plLinkHint =>
      'Link an existing transaction, or choose an account or card for the plan.';

  @override
  String get plLinkToPlan => 'Link a transaction to this plan';

  @override
  String get plNoSuitableTx => 'No suitable transactions';

  @override
  String get plAllLinkedAlready =>
      'Every suitable transaction is already linked, or not yet confirmed.';

  @override
  String get pcrWhyBody =>
      'Older budgets and goals do not store a currency alongside the amount. Qirsh will not guess one — you choose how each should be treated. No amount changes and nothing is deleted. Goal contributions follow the goal’s currency automatically.';

  @override
  String pcrNoCurrencySet(String amount) {
    return '$amount · no currency set';
  }

  @override
  String pcrConfirmedFor(String currency) {
    return '$currency confirmed for every existing budget and goal.';
  }

  @override
  String bkLastBackup(String date, String time) {
    return 'Last backup: $date · $time';
  }

  @override
  String get pcrTitle => 'Confirm your planning currency';

  @override
  String get pcrListChanged => 'Your budgets or goals have changed';

  @override
  String get pcrListChangedBody =>
      'Your earlier decision no longer matches the current list. Refresh it, then confirm the currencies again.';

  @override
  String get pcrRefreshList => 'Refresh the list';

  @override
  String get pcrWhyTitle => 'Why do we need you to confirm?';

  @override
  String get pcrDefaultSuggestion => 'Default suggestion';

  @override
  String get pcrSuggestionNote =>
      'This is only a suggestion based on your current currency — nothing is saved until you confirm.';

  @override
  String get pcrHowToConfirm => 'How to confirm';

  @override
  String get pcrOneCurrencyForAll => 'One currency for everything';

  @override
  String get pcrOneCurrencyHint =>
      'Every existing budget and goal uses the same currency';

  @override
  String get pcrPerItem => 'Choose a currency per item';

  @override
  String get pcrPerItemHint =>
      'Pick a different currency for a budget or goal where you need to';

  @override
  String get pcrSaveSelected => 'Save the selected currencies';

  @override
  String get pcrNotNow => 'Not now — I will finish later';

  @override
  String get pcrAllOneCurrency => 'Everything in one currency';

  @override
  String get pcrCurrencyCode => 'Currency code';

  @override
  String get pcrWillRecord =>
      'Confirming records that every existing budget and goal uses this code.';

  @override
  String get pcrUnsupportedCodeLong =>
      'That currency code is not supported. Use a three-letter code such as EGP or SAR.';

  @override
  String get pcrUnsupportedCode => 'That currency code is not supported.';

  @override
  String get pcrSaveFailed =>
      'The confirmation could not be saved right now. None of your financial data changed.';

  @override
  String get pcrTreatAsCurrency => 'Treat it as this currency';

  @override
  String get pcrNothingToFix => 'Nothing needs fixing';

  @override
  String get pcrNothingToFixBody =>
      'There are no older budgets or goals whose currency needs confirming.';

  @override
  String get pcrPerItemSaved =>
      'A separate currency was saved for every existing budget and goal.';

  @override
  String get pcrConfirmed => 'Currencies confirmed';

  @override
  String get pcrBackToSettings => 'Back to Settings';

  @override
  String get pcrReadFailed =>
      'Your planning data could not be read. Nothing was changed.';

  @override
  String get rcTitle => 'Create a financial report';

  @override
  String get rcPeriod => 'Period';

  @override
  String get rcCustom => 'Custom';

  @override
  String get rcPickRange => 'Choose a range';

  @override
  String get accTitleShort => 'Accounts';

  @override
  String get rcLanguage => 'Language';

  @override
  String get rcArabic => 'Arabic';

  @override
  String get rcTxDetails => 'Transaction details';

  @override
  String get rcMerchantNames => 'Merchant names';

  @override
  String get rcAccountNames => 'Account names';

  @override
  String get rcBalances => 'Balances';

  @override
  String get rcNotes => 'Notes';

  @override
  String get rcPrivacyMode => 'Privacy mode (hide amounts)';

  @override
  String get rcCreateReport => 'Create report';

  @override
  String get rcNoDataInPeriod => 'No data in this period';

  @override
  String get rcFontsFailed => 'The fonts could not be loaded';

  @override
  String get rcPdfFailed => 'The PDF could not be created';

  @override
  String get rcSaveFailed => 'The file could not be saved';

  @override
  String get rcCancelled => 'Cancelled';

  @override
  String get rcUnexpectedError => 'Something unexpected went wrong';

  @override
  String get rcGenerating => 'Creating your report…';

  @override
  String get rcStepCollect => 'Collecting data';

  @override
  String get rcStepMetrics => 'Working out the figures';

  @override
  String get rcStepDraw => 'Drawing the pages';

  @override
  String get rcStepSave => 'Saving the file';

  @override
  String get rcStepDone => 'Done';

  @override
  String get bkTitle => 'Backup & restore';

  @override
  String get bkSubtitle =>
      'Save your financial data and bring it back, securely and privately, whenever you need to.';

  @override
  String get bkCreateAccountTitle => 'Create an account to turn on backup';

  @override
  String get bkCreateAccountBody =>
      'You can use Qirsh locally without an account. Backup needs a sign-in so the encrypted copy can be tied to you.';

  @override
  String get bkNoBackupYet => 'No backup yet';

  @override
  String get bkBackupNow => 'Back up now';

  @override
  String get bkTurnOff => 'Turn off backup';

  @override
  String get bkLocalDataStays => 'Your local data stays when you turn it off.';

  @override
  String get bkEnableFailed =>
      'Backup could not be turned on. Please try again.';

  @override
  String get bkEncryptedWeCannotRead => 'An encrypted copy we cannot read';

  @override
  String get bkOptionalOffByDefault =>
      'Backup is optional and off by default. Turn it on and your data is encrypted end-to-end, and restorable on any device.';

  @override
  String get bkPassphrase => 'Encryption passphrase';

  @override
  String get bkContinue => 'Continue';

  @override
  String get bkRecoveryCode => 'Recovery code';

  @override
  String get bkCopyCode => 'Copy the code';

  @override
  String get bkLoseBothWarning =>
      'If you lose both the passphrase and the code, we cannot recover your backup.';

  @override
  String get bkSavedTheCode => 'I have saved the code and I understand';

  @override
  String get bkEnable => 'Turn on';

  @override
  String get bkRestoreFromBackup => 'Restore from a backup';

  @override
  String get pcrOldAmount => 'Previous amount';

  @override
  String get pcrOldTarget => 'Previous target amount';

  @override
  String get cesTitle => 'Add a transaction';

  @override
  String get cesPasteBankMessage => 'Paste a bank message';

  @override
  String get cesPasteHint =>
      'We read the message and prepare the transaction for review.';

  @override
  String get cesManualEntry => 'Add manually';

  @override
  String get cesManualHint => 'Enter the transaction details yourself.';

  @override
  String get bkStateDisabled => 'Backup is off';

  @override
  String get bkStateEnabling => 'Turning on…';

  @override
  String get bkStatePreparing => 'Preparing…';

  @override
  String get bkStateEncrypting => 'Encrypting…';

  @override
  String get bkStateUploading => 'Uploading…';

  @override
  String get bkStateVerifying => 'Verifying…';

  @override
  String get bkStateDownloading => 'Downloading…';

  @override
  String get bkStateProtected => 'Protected';

  @override
  String get bkStateWaitingForConnection => 'Waiting for a connection';

  @override
  String get bkStateWillRetry => 'Will retry';

  @override
  String get bkStateNeedsSignIn => 'Sign-in required';

  @override
  String get bkStateNeedsCloudSync => 'Cloud sync must be on';

  @override
  String get bkStateFailedRetryable => 'Failed — try again';

  @override
  String get bkStateFailed => 'Failed';

  @override
  String get bkStateDeleting => 'Deleting the remote copy…';

  @override
  String get bkStateCancelled => 'Cancelled';

  @override
  String get iosStep1 => 'Open the Shortcuts app';

  @override
  String get iosStep1Body =>
      'Open Shortcuts, then the Automation tab at the bottom.';

  @override
  String get iosStep2 => 'Create a new Automation';

  @override
  String get iosStep2Body =>
      'Tap New Automation or the + sign, then choose Message.';

  @override
  String get iosStep3 => 'Narrow it to bank messages';

  @override
  String get iosStep4 => 'Run it immediately';

  @override
  String get iosStep4Body =>
      'Choose Run Immediately. If Notify When Run appears, turn it off, then tap Next.';

  @override
  String get iosStep5 => 'Pick the Qirsh shortcut';

  @override
  String get iosStep5Body =>
      'Tap New Blank Automation and search for Process Bank SMS.';

  @override
  String get iosStep6 => 'Pass the message text through';

  @override
  String get iosStep6Body =>
      'Set SMS Text to Shortcut Input. Keep Sender as the message sender. Qirsh records the capture time automatically.';

  @override
  String get iosStep7 => 'Match the final shape';

  @override
  String get iosStep7Body =>
      'It must read: Receive messages as input, then Process Bank SMS with SMS Text = Shortcut Input. Open the action’s details and turn off Show When Run if it appears.';

  @override
  String get iosStep8 => 'Save the shortcut';

  @override
  String get iosStep8Body =>
      'Tap Done. From then on, any matching bank message becomes a transaction in Qirsh.';

  @override
  String get countrySA => 'Saudi Arabia';

  @override
  String get countryAE => 'United Arab Emirates';

  @override
  String get countryEG => 'Egypt';

  @override
  String get countryKW => 'Kuwait';

  @override
  String get countryQA => 'Qatar';

  @override
  String get countryBH => 'Bahrain';

  @override
  String get countryOM => 'Oman';

  @override
  String get countryJO => 'Jordan';

  @override
  String get setupSaveFailed =>
      'Your settings could not be saved. Please try again.';

  @override
  String get setupFinishFailed =>
      'Setup could not be completed. Please try again.';

  @override
  String iosStep3Body(String currency) {
    return 'In Message Contents, enter a currency code such as $currency — repeat later for any other currency.';
  }

  @override
  String pfCurrencyOnly(String currency) {
    return 'The plan counts $currency transactions only — an account in any other currency is not included.';
  }

  @override
  String pfCardNamed(String last4) {
    return 'Card $last4';
  }

  @override
  String obPerMonth(String amount, String currency) {
    return '$amount $currency/month';
  }

  @override
  String get aiTitle => 'Split your income';

  @override
  String get aiSubtitle =>
      'Enter your income and split it into envelopes — you can change any number.';

  @override
  String get aiSaving => 'Saving…';

  @override
  String get aiSaveSplit => 'Save the split';

  @override
  String get aiMonthlyIncome => 'Your monthly income';

  @override
  String get aiSuggestSplit => 'Suggest a split';

  @override
  String get aiSavings => 'Savings';

  @override
  String get aiCreateGoalHint =>
      'Create a savings goal and we will move it across automatically each month.';

  @override
  String get aiAutoToGoal => 'Moved to a goal automatically';

  @override
  String get aiAllocated => 'Allocated to envelopes';

  @override
  String get aiUnallocated => 'Left unallocated';

  @override
  String get aiOverIncomeBy => 'Over your income by';

  @override
  String get pfEditPlan => 'Edit plan';

  @override
  String get pfSubtitle =>
      'A trip, a wedding, Ramadan… a budget for a set period that tracks itself.';

  @override
  String get pfSavePlan => 'Save plan';

  @override
  String get pfPlanName => 'Plan name';

  @override
  String get pfPlanNameHint => 'For example: Dubai trip';

  @override
  String get pfPlanBudget => 'Plan budget';

  @override
  String get pfAccountsToSpendFrom => 'The accounts you will spend from';

  @override
  String get pfCardsOptional => 'Cards (optional)';

  @override
  String get pfNoScopeHint =>
      'If you pick no account or card, the plan counts all spending in the period.';

  @override
  String ctsFeeAlsoAdded(String amount, String currency) {
    return 'We found two transactions in the message: we also added the fee/tax of $amount $currency (in a different currency).';
  }

  @override
  String ctsForeignCurrencyHint(String amount, String foreign, String home) {
    return 'A transaction in another currency ($amount $foreign). Enter what it came to in $home so it counts — or leave it and edit it later, once the charged amount arrives.';
  }

  @override
  String get pcsIntro =>
      'This item was edited on another device too. Choose which version to keep.';

  @override
  String get ctsNeedsCategory => 'Needs a category — pick one below.';

  @override
  String get ctsAiParsed => 'Read by AI — confirm the amount and the category.';

  @override
  String get ctsLowConfidence =>
      'The reading is not fully certain — check the details before confirming.';

  @override
  String get ctsReviewBeforeConfirm => 'Check the details before confirming.';

  @override
  String get ctsTitle => 'Review transaction';

  @override
  String get ctsCategoryLabel => 'Category:';

  @override
  String get ctsCategoryUpdateFailed => 'The category could not be updated.';

  @override
  String get ctsConfirmFailed =>
      'The transaction could not be confirmed. Please try again.';

  @override
  String get ctsEditDetails => 'Edit details';

  @override
  String get adTitle => 'Account';

  @override
  String get adNotFound => 'That account no longer exists';

  @override
  String get adCards => 'Cards';

  @override
  String get adNoCards =>
      'No cards yet — they appear automatically from your messages, or add one yourself.';

  @override
  String get adRecentTx => 'Recent transactions';

  @override
  String get pcsLoadFailed =>
      'The conflicts could not be loaded — please try again.';

  @override
  String get pcsNoConflicts => 'No conflicts';

  @override
  String get pcsAllSynced => 'All your planning data is in sync.';

  @override
  String get pcsTitle => 'Resolve sync conflicts';

  @override
  String get pcsKeptMine => 'Your version was kept.';

  @override
  String get pcsKeptTheirs => 'The other device’s version was kept.';

  @override
  String get pcsKeepMine => 'Keep mine';

  @override
  String get pcsKeepTheirs => 'The other device’s version';

  @override
  String get rprUnsupportedCode => 'Unsupported currency code';

  @override
  String get rprTitle => 'Currency for the backup’s data';

  @override
  String get rprPerItem => 'A currency per item';

  @override
  String get rprTreatAllAs => 'Treat everything as this currency';

  @override
  String get rprContinueRestore => 'Continue the restore';

  @override
  String get rprCancelRestore => 'Cancel the restore';

  @override
  String get rprGoal => 'Goal';

  @override
  String get rprBudget => 'Budget';

  @override
  String get psrTitle => 'Items waiting for a currency (from sync)';

  @override
  String get psrUnsupported => 'Unsupported currency';

  @override
  String get psrConfirmed => 'Confirmed';

  @override
  String get psrConfirmFailed => 'Could not confirm — please try again';

  @override
  String get psrCurrencyExample => 'Currency (for example: KWD)';

  @override
  String get adsSubsAndBills => 'Subscriptions & bills';

  @override
  String get adsPickDestination =>
      'Choose where each active subscription should go — none is deleted automatically.';

  @override
  String get adsChoose => 'Choose…';

  @override
  String get adsArchive => 'Archive';

  @override
  String get rpTitle => 'Report preview';

  @override
  String get rpShare => 'Share';

  @override
  String get rpPrint => 'Print';

  @override
  String get rpShareFinancialData => 'Share financial data';

  @override
  String get rpShareWarning =>
      'This report contains balances and merchant names. Do you want to share it?';

  @override
  String get rpFinancialReport => 'Financial report';

  @override
  String get psrIntro =>
      'These rows arrived from sync without a currency. Pick the right one for each — Qirsh will not guess, and no amount changes.';

  @override
  String psrAmount(String amount) {
    return 'Amount: $amount';
  }

  @override
  String adsWillDetach(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions will be detached',
      one: '1 transaction will be detached',
    );
    return '$_temp0 (their history is kept in full).';
  }

  @override
  String adsMoveTo(String account) {
    return 'Move to $account';
  }

  @override
  String get rprIntro =>
      'The backup does not record a currency for budgets and goals. Choose how you want those treated when restoring.';

  @override
  String rprLegacyAmount(String amount) {
    return 'Previous amount: $amount · no currency set';
  }

  @override
  String get dpeCsvTooLarge => 'The CSV file is larger than 25MB.';

  @override
  String get dpeCsvEmpty => 'The CSV file is empty.';

  @override
  String get dpeCsvTooManyRows => 'The CSV file has more than 100,000 rows.';

  @override
  String get dpeCsvBadHeaders => 'The CSV column headers are not valid.';

  @override
  String get dpeCsvDuplicateColumns => 'The CSV file has duplicate columns.';

  @override
  String get dpeFileTooLarge => 'The file is larger than 25MB.';

  @override
  String get dpeZipInvalid => 'The ZIP file is invalid or damaged.';

  @override
  String get dpePickCsvOrZip => 'Choose a CSV or ZIP file.';

  @override
  String get dpeFixErrorsFirst =>
      'Fix the errors in the file before importing.';

  @override
  String get dpeExternalCsvMergeOnly =>
      'An external CSV can only be merged, not replaced.';

  @override
  String get dpeReplaceUnavailableMixed =>
      'Replace is not available while mixed data sources are active.';

  @override
  String get dpeReplaceUnavailableCloud =>
      'Replace is only available for data kept on this device. Because your data is synced to your account, use Merge instead.';

  @override
  String get dpeReselectFile => 'Select the file again, then try once more.';

  @override
  String get dpeCsvMappingIncomplete => 'The CSV column mapping is incomplete.';

  @override
  String get dpeExportTooLarge => 'The export exceeded the 100MB limit.';

  @override
  String get dpePackageAlreadyImported =>
      'This package was already imported, in a different mode.';

  @override
  String get dpeForeignPairRequired =>
      'The foreign amount and its currency must both be present.';

  @override
  String dpeUnsupportedTable(String value) {
    return 'Unsupported table: $value';
  }

  @override
  String get dpeOtherCategoryMissing => 'The “Other” category is missing.';

  @override
  String dpeMissingValue(String value) {
    return '$value is missing.';
  }

  @override
  String dpeInvalidCurrencyCode(String value) {
    return 'Invalid currency code: $value';
  }

  @override
  String dpeInvalidMinorAmount(String value) {
    return 'Invalid exact amount: $value';
  }

  @override
  String dpeInvalidAmount(String value) {
    return 'Invalid amount: $value';
  }

  @override
  String dpeInvalidDate(String value) {
    return 'Invalid date: $value';
  }

  @override
  String dpeExportFileMissing(String value) {
    return '$value is missing from the export.';
  }

  @override
  String get dpeZipTooLarge => 'The ZIP file is larger than 25MB.';

  @override
  String get dpePackageUnsafePath =>
      'The Qirsh package contains a path or file that is not allowed.';

  @override
  String get dpePackageInflatedTooLarge =>
      'The package is larger than 100MB once unpacked.';

  @override
  String dpeEntryUnreadable(String value) {
    return '$value could not be read.';
  }

  @override
  String dpeEntrySizeMismatch(String value) {
    return 'The size of $value does not match the ZIP header.';
  }

  @override
  String get dpeManifestMissing => 'manifest.json is missing.';

  @override
  String get dpeManifestInvalid => 'manifest.json is not valid.';

  @override
  String get dpeNotAQirshExport => 'This is not a Qirsh export file.';

  @override
  String get dpeNewerVersion =>
      'This file comes from a newer version. Update Qirsh and try again.';

  @override
  String get dpeUnsupportedVersion =>
      'This Qirsh file version is not supported.';

  @override
  String get dpePackageMetaIncomplete => 'The package metadata is incomplete.';

  @override
  String dpePackageEntryMissing(String value) {
    return '$value is missing from the package.';
  }

  @override
  String dpeIntegrityCheckFailed(String value) {
    return 'The integrity check for $value failed.';
  }

  @override
  String get dpePackageTooManyRows =>
      'The package exceeds 100,000 rows in total.';

  @override
  String get repoErrNetwork =>
      'Could not reach the server — check your connection and try again.';

  @override
  String get repoErrAuth => 'Please sign in to continue.';

  @override
  String repoErrValidation(String detail) {
    return 'Invalid data: $detail';
  }

  @override
  String get repoErrForbidden => 'You do not have permission to do that.';

  @override
  String get repoErrDuplicate => 'That item already exists.';

  @override
  String get repoErrNotFound => 'That item no longer exists, or was deleted.';

  @override
  String get repoErrServer =>
      'The server had a problem — please try again later.';

  @override
  String get repoErrUnknown =>
      'Something unexpected went wrong — please try again.';

  @override
  String get cardThemeNavy => 'Navy';

  @override
  String get cardThemeEmerald => 'Emerald';

  @override
  String get cardThemePlum => 'Plum';

  @override
  String get cardThemeSunset => 'Sunset';

  @override
  String get cardThemeGraphite => 'Graphite';

  @override
  String get cardThemeOcean => 'Ocean';

  @override
  String get authGoogleUnavailable =>
      'Google sign-in is not available in this build. Use another method.';

  @override
  String get authGoogleCancelled => 'Google sign-in was cancelled.';

  @override
  String get authGoogleTokenUnreadable =>
      'We could not read the Google sign-in token.';

  @override
  String get authAppleCancelled => 'Apple sign-in was cancelled.';

  @override
  String get authAppleFailed => 'Apple sign-in failed.';

  @override
  String get authAppleTokenUnreadable =>
      'We could not read the Apple sign-in token.';

  @override
  String get navHome => 'Home';

  @override
  String get navTransactions => 'Activity';

  @override
  String get navBudgets => 'Budgets';

  @override
  String get navMore => 'More';

  @override
  String get navAnalytics => 'Insights';

  @override
  String navExpandBar(String tab) {
    return 'Open the navigation bar — $tab';
  }

  @override
  String get bkeNoLocalBackup => 'There is no backup on this device.';

  @override
  String get bkeNeedsReenable => 'Backup needs to be set up again.';

  @override
  String get bkeSignInRequired => 'Sign in first to turn on backup.';

  @override
  String get bkeStateSaveFailed =>
      'Could not save the backup state. Please try again.';

  @override
  String get bkeBucketMissing =>
      'Backup is not fully set up: create a Storage bucket named backups in Supabase, then try again.';

  @override
  String bkeUploadFailed(String value) {
    return 'Uploading the backup failed: $value';
  }

  @override
  String get bkeWrongPassphrase => 'That backup passphrase is not correct.';

  @override
  String get bkeInvalidBackupFile => 'That backup file is not valid.';

  @override
  String get bkeDecryptFailed =>
      'Could not open the backup: the passphrase is wrong, or the file is damaged.';

  @override
  String get bkeUnsupportedEnvelopeVersion =>
      'This backup comes from an unsupported version. Update Qirsh and try again.';

  @override
  String get bkeBackupFromNewerApp =>
      'This backup comes from a newer version of the app. Update Qirsh and try again.';

  @override
  String bkeUnsupportedBackupVersion(String value) {
    return 'This backup comes from an unsupported version ($value). Update Qirsh.';
  }

  @override
  String get bkeBackupCorrupt =>
      'The backup is damaged or incomplete. Nothing was restored.';

  @override
  String bkeTableCorrupt(String value) {
    return 'The backup is damaged at the “$value” table. Nothing was restored.';
  }

  @override
  String bkeRequiredTableMissing(String value) {
    return 'The backup is incomplete — the “$value” table is missing. Nothing was restored.';
  }

  @override
  String bkeUnsupportedTable(String value) {
    return 'The backup contains an unsupported table, “$value”. Nothing was restored.';
  }

  @override
  String bkeUnexpectedSensitiveField(String value) {
    return 'The backup contains an unexpected sensitive field, “$value”. Nothing was restored.';
  }

  @override
  String bkeInvalidMoneyValue(String value) {
    return 'Restore stopped: invalid money value “$value”.';
  }

  @override
  String get bkeAccountChanged =>
      'The account changed while the restore was being prepared. Please try again.';

  @override
  String get bkeRelationalIntegrity =>
      'Restore stopped: the backup breaks the links between your records.';

  @override
  String get bkePlanningInconsistent =>
      'Restore stopped: your planning data was inconsistent afterwards.';

  @override
  String get bkeForeignKeys =>
      'Could not re-enable the relationship checks after the restore.';

  @override
  String bkeOrphanGoalContribution(String value) {
    return 'Restore stopped: a goal contribution has no goal (“$value”).';
  }

  @override
  String get bkePrepareFailed =>
      'Could not prepare the restore. Check the file and the passphrase.';

  @override
  String get bkeRestoreFailedNoChanges =>
      'The restore failed, and your current data is unchanged.';

  @override
  String get bkeCommittedPendingBackupState =>
      'Your data was restored, but finishing the backup protection failed. Please try again.';

  @override
  String get bkeRestoredDbNotReady =>
      'The restore finished, but the database could not be prepared. Restart Qirsh.';

  @override
  String get bkeNeedsDatabaseRepair =>
      'The restore failed and the database needs repair.';

  @override
  String get startPreparing => 'Getting Qirsh ready…';

  @override
  String get startTookLonger => 'Startup is taking longer than expected';

  @override
  String get startFailed => 'Qirsh could not start';

  @override
  String get startCheckConnection =>
      'Check your internet connection and try again.';

  @override
  String startStepId(String step) {
    return 'Step: $step';
  }

  @override
  String get startRetry => 'Try again';

  @override
  String get dbRecoveryTitle => 'We could not open your data';

  @override
  String get dbRecoveryBody =>
      'The data file is damaged, or encrypted with a key that no longer matches, and cannot be opened. You can reset the app’s data and start fresh (only transactions saved on this device are deleted).';

  @override
  String get dbRecoveryReset => 'Reset the data';

  @override
  String get lockTitle => 'Qirsh is locked';

  @override
  String get lockBody =>
      'Unlock the app to verify it is you and see your finances.';

  @override
  String get lockVerifying => 'Verifying…';

  @override
  String get lockUnlock => 'Unlock Qirsh';

  @override
  String get lockPrompt => 'Unlock Qirsh to protect your financial data.';

  @override
  String get bdConfirmTitle => 'Confirm the bank';

  @override
  String bdIsSenderFrom(String bank) {
    return 'Is this sender $bank?';
  }

  @override
  String get bdSender => 'Sender';

  @override
  String get bdCountry => 'Country';

  @override
  String get bdConfidence => 'Confidence';

  @override
  String get bdKey => 'Key';

  @override
  String bdReason(String reason) {
    return 'Reason: $reason';
  }

  @override
  String bdReasonDefault(String bank) {
    return 'Reason: $bank is a strong match for this sender and message pattern.';
  }

  @override
  String get bdConfirmThis => 'Yes, this bank';

  @override
  String get bdNotThis => 'Not this bank';

  @override
  String get bdAskLater => 'Ask me later';

  @override
  String get smsShareTitle => 'Share a bank message with Qirsh';

  @override
  String get smsShareBody =>
      'Without SMS read permission: open the bank message, tap Share, and choose Qirsh. With Smart Analysis off, the text is analysed only on your device.';

  @override
  String get smsShareExample =>
      'For example: “Purchase SAR 45 at BURGER BOUTIQUE”';

  @override
  String get smsShareFallback =>
      'If your Messages app has no Share button, pasting manually is the quick alternative.';

  @override
  String get smsPasteManually => 'Paste a message manually';

  @override
  String get smsPasteLater => 'Later — I’ll paste manually';

  @override
  String get rngPickAccount => 'Choose an account';

  @override
  String get rngPickPeriod => 'Choose a period';

  @override
  String get rngFrom => 'From';

  @override
  String get rngTo => 'To';

  @override
  String get rngApplyCustom => 'Apply this period';

  @override
  String get ccTitle => 'Change the category';

  @override
  String get ccScope => 'Apply to';

  @override
  String get ccThisOnly => 'This transaction only';

  @override
  String get ccAllMerchant => 'Every transaction from this merchant';

  @override
  String get ccSave => 'Save the change';

  @override
  String get commonClose => 'Close';

  @override
  String get commonHide => 'Hide';

  @override
  String get commonSkip => 'Skip';

  @override
  String get commonDefault => 'Default';

  @override
  String get commonReview => 'Review';

  @override
  String get commonSmart => 'Smart';

  @override
  String get commonPending => 'Pending';

  @override
  String get commonTransaction => 'Transaction';

  @override
  String get commonUnderReview => 'Under review';

  @override
  String get chartCategories => 'Categories';

  @override
  String get chartCategoriesEmpty =>
      'Add confirmed transactions to see the category breakdown here.';

  @override
  String get chartRefund => 'Refund';

  @override
  String get chartTotal => 'Total';

  @override
  String get prgTitle => 'Planning is temporarily unavailable';

  @override
  String get prgBody =>
      'Before you use budgets and goals, we need to confirm the currency your existing planning data is held in. No amount will be changed.';

  @override
  String get prgConfirmNow => 'Confirm the currency';

  @override
  String get prgNotNow => 'Not now';

  @override
  String get fuTitle => 'Update required';

  @override
  String get fuBody => 'Please update Qirsh to keep using it.';

  @override
  String get fuNow => 'Update now';

  @override
  String get rpConfirmTitle => 'Confirm the restore';

  @override
  String get rpConfirmBody =>
      'The backup will replace your current data on this device. This cannot be undone once you confirm. Continue?';

  @override
  String get rpCancel => 'Cancel';

  @override
  String get rpRestore => 'Restore';

  @override
  String get rpPrivacyNote =>
      'A restore needs only your passphrase or recovery code. Qirsh cannot read the backup without them.';

  @override
  String get adNoticeTitle => 'An ad before your report';

  @override
  String get adNoticeBody =>
      'A short ad may play before the report is generated.';

  @override
  String get adNoticeCancel => 'Cancel';

  @override
  String get adNoticeContinue => 'Continue';

  @override
  String get plansFrom => 'from';

  @override
  String get plansOverBudget => 'over budget by';

  @override
  String get plansRemaining => 'left';

  @override
  String get pcrConfirmAll => 'Confirm that every current budget and goal uses';

  @override
  String get cardNetworkMada => 'mada';

  @override
  String get budgetsAllAccounts => 'All accounts';

  @override
  String txnCountSuffix(String count) {
    return '· $count transactions';
  }

  @override
  String get a11yDebit => 'debit';

  @override
  String get a11yCredit => 'credit';

  @override
  String get a11yPending => 'pending';

  @override
  String get a11yAi => 'AI';

  @override
  String chartSliceCount(String count) {
    return '$count transactions';
  }

  @override
  String planSpent(String amount) {
    return 'Spent: $amount';
  }

  @override
  String planEnds(String date) {
    return 'Ends: $date';
  }

  @override
  String planPerDayLeft(String amount) {
    return '$amount a day available for the rest of the plan';
  }

  @override
  String get iiUnreadableDate => 'We could not read the date.';

  @override
  String get iiCurrencyNotIso =>
      'The currency must be a three-letter ISO code.';

  @override
  String get iiAmountInvalidOrZero => 'The amount is not valid, or it is zero.';

  @override
  String get iiCsvNeedsTwoColumns =>
      'A CSV needs at least two columns: the date and the amount.';

  @override
  String get iiHeadersNotRecognised =>
      'We did not recognise the headers. Check the column mapping.';

  @override
  String iiDuplicatesFound(String value) {
    return '$value similar transactions already exist and will be shown before saving.';
  }

  @override
  String iiRowPrefix(String row) {
    return 'Row $row: ';
  }

  @override
  String conflictBudgetLabel(String amount) {
    return 'Budget $amount';
  }

  @override
  String get cardSourceAuto => 'Detected from bank messages';

  @override
  String get cardSourceManual => 'You added it yourself';

  @override
  String get smartConsentTitle => 'Smart Analysis & Cloud Sync';

  @override
  String get smartConsentBullet1 =>
      'Captured bank messages, including bank SMS read automatically on Android, are sent to Qirsh servers after card, account and phone numbers and codes are removed. Google Gemini may process this text to identify the amount, merchant and bank; Google Places may receive merchant names. Amounts, merchants and balances remain, so it is not anonymous.';

  @override
  String get smartConsentBullet2 =>
      'Your transactions, accounts, budgets, goals and settings are also synced and backed up to your Qirsh cloud account.';

  @override
  String get smartConsentBullet3 =>
      'After you accept, sync and permitted analysis run automatically when available. You can withdraw either permission in Settings → Privacy. Choosing local use sends none of this data.';

  @override
  String get smartConsentEnable => 'Enable Smart Analysis & Cloud Sync';

  @override
  String get smartConsentNotNow => 'Not now';

  @override
  String get smartConsentPrivacyLink => 'Privacy settings';

  @override
  String get smartConsentStatusConnecting => 'Connecting…';

  @override
  String get smartConsentStatusConnected => 'Smart Analysis is connected';

  @override
  String get smartConsentStatusFailed =>
      'Smart Analysis isn\'t connected, so bank messages are read on this device only until it connects.';

  @override
  String get smartConsentRetry => 'Retry';

  @override
  String get txnAwaitingPrice => 'Awaiting price';

  @override
  String get onbCloudTitle => 'Cloud Sync';

  @override
  String get onbCloudBullet1 =>
      'Captured bank messages are sent to Qirsh servers to be read, with card, account and phone numbers and codes removed, and your transactions, accounts, budgets, goals and settings are synced and backed up to your Qirsh cloud account.';

  @override
  String get onbCloudBullet2 =>
      'Without it, your data stays only on this phone and is not backed up.';

  @override
  String get onbCloudBullet3 =>
      'You can turn it off at any time in Settings → Privacy.';

  @override
  String get onbCloudEnable => 'Enable Cloud Sync';

  @override
  String get onbAiTitle => 'Smart Analysis';

  @override
  String get onbAiBullet1 =>
      'With Smart Analysis on, captured bank messages — with card, account and phone numbers and codes removed — may be analysed by an AI service to read the amount, merchant and bank.';

  @override
  String get onbAiBullet2 =>
      'You can turn it off at any time in Settings → Privacy.';

  @override
  String get onbAiEnable => 'Enable Smart Analysis';

  @override
  String get onbAiNeedsCloud =>
      'Smart Analysis requires Cloud Sync, which is off right now. You can enable both together:';

  @override
  String get onbAiEnableBoth => 'Enable Cloud Sync and Smart Analysis';

  @override
  String get onbReadyTitle => 'Connection status';

  @override
  String get onbReadyBodyOn =>
      'Qirsh is connecting this device for cloud features. You can continue while this finishes.';

  @override
  String get onbReadyBodyOff =>
      'Cloud Sync and Smart Analysis are off, so your data stays on this phone. You can turn them on any time in Settings → Privacy.';

  @override
  String get onbAccountTitle => 'Set up your account';

  @override
  String get onbAccountBody =>
      'Add the account where you keep your money, such as a bank account, cash or a wallet. You can add more later.';

  @override
  String get onbAccountExistingTitle => 'Your accounts';

  @override
  String get onbAccountExistingBody =>
      'You already have these accounts. Continue, or add another.';

  @override
  String get onbAccountAddAnother => 'Add another account';

  @override
  String get onbAccountContinue => 'Continue';

  @override
  String get onbAccountRequired => 'Add an account to finish setup.';

  @override
  String get syncStatusAllSynced => 'All data synced';

  @override
  String get syncStatusSyncing => 'Syncing…';

  @override
  String syncStatusWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to sync',
      one: '1 change waiting to sync',
      zero: 'Waiting to sync',
    );
    return '$_temp0';
  }

  @override
  String get syncStatusConsentOff =>
      'Cloud Sync is off — data stays on this device';

  @override
  String get syncStatusSignedOut => 'Signed out — data stays on this device';

  @override
  String get syncStatusFailed => 'Sync failed — Retry';

  @override
  String get syncStatusNeedsAttention => 'Needs your attention';

  @override
  String get syncSheetTitle => 'Sync status';

  @override
  String syncSheetKeptOnDevice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes are kept on this device',
      one: '1 change is kept on this device',
      zero: 'No changes are waiting',
    );
    return '$_temp0';
  }

  @override
  String get syncSheetWaitingConnection => 'Waiting for connection';

  @override
  String get syncSheetWaitingServer => 'Waiting for server update';

  @override
  String get syncSheetNeedsAttention => 'Needs attention';

  @override
  String syncSheetStayFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items can’t be retried and stay failed',
      one: '1 item can’t be retried and stays failed',
    );
    return '$_temp0';
  }

  @override
  String syncSheetLastSync(String time) {
    return 'Last successful sync: $time';
  }

  @override
  String get syncSheetNeverSynced => 'No successful sync yet';

  @override
  String get syncSheetRetry => 'Retry';

  @override
  String get signOutKeepData => 'Sign out and keep encrypted data';

  @override
  String get signOutKeepDataHint =>
      'Your data stays encrypted on this device. Sign in again to open it.';

  @override
  String get signOutRemoveData => 'Sign out and remove data from this device';

  @override
  String get signOutRemoveDataHint =>
      'Deletes this account\'s data from this device only. Data already saved to the cloud is not affected.';

  @override
  String signOutUnsyncedKeepBody(String list) {
    return 'Some data has not reached the cloud yet: $list. It stays on this device and syncs when you sign back in.';
  }

  @override
  String get removeDataTitle => 'Remove data from this device?';

  @override
  String get removeDataBody =>
      'This permanently deletes this account\'s data on this device. Data already saved to the cloud can be downloaded again by signing in.';

  @override
  String removeDataUnsyncedBody(String list) {
    return 'This has not reached the cloud and will be lost: $list.';
  }

  @override
  String get removeDataAction => 'Remove data';

  @override
  String get captureUnboundTitle => 'Messages received while signed out';

  @override
  String captureUnboundBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count bank messages were',
      one: '1 bank message was',
    );
    return '$_temp0 received while you were signed out.';
  }

  @override
  String captureUnboundSenders(String senders) {
    return 'From: $senders';
  }

  @override
  String get captureUnboundAdd => 'Add them to my account';

  @override
  String get captureUnboundDiscard => 'Discard them';

  @override
  String get conflictKeepMine => 'Keep mine';

  @override
  String get conflictKeepMineAsNew => 'Keep mine as a new copy';

  @override
  String get conflictKeepCloud => 'Keep cloud version';

  @override
  String get conflictKeptCloud => 'The cloud version was kept.';

  @override
  String get conflictThisDevice => 'This device';

  @override
  String get conflictCloud => 'Cloud';

  @override
  String get conflictDeletedInCloud => 'Deleted in the cloud';

  @override
  String get conflictDeletedHere => 'Deleted on this device';

  @override
  String get conflictNotSet => 'Not set';

  @override
  String get conflictFieldAmount => 'Amount';

  @override
  String get conflictFieldCurrency => 'Currency';

  @override
  String get conflictFieldMerchant => 'Merchant';

  @override
  String get conflictFieldNote => 'Note';

  @override
  String get conflictFieldDate => 'Date';

  @override
  String get conflictFieldStatus => 'Status';

  @override
  String get conflictFieldCategory => 'Category';

  @override
  String get conflictFieldName => 'Name';

  @override
  String get conflictFieldType => 'Type';

  @override
  String get conflictFieldBalance => 'Balance';

  @override
  String get conflictFieldInitialBalance => 'Initial balance';

  @override
  String get conflictFieldCreditLimit => 'Credit limit';

  @override
  String get conflictFieldPeriod => 'Period';

  @override
  String get conflictFieldStartDate => 'Start date';

  @override
  String get conflictFieldEndDate => 'End date';

  @override
  String get conflictFieldFrequency => 'Frequency';

  @override
  String get conflictFieldNextDue => 'Next due date';

  @override
  String get conflictFieldTargetAmount => 'Target amount';

  @override
  String get conflictFieldDeadline => 'Deadline';

  @override
  String get conflictFieldNickname => 'Card name';

  @override
  String get conflictFieldLast4 => 'Last 4 digits';

  @override
  String get conflictFieldActive => 'Active';

  @override
  String get startupCoordinatorTitle => 'We could not start safely';

  @override
  String get startupCoordinatorBody =>
      'Qirsh could not confirm that no other part of the app is using your data, so it has not opened anything. Your data was not changed. Try again; if this keeps happening, restart the app.';

  @override
  String get startupCoordinatorRetry => 'Try again';

  @override
  String get sessionRecoveryTitle => 'Couldn\'t finish opening Qirsh';

  @override
  String get sessionRecoveryBody =>
      'Check your connection and try again, or sign in again to continue. Your saved data stays on this device.';

  @override
  String get sessionRecoverySignIn => 'Sign in again';

  @override
  String get localReadBannerTitle => 'Offline — read only';

  @override
  String get localReadBannerBody =>
      'Your data on this device is shown for viewing only. Sign in again to add, edit or sync.';

  @override
  String get localReadReconnect => 'Reconnect';

  @override
  String get localReadLogout => 'Log out';

  @override
  String get localReadBalancesTitle => 'Balances';

  @override
  String get localReadTransactionsTitle => 'Transactions';

  @override
  String get localReadNoTransactions =>
      'There are no transactions on this device.';

  @override
  String get localReadNoAccounts => 'There are no accounts on this device.';

  @override
  String get localReadLoadError =>
      'Your data on this device could not be read.';

  @override
  String get localReadLogoutFailed =>
      'Logging out did not complete. Try again.';

  @override
  String get signOutCleanupIncompleteMessage =>
      'You\'re signed out on this device, but we couldn\'t finish locking your offline data, so it may open again after a restart. Try again.';

  @override
  String get signOutCleanupRetry => 'Retry';

  @override
  String get signOutCleanupStillIncomplete =>
      'Your offline data still couldn\'t be locked. It may open again after a restart. Try again.';

  @override
  String get removeDataDenyIncompleteMessage =>
      'We couldn\'t finish revoking offline access to the data on this device, so it may open again after a restart. Try again.';

  @override
  String get removeDataDenyStillIncomplete =>
      'Offline access still couldn\'t be revoked. It may open again after a restart. Try again.';

  @override
  String get cloudEnableIncomplete =>
      'Couldn\'t turn on cloud processing. It stays off. Please try again.';

  @override
  String get cloudEnableWithdrawFirst =>
      'We can\'t confirm the current state, so nothing was changed. Turn it off first, then turn it on again.';

  @override
  String get cloudEnableChoiceNotSaved =>
      'Cloud processing was finished with your earlier choice. Your new choice was not saved. Review and choose again to add it.';

  @override
  String get initialConsentAccept => 'Accept cloud sync and smart analysis';

  @override
  String get initialConsentDecline => 'Continue locally';

  @override
  String get consentMgmtTitle => 'Cloud sync & Smart Analysis';

  @override
  String get consentStatusActive => 'On';

  @override
  String get consentStatusPartial => 'Partly on';

  @override
  String get consentStatusOff => 'Off';

  @override
  String get consentStatusUnknown => 'Can\'t confirm';

  @override
  String get consentStatusTurningOn => 'Turning on…';

  @override
  String get consentStatusTurningOff => 'Turning off…';

  @override
  String get consentStatusActiveBody =>
      'Cloud sync and Smart Analysis are both on.';

  @override
  String get consentStatusPartialBody =>
      'Only part of this permission is on. Turn it on to review and choose again, or turn it off.';

  @override
  String get consentStatusOffBody =>
      'Nothing is sent to Qirsh servers or analysed by AI. Everything stays on this device and manual entry keeps working.';

  @override
  String get consentStatusUnknownBody =>
      'We can\'t confirm the current state right now, so sync and analysis stay paused until it is confirmed.';

  @override
  String get consentStatusUnknownRecovery =>
      'To restore it, turn it off first, then turn it on again.';

  @override
  String get consentStatusTurningOnBody =>
      'We couldn\'t confirm that this finished. Sync and analysis stay paused until it does.';

  @override
  String get consentStatusTurningOffBody =>
      'Sync and analysis are already stopped. Finishing up.';

  @override
  String get consentTurnOn => 'Review and turn on';

  @override
  String get consentTurnOff => 'Turn off';

  @override
  String get consentRefresh => 'Check again';

  @override
  String get consentWithdrawTitle => 'Turn off cloud sync and Smart Analysis?';

  @override
  String get consentWithdrawBody =>
      'Sync and analysis stop right away, both together. Your data stays on this device, and you can turn them on again here at any time.';

  @override
  String get consentWithdrawConfirm => 'Turn off';

  @override
  String get consentWithdrawFailed =>
      'We couldn\'t confirm turning this off. Sharing stays paused. Please try again.';

  @override
  String get signOutDataStays =>
      'Your data stays on this device and comes back when you sign in again.';

  @override
  String get deleteAccountTitle => 'Delete account';

  @override
  String get deleteAccountIntro =>
      'Permanently and immediately delete your Qirsh account and the data saved with it. You’ll confirm your identity first, with Apple or the method you signed in with.';

  @override
  String get deleteAccountAction => 'Delete account';

  @override
  String get deleteAccountConfirmTitle => 'Delete your account?';

  @override
  String get deleteAccountConfirmBody =>
      'This permanently and immediately deletes your account and its data. Confirm your identity with Apple or the method you signed in with to continue. This cannot be undone.';

  @override
  String get deleteAccountConfirmAction => 'Delete permanently';

  @override
  String get deleteAccountProgress => 'Deleting your account…';

  @override
  String get deleteAccountSuccess => 'Your account was deleted.';

  @override
  String get deleteAccountAcceptedBody =>
      'We received your deletion request, but your account is not deleted yet. You can check or cancel it in Privacy & data.';

  @override
  String get deleteAccountFailed =>
      'We couldn\'t finish deleting your account. Please try again.';

  @override
  String get deleteAccountFailedFinal =>
      'We can\'t delete your account from here right now. Please try again later or contact support.';

  @override
  String get deleteAccountUnconfirmed =>
      'We couldn\'t confirm that your account was deleted yet.';

  @override
  String get deleteAccountRetry => 'Try again';

  @override
  String get deleteAccountRejected =>
      'Confirmation failed or expired. Try again.';

  @override
  String get deleteAccountDone => 'Done';

  @override
  String get deleteAccountConfirmBodyScheduled =>
      'Your deletion request will be sent, and the server will then permanently delete your account and all your data. This cannot be undone.';

  @override
  String get deleteAccountPendingBody =>
      'Your account deletion is in progress. Your account is not deleted yet. Check again in a moment.';

  @override
  String get deleteAccountCheckStatus => 'Check status';

  @override
  String get deleteAccountUnconfirmedStale =>
      'Your sign-in changed before we could confirm the result. Reopen this screen to check.';

  @override
  String get deleteAccountAdminBlocked =>
      'This is an admin account and can\'t be deleted until its admin access is removed. Contact the team to remove it first.';

  @override
  String get deleteAccountRateLimited =>
      'Too many attempts. Please wait a few minutes and try again.';

  @override
  String get deleteAccountLocalCleanupPending =>
      'Your account was deleted from our servers, but we couldn\'t finish clearing this device. Close and reopen the app.';

  @override
  String get pasteAnalysisHowItWorks =>
      'Smart Analysis reads messages when Cloud and AI are enabled. Otherwise, Qirsh reads them on your device.';

  @override
  String get pasteReadOnDevice => 'Read on your device — AI was not needed.';

  @override
  String get pasteReadWithAi => 'Read with AI.';

  @override
  String get pasteAiOff =>
      'Read on your device — AI is off. Turn on Cloud and AI analysis in Settings.';

  @override
  String get pasteAiUnavailable =>
      'Read on your device — AI is not available in this build.';

  @override
  String get pasteAiMismatch =>
      'Read on your device — AI\'s answer didn\'t match the message, so it was not used.';

  @override
  String pasteAiFailed(String code) {
    return 'Read on your device — AI could not be reached ($code).';
  }

  @override
  String get pasteAiConsentOff =>
      'This message could not be read on your device. Enable Cloud and Smart Analysis in Privacy to allow AI assistance.';

  @override
  String get homeGoodMorning => 'Good morning';

  @override
  String get homeGoodEvening => 'Good evening';

  @override
  String get homeQuickAdd => 'Add';

  @override
  String get homeQuickPaste => 'Paste SMS';

  @override
  String get homeQuickBudget => 'Budget';

  @override
  String get homeQuickGoals => 'Goals';

  @override
  String homeBudgetLeft(String limit, String left) {
    return 'of a $limit budget · $left left';
  }

  @override
  String homeBudgetOverBy(String limit, String over) {
    return '$over over the $limit budget';
  }

  @override
  String homeProjectedMonthEnd(String amount) {
    return 'Expected by month end: $amount';
  }

  @override
  String homeLastWeekWas(String amount) {
    return 'Last week: $amount';
  }

  @override
  String homeTodayTxCount(int count) {
    return 'Transactions today: $count';
  }

  @override
  String homeLeftTodayShort(String amount) {
    return '$amount left today';
  }

  @override
  String homePaceUnder(int percent) {
    return '$percent% under budget pace';
  }

  @override
  String homePaceOver(int percent) {
    return '$percent% over budget pace';
  }

  @override
  String get homePaceOnTrack => 'On budget pace';

  @override
  String get homePaceSetBudget => 'Set a budget to track your pace';

  @override
  String homeWeekMoreThan(int percent) {
    return '$percent% more than last week';
  }

  @override
  String homeWeekLessThan(int percent) {
    return '$percent% less than last week';
  }

  @override
  String homeDayMoreThan(int percent) {
    return '$percent% more than yesterday';
  }

  @override
  String homeDayLessThan(int percent) {
    return '$percent% less than yesterday';
  }

  @override
  String get homeToReview => 'To review';

  @override
  String get homeReviewNow => 'Review';

  @override
  String homeSpentOfAllowance(String spent, String allowance) {
    return 'Spent $spent of $allowance';
  }

  @override
  String get homeLastSevenDays => 'Last 7 days';

  @override
  String homeDailyAverage(String amount) {
    return '$amount a day on average';
  }

  @override
  String get homeWhereMoneyWent => 'Where your money went';

  @override
  String get homeDetails => 'Details';

  @override
  String get homeUpcoming => 'Upcoming payments';

  @override
  String homeInstalmentProgress(int n, int total) {
    return 'Payment $n of $total';
  }

  @override
  String get homeGoalsAndPlans => 'Goals & plans';

  @override
  String get homeNewGoal => 'New goal';

  @override
  String get homeRecentTx => 'Recent transactions';

  @override
  String get homeSeeAll => 'See all';

  @override
  String get homeWelcomeTo => 'Welcome to Qirsh';

  @override
  String get homeWelcomeTitle =>
      'Add your first transaction,\nQirsh sorts the rest';

  @override
  String get homeWelcomeBody =>
      'Your daily spend, what you have left and where your money goes all show up here after your first transaction.';

  @override
  String get homeStartSteps => 'Start in 3 steps';

  @override
  String get homeStartStepsHint => 'Takes under two minutes';

  @override
  String get homeStepAddTitle => 'Add your first transaction';

  @override
  String get homeStepAddBody => 'Paste a bank SMS or enter it by hand';

  @override
  String get homeStepAddCta => 'Add transaction';

  @override
  String get homeStepBudgetTitle => 'Set a monthly budget';

  @override
  String get homeStepBudgetBody => 'So you know what you can spend each day';

  @override
  String get homeStepBudgetCta => 'Set budget';

  @override
  String get homeStepCaptureTitle => 'Turn on bank SMS capture';

  @override
  String get homeStepCaptureBody => 'So transactions are added without pasting';

  @override
  String get homeStepCaptureCta => 'How to set it up';

  @override
  String get homeOnDeviceTitle => 'Your data stays on your device';

  @override
  String get homeOnDeviceBody => 'Your database is encrypted on this device.';

  @override
  String get homeCreateYourself => 'Or create your own';

  @override
  String get homeTileBudgetSub => 'Monthly or per category';

  @override
  String get homeTileGoal => 'Savings goal';

  @override
  String get homeTileGoalSub => 'Travel, car, emergencies';

  @override
  String get homeTileBill => 'Subscription or instalment';

  @override
  String get homeTileBillSub => 'We remind you before it\'s charged';

  @override
  String get homeTilePlan => 'Plan';

  @override
  String get homeTilePlanSub => 'For trips or occasions';

  @override
  String get homePrivacyToggle => 'Show or hide amounts';

  @override
  String get accTotalBalance => 'Total balance';

  @override
  String get achBadges => 'Badges';

  @override
  String achEarnedCount(int earned, int total) {
    return '$earned of $total earned';
  }

  @override
  String achNextLevelXp(int remaining) {
    return '$remaining to the next level';
  }

  @override
  String get gdSavedLabel => 'Saved';

  @override
  String get homeSavingsGrowing => 'Your savings are growing';

  @override
  String homeSavingsSurplus(String amount) {
    return 'You earned $amount more than you spent this month';
  }

  @override
  String get homeSavingsMotivation =>
      'Move some of it into your goals and let it grow.';

  @override
  String get homeAddToGoal => 'Add to a goal';

  @override
  String get rptPhotoKicker => 'A clearer view of your money';

  @override
  String get rptPhotoTitle => 'Your spending, in one place';

  @override
  String homeSpendingAhead(String amount) {
    return 'You spent $amount more than you earned this month';
  }

  @override
  String get goalCoverLabel => 'Goal cover';

  @override
  String get goalCoverTravel => 'Travel';

  @override
  String get goalCoverCar => 'Car';

  @override
  String get goalCoverHome => 'Home';

  @override
  String get goalCoverEducation => 'Education';

  @override
  String get goalCoverGadgets => 'Gadgets';

  @override
  String get goalCoverEmergency => 'Safety net';

  @override
  String get bdgOverviewSubtitle => 'Your limits and goals in one place';

  @override
  String get rptExpenseCountLabel => 'Expense transactions';

  @override
  String get rptDailySpending => 'Daily spending';

  @override
  String get dtxExportSection => 'Export';

  @override
  String get dtxImportSection => 'Import';

  @override
  String get dtxPdfReport => 'PDF financial report';

  @override
  String get dtxPdfReportSub => 'A designed summary to share';

  @override
  String get captureAutomaticTitle => 'Automatic capture';

  @override
  String get captureAutomaticBody =>
      'Set up Apple Shortcuts or bank-message capture';

  @override
  String get homeHeroIncome => 'Income';

  @override
  String get homeHeroSpent => 'Spent';

  @override
  String get homeHeroNet => 'Net';

  @override
  String homePaceUsed(int percent) {
    return '$percent% used';
  }

  @override
  String homePaceExpected(int percent) {
    return 'Expected by now $percent%';
  }

  @override
  String get introWelcomeTitle => 'Your money, clear — without the effort';

  @override
  String get introWelcomeBody =>
      'Qirsh turns bank messages into a clear picture of your spending, budgets and goals.';

  @override
  String get introCaptureTitle => 'Transactions from bank messages';

  @override
  String get introCaptureBody =>
      'An Apple Shortcut sends the bank message to Qirsh. Read it on your device and review the result before saving.';

  @override
  String get introBudgetTitle => 'Budgets that warn you early';

  @override
  String get introBudgetBody =>
      'See your pace day by day and know when to slow down.';

  @override
  String get introPrivacyTitle => 'Privacy before anything';

  @override
  String get introPrivacyBody =>
      'Your data is encrypted on your device. Cloud processing is optional and controlled in Settings.';

  @override
  String introPageSemantic(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get introPrivacyLocalBody =>
      'Your records are stored encrypted on this device.';

  @override
  String get introPrivacyCloudBody =>
      'Optional. Choose whether to enable it during setup or in Settings.';

  @override
  String get annPreferencesTitle => 'Choose the alerts you care about';

  @override
  String get annPreferencesAction => 'Notification settings';

  @override
  String get couponsAvailableLabel => 'Available offers';

  @override
  String setCategoryIconName(String icon) {
    String _temp0 = intl.Intl.selectLogic(
      icon,
      {
        'restaurants': 'Restaurants',
        'groceries': 'Groceries',
        'shopping': 'Shopping',
        'transport': 'Transport',
        'bills': 'Bills',
        'cards': 'Cards',
        'cash': 'Cash',
        'cafes': 'Cafés',
        'gifts': 'Gifts',
        'home': 'Home',
        'travel': 'Travel',
        'health': 'Health',
        'education': 'Education',
        'transfers': 'Transfers',
        'other': 'Other icon',
      },
    );
    return '$_temp0';
  }

  @override
  String setCategoryColourName(String colour) {
    String _temp0 = intl.Intl.selectLogic(
      colour,
      {
        'grey': 'Grey',
        'coral': 'Coral',
        'green': 'Green',
        'blue': 'Blue',
        'purple': 'Purple',
        'brightGreen': 'Bright green',
        'teal': 'Teal',
        'pink': 'Pink',
        'blueGrey': 'Blue grey',
        'orange': 'Orange',
        'other': 'Custom colour',
      },
    );
    return '$_temp0';
  }

  @override
  String get rptPreviousPeriod => 'Previous period';

  @override
  String get cloudResumeTitle => 'Resume Cloud Sync';

  @override
  String get cloudResumeBody =>
      'Cloud Sync and Smart Analysis are paused after sign-out. Turn them on again to resume.';

  @override
  String get languageFirstTitle => 'Choose your language';

  @override
  String get languageFirstBody =>
      'Choose how you would like to use Qirsh. You can change this later.';

  @override
  String get coachPasteTitle => 'Read a bank message';

  @override
  String get coachPasteBody =>
      'Use Paste message here. In the + menu, choose Paste message to let Smart Analysis read it.';

  @override
  String get coachAccountTitle => 'Choose the account';

  @override
  String get coachAccountBody =>
      'Choose which account you want to view. Its currency and figures follow your selection.';

  @override
  String get coachBudgetTitle => 'Set your first budget';

  @override
  String get coachBudgetBody =>
      'Tap + to choose a spending limit, period and account. You can adjust it later.';

  @override
  String get coachBillsTitle => 'Track a bill';

  @override
  String get coachBillsBody =>
      'Tap + to add a subscription or instalment. Set its amount and due date, then record payments from its details.';

  @override
  String get pasteSavedForAnalysis =>
      'Message saved in Smart Inbox for analysis.';

  @override
  String get retryBankAnalysis => 'Retry smart analysis';

  @override
  String get onboardingAccountCheckFailed =>
      'We couldn\'t check your account setup. Check your connection and try again.';

  @override
  String get shortcutVisualInstallTitle => 'Add the Qirsh shortcut';

  @override
  String get shortcutVisualInstallBody =>
      'Tap Add Qirsh Shortcut, then Add Shortcut in iOS. Keep the new template name QIRSH so the connection test can find it.';

  @override
  String get shortcutVisualFilterTitle =>
      'Choose which bank messages to capture';

  @override
  String shortcutVisualFilterBody(String currencyCode) {
    return 'The shared template starts with EGP. Set Message contains to $currencyCode; keep it if it already matches. Keep Shortcut Input and Sender in Process.';
  }

  @override
  String get shortcutVisualAutomationTitle => 'Turn on automatic capture';

  @override
  String get shortcutVisualAutomationBody =>
      'Tap the arrow beside When I receive a message. Turn Automation ON and Confirm Before Run OFF, then save.\n\nIf your iOS version shows Run Immediately, choose it.';

  @override
  String get shortcutVisualTestTitle => 'Check the connection';

  @override
  String get shortcutVisualTestBody =>
      'Test connection runs QIRSH without adding a transaction. Success confirms the connection.\n\nTo check automatic capture, receive a bank SMS matching your filter.';

  @override
  String get shortcutVisualImageCaption =>
      'iOS reference · tap to zoom. The shortcut name for testing is QIRSH.';

  @override
  String get shortcutVisualEnlarge => 'Enlarge the iOS setup screenshot';

  @override
  String get shortcutVisualReviewed =>
      'Steps reviewed. Automatic capture still depends on enabling Automation in Shortcuts.';

  @override
  String get shortcutCatalogTitle => 'Bank messages';

  @override
  String get shortcutCatalogBody =>
      'Choose the word your bank uses. We’ll guide you through the filter and automatic capture, one step at a time.';

  @override
  String get shortcutCatalogSearch => 'Word or currency';

  @override
  String get shortcutCatalogOther => 'Other words and currencies';

  @override
  String shortcutCatalogKeyword(String keyword) {
    return 'Texts with “$keyword”';
  }

  @override
  String shortcutCatalogExample(String keyword) {
    return 'Purchase of $keyword 450.00 at Talabat.';
  }

  @override
  String get shortcutCatalogSetUp => 'Set up';

  @override
  String get shortcutCatalogReviewed => 'Steps reviewed';

  @override
  String get shortcutCatalogNoMatches =>
      'No matches. Try a currency code such as EGP or USD.';

  @override
  String get shortcutCatalogSingleTemplate =>
      'All choices use the same QIRSH template. You’ll change its existing filter in Shortcuts. Reviewing the steps does not confirm that iOS Automation is on.';

  @override
  String shortcutVisualInstallDedicatedBody(String keyword) {
    return 'Tap Add Qirsh Shortcut, then Add Shortcut in iOS. This shortcut already listens for messages containing $keyword, so there is nothing to type.';
  }

  @override
  String shortcutCatalogDedicated(String keyword) {
    return '$keyword has its own ready shortcut with the keyword already filled in. iOS still asks you to turn its Automation on yourself, and Qirsh cannot see whether it is on.';
  }

  @override
  String get shortcutConfirmAutomation => 'I turned Automation on';

  @override
  String get shortcutStateConfirmed =>
      'You confirmed Automation is on. Qirsh can’t check this in iOS.';

  @override
  String get shortcutStateTested =>
      'Connection tested. Turn Automation on to capture texts automatically.';

  @override
  String shortcutOverlapWarning(String keyword) {
    return 'You already set up $keyword for this currency. Keep one keyword per currency so a single text isn’t captured twice.';
  }

  @override
  String shortcutOpenEditor(String name) {
    return 'Open $name in Shortcuts';
  }

  @override
  String get shortcutVisualArrowTitle => 'Open the automation controls';

  @override
  String shortcutVisualArrowBody(String name) {
    return 'Open $name in Shortcuts. Tap the small blue arrow beside “where”, under “When I receive a message”.';
  }

  @override
  String shortcutVisualStep(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get shortcutStudioTitle => 'Connect your messages';

  @override
  String get shortcutStudioBody =>
      'A small bridge between your bank messages and Qirsh. Set your filter, connect it, and check it.';

  @override
  String get shortcutRouteMessage => 'Message';

  @override
  String get shortcutRouteAutomation => 'Shortcut';

  @override
  String get shortcutStudioCurrency => '1 · Message currency';

  @override
  String get shortcutStudioWord => '2 · Word to match';

  @override
  String get shortcutStudioPreview => 'Your capture filter';

  @override
  String shortcutStudioBegin(String keyword) {
    return 'Connect “$keyword”';
  }

  @override
  String get authEmailExplanation =>
      'Enter the email on your Qirsh account to receive a one-time login code.';

  @override
  String get authEmailLinkExplanation =>
      'Add an email to this account. Your transactions and settings stay in the same account. Changing your email requires confirmation of both addresses.';

  @override
  String get authInvalidEmail => 'Enter a valid email address.';

  @override
  String get authCodeSendFailed =>
      'Could not send the code. Check your connection and try again after a minute.';

  @override
  String get authCodeVerifyFailed =>
      'Could not verify the code. Check it and try again.';

  @override
  String get authResendCode => 'Resend code';

  @override
  String get authChangeEmail => 'Use a different email';

  @override
  String get authConfirmBothEmails =>
      'New email confirmed. Enter the code sent to your current email to finish.';

  @override
  String get authCurrentEmailCode => 'Code from your current email';

  @override
  String get authSignInMethods => 'Sign-in methods';

  @override
  String get authSignInMethodsDescription =>
      'Add a way to sign in to this account. Your data stays together.';

  @override
  String get authLinked => 'Connected';

  @override
  String get authLinkGoogle => 'Connect Google';

  @override
  String get authLinkEmail => 'Connect email';

  @override
  String get authLinkSuccess => 'Sign-in method connected to your account.';

  @override
  String get authLinkFailed =>
      'Could not connect this sign-in method. If it belongs to another Qirsh account, use a different one.';

  @override
  String get authExistingAccountHint =>
      'Already use Apple? Sign in with Apple to link a new method.';

  @override
  String get authCreateAccount => 'Create an account';

  @override
  String get authBackToSignIn => 'Already have an account? Sign in';

  @override
  String get authCreateAccountSubtitle =>
      'Choose a method for your new Qirsh account.';

  @override
  String get authCreateEmailExplanation =>
      'Enter your email. Confirm the code to finish creating your Qirsh account.';

  @override
  String get deleteAccountEmailProofTitle => 'Email confirmation code';

  @override
  String get deleteAccountEmailProofBody =>
      'We sent a one-time code to the verified email on this Qirsh account. Enter it to authorize deletion.';

  @override
  String get authGoogleSignupRequired =>
      'This Google account is new to Qirsh. Choose Create an account to register.';

  @override
  String get accV2Balance => 'Balance';

  @override
  String get accV2YourAccounts => 'Your accounts';

  @override
  String get subsV2Upcoming => 'Upcoming';

  @override
  String get subsV2AllSubs => 'All subscriptions';

  @override
  String get gfV2Preview => 'Preview';

  @override
  String gdV2DaysCount(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get gdV2MoreActions => 'Goal options';

  @override
  String get setV2Tools => 'Tools';

  @override
  String setV2Version(String version) {
    return 'Qirsh $version';
  }

  @override
  String get setV2AppearanceLead =>
      'Choose how Qirsh looks — it changes right away.';

  @override
  String get setV2CaptureNeedsCheck => 'Needs a check';

  @override
  String get bdgV2YourBudgets => 'Your budgets';

  @override
  String get bdgV2WorstFirst => 'Worst first';

  @override
  String get bfsV2ShowAll => 'Show all';

  @override
  String get bfsV2ShowLess => 'Show less';

  @override
  String get couponsV2BrowseOffers => 'Browse offers';

  @override
  String get txnV2EndOfList => '— That\'s every transaction in this period —';

  @override
  String get txnV2Filters => 'Filters';

  @override
  String pasteV2DetectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count messages detected',
      one: '1 message detected',
    );
    return '$_temp0';
  }

  @override
  String get pasteV2Clear => 'Clear text';

  @override
  String get smsV2Step1 => 'Open the bank message';

  @override
  String get smsV2Step2 => 'Tap Share';

  @override
  String get smsV2Step3 => 'Choose Qirsh';

  @override
  String get smsV2PrivacyLine =>
      'Without SMS read permission · With Smart Analysis off, the text is analysed only on your device.';

  @override
  String get insV3Report => 'Report';

  @override
  String get txnV3NetThisMonth => 'Net this month';

  @override
  String get txnV3NetThisPeriod => 'Net this period';

  @override
  String billsV3Counts(int subs, int instalments) {
    return '$subs subscriptions · $instalments instalments';
  }

  @override
  String get captureQueueNotSaved =>
      'One or more bank messages couldn\'t be saved on this device. Share them again or add the transaction manually.';

  @override
  String get captureQueueReadFailed =>
      'Couldn\'t read the bank messages saved on this device. Nothing was deleted, and we\'ll try again automatically.';

  @override
  String get smsAutoCaptureRestoredNotice =>
      'Automatic SMS capture was turned back on for this account.';
}
