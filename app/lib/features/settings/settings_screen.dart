import '../../core/utils/l10n_ext.dart';
import '../capture/widgets/sms_capture_disclosure.dart';
import '../capture/services/native_capture_bridge.dart';
import '../capture/services/android_sms_capture_service.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_coordinator.dart';
import '../../core/auth/auth_service.dart';
import '../../core/auth/auth_methods_config.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../planning_sync/planning_conflicts_sheet.dart';
import 'sign_out_sheet.dart';
import 'sign_in_methods_sheet.dart';
import '../../core/theme/app_shadows.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../core/security/app_lock_service.dart';
import '../../core/router/app_router.dart';
import '../../core/session/app_session.dart';
import '../../core/session/remove_data_flow.dart'
    show RemoveDataIncompleteException;
import '../../core/session/unsynced_inventory.dart';
import '../app/local_read_cleanup_notice.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/theme_mode_controller.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../referrals/referrals_providers.dart';
import '../achievements/achievements_providers.dart';
import '../report_ads/report_ads_providers.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../budgets/budgets_providers.dart';
import '../cards/my_cards_screen.dart';
import '../plans/plans_screen.dart';
import '../common/app_avatar.dart';
import '../common/category_catalog.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../common/motion.dart';
import '../dashboard/dashboard_providers.dart';
import '../capture/services/local_notification_service.dart';
import '../onboarding/ios_shortcut_guide.dart';
import '../transactions/transactions_providers.dart';
import 'settings_providers.dart';
import 'sync_status_ui.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

class _ProfileTextSheet extends StatefulWidget {
  const _ProfileTextSheet({required this.title, required this.label,
    required this.initialValue, required this.keyboardType, required this.onSave});
  final String title;
  final String label;
  final String initialValue;
  final TextInputType keyboardType;
  final Future<void> Function(String value) onSave;
  @override
  State<_ProfileTextSheet> createState() => _ProfileTextSheetState();
}

class _ProfileTextSheetState extends State<_ProfileTextSheet> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);
  bool _busy = false;
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSave(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: Directionality.of(context),
    child: Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.s2,
        AppSpacing.gutter, MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: AppTypography.sectionTitle(context.colors.textMain)),
          const SizedBox(height: AppSpacing.s3),
          TextField(controller: _controller, enabled: !_busy, autofocus: true,
            keyboardType: widget.keyboardType,
            decoration: InputDecoration(labelText: widget.label,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md)))),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(height: AppSpacing.buttonHeight,
            child: FilledButton(onPressed: _busy ? null : _save,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_busy) ...[
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(
                    strokeWidth: 2, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .38))),
                  const SizedBox(width: AppSpacing.s2),
                ],
                Text(context.l10n.setSave),
              ]))),
        ]),
    ),
  );
}

/// maybeWhen that keeps rendering the last loaded value during a reload, so the
/// frequent `user_settings` writes (sync, notification history, journey) don't
/// flash the settings cards back to their skeleton/placeholder — the settings
/// screen flicker. Falls back only on a genuine first load with no value yet.
extension _AsyncReloadSafe<T> on AsyncValue<T> {
  R dataOr<R>(R Function(T value) onData, R Function() orElse) {
    final value = valueOrNull;
    return value != null ? onData(value) : orElse();
  }
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.showBackButton = false});

  final bool showBackButton;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _savingPrefs = false;
  String _profileName(UserSettingsEntity? s, String email) {
    final n = s?.displayName?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final local = email.split('@').first.trim();
    if (local.isEmpty || local == '—') return context.l10n.homeMoneyFriend;
    return local.replaceAll('.', ' ').replaceAll('_', ' ');
  }

  /// The catalog carries `name_en` for every country and currency — the sync
  /// pulls it and the DAO stores it. Only the render discarded it, which is why
  /// the English build said «الريال السعودي».
  String _catalogName(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'en' ? en : ar;

  String _countryLabel(
      UserSettingsEntity s, List<RemoteCountry> countries, bool loading) {
    final code = s.country.toUpperCase();
    for (final country in countries) {
      if (country.code.toUpperCase() == code) {
        return '${country.flagEmoji} ${_catalogName(country.nameAr, country.nameEn)}';
      }
    }
    return loading ? context.l10n.setLoadingCountries : s.country;
  }

  String _currencyLabel(
      UserSettingsEntity s, List<RemoteCurrency> currencies, bool loading) {
    final code = s.currency.toUpperCase();
    for (final currency in currencies) {
      if (currency.code.toUpperCase() == code) {
        return '${currency.code} · ${_catalogName(currency.nameAr, currency.nameEn)}';
      }
    }
    return loading ? context.l10n.setLoadingCurrencies : s.currency;
  }

  void _editCountry(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
    List<RemoteCountry> countries,
    List<RemoteCurrency> currencies,
  ) {
    _showSettingsPicker(
      context,
      ref,
      title: context.l10n.setCountry,
      current: settings.country.toUpperCase(),
      values: _countryValues(countries),
      save: (value) async {
        final country = value.toUpperCase();
        final currency = _preferredCurrencyForCountry(
            country, currencies, settings.currency);
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country, currency);
      },
    );
  }

  void _editCurrency(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
    List<RemoteCurrency> currencies,
  ) {
    _showSettingsPicker(
      context,
      ref,
      title: context.l10n.setBaseCurrency,
      current: settings.currency.toUpperCase(),
      values: _currencyValuesForCountry(settings.country, currencies),
      save: (value) async {
        await ref.read(saveCountryCurrencyUseCaseProvider).call(
              settings.country.toUpperCase(),
              value.toUpperCase(),
            );
      },
    );
  }

  /// The language names are endonyms, and deliberately NOT ARB strings. A
  /// reader looking for their own language looks for its own name; translating
  /// the list labels the language you cannot read in the language you cannot
  /// read.
  static const Map<String, String> languageValues = <String, String>{
    'ar': 'العربية',
    'en': 'English',
  };

  static String _languageKey(UserSettingsEntity settings) =>
      settings.language == 'en' ? 'en' : 'ar';

  void _editLanguage(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
  ) {
    _showSettingsPicker(
      context,
      ref,
      title: context.l10n.setLanguage,
      current: _languageKey(settings),
      values: languageValues,
      // `SaveLanguageUseCase` is the app's write path for this value, and the
      // only one. Choosing here refreshes `userSettingsProvider`, which
      // `localeProvider` watches, so the app re-renders in the new language and
      // flips direction without a restart.
      save: (value) => ref.read(saveLanguageUseCaseProvider).call(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final captureHealthAsync = ref.watch(captureHealthStatusProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final achievements = ref.watch(achievementsViewProvider).valueOrNull;
    final countriesAsync = ref.watch(supportedCountriesProvider);
    final currenciesAsync = ref.watch(activeCurrenciesProvider);
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = AppSession.instance;
    final email = session.email ?? '—';
    final countries = countriesAsync.valueOrNull ?? const <RemoteCountry>[];
    final currencies = currenciesAsync.valueOrNull ?? const <RemoteCurrency>[];

    return Scaffold(
      backgroundColor: c.bg,
      body: StatusBarScrim(
        child: Stack(
        children: [
          // Ambient glow for dark mode (matches dashboard)
          if (isDark) ...[
            Positioned(
              right: -100,
              top: -100,
              width: 320,
              height: 320,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.cta.withValues(alpha: 0.05),
                      c.cta.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: -120,
              bottom: -120,
              width: 360,
              height: 360,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.cta.withValues(alpha: 0.035),
                      c.cta.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _SettingsHeader(
                  name: _profileName(settings, email),
                  contact: (settings?.phoneNumber?.trim().isNotEmpty ?? false)
                      ? settings!.phoneNumber!.trim()
                      : email,
                  avatarPath: settings?.avatarPath?.trim() ?? '',
                  levelKey: achievements?.xpLevel.levelKey,
                  totalXp: achievements?.xpLevel.totalXp,
                  onBack: widget.showBackButton
                      ? () {
                          if (context.canPop()) context.pop();
                        }
                      : null,
                  onAvatarTap: settings == null
                      ? null
                      : () => _pickProfileImage(context, ref, settings),
                  onNameTap: settings == null
                      ? null
                      : () => _showProfileTextSheet(
                            context,
                            ref,
                            title: context.l10n.setName,
                            label: context.l10n.setNameInApp,
                            initialValue: settings.displayName ?? '',
                            apply: (value) =>
                                settings.copyWith(displayName: value.trim()),
                          ),
                ),
              ),
              // الذوبان لازم يلفّ المحتوى كامل العرض ومن غير مسافة فوقه — لو
              // اتحط جوّه الـ padding بيبقى شريط أزرق مقصوص من الجناب وبحافة
              // حادّة تحت الهيدر.
              SliverToBoxAdapter(
                child: MeltTail(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter,
                      AppSpacing.s4,
                      AppSpacing.gutter,
                      120,
                    ),
                    child: Column(children: [
                      _buildGeneralTab(context, ref, settingsAsync),
                      const SizedBox(height: AppSpacing.s4),
                      if (settings != null) ...[
                        _Section(
                          // UX-028 — the other «الحساب». This group is profile
                          // data, so it says so.
                          title: context.l10n.setAccountData,
                          children: [
                            // A-5: the one quiet answer to "did my data reach
                            // the cloud?".
                            const SyncStatusTile(),
                            if (!AppSession.instance.isGuest &&
                                (ref.watch(authMethodsConfigProvider).google ||
                                    ref.watch(authMethodsConfigProvider).email))
                              _NavTile(
                                key: const ValueKey('settings-sign-in-methods'),
                                icon: AppLucideIcons.shieldCheck,
                                title: context.l10n.authSignInMethods,
                                subtitle: context.l10n.authSignInMethodsDescription,
                                onTap: () => showGlassSheet<void>(context: context,
                                  isScrollControlled: true, useSafeArea: true,
                                  builder: (_) => const SignInMethodsSheet()),
                              ),
                            _NavTile(
                              icon: AppLucideIcons.smartphone,
                              title: context.l10n.setMobileNumber,
                              subtitle:
                                  (settings.phoneNumber?.trim().isNotEmpty ??
                                          false)
                                      ? settings.phoneNumber!.trim()
                                      : context.l10n.setAddYourNumber,
                              onTap: () => _showProfileTextSheet(
                                context,
                                ref,
                                title: context.l10n.setMobileNumber,
                                label: context.l10n.setMobileNumber,
                                keyboardType: TextInputType.phone,
                                initialValue: settings.phoneNumber ?? '',
                                apply: (value) => settings.copyWith(
                                    phoneNumber: value.trim()),
                              ),
                            ),
                            _NavTile(
                              icon: AppLucideIcons.flag,
                              title: context.l10n.setCountry,
                              subtitle: _countryLabel(settings, countries,
                                  countriesAsync.isLoading),
                              onTap: countries.isEmpty
                                  ? null
                                  : () => _editCountry(context, ref, settings,
                                      countries, currencies),
                            ),
                            _NavTile(
                              icon: AppLucideIcons.banknote,
                              title: context.l10n.setBaseCurrency,
                              subtitle: _currencyLabel(settings, currencies,
                                  currenciesAsync.isLoading),
                              onTap: currencies.isEmpty
                                  ? null
                                  : () => _editCurrency(
                                      context, ref, settings, currencies),
                            ),
                            _NavTile(
                              // Named so the device walk can reach the control
                              // by identity rather than by a label that changes
                              // language the moment it is used.
                              key: const ValueKey('settings-language'),
                              icon: AppLucideIcons.globe,
                              title: context.l10n.setLanguage,
                              subtitle: languageValues[_languageKey(settings)]!,
                              onTap: () =>
                                  _editLanguage(context, ref, settings),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s4),
                      ],
                      _buildAppearanceSection(context, ref),
                      const SizedBox(height: AppSpacing.s4),
                      _buildNotificationsTab(
                        context,
                        ref,
                        prefsAsync,
                        captureHealthAsync,
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      _buildDataTab(context, ref, settingsAsync),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildAppearanceSection(BuildContext context, WidgetRef ref) {
    return _Section(
      title: context.l10n.setAppearance,
      description: context.l10n.setAppearanceSub,
      children: [
        _ThemeModeSelector(
          value: ref.watch(themeModeProvider),
          onChanged: (mode) => ref.read(themeModeProvider.notifier).set(mode),
        ),
      ],
    );
  }

  Widget _buildGeneralTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserSettingsEntity> settingsAsync,
  ) {
    return Column(
      children: [
        PremiumMotion(
            delay: const Duration(milliseconds: 80),
            // UX-029 — «إدارة أموالك» had become the app's navigation hub: ten
            // flat entries under one heading, with primary destinations
            // reachable THROUGH Settings, which is where users go for
            // configuration and not for their money.
            //
            // The QA's own diagnosis was that this compensates for UX-012 —
            // the bottom-navigation icons were illegible, so a second,
            // text-labelled route was built beside them — and its instruction
            // was explicit: *"Fixing UX-012 should reduce this list, not
            // duplicate it."*
            //
            // UX-012 is fixed: every bottom-nav destination now carries a text
            // label (app_shell.dart), including «التحليلات» — which is the
            // Reports screen. «الرؤى والتقارير» was therefore a duplicate route
            // to a tab that is now legible, and it is removed.
            //
            // The rest are NOT duplicates: accounts, cards, subscriptions and
            // plans have no tab of their own and legitimately live here. They
            // are split from the configuration entries so ten undifferentiated
            // rows stop reading as a second navigation bar.
            child: _Section(
              title: context.l10n.setAccountsAndDues,
              children: [
                // MALI-022: surface unresolved multi-device conflicts so they
                // are no longer stuck/invisible. Shown only when some exist.
                if ((ref.watch(conflictsProvider).valueOrNull ?? const [])
                    .isNotEmpty)
                  _NavTile(
                    icon: AppLucideIcons.cloudOff,
                    title: context.l10n.setSyncConflicts,
                    subtitle: context.l10n.setSyncConflictsSub,
                    onTap: () => PlanningConflictsSheet.show(context),
                  ),
                _NavTile(
                  icon: AppLucideIcons.wallet,
                  title: context.l10n.setAccountsWallets,
                  subtitle: context.l10n.setAccountsWalletsSub,
                  onTap: () => context.push('/accounts'),
                ),
                _NavTile(
                  icon: AppLucideIcons.creditCard,
                  title: context.l10n.setAllCards,
                  subtitle: context.l10n.setAllCardsSub,
                  onTap: () => MyCardsScreen.open(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.receipt,
                  title: context.l10n.setSubsAndBills,
                  subtitle: context.l10n.setSubsAndBillsSub,
                  onTap: () => context.push('/subscriptions'),
                ),
                _NavTile(
                  icon: AppLucideIcons.luggage,
                  title: context.l10n.setPlans,
                  subtitle: context.l10n.setPlansSub,
                  onTap: () => PlansScreen.open(context),
                ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 100),
            child: _Section(
              title: context.l10n.setToolsAndSettings,
              children: [
                _NavTile(
                  icon: AppLucideIcons.inbox,
                  title: context.l10n.setCategories,
                  subtitle: context.l10n.setCategoriesSub,
                  onTap: () => _showCategoriesSheet(context, ref),
                ),
                _NavTile(
                  icon: AppLucideIcons.trophy,
                  title: context.l10n.setAchievements,
                  subtitle: context.l10n.setAchievementsSub,
                  onTap: () => context.push('/achievements'),
                ),
                _NavTile(
                  icon: AppLucideIcons.arrowLeftRight,
                  title: context.l10n.setCurrencyRepair,
                  subtitle: context.l10n.setCurrencyRepairSub,
                  onTap: () =>
                      context.push('/settings/planning-currency-repair'),
                ),
                if (Platform.isIOS)
                  _NavTile(
                    icon: AppLucideIcons.share,
                    title: context.l10n.setAppleShortcut,
                    subtitle: context.l10n.setAppleShortcutSub,
                    onTap: () => showIosShortcutSheet(context),
                  ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 120),
            child: _Section(
              title: context.l10n.setRewardsAndSupport,
              children: [
                // Referral discovery is gated by enable_referrals (R3). When the
                // flag is off the tile is hidden — no referral functionality is
                // presented (docs REFERRAL_REWARDS_SYSTEM.md §19/§24).
                if (ref.watch(referralsEnabledProvider))
                  _NavTile(
                    icon: AppLucideIcons.gift,
                    title: context.l10n.setInviteFriends,
                    subtitle: context.l10n.setInviteFriendsSub,
                    onTap: () => context.push('/referrals'),
                  ),
                // Ads privacy (R4 §11): shown only when UMP requires privacy
                // options; invokes the Google UMP privacy-options form. UMP is
                // the sole ad-consent authority — no Qirsh consent boolean here.
                if (ref.watch(adPrivacyOptionsRequiredProvider).valueOrNull ??
                    false)
                  _NavTile(
                    icon: Icons.privacy_tip_outlined,
                    title: context.l10n.setAdPrivacyOptions,
                    subtitle: context.l10n.setAdPrivacyOptionsSub,
                    onTap: () =>
                        ref.read(adConsentServiceProvider).showPrivacyOptions(),
                  ),
                _NavTile(
                  icon: AppLucideIcons.receipt,
                  title: context.l10n.setContactUs,
                  subtitle: context.l10n.setContactUsSub,
                  onTap: () => _showContactSupport(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.info,
                  title: context.l10n.setAboutQirsh,
                  subtitle: context.l10n.setAboutQirshSub,
                  onTap: () => _showAboutApp(context),
                ),
              ],
            )),
      ],
    );
  }

  Widget _buildNotificationsTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<NotificationPreferences> prefsAsync,
    AsyncValue<CaptureHealthStatus> captureHealthAsync,
  ) {
    final c = context.colors;
    return prefsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const _SettingsLoadingState(),
      error: (error, _) => const _SettingsErrorState(),
      data: (prefs) => Column(
        children: [
          PremiumMotion(
              delay: const Duration(milliseconds: 80),
              child: _Section(
                title: context.l10n.setCaptureStatus,
                description: context.l10n.setCaptureStatusSub,
                children: [
                  captureHealthAsync.dataOr(
                    (status) => _CaptureHealthTile(status: status),
                    () => const SizedBox.shrink(),
                  ),
                  // MALI-013 — the automatic bank-SMS capture opt-in.
                  //
                  // This is the ONLY way a user can turn the feature on. Until
                  // it existed, the app shipped RECEIVE_SMS and a registered
                  // SMS_RECEIVED receiver for a feature no user could reach —
                  // which fails Play's core-functionality test for a restricted
                  // permission and contradicted the already-live privacy policy
                  // §8. Android-only, and hidden entirely when the build does
                  // not declare the permission.
                  const _SmsAutoCaptureTile(),
                  // Replaces a sentence that said Qirsh "does not read bank
                  // notifications or system SMS". That was true of a fresh
                  // install through the UI that existed, and false as a
                  // description of what the app implements and declares.
                  _TrustNoticeTile(text: context.l10n.smsCaptureTrustNotice),
                  _SwitchTile(
                    title: context.l10n.setConfirmCaptured,
                    icon: AppLucideIcons.messageSquare,
                    value: prefs.captureReview,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(captureReview: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setNotifyOnCapture,
                    icon: AppLucideIcons.bellRing,
                    iconColor: c.cta,
                    value: prefs.captureLight,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(captureLight: value),
                    ),
                  ),
                  // MALI-019 §6 — lock-screen privacy.
                  _SwitchTile(
                    title: context.l10n.setHideOnLockScreen,
                    icon: AppLucideIcons.lock,
                    value: prefs.hideLockScreenContent,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(hideLockScreenContent: value),
                    ),
                  ),
                ],
              )),
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 100),
              child: _Section(
                title: context.l10n.setYourAlerts,
                children: [
                  _SwitchTile(
                    title: context.l10n.setQirshMessages,
                    icon: AppLucideIcons.megaphone,
                    value: prefs.marketingMessages,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(marketingMessages: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setBudgetAlerts,
                    icon: AppLucideIcons.alertTriangle,
                    iconColor: c.accent,
                    value: prefs.budgetWarning,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(budgetWarning: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setBudgetOverAlert,
                    icon: AppLucideIcons.alertCircle,
                    iconColor: c.danger,
                    value: prefs.budgetOver,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(budgetOver: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setDailyReminder,
                    subtitle: context.l10n.setDailyReminderTime,
                    icon: AppLucideIcons.bell,
                    value: prefs.dailyReminder,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(dailyReminder: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setWeeklyReport,
                    icon: AppLucideIcons.lineChart,
                    value: prefs.weeklyReport,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(weeklyReport: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setBillReminders,
                    icon: AppLucideIcons.calendarCheck,
                    iconColor: c.cta,
                    value: prefs.subscriptionReminder,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(subscriptionReminder: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setGoalCelebrations,
                    icon: AppLucideIcons.flag,
                    iconColor: c.success,
                    value: prefs.goalMilestone,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(goalMilestone: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setAchievementAlerts,
                    icon: AppLucideIcons.trophy,
                    iconColor: c.success,
                    value: prefs.achievements,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(achievements: value),
                    ),
                  ),
                  _SwitchTile(
                    icon: AppLucideIcons.moon,
                    iconColor: c.textMuted,
                    title: context.l10n.setQuietHours,
                    subtitle: prefs.quietHoursEnabled
                        ? '${Formatters.hourOfDay(prefs.quietHoursStartHour, context)} - ${Formatters.hourOfDay(prefs.quietHoursEndHour, context)}'
                        : context.l10n.setDisabled,
                    value: prefs.quietHoursEnabled,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(quietHoursEnabled: value),
                    ),
                  ),
                  if (prefs.quietHoursEnabled)
                    _NavTile(
                      icon: AppLucideIcons.clock,
                      title: context.l10n.setEditQuietHours,
                      subtitle:
                          '${Formatters.hourOfDay(prefs.quietHoursStartHour, context)} - ${Formatters.hourOfDay(prefs.quietHoursEndHour, context)}',
                      onTap: () => _showQuietHoursSheet(context, ref, prefs),
                    ),
                ],
              )),
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 120),
              child: _Section(
                title: context.l10n.setNotificationTools,
                children: [
                  _NavTile(
                    icon: AppLucideIcons.bellPlus,
                    title: context.l10n.setTestNotifications,
                    subtitle: context.l10n.setTestNotificationsSub,
                    onTap: () => _sendTestNotification(context),
                  ),
                  _NavTile(
                    icon: AppLucideIcons.inbox,
                    title: context.l10n.setMessageCentre,
                    subtitle: context.l10n.setMessageCentreSub,
                    onTap: () => context.push('/announcements'),
                  ),
                ],
              )),
        ],
      ),
    );
  }

  Widget _buildDataTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserSettingsEntity> settingsAsync,
  ) {
    final c = context.colors;
    return Column(
      children: [
        PremiumMotion(
            delay: const Duration(milliseconds: 80),
            child: _Section(
              title: context.l10n.setDataTransfer,
              description: context.l10n.setDataTransferSub,
              children: [
                _NavTile(
                  icon: AppLucideIcons.folderOpen,
                  title: context.l10n.setImportFile,
                  subtitle: context.l10n.setImportFileSub,
                  onTap: () => context.push('/data-transfer?intent=import'),
                ),
                _NavTile(
                  icon: AppLucideIcons.table,
                  title: context.l10n.setExportCsv,
                  subtitle: context.l10n.setExportCsvSub,
                  onTap: () =>
                      context.push('/data-transfer?intent=transactions'),
                ),
                _NavTile(
                  icon: AppLucideIcons.archive,
                  title: context.l10n.setExportAll,
                  subtitle: context.l10n.setExportAllSub,
                  onTap: () => context.push('/data-transfer?intent=package'),
                ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 100),
            child: _Section(
              title: context.l10n.setSecurityPrivacy,
              // UX-030 — the strongest TRUE privacy claim the product can make
              // was never made anywhere in the UI. The local database is opened
              // with `PRAGMA cipher = 'sqlcipher'` and a key held in the
              // platform keychain (`database_key_store.dart`), and the open
              // FAILS CLOSED if the encryption extension is missing rather than
              // continuing unencrypted (`app_database.dart`).
              //
              // Worth stating precisely because it is verifiable, and worth
              // stating carefully: it claims local-database encryption, which
              // is what the code does — not end-to-end encryption, which it
              // does not.
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                    vertical: AppSpacing.s3,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.setEncryptedDbPart1 +
                              context.l10n.setEncryptedDbPart2,
                          style: AppTypography.caption(
                              context.colors.textSecondary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      const QirshIllustration(
                        name: 'privacy', width: 92, height: 69),
                    ],
                  ),
                ),
                _NavTile(
                  icon: AppLucideIcons.helpCircle,
                  title: context.l10n.helpSettingsTile,
                  subtitle: context.l10n.helpSettingsSubtitle,
                  onTap: () => context.push('/help'),
                ),
                _NavTile(
                  icon: AppLucideIcons.heartPulse,
                  title: context.l10n.setPrivacyAndData,
                  subtitle: context.l10n.setPrivacyAndDataSub,
                  onTap: () => context.push('/privacy'),
                ),
                settingsAsync.dataOr(
                  (settings) => _SwitchTile(
                    title: context.l10n.setHideAmounts,
                    icon: AppLucideIcons.eyeOff,
                    value: settings.privacyModeEnabled,
                    onChanged: (value) async {
                      await ref
                          .read(userSettingsRepositoryProvider)
                          .saveSettings(settings.copyWith(
                            privacyModeEnabled: value,
                          ));
                      // dbRevision (from saveSettings) rebuilds the switch and
                      // dashboard while keeping their value — invalidating would
                      // blank them and flicker.
                    },
                  ),
                  () => const SizedBox.shrink(),
                ),
                const _AppLockTile(),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 120),
            // UX-028 — «الحساب» was used as the heading TWICE: once near the
            // top for profile data (رقم الموبايل · الدولة · العملة الأساسية)
            // and again here for the destructive group. Two unrelated groups
            // under an identical name. This one is named for what it does.
            child: _Section(
              title: context.l10n.setExitAndErase,
              description: context.l10n.setExitAndEraseSub,
              children: [
                _NavTile(
                  icon: AppLucideIcons.logOut,
                  iconColor: c.danger,
                  title: context.l10n.setSignOut,
                  onTap: () => _signOut(context, ref),
                ),
                _NavTile(
                  icon: AppLucideIcons.trash2,
                  iconColor: c.danger,
                  title: context.l10n.setDeleteAccount,
                  subtitle: context.l10n.setDeleteAccountSub,
                  onTap: () => context.push('/privacy'),
                ),
              ],
            )),
        // Debug-only entry point into the Mali design-system review surface
        // (docs/MALI_DESIGN_SYSTEM.md). The route itself is also gated by
        // kDebugMode in app_router.dart, so this tile is redundant defense,
        // not the only gate — it simply doesn't exist in release builds.
        if (kDebugMode) ...[
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 140),
              child: _Section(
                title: 'Developer',
                children: [
                  _NavTile(
                    icon: AppLucideIcons.shapes,
                    title: 'Design Gallery',
                    subtitle: 'Qirsh flagship design system — debug only',
                    onTap: () => context.push('/design'),
                  ),
                  _NavTile(
                    icon: AppLucideIcons.refreshCw,
                    title: 'Sync diagnostics',
                    subtitle: 'Queue, health and capability state — debug only',
                    onTap: () => context.push('/settings/sync-diagnostics'),
                  ),
                ],
              )),
        ],
      ],
    );
  }

  Future<bool> _savePrefs(
    WidgetRef ref,
    NotificationPreferences preferences,
  ) async {
    if (_savingPrefs) return false;
    setState(() => _savingPrefs = true);
    try {
      await ref.read(saveNotificationPreferencesUseCaseProvider).call(preferences);
      unawaited(NativeCaptureBridge.setHideCaptureDetails(
          preferences.hideLockScreenContent));
      if (mounted) refreshNotificationPreferences(ref);
      return true;
    } catch (_) {
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
      return false;
    } finally {
      if (mounted) setState(() => _savingPrefs = false);
    }
  }

  Future<void> _sendTestNotification(BuildContext context) async {
    final sent = await LocalNotificationService.instance.showTestNotification();
    if (!context.mounted) return;
    if (sent) {
      AppToast.show(context, context.l10n.setTestNotificationSent);
    } else {
      AppToast.showError(context, context.l10n.setTestNotificationFailed);
    }
  }

  /// Sign-out (WP-3b, SYNC-Q2/Q3/Q8). The default choice LOCKS this account's
  /// encrypted replica and keeps everything on the device; a separate, confirmed
  /// choice removes this account's data from the device. Unsynced work is only
  /// WARNED about: it never blocks either choice and nothing is discarded unless
  /// the person explicitly chose removal. The local sign-out comes first so a
  /// failure leaves the device signed in rather than half signed out.
  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // Signing out replaces the account scope, which disposes this screen and
    // every provider built on it: everything the flow needs comes from `ref` now.
    final inventory = ref.read(unsyncedInventoryServiceProvider);
    final auth = ref.read(authServiceProvider);
    UnsyncedInventory? pending;
    try {
      pending = await inventory.collect();
      if (pending.hasPendingUserData) {
        await AppSession.instance.flushPendingForSignOut();
        pending = await inventory.collect(); // re-check after the flush
      }
    } catch (_) {
      // Never traps the user and never discards: without an inventory the sheet
      // simply shows no warning, and its default keeps the data.
      pending = null;
    }
    if (!context.mounted) return;
    // Captured while the screen still exists.
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final failedText = context.l10n.setSignOutFailed;
    final navigator = Navigator.of(context, rootNavigator: true);
    final l10n = context.l10n;
    final choice = await showSignOutSheet(context, pending: pending);
    if (choice == null) return;
    if (choice == SignOutChoice.removeData) {
      if (!context.mounted) return;
      if (!await confirmRemoveData(context, pending: pending)) return;
    }
    // F2: the provider/SDK logout runs from the session layer at the end of the
    // removal (this screen is disposed by the scope swap), best effort, and is
    // neither the admission fence nor a prerequisite of the deletion.
    Future<void> signOutRemote() async {
      try {
        await auth.signOutProviderSession();
      } catch (_) {
        // The local sign-out is already authoritative. A provider logout failure
        // must not reopen access to this account's local data.
      }
      if (SupabaseConfig.isConfigured) {
        try {
          // ASR §4.9: durable removal first, then the server revocation.
          await AuthCoordinator.logout(supabase.Supabase.instance.client.auth);
        } catch (_) {
          // The local sign-out above already protects the device even if the
          // network sign-out fails.
        }
      }
    }

    var outcome = SignOutOutcome.complete;
    try {
      if (choice == SignOutChoice.removeData) {
        // D4: this screen is disposed by the scope swap. An unfinished durable
        // denial is reported by the ROOT (`DenyIncompleteNoticeHost`, fed by the
        // session), not from here, and apart from the data-removed notice.
        await AppSession.instance
            .removeDataFromDevice(signOutRemote: signOutRemote);
        return;
      }
      outcome = await AppSession.instance.signOut();
    } on RemoveDataIncompleteException {
      // The device is signed out locally and the unfinished removal resumes at
      // the next launch or sign-in (the remote sign-out already ran).
      return;
    } catch (_) {
      if (overlay != null) AppToast.showErrorInOverlay(overlay, failedText);
      return;
    }
    await signOutRemote();
    if (outcome == SignOutOutcome.durableDenyIncomplete) {
      await showSignOutIncompleteNotice(navigator, l10n);
    }
  }

  Map<String, String> _countryValues(List<RemoteCountry> countries) {
    return {
      for (final country in countries)
        country.code.toUpperCase():
            '${country.flagEmoji} ${_catalogName(country.nameAr, country.nameEn)}'
                ' · ${country.phonePrefix}',
    };
  }

  Map<String, String> _currencyValuesForCountry(
    String country,
    List<RemoteCurrency> currencies,
  ) {
    final normalizedCountry = country.trim().toUpperCase();
    final scoped = currencies
        .where((currency) => currency.countryCodes.contains(normalizedCountry))
        .toList(growable: false);
    final source = scoped.isEmpty ? currencies : scoped;
    return {
      for (final currency in source)
        currency.code.toUpperCase(): '${currency.code.toUpperCase()}'
            ' · ${_catalogName(currency.nameAr, currency.nameEn)}'
            ' · ${currency.symbol}',
    };
  }

  String _preferredCurrencyForCountry(
    String country,
    List<RemoteCurrency> currencies,
    String current,
  ) {
    final normalizedCountry = country.trim().toUpperCase();
    final normalizedCurrent = current.trim().toUpperCase();
    final countryCurrencies = currencies
        .where((currency) => currency.countryCodes.contains(normalizedCountry))
        .toList(growable: false);
    if (countryCurrencies.any(
      (currency) => currency.code.toUpperCase() == normalizedCurrent,
    )) {
      return normalizedCurrent;
    }
    if (countryCurrencies.isNotEmpty) {
      return countryCurrencies.first.code.toUpperCase();
    }
    return normalizedCurrent;
  }

  Future<void> _pickProfileImage(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 86,
    );
    if (picked == null) return;
    final directory = await getApplicationDocumentsDirectory();
    final extension = p.extension(picked.path).isEmpty
        ? '.jpg'
        : p.extension(picked.path).toLowerCase();
    final avatarsDir = Directory(p.join(directory.path, 'profile'));
    if (!await avatarsDir.exists()) {
      await avatarsDir.create(recursive: true);
    }
    final destination = File(
      p.join(avatarsDir.path, 'avatar$extension'),
    );
    await File(picked.path).copy(destination.path);
    await ref.read(userSettingsRepositoryProvider).saveSettings(
          settings.copyWith(avatarPath: destination.path),
        );
    _refreshSettingsDependents(ref);
    if (!context.mounted) return;
    AppToast.show(context, context.l10n.setPhotoUpdated);
  }

  Future<void> _showProfileTextSheet(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String label,
    required String initialValue,
    required UserSettingsEntity Function(String value) apply,
    TextInputType keyboardType = TextInputType.text,
  }) async {
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => navySheetTheme(_ProfileTextSheet(
        title: title,
        label: label,
        initialValue: initialValue,
        keyboardType: keyboardType,
        onSave: (value) async {
          await ref.read(userSettingsRepositoryProvider).saveSettings(apply(value));
          if (mounted) _refreshSettingsDependents(ref);
        },
      )),
    );
  }

  void _refreshSettingsDependents(WidgetRef ref) {
    refreshUserSettings(ref);
    ref.invalidate(baseCurrencyProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _showSettingsPicker(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String current,
    required Map<String, String> values,
    UserSettingsEntity Function(String value)? apply,
    Future<void> Function(String value)? save,
  }) {
    final c = context.colors;
    return showGlassSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => navySheetTheme(Directionality(
        textDirection: Directionality.of(context),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          children: [
            Text(title, style: AppTypography.sectionTitle(c.textMain)),
            const SizedBox(height: AppSpacing.s3),
            for (final entry in values.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: current,
                secondary: title == context.l10n.setCountry
                    ? _FlagAvatar(code: entry.key.toLowerCase(), size: 32)
                    : null,
                title: Text(
                  entry.value,
                  style: AppTypography.bodyStrong(c.textMain),
                ),
                subtitle: title == context.l10n.setCountry
                    ? Text(
                        entry.key.toUpperCase(),
                        style: AppTypography.caption(c.textLight),
                      )
                    : null,
                activeColor: c.primary,
                onChanged: (value) async {
                  if (value == null) return;
                  if (save != null) {
                    await save(value);
                  } else if (apply != null) {
                    await ref
                        .read(userSettingsRepositoryProvider)
                        .saveSettings(apply(value));
                  }
                  _refreshSettingsDependents(ref);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
        ),
      )),
    );
  }

  Future<void> _showCategoriesSheet(BuildContext context, WidgetRef ref) async {
    final c = context.colors;
    final initialCatalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Consumer(builder: (context, sheetRef, _) {
        final catalog = sheetRef.watch(categoryCatalogProvider).valueOrNull ??
            initialCatalog;
        final income = catalog.all.where((item) => item.entity.isIncome).toList();
        final transfers =
            catalog.all.where((item) => item.key == 'transfers').toList();
        final expenses = catalog.all
            .where((item) =>
                !item.entity.isIncome &&
                item.key != 'transfers' &&
                item.key != 'all_expenses')
            .toList();
        return navySheetTheme(Directionality(
        textDirection: Directionality.of(context),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            children: [
              Text(context.l10n.setCategories,
                  style: AppTypography.sectionTitle(c.textMain)),
              Text(
                context.l10n.setCategoriesSheetIntro,
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s3),
              FilledButton.icon(
                onPressed: () => _showCategoryForm(context, ref),
                icon: const Icon(AppLucideIcons.plus),
                label: Text(context.l10n.setAddCategory),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: context.l10n.setExpenses,
                items: expenses,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: context.l10n.setIncome,
                items: income,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: context.l10n.setTransfers,
                items: transfers,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
            ],
          ),
        ),
      ));
      }),
    );
  }

  Future<void> _showCategoryForm(
    BuildContext context,
    WidgetRef ref, {
    CategoryView? item,
  }) async {
    final c = context.colors;
    final name = TextEditingController(text: item?.nameAr ?? '');
    var icon = item?.entity.icon ?? 'shapes';
    var color = item?.entity.color ?? '#9E9E9E';
    var isIncome = item?.entity.isIncome ?? false;
    final isEditing = item != null;
    const icons = [
      ('shapes', 'other'),
      ('utensils-crossed', 'restaurants'),
      ('shopping-basket', 'groceries'),
      ('shopping-bag', 'shopping'),
      ('car-taxi-front', 'transport'),
      ('receipt-text', 'bills'),
      ('wallet-cards', 'cards'),
      ('banknote', 'cash'),
      ('coffee', 'cafes'),
      ('gift', 'gifts'),
      ('house', 'home'),
      ('plane', 'travel'),
      ('heart-pulse', 'health'),
      ('graduation-cap', 'education'),
      ('arrow-left-right', 'transfers'),
    ];
    const colors = [
      ('#9E9E9E', 'grey'),
      ('#FF7043', 'coral'),
      ('#43A047', 'green'),
      ('#1E88E5', 'blue'),
      ('#8E24AA', 'purple'),
      ('#00C853', 'brightGreen'),
      ('#00897B', 'teal'),
      ('#D81B60', 'pink'),
      ('#546E7A', 'blueGrey'),
      ('#FB8C00', 'orange'),
    ];

    ModalRoute<void>? categoryRoute;
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        categoryRoute = ModalRoute.of<void>(context);
        return navySheetTheme(StatefulBuilder(
        builder: (context, setState) => Directionality(
          textDirection: Directionality.of(context),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
            ),
            child: ListView(
              children: [
                Text(
                  isEditing
                      ? context.l10n.setEditCategory
                      : context.l10n.setAddCategory,
                  style: AppTypography.sectionTitle(c.textMain),
                ),
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: context.l10n.setCategoryName,
                    prefixIcon: const Icon(AppLucideIcons.tag),
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isIncome,
                  onChanged: (value) => setState(() => isIncome = value),
                  title: Text(context.l10n.setIncomeCategory),
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(context.l10n.setIcon,
                    style: AppTypography.subhead(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in [
                      if (!icons.any((entry) => entry.$1 == icon)) (icon, 'other'),
                      ...icons,
                    ])
                      _CategoryChoiceTile(
                        key: ValueKey('category-icon-${choice.$1}'),
                        label: context.l10n.setCategoryIconName(choice.$2),
                        selected: icon == choice.$1,
                        onTap: () => setState(() => icon = choice.$1),
                        child: CategoryGlyph(name: choice.$1, size: 24,
                            color: c.textMain),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                Text(context.l10n.setColor,
                    style: AppTypography.subhead(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in [
                      if (!colors.any((entry) => entry.$1 == color)) (color, 'other'),
                      ...colors,
                    ])
                      _CategoryChoiceTile(
                        key: ValueKey('category-colour-${choice.$1}'),
                        label: context.l10n.setCategoryColourName(choice.$2),
                        selected: color == choice.$1,
                        onTap: () => setState(() => color = choice.$1),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Formatters.colorFromHex(choice.$1),
                          ),
                          child: color == choice.$1
                              ? Icon(AppLucideIcons.check, size: 18,
                                  color: Formatters.colorFromHex(choice.$1)
                                              .computeLuminance() > 0.4
                                      ? Colors.black : Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                FilledButton(
                  onPressed: () async {
                    final title = name.text.trim();
                    if (title.isEmpty) {
                      AppToast.showError(context, context.l10n.setEnterCategoryName);
                      return;
                    }
                    final repo = ref.read(categoryRepositoryProvider);
                    if (item == null) {
                      await repo.createCategory(
                        nameAr: title,
                        icon: icon,
                        color: color,
                        isIncome: isIncome,
                      );
                    } else {
                      await repo.updateCategory(
                        CategoryEntity(
                          id: item.id,
                          key: item.key,
                          nameAr: title,
                          icon: icon,
                          color: color,
                          isIncome: isIncome,
                          sort: item.entity.sort,
                        ),
                      );
                    }
                    _refreshCategoryDependents(ref);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(isEditing
                      ? context.l10n.setSaveChanges
                      : context.l10n.setAdd),
                ),
              ],
            ),
          ),
        ),
        ));
      },
    );
    // The modal result resolves when popped, before its exit animation ends.
    // Keep the name controller alive until the route releases its TextField.
    await categoryRoute?.completed;
    name.dispose();
  }

  Future<void> _deleteCategory(
    BuildContext context,
    WidgetRef ref,
    CategoryView item,
  ) async {
    if (item.entity.sort < 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(context.l10n.setDeleteCategoryQ),
        content: Text(
          context.l10n.setDeleteCategoryBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.setCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            child: Text(context.l10n.setDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(categoryRepositoryProvider).deleteCategory(item.id);
    _refreshCategoryDependents(ref);
  }

  void _refreshCategoryDependents(WidgetRef ref) {
    ref.invalidate(categoryCatalogProvider);
    refreshTransactions(ref);
    refreshBudgets(ref);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _showQuietHoursSheet(
    BuildContext context,
    WidgetRef ref,
    NotificationPreferences preferences,
  ) {
    final c = context.colors;
    var start = preferences.quietHoursStartHour;
    var end = preferences.quietHoursEndHour;
    var saving = false;
    return showGlassSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => navySheetTheme(StatefulBuilder(
        builder: (context, setState) => Directionality(
          textDirection: Directionality.of(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.l10n.setQuietHours,
                    style: AppTypography.sectionTitle(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  context.l10n.setQuietHoursNote,
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  children: [
                    Expanded(
                      child: _HourPicker(
                        label: context.l10n.setStarts,
                        value: start,
                        onChanged: saving ? null : (value) => setState(() => start = value),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: _HourPicker(
                        label: context.l10n.setEnds,
                        value: end,
                        onChanged: saving ? null : (value) => setState(() => end = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                SizedBox(
                  height: AppSpacing.buttonHeight,
                  child: FilledButton(
                    onPressed: saving ? null : () async {
                      setState(() => saving = true);
                      final saved = await _savePrefs(
                        ref,
                        preferences.copyWith(
                          quietHoursStartHour: start,
                          quietHoursEndHour: end,
                        ),
                      );
                      if (!context.mounted) return;
                      if (saved) {
                        Navigator.of(context).pop();
                      } else {
                        setState(() => saving = false);
                      }
                    },
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      context.l10n.setSave,
                      style: AppTypography.bodyStrong(c.onInk),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      )),
    );
  }

  void _showAboutApp(BuildContext context) {
    _showInfoSheet(
      context,
      title: context.l10n.setAboutApp,
      photo: QirshPhoto.brand,
      body: context.l10n.setAboutBody,
      actionLabel: context.l10n.setOk,
    );
  }

  void _showContactSupport(BuildContext context) {
    _showInfoSheet(
      context,
      title: context.l10n.setContactUs,
      illustration: 'help',
      body: context.l10n.setSupportBody,
      actionLabel: context.l10n.setCopyEmail,
      onAction: () async {
        await Clipboard.setData(
          const ClipboardData(text: 'support@money-companion.app'),
        );
      },
    );
  }

  void _showInfoSheet(
    BuildContext context, {
    required String title,
    required String body,
    required String actionLabel,
    Future<void> Function()? onAction,
    QirshPhoto? photo,
    String? illustration,
  }) {
    final c = context.colors;
    showGlassSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => navySheetTheme(Directionality(
        textDirection: Directionality.of(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (photo != null) QirshPhotoBanner(photo: photo,
                height: 150, margin: const EdgeInsets.only(bottom: 14)),
              if (illustration != null) ...[
                Center(child: QirshIllustration(
                    name: illustration, width: 120, height: 90)),
                const SizedBox(height: AppSpacing.s3),
              ],
              Text(title, style: AppTypography.sectionTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(body, style: AppTypography.callout(c.textLight)),
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: AppSpacing.buttonHeight,
                child: FilledButton(
                  onPressed: () async {
                    await onAction?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    actionLabel,
                    style: AppTypography.bodyStrong(c.onInk),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }

  // Retained F2 removal flow; ordinary logout no longer exposes it.
  // ignore: unused_element
  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(context.l10n.setEraseAllQ),
        content: Text(context.l10n.setEraseAllBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.setCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.setErase),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // The reset replaces the account scope, which disposes this screen, so the
    // navigation uses the app router rather than this screen's context.
    await AppSession.instance.resetAllLocalData(
      signOutRemote: SupabaseConfig.isConfigured
          ? () => AuthCoordinator.logout(supabase.Supabase.instance.client.auth)
          : null,
    );
    appRouter.go('/welcome');
  }
}

class _SettingsLoadingState extends StatelessWidget {
  const _SettingsLoadingState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 140,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.border),
      ),
      child: const CircularProgressIndicator(),
    );
  }
}

class _SettingsErrorState extends StatelessWidget {
  const _SettingsErrorState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.dangerBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(AppLucideIcons.alertCircle, color: c.danger),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              context.l10n.setSettingsLoadFailed,
              style: AppTypography.body(c.textMain),
            ),
          ),
        ],
      ),
    );
  }
}

/// Profile and canonical level summary, followed by the existing settings.
class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({
    required this.name,
    required this.contact,
    required this.avatarPath,
    this.levelKey,
    this.totalXp,
    this.onBack,
    this.onAvatarTap,
    this.onNameTap,
  });

  final String name;
  final String contact;
  final String avatarPath;
  final String? levelKey;
  final int? totalXp;
  final VoidCallback? onBack;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNameTap;

  String _levelName(BuildContext context) => switch (levelKey) {
    'organized' => context.l10n.achLevelOrganised,
    'smart_saver' => context.l10n.achLevelSmartSaver,
    'financial_expert' => context.l10n.achLevelExpert,
    'saving_legend' => context.l10n.achLevelLegend,
    _ => context.l10n.achLevelBeginner,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final file = avatarPath.isEmpty ? null : File(avatarPath);
    final hasImage = file != null && file.existsSync();
    final initial = name.trim().isEmpty ? 'م' : name.characters.first;
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.gutter,
          MediaQuery.paddingOf(context).top + 16, AppSpacing.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (onBack != null) IconButton(
            tooltip: context.l10n.setBack,
            onPressed: onBack,
            icon: const BackButtonIcon(),
            color: c.textPrimary,
          ),
          Expanded(child: Text(onBack == null ? context.l10n.navMore : context.l10n.setSettings,
            style: AppTypography.title1(c.textPrimary))),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border), boxShadow: AppShadows.card),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              GestureDetector(onTap: onAvatarTap,
                child: Container(width: 54, height: 54, alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: const Color(0xFFFFD46C),
                    borderRadius: BorderRadius.circular(27)),
                  child: hasImage
                    ? Image.file(file, fit: BoxFit.cover, width: 54, height: 54)
                    : Text(initial, style: AppTypography.title2(const Color(0xFF0A2540))))),
              const SizedBox(width: 12),
              Expanded(child: GestureDetector(onTap: onNameTap,
                behavior: HitTestBehavior.opaque,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTypography.headline(c.textPrimary)),
                    const SizedBox(height: 4),
                    Text(contact, maxLines: 1, overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: AppTypography.caption(c.textMuted)),
                  ]))),
              const SizedBox(width: 8),
              TextButton(onPressed: onNameTap,
                style: TextButton.styleFrom(backgroundColor: c.surfaceMuted,
                  foregroundColor: c.textPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Text(context.l10n.setEdit)),
            ]),
            if (levelKey != null && totalXp != null) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: c.divider),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text('${context.l10n.achLevel} ${_levelName(context)}',
                  style: AppTypography.caption(c.textMuted))),
                Text('$totalXp XP', textDirection: TextDirection.ltr,
                  style: AppTypography.caption(c.textPrimary)),
                const SizedBox(width: 6),
                SizedBox(width: 32, height: 32, child: IconButton(
                  padding: EdgeInsets.zero, tooltip: context.l10n.achTitle,
                  onPressed: () => context.push('/achievements'),
                  icon: Icon(AppLucideIcons.trophy, color: c.primary, size: 18))),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.description,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.s2, 0, AppSpacing.s2, AppSpacing.s1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.footnote(c.textLight)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              if (description != null) ...[
                const SizedBox(height: 1),
                Text(
                  description!,
                  style: AppTypography.micro(c.textMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
            boxShadow: AppShadows.card,
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      indent: AppSpacing.s4,
                      endIndent: AppSpacing.s4,
                      color: c.divider,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final options = <(ThemeMode, IconData, String)>[
      (ThemeMode.system, AppLucideIcons.monitor, l10n.setThemeAuto),
      (ThemeMode.light, AppLucideIcons.sun, l10n.setThemeLight),
      (ThemeMode.dark, AppLucideIcons.moon, l10n.setThemeDark),
    ];
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          for (final (mode, icon, label) in options) ...[
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(mode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  // المختار = سطح ink الموحّد (كان أزرق ctaSoft).
                  decoration: BoxDecoration(
                    color: value == mode ? c.ink : c.surfaceMuted,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: value == mode ? null : Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        icon,
                        size: 20,
                        color: value == mode ? c.onInk : c.textSecondary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: AppTypography.caption(
                          value == mode ? c.onInk : c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (mode != ThemeMode.dark) const SizedBox(width: AppSpacing.s3),
          ],
        ],
      ),
    );
  }
}

class _CategoryChoiceTile extends StatelessWidget {
  const _CategoryChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          color: selected ? c.primary.withValues(alpha: 0.10) : c.surface2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: selected ? c.primary : c.border,
                width: selected ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 48, height: 48,
                child: Center(child: ExcludeSemantics(child: child))),
          ),
        ),
      ),
    );
  }
}

class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.title,
    required this.items,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final List<CategoryView> items;
  final ValueChanged<CategoryView> onEdit;
  final ValueChanged<CategoryView> onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
          child: Text(title, style: AppTypography.caption(c.textLight)),
        ),
        const SizedBox(height: AppSpacing.s2),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                    leading: AppAvatar.category(category: items[i]),
                    title: Text(items[i].name),
                    subtitle: Text(items[i].entity.isIncome
                        ? context.l10n.setIncome
                        : items[i].key == 'transfers'
                            ? context.l10n.setTransfers
                            : context.l10n.setExpenses),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: context.l10n.setEdit,
                          onPressed: () => onEdit(items[i]),
                          icon: const Icon(AppLucideIcons.pencil),
                        ),
                        if (items[i].entity.sort >= 0)
                          IconButton(
                            tooltip: context.l10n.setDelete,
                            onPressed: () => onDelete(items[i]),
                            icon: Icon(AppLucideIcons.trash2, color: c.danger),
                          ),
                      ],
                    ),
                  ),
                  if (i != items.length - 1)
                    Divider(height: 1, color: c.border),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.code, required this.size});

  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: c.surface,
        shape: BoxShape.circle,
        border: Border.all(color: c.border),
      ),
      child: ClipOval(
        child: SvgPicture.asset(
          'assets/flags/$code.svg',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _AppLockTile extends StatefulWidget {
  const _AppLockTile();

  @override
  State<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<_AppLockTile> {
  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppLockService.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await AppLockService.instance
          .setEnabled(value, reason: context.l10n.lockPrompt);
      if (!mounted) return;
      if (ok) {
        setState(() => _enabled = value);
      } else {
        AppToast.showError(context, context.l10n.setAppLockFailed);
      }
    } catch (_) {
      if (mounted) {
        AppToast.showError(context, context.l10n.setupSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SwitchTile(
      title: context.l10n.setAppLock,
      icon: AppLucideIcons.lock,
      iconColor: c.primary,
      value: _enabled,
      onChanged: _loading || _busy ? null : _setEnabled,
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      minVerticalPadding: AppSpacing.s2,
      leading: _TileIcon(icon: icon, color: iconColor ?? c.primary),
      title: Text(title, style: AppTypography.subhead(c.textMain)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption(c.textLight),
            ),
      trailing: DirectionalChevron(color: c.textMuted, size: 20),
      onTap: onTap,
    );
  }
}

/// MALI-013 — the Android automatic-SMS-capture switch.
///
/// ## Why it renders from the platform, never from a local bool
///
/// Every input can change outside this screen: the OS permission can be revoked
/// in system Settings while the app is backgrounded, and the stored opt-in is
/// reset on identity change. A locally-held boolean would leave the switch ON
/// for a permission Android has already taken away — the app claiming to
/// capture a user's bank messages when it cannot is the one lie this feature
/// must never tell. So the value is always the platform's `effective` state.
///
/// ## Disclosure ordering is structural
///
/// Turning the switch on calls `requestAndEnable`, which takes the disclosure
/// as a callback and has no path to the system dialog without it returning
/// true. Play treats a permission dialog shown before the disclosure as a
/// violation even when the user then grants it, so the ordering cannot be left
/// to whoever calls this — and it is not.
class _SmsAutoCaptureTile extends ConsumerWidget {
  const _SmsAutoCaptureTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final caps = ref.watch(captureCapabilitiesProvider).valueOrNull;
    // Hidden until the platform confirms the build declares the permission.
    // iOS, and any future share-only Android build, never see this row.
    if (caps == null || !caps.receiveSmsDeclared) {
      return const SizedBox.shrink();
    }

    final enabled = caps.isAutomaticSmsCaptureEnabled;
    final blocked = !caps.hasReceiveSmsPermission && !enabled;

    Future<void> refresh() async {
      ref.invalidate(captureCapabilitiesProvider);
      await ref.read(captureCapabilitiesProvider.future);
    }

    Future<void> onChanged(bool wanted) async {
      final l10n = context.l10n;
      final service = AndroidSmsCaptureService.instance;
      if (!wanted) {
        // Off is immediate and does NOT revoke the OS permission — that is the
        // user's business in system Settings. This is the in-app stop switch
        // and it has to work while the permission is still granted.
        await service.disableAutomaticCapture();
        await refresh();
        return;
      }

      final result = await service.requestAndEnable(
        showDisclosure: () => showSmsCaptureDisclosure(context),
      );
      await refresh();
      if (!context.mounted) return;

      switch (result.status) {
        case SmsPermissionStatus.granted:
          return;
        case SmsPermissionStatus.permanentlyDenied:
          // The ONLY route out of "don't ask again": asking again returns
          // instantly without showing anything, so offering a retry here would
          // be a button that silently does nothing.
          final go = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => GlassAlertDialog(
              title: Text(l10n.smsAutoCaptureDeniedTitle),
              content: Text(l10n.smsAutoCaptureDeniedBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.smsAutoCaptureOpenSettings),
                ),
              ],
            ),
          );
          if (go ?? false) await service.openSystemSettings();
        case SmsPermissionStatus.denied:
        case SmsPermissionStatus.unavailable:
        case SmsPermissionStatus.inProgress:
          // Declined, dismissed, denied-but-askable, or a platform error. The
          // switch stays off and share/manual capture keep working; there is
          // nothing to announce.
          return;
      }
    }

    return _SwitchTile(
      title: l10n.smsAutoCaptureTitle,
      icon: AppLucideIcons.messageSquare,
      value: enabled,
      subtitle: enabled
          ? l10n.smsAutoCaptureSubtitleOn
          : blocked
              ? l10n.smsAutoCaptureSubtitleBlocked
              : l10n.smsAutoCaptureSubtitleOff,
      onChanged: (v) => unawaited(onChanged(v)),
    );
  }
}

class _TrustNoticeTile extends StatelessWidget {
  const _TrustNoticeTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileIcon(icon: AppLucideIcons.shieldCheck, color: c.success),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              text,
              style: AppTypography.caption(c.textLight).copyWith(height: 1.45),
              textAlign: TextAlign.start,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureHealthTile extends StatelessWidget {
  const _CaptureHealthTile({required this.status});

  final CaptureHealthStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final subtitle = status.lastCaptureAt == null
        ? context.l10n.setNoBankMessageYet
        : context.l10n.setLastCapture(_captureGapLabel(context, status.gap!));
    final apnsFailure = status.apnsRegistrationFailure;
    final color = status.shouldNudge ? c.accent : c.success;
    final title = apnsFailure != null
        ? context.l10n.setCaptureEnableFailed
        : status.shouldNudge
            ? context.l10n.setNoBankMessagesRecently
            : context.l10n.setBankCaptureStatus;
    final statusSubtitle = apnsFailure != null
        ? context.l10n.setApnsFailed(apnsFailure.message)
        : status.shouldNudge
            ? context.l10n.setCheckShortcutStillOn(subtitle)
            : subtitle;
    final Widget? trailing = status.shouldNudge
        ? TextButton(
            onPressed:
                Platform.isIOS ? () => showIosShortcutSheet(context) : null,
            child: Text(context.l10n.setCheck),
          )
        : null;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      leading: _TileIcon(icon: AppLucideIcons.shieldCheck, color: color),
      title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
      subtitle: Text(
        statusSubtitle,
        style: AppTypography.caption(c.textLight),
      ),
      trailing: trailing,
    );
  }
}

/// MALI-053n: precise "what will be lost" text for the sign-out discard dialog.
String _captureGapLabel(BuildContext context, Duration gap) {
  if (gap.inDays >= 1) return context.l10n.setGapDays(gap.inDays);
  if (gap.inHours >= 1) return context.l10n.setGapHours(gap.inHours);
  return context.l10n.setGapToday;
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.icon,
    this.iconColor,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? iconColor;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SwitchListTile(
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      minVerticalPadding: AppSpacing.s2,
      secondary: _TileIcon(icon: icon, color: iconColor ?? c.primary),
      value: value,
      onChanged: onChanged,
      activeThumbColor: c.onCta,
      activeTrackColor: c.cta,
      title: Text(title, style: AppTypography.subhead(c.textMain)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.caption(c.textLight)),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // نفس تايل [AppAvatar] بالظبط — سوبر-إليبس بلون هادي وجليف بلونه
    // (`iconTile` في النموذج).
    return AppAvatar.icon(icon: icon, color: color, tone: AppAvatarTone.soft);
  }
}

class _HourPicker extends StatelessWidget {
  const _HourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.subhead(c.textLight)),
        const SizedBox(height: AppSpacing.s2),
        GlassDropdownField<int>(
          value: value,
          decoration: InputDecoration(
            filled: true,
            fillColor: c.surface2.withValues(alpha: 0.55),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: c.border),
            ),
          ),
          items: [
            for (var hour = 0; hour < 24; hour++)
              DropdownMenuItem(
                value: hour,
                child: Text(Formatters.hourOfDay(hour, context)),
              ),
          ],
          onChanged: onChanged == null ? null : (value) {
            if (value != null) onChanged!(value);
          },
        ),
      ],
    );
  }
}
