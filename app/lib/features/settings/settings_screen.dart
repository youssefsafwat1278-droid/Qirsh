import 'profile_image_store.dart';
import '../../core/utils/l10n_ext.dart';
import '../capture/widgets/sms_auto_capture_enable.dart';
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
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_coordinator.dart';
import '../../core/auth/auth_service.dart';
import '../../core/auth/auth_methods_config.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/observability/diagnostic_export.dart';
import '../../core/di/app_providers.dart';
import '../planning_sync/planning_conflicts_sheet.dart';
import 'sign_out_sheet.dart';
import 'sign_in_methods_sheet.dart';
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
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../common/motion.dart';
import '../dashboard/dashboard_providers.dart';
import '../capture/services/local_notification_service.dart';
import '../onboarding/ios_shortcut_guide.dart';
import '../transactions/transactions_providers.dart';
import 'settings_providers.dart';
import 'sync_status_ui.dart';
import 'widgets/settings_v2.dart';
import '../common/app_button.dart';
import '../common/app_card.dart';
import '../../core/backend/app_version.dart';
import '../../core/theme/app_motion.dart';
import '../../domain/usecases/gamification_rules.dart';
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

/// The «المزيد» hub and its one-topic sub-pages (Calm Capital v2 §09).
enum SettingsPage { hub, account, appearance, capture, alerts, security }

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    super.key,
    this.showBackButton = false,
    this.page = SettingsPage.hub,
  });

  final bool showBackButton;

  /// Which page this instance renders. Sub-pages share this state class, so
  /// every control keeps exactly the save path it had in the single scroll.
  final SettingsPage page;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _savingPrefs = false;
  bool _showDeveloper = false;
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
    return switch (widget.page) {
      SettingsPage.hub => _buildHub(context, ref),
      SettingsPage.account => _buildAccountPage(context, ref),
      SettingsPage.appearance => _buildAppearancePage(context, ref),
      SettingsPage.capture => _buildCapturePage(context, ref),
      SettingsPage.alerts => _buildAlertsPage(context, ref),
      SettingsPage.security => _buildSecurityPage(context, ref),
    };
  }

  /// v2: «المزيد» is a hub; each settings topic is its own sub-page with the
  /// same controls it had in the old single scroll.
  void _openPage(BuildContext context, SettingsPage page) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(page: page, showBackButton: true),
    ));
  }

  String _themeLabel(BuildContext context, ThemeMode mode) => switch (mode) {
        ThemeMode.light => context.l10n.setThemeLight,
        ThemeMode.dark => context.l10n.setThemeDark,
        ThemeMode.system => context.l10n.setThemeAuto,
      };

  /// Progress through the current XP tier, for the profile card's gold bar.
  static double _xpProgress(AchievementsView? view) {
    if (view == null) return 0;
    final next = view.nextLevelThreshold;
    if (next == null) return 1;
    final level = view.xpLevel.level.clamp(1, XpLevelEngine.thresholds.length);
    final floor = XpLevelEngine.thresholds[level - 1];
    final span = next - floor;
    if (span <= 0) return 1;
    return ((view.xpLevel.totalXp - floor) / span).clamp(0.0, 1.0);
  }

  Widget _buildHub(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    final achievements = ref.watch(achievementsViewProvider).valueOrNull;
    final captureHealth = ref.watch(captureHealthStatusProvider).valueOrNull;
    final themeMode = ref.watch(themeModeProvider);
    final email = AppSession.instance.email ?? '—';
    final captureNeedsCheck = captureHealth != null &&
        (captureHealth.shouldNudge ||
            captureHealth.apnsRegistrationFailure != null);

    return SettingsV2Page(
      title: widget.showBackButton ? l10n.setSettings : l10n.navMore,
      showBack: widget.showBackButton,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      bottomPadding: 96,
      children: [
        const SizedBox(height: AppSpacing.s3),
        settingsV2Enter(
          0,
          _ProfileCard(
            name: _profileName(settings, email),
            avatarPath: settings?.avatarPath?.trim() ?? '',
            levelKey: achievements?.xpLevel.levelKey,
            totalXp: achievements?.xpLevel.totalXp,
            xpProgress: _xpProgress(achievements),
            onAvatarTap: settings == null
                ? null
                : () => _pickProfileImage(context, ref, settings),
            onNameTap: settings == null
                ? null
                : () => _editName(context, ref, settings),
          ),
        ),
        // MALI-022: surface unresolved multi-device conflicts so they are no
        // longer stuck/invisible. Shown only when some exist.
        if ((ref.watch(conflictsProvider).valueOrNull ?? const [])
            .isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          SettingsV2Group(children: [
            SettingsV2Row(
              icon: AppLucideIcons.cloudOff,
              tileColor: c.warning,
              title: l10n.setSyncConflicts,
              subtitle: l10n.setSyncConflictsSub,
              onTap: () => PlanningConflictsSheet.show(context),
            ),
          ]),
        ],
        // UX-029 — accounts, cards, subscriptions and plans have no tab of
        // their own and legitimately live here, as destinations — split from
        // the configuration entries so they stop reading as a second nav bar.
        settingsV2Enter(
          1,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsV2Label(l10n.setAccountsAndDues),
              _DestinationGrid(items: [
                _Destination(
                  icon: AppLucideIcons.landmark,
                  title: l10n.setAccountsWallets,
                  hint: l10n.setAccountsWalletsSub,
                  onTap: () => context.push('/accounts'),
                ),
                _Destination(
                  icon: AppLucideIcons.creditCard,
                  title: l10n.setAllCards,
                  hint: l10n.setAllCardsSub,
                  onTap: () => MyCardsScreen.open(context),
                ),
                _Destination(
                  icon: AppLucideIcons.repeat,
                  title: l10n.setSubsAndBills,
                  hint: l10n.setSubsAndBillsSub,
                  onTap: () => context.push('/subscriptions'),
                ),
                _Destination(
                  icon: AppLucideIcons.target,
                  title: l10n.setPlans,
                  hint: l10n.setPlansSub,
                  onTap: () => PlansScreen.open(context),
                ),
              ]),
            ],
          ),
        ),
        settingsV2Enter(
          2,
          SettingsV2Group(label: l10n.setV2Tools, children: [
            _NavTile(
              icon: AppLucideIcons.tag,
              title: l10n.setCategories,
              subtitle: l10n.setCategoriesSub,
              onTap: () => _showCategoriesSheet(context, ref),
            ),
            _NavTile(
              icon: AppLucideIcons.trophy,
              title: l10n.setAchievements,
              subtitle: l10n.setAchievementsSub,
              onTap: () => context.push('/achievements'),
            ),
            _NavTile(
              icon: AppLucideIcons.arrowLeftRight,
              title: l10n.setCurrencyRepair,
              subtitle: l10n.setCurrencyRepairSub,
              onTap: () => context.push('/settings/planning-currency-repair'),
            ),
            if (Platform.isIOS)
              _NavTile(
                icon: AppLucideIcons.zap,
                title: l10n.setAppleShortcut,
                subtitle: l10n.setAppleShortcutSub,
                onTap: () => showIosShortcutSheet(context),
              ),
          ]),
        ),
        settingsV2Enter(
          3,
          SettingsV2Group(label: l10n.setSettings, children: [
            _NavTile(
              key: const ValueKey('settings-page-account'),
              icon: AppLucideIcons.user,
              title: l10n.setAccountData,
              onTap: () => _openPage(context, SettingsPage.account),
            ),
            _NavTile(
              key: const ValueKey('settings-page-appearance'),
              icon: AppLucideIcons.palette,
              title: l10n.setAppearance,
              value: _themeLabel(context, themeMode),
              onTap: () => _openPage(context, SettingsPage.appearance),
            ),
            _NavTile(
              key: const ValueKey('settings-page-capture'),
              icon: AppLucideIcons.circleDot,
              title: l10n.setCaptureStatus,
              valueWidget: captureNeedsCheck
                  ? Semantics(
                      label: l10n.setV2CaptureNeedsCheck,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: c.warning, shape: BoxShape.circle),
                      ),
                    )
                  : null,
              onTap: () => _openPage(context, SettingsPage.capture),
            ),
            _NavTile(
              key: const ValueKey('settings-page-alerts'),
              icon: AppLucideIcons.bell,
              title: l10n.setYourAlerts,
              onTap: () => _openPage(context, SettingsPage.alerts),
            ),
            _NavTile(
              icon: AppLucideIcons.arrowUpDown,
              title: l10n.setDataTransfer,
              onTap: () => context.push('/data-transfer'),
            ),
            _NavTile(
              key: const ValueKey('settings-page-security'),
              icon: AppLucideIcons.shieldCheck,
              title: l10n.setSecurityPrivacy,
              onTap: () => _openPage(context, SettingsPage.security),
            ),
          ]),
        ),
        settingsV2Enter(
          4,
          SettingsV2Group(label: l10n.setRewardsAndSupport, children: [
            // Referral discovery is gated by enable_referrals (R3). When the
            // flag is off the tile is hidden — no referral functionality is
            // presented (docs REFERRAL_REWARDS_SYSTEM.md §19/§24).
            if (ref.watch(referralsEnabledProvider))
              _NavTile(
                icon: AppLucideIcons.gift,
                title: l10n.setInviteFriends,
                subtitle: l10n.setInviteFriendsSub,
                onTap: () => context.push('/referrals'),
              ),
            // Ads privacy (R4 §11): shown only when UMP requires privacy
            // options; invokes the Google UMP privacy-options form. UMP is
            // the sole ad-consent authority — no Qirsh consent boolean here.
            if (ref.watch(adPrivacyOptionsRequiredProvider).valueOrNull ??
                false)
              _NavTile(
                icon: Icons.privacy_tip_outlined,
                title: l10n.setAdPrivacyOptions,
                subtitle: l10n.setAdPrivacyOptionsSub,
                onTap: () =>
                    ref.read(adConsentServiceProvider).showPrivacyOptions(),
              ),
            _NavTile(
              icon: AppLucideIcons.messageSquare,
              title: l10n.setContactUs,
              onTap: () => _showContactSupport(context),
            ),
            _NavTile(
              key: const ValueKey('copy-app-diagnostics'),
              icon: AppLucideIcons.copy,
              title: l10n.copyAppDiagnostics,
              subtitle: l10n.copyAppDiagnosticsDescription,
              showChevron: false,
              onTap: () async {
                try {
                  await copyAppDiagnostics();
                  if (context.mounted) {
                    AppToast.show(context, l10n.appDiagnosticsCopied);
                  }
                } catch (_) {
                  if (context.mounted) {
                    AppToast.showError(context, l10n.txnError);
                  }
                }
              },
            ),
            _NavTile(
              icon: AppLucideIcons.info,
              title: l10n.setAboutQirsh,
              onTap: () => _showAboutApp(context),
            ),
            _NavTile(
              icon: AppLucideIcons.helpCircle,
              title: l10n.helpSettingsTile,
              onTap: () => context.push('/help'),
            ),
          ]),
        ),
        const SizedBox(height: AppSpacing.s6),
        SettingsV2Group(children: [
          _NavTile(
            icon: AppLucideIcons.logOut,
            danger: true,
            showChevron: false,
            title: l10n.setSignOut,
            onTap: () => _signOut(context, ref),
          ),
        ]),
        // The version string; in debug builds a long-press reveals the
        // Developer group. Release builds have neither the group nor the
        // gesture (the routes are kDebugMode-gated in app_router.dart too).
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: kDebugMode
              ? () => setState(() => _showDeveloper = !_showDeveloper)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Text(
              l10n.setV2Version(kAppVersion),
              textAlign: TextAlign.center,
              style: AppTypography.mono(size: 13, color: c.textMuted),
            ),
          ),
        ),
        // Debug-only entry point into the Mali design-system review surface
        // (docs/MALI_DESIGN_SYSTEM.md). The route itself is also gated by
        // kDebugMode in app_router.dart, so this tile is redundant defense,
        // not the only gate — it simply doesn't exist in release builds.
        if (kDebugMode)
          if (_showDeveloper)
            SettingsV2Group(label: 'Developer', children: [
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
            ]),
      ],
    );
  }

  void _editName(
      BuildContext context, WidgetRef ref, UserSettingsEntity settings) {
    _showProfileTextSheet(
      context,
      ref,
      title: context.l10n.setName,
      label: context.l10n.setNameInApp,
      initialValue: settings.displayName ?? '',
      apply: (value) => settings.copyWith(displayName: value.trim()),
    );
  }

  /// «بيانات حسابك» (spec 23): identity, sync status and the profile data.
  Widget _buildAccountPage(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final settingsAsync = ref.watch(userSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final achievements = ref.watch(achievementsViewProvider).valueOrNull;
    final countriesAsync = ref.watch(supportedCountriesProvider);
    final currenciesAsync = ref.watch(activeCurrenciesProvider);
    final email = AppSession.instance.email ?? '—';
    final countries = countriesAsync.valueOrNull ?? const <RemoteCountry>[];
    final currencies = currenciesAsync.valueOrNull ?? const <RemoteCurrency>[];
    final hasPhone = settings?.phoneNumber?.trim().isNotEmpty ?? false;

    return SettingsV2Page(
      title: l10n.setAccountData,
      children: [
        const SizedBox(height: AppSpacing.s4),
        settingsV2Enter(
          0,
          _IdentityHeader(
            name: _profileName(settings, email),
            contact: hasPhone ? settings!.phoneNumber!.trim() : email,
            avatarPath: settings?.avatarPath?.trim() ?? '',
            levelKey: achievements?.xpLevel.levelKey,
            totalXp: achievements?.xpLevel.totalXp,
            onAvatarTap: settings == null
                ? null
                : () => _pickProfileImage(context, ref, settings),
            onNameTap: settings == null
                ? null
                : () => _editName(context, ref, settings),
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        // A-5: the one quiet answer to "did my data reach the cloud?".
        const SyncStatusTile(banner: true),
        if (settings != null)
          settingsV2Enter(
            1,
            SettingsV2Group(label: l10n.setAccountData, children: [
              if (!AppSession.instance.isGuest &&
                  (ref.watch(authMethodsConfigProvider).google ||
                      ref.watch(authMethodsConfigProvider).email))
                _NavTile(
                  key: const ValueKey('settings-sign-in-methods'),
                  icon: AppLucideIcons.shieldCheck,
                  title: l10n.authSignInMethods,
                  subtitle: l10n.authSignInMethodsDescription,
                  onTap: () => showGlassSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => const SignInMethodsSheet()),
                ),
              _NavTile(
                icon: AppLucideIcons.smartphone,
                title: l10n.setMobileNumber,
                value: hasPhone ? settings.phoneNumber!.trim() : null,
                valueLtr: hasPhone,
                valueWidget: hasPhone
                    ? null
                    : Text(l10n.setAddYourNumber,
                        style: AppTypography.subhead(c.actionText)),
                onTap: () => _showProfileTextSheet(
                  context,
                  ref,
                  title: l10n.setMobileNumber,
                  label: l10n.setMobileNumber,
                  keyboardType: TextInputType.phone,
                  initialValue: settings.phoneNumber ?? '',
                  apply: (value) =>
                      settings.copyWith(phoneNumber: value.trim()),
                ),
              ),
              _NavTile(
                icon: AppLucideIcons.flag,
                title: l10n.setCountry,
                value: _countryLabel(
                    settings, countries, countriesAsync.isLoading),
                onTap: countries.isEmpty
                    ? null
                    : () => _editCountry(
                        context, ref, settings, countries, currencies),
              ),
              _NavTile(
                icon: AppLucideIcons.banknote,
                title: l10n.setBaseCurrency,
                value: _currencyLabel(
                    settings, currencies, currenciesAsync.isLoading),
                onTap: currencies.isEmpty
                    ? null
                    : () => _editCurrency(context, ref, settings, currencies),
              ),
              _NavTile(
                // Named so the device walk can reach the control by identity
                // rather than by a label that changes language the moment it
                // is used.
                key: const ValueKey('settings-language'),
                icon: AppLucideIcons.globe,
                title: l10n.setLanguage,
                value: languageValues[_languageKey(settings)]!,
                onTap: () => _editLanguage(context, ref, settings),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _buildAppearancePage(BuildContext context, WidgetRef ref) {
    return SettingsV2Page(
      title: context.l10n.setAppearance,
      subtitle: context.l10n.setV2AppearanceLead,
      children: [
        const SizedBox(height: AppSpacing.s5),
        settingsV2Enter(
          0,
          _ThemeModeSelector(
            value: ref.watch(themeModeProvider),
            onChanged: (mode) => ref.read(themeModeProvider.notifier).set(mode),
          ),
        ),
      ],
    );
  }

  Widget _buildCapturePage(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final captureHealthAsync = ref.watch(captureHealthStatusProvider);
    return SettingsV2Page(
      title: context.l10n.setCaptureStatus,
      subtitle: context.l10n.setCaptureStatusSub,
      children: [
        const SizedBox(height: AppSpacing.s5),
        captureHealthAsync.dataOr(
          (status) => settingsV2Enter(0, _CaptureHealthTile(status: status)),
          () => const SizedBox.shrink(),
        ),
        const SizedBox(height: AppSpacing.s3),
        prefsAsync.when(
          skipLoadingOnReload: true,
          loading: () => const _SettingsLoadingState(),
          error: (error, _) => const _SettingsErrorState(),
          data: (prefs) => settingsV2Enter(
            1,
            SettingsV2Group(children: [
              // MALI-013 — the automatic bank-SMS capture opt-in.
              //
              // This is the ONLY way a user can turn the feature on. Until it
              // existed, the app shipped RECEIVE_SMS and a registered
              // SMS_RECEIVED receiver for a feature no user could reach —
              // which fails Play's core-functionality test for a restricted
              // permission and contradicted the already-live privacy policy
              // §8. Android-only, and hidden entirely when the build does not
              // declare the permission.
              const _SmsAutoCaptureTile(),
              // Replaces a sentence that said Qirsh "does not read bank
              // notifications or system SMS". That was true of a fresh install
              // through the UI that existed, and false as a description of
              // what the app implements and declares. The copy is about
              // Android's automatic capture, so it is shown on Android only.
              if (Platform.isAndroid)
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
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildAlertsPage(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    return SettingsV2Page(
      title: context.l10n.setYourAlerts,
      children: [
        const SizedBox(height: AppSpacing.s5),
        prefsAsync.when(
          skipLoadingOnReload: true,
          loading: () => const _SettingsLoadingState(),
          error: (error, _) => const _SettingsErrorState(),
          data: (prefs) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              settingsV2Enter(
                0,
                SettingsV2Group(children: [
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
                    value: prefs.budgetWarning,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(budgetWarning: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setBudgetOverAlert,
                    icon: AppLucideIcons.alertCircle,
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
                    value: prefs.subscriptionReminder,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(subscriptionReminder: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setGoalCelebrations,
                    icon: AppLucideIcons.flag,
                    value: prefs.goalMilestone,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(goalMilestone: value),
                    ),
                  ),
                  _SwitchTile(
                    title: context.l10n.setAchievementAlerts,
                    icon: AppLucideIcons.trophy,
                    value: prefs.achievements,
                    onChanged: _savingPrefs ? null : (value) => _savePrefs(
                      ref,
                      prefs.copyWith(achievements: value),
                    ),
                  ),
                  _SwitchTile(
                    icon: AppLucideIcons.moon,
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
                      value:
                          '${Formatters.hourOfDay(prefs.quietHoursStartHour, context)} - ${Formatters.hourOfDay(prefs.quietHoursEndHour, context)}',
                      onTap: () => _showQuietHoursSheet(context, ref, prefs),
                    ),
                ]),
              ),
              settingsV2Enter(
                1,
                SettingsV2Group(
                    label: context.l10n.setNotificationTools,
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
                    ]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSecurityPage(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(userSettingsProvider);
    final c = context.colors;
    final l10n = context.l10n;
    return SettingsV2Page(
      title: l10n.setSecurityPrivacy,
      children: [
        const SizedBox(height: AppSpacing.s4),
        // UX-030 — the strongest TRUE privacy claim the product can make was
        // never made anywhere in the UI. The local database is opened with
        // `PRAGMA cipher = 'sqlcipher'` and a key held in the platform
        // keychain (`database_key_store.dart`), and the open FAILS CLOSED if
        // the encryption extension is missing rather than continuing
        // unencrypted (`app_database.dart`).
        //
        // Worth stating precisely because it is verifiable, and worth stating
        // carefully: it claims local-database encryption, which is what the
        // code does — not end-to-end encryption, which it does not.
        settingsV2Enter(
          0,
          SettingsV2Tinted(
            background: c.successBg,
            accent: c.success,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.setEncryptedDbPart1 + l10n.setEncryptedDbPart2,
                    style: AppTypography.callout(c.textSecondary),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                const QirshIllustration(name: 'privacy', width: 92, height: 69),
              ],
            ),
          ),
        ),
        settingsV2Enter(
          1,
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: SettingsV2Group(children: [
              _NavTile(
                icon: AppLucideIcons.heartPulse,
                title: l10n.setPrivacyAndData,
                subtitle: l10n.setPrivacyAndDataSub,
                onTap: () => context.push('/privacy'),
              ),
              settingsAsync.dataOr(
                (settings) => _SwitchTile(
                  title: l10n.setHideAmounts,
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
            ]),
          ),
        ),
        // UX-028 — the destructive group is named for what it does.
        settingsV2Enter(
          2,
          SettingsV2Group(
            label: l10n.setExitAndErase,
            children: [
              _NavTile(
                icon: AppLucideIcons.trash2,
                danger: true,
                title: l10n.setDeleteAccount,
                subtitle: l10n.setDeleteAccountSub,
                onTap: () => context.push('/privacy'),
              ),
            ],
          ),
        ),
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
    final destination = await storeProfileImage(
      pickedPath: picked.path,
      documents: await getApplicationDocumentsDirectory(),
      previousPath: settings.avatarPath,
      ownerUid: AppSession.instance.captureConsentCapability()?.uid,
    );
    await ref.read(userSettingsRepositoryProvider).saveSettings(
          settings.copyWith(avatarPath: destination),
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
    return const SettingsV2Group(children: [
      SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      ),
    ]);
  }
}

class _SettingsErrorState extends StatelessWidget {
  const _SettingsErrorState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SettingsV2Tinted(
      background: c.dangerBg,
      accent: c.danger,
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

String _levelName(BuildContext context, String? levelKey) =>
    switch (levelKey) {
      'organized' => context.l10n.achLevelOrganised,
      'smart_saver' => context.l10n.achLevelSmartSaver,
      'financial_expert' => context.l10n.achLevelExpert,
      'saving_legend' => context.l10n.achLevelLegend,
      _ => context.l10n.achLevelBeginner,
    };

/// «المستوى مبتدئ · 0 XP» — the XP figure kept left-to-right.
String _levelLine(BuildContext context, String? levelKey, int totalXp) =>
    '${context.l10n.achLevel} ${_levelName(context, levelKey)} · '
    '\u2066$totalXp XP\u2069';

/// Avatar with a gold ring (v2: gold = value earned). Image or initial.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.name,
    required this.avatarPath,
    required this.size,
    this.onTap,
  });

  final String name;
  final String avatarPath;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final file = avatarPath.isEmpty ? null : File(avatarPath);
    final hasImage = file != null && file.existsSync();
    final initial = name.trim().isEmpty ? 'م' : name.characters.first;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c.accent, width: 2),
        ),
        child: Container(
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: c.goldSoft, shape: BoxShape.circle),
          child: hasImage
              ? Image.file(file, fit: BoxFit.cover, width: size, height: size)
              : Text(
                  initial,
                  style: AppTypography.custom(
                      size: size * 0.36,
                      weight: FontWeight.w700,
                      height: 1.1,
                      color: c.goldText),
                ),
        ),
      ),
    );
  }
}

/// Hub profile card (v2 §09 item 2): `surface.raised` (dark raised + hairline,
/// light white + e2), radius 24, 56pt gold-ringed avatar, name, level line with
/// a 4pt gold XP bar that fills once on enter, trailing tinted «تعديل».
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.name,
    required this.avatarPath,
    required this.xpProgress,
    this.levelKey,
    this.totalXp,
    this.onAvatarTap,
    this.onNameTap,
  });

  final String name;
  final String avatarPath;
  final String? levelKey;
  final int? totalXp;
  final double xpProgress;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNameTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduce = shouldReduceMotion(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: settingsV2RaisedDecoration(context),
      child: Row(children: [
        _ProfileAvatar(
            name: name, avatarPath: avatarPath, size: 56, onTap: onAvatarTap),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: GestureDetector(
            onTap: onNameTap,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.cardTitle(c.textPrimary)),
                if (levelKey != null && totalXp != null) ...[
                  const SizedBox(height: 2),
                  Text(_levelLine(context, levelKey, totalXp!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textMuted)),
                  const SizedBox(height: AppSpacing.s2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: SizedBox(
                      width: 120,
                      height: 4,
                      child: ColoredBox(
                        color: c.surfaceMuted,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: xpProgress),
                          duration: reduce
                              ? Duration.zero
                              : const Duration(milliseconds: 600),
                          curve: AppMotion.easeOut,
                          builder: (context, t, _) => FractionallySizedBox(
                            alignment: AlignmentDirectional.centerStart,
                            widthFactor: t,
                            child: ColoredBox(color: c.accent),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        AppSecondaryButton(
          label: context.l10n.setEdit,
          height: 36,
          onTap: onNameTap,
        ),
      ]),
    );
  }
}

/// «بيانات حسابك» identity header (spec 23): centred 88pt gold-ringed avatar
/// that pops in, name, contact (LTR, middle-ellipsised), level line with a
/// trophy glyph, tinted «تعديل».
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({
    required this.name,
    required this.contact,
    required this.avatarPath,
    this.levelKey,
    this.totalXp,
    this.onAvatarTap,
    this.onNameTap,
  });

  final String name;
  final String contact;
  final String avatarPath;
  final String? levelKey;
  final int? totalXp;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNameTap;

  /// Middle ellipsis for an LTR address: keeps the start and the domain end.
  static String _middleEllipsis(String value, {int max = 30}) {
    if (value.length <= max) return value;
    final head = (max * 0.55).floor();
    final tail = max - head - 1;
    return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final avatar = _ProfileAvatar(
        name: name, avatarPath: avatarPath, size: 88, onTap: onAvatarTap);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        children: [
          if (shouldReduceMotion(context))
            avatar
          else
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.9, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: AppMotion.springLivelyCurve,
              builder: (context, s, child) =>
                  Transform.scale(scale: s, child: child),
              child: avatar,
            ),
          const SizedBox(height: AppSpacing.s3),
          GestureDetector(
            onTap: onNameTap,
            child: Text(name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sectionTitle(c.textPrimary)),
          ),
          const SizedBox(height: 2),
          Text(_middleEllipsis(contact),
              textAlign: TextAlign.center,
              maxLines: 1,
              textDirection: TextDirection.ltr,
              style: AppTypography.callout(c.textMuted)),
          if (levelKey != null && totalXp != null) ...[
            const SizedBox(height: AppSpacing.s2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppLucideIcons.trophy, size: 16, color: c.goldText),
                const SizedBox(width: AppSpacing.s1),
                Text(_levelLine(context, levelKey, totalXp!),
                    style: AppTypography.caption(c.textMuted)),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            width: 140,
            child: AppSecondaryButton(
              label: context.l10n.setEdit,
              height: 40,
              onTap: onNameTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination({
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String title;

  /// The old row description, kept as an accessibility hint (v2 §09 item 3).
  final String hint;
  final VoidCallback onTap;
}

/// «حساباتك والتزاماتك» — a 2×2 grid of 88pt Group tiles, icon 28pt in
/// `action.text`, title `subhead`.
class _DestinationGrid extends StatelessWidget {
  const _DestinationGrid({required this.items});

  final List<_Destination> items;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: AppSpacing.s3));
      rows.add(Row(children: [
        Expanded(child: _DestinationTile(item: items[i])),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: i + 1 < items.length
              ? _DestinationTile(item: items[i + 1])
              : const SizedBox.shrink(),
        ),
      ]));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(children: rows),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({required this.item});

  final _Destination item;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Semantics(
        button: true,
        hint: item.hint,
        child: InkWell(
          onTap: item.onTap,
          splashFactory: NoSplash.splashFactory,
          highlightColor: settingsV2PressedColor(context),
          child: SizedBox(
            height: 88,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s3 + 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(item.icon, size: 28, color: c.actionText),
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textPrimary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// «المظهر»: three preview tiles «تلقائي / فاتح / داكن» with a mini phone
/// mock each. Unselected: dark well + hairline / light white + strokeSoft.
/// Selected: a 2pt `action` ring and a check badge; the ring morphs between
/// tiles and the theme cross-fades app-wide.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = <(ThemeMode, String)>[
      (ThemeMode.system, l10n.setThemeAuto),
      (ThemeMode.light, l10n.setThemeLight),
      (ThemeMode.dark, l10n.setThemeDark),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Row(
        children: [
          for (final (mode, label) in options) ...[
            Expanded(
              child: _ThemeTile(
                mode: mode,
                label: label,
                selected: value == mode,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(mode);
                },
              ),
            ),
            if (mode != ThemeMode.dark) const SizedBox(width: AppSpacing.s3),
          ],
        ],
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lightCanvas = AppColors.light.bg;
    final darkCanvas = AppColors.dark.bg;
    final canvas = switch (mode) {
      ThemeMode.light => BoxDecoration(color: lightCanvas),
      ThemeMode.dark => BoxDecoration(color: darkCanvas),
      ThemeMode.system => BoxDecoration(
          gradient: LinearGradient(
            colors: [lightCanvas, lightCanvas, darkCanvas, darkCanvas],
            stops: const [0, .5, .5, 1],
          ),
        ),
    };
    final line = c.textMuted.withValues(alpha: 0.35);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ExcludeSemantics(
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: AppMotion.micro,
                    curve: AppMotion.easeOut,
                    height: 96,
                    padding: const EdgeInsets.all(AppSpacing.s2),
                    decoration: BoxDecoration(
                      color: isDark ? c.surfaceMuted : c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.row),
                      border: Border.all(
                        color: selected
                            ? c.ink
                            : (isDark ? c.border : c.strokeSoft),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: canvas.copyWith(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      padding: const EdgeInsets.all(AppSpacing.s2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            height: 20,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              gradient: LinearGradient(
                                  colors: [AppBrandBlue.brand, c.cta]),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final f in const [1.0, 0.7, 0.85]) ...[
                            FractionallySizedBox(
                              alignment: AlignmentDirectional.centerStart,
                              widthFactor: f,
                              child: Container(
                                height: 6,
                                decoration: BoxDecoration(
                                  color: line,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                        ],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: -6,
                    end: -6,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0,
                      duration: AppMotion.base,
                      curve: AppMotion.springLivelyCurve,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: c.cta,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.bg, width: 2),
                        ),
                        child: Icon(AppLucideIcons.check,
                            size: 12, color: c.onCta),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                label,
                style: AppTypography.subhead(
                    selected ? c.actionText : c.textSecondary),
              ),
            ],
          ),
        ),
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
    return _SwitchTile(
      title: context.l10n.setAppLock,
      icon: AppLucideIcons.lock,
      // v2 haptics: toggling app lock is a commit (mediumImpact).
      commitHaptic: true,
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
    this.value,
    this.valueWidget,
    this.valueLtr = false,
    this.danger = false,
    this.showChevron = true,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// The current value, shown at the trailing side in `text.muted`.
  final String? value;
  final Widget? valueWidget;
  final bool valueLtr;
  final bool danger;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SettingsV2Row(
      icon: icon,
      title: title,
      subtitle: subtitle,
      value: value,
      valueWidget: valueWidget,
      valueLtr: valueLtr,
      danger: danger,
      showChevron: showChevron,
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
      if (!wanted) {
        final service = AndroidSmsCaptureService.instance;
        // Off is immediate and does NOT revoke the OS permission — that is the
        // user's business in system Settings. This is the in-app stop switch
        // and it has to work while the permission is still granted.
        await service.disableAutomaticCapture();
        await refresh();
        return;
      }

      await enableAutomaticSmsCapture(context, onRequested: refresh);
    }

    // With Smart Analysis & Cloud Sync accepted, captured messages may leave
    // the device (sanitised) for Qirsh servers and Google Gemini, so the "on"
    // subtitle must not say they are read on the device.
    final consent = ref.watch(userSettingsProvider).valueOrNull;
    final smartAnalysisOn = consent != null &&
        consent.cloudProcessingEnabled &&
        consent.aiConsentGranted;

    return _SwitchTile(
      title: l10n.smsAutoCaptureTitle,
      icon: AppLucideIcons.messageSquare,
      value: enabled,
      subtitle: enabled
          ? (smartAnalysisOn
              ? l10n.smsAutoCaptureSubtitleOnSmart
              : l10n.smsAutoCaptureSubtitleOn)
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
      padding: const EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, AppSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsV2Tile(icon: AppLucideIcons.shieldCheck, color: c.success),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              text,
              style: AppTypography.caption(c.textSecondary).copyWith(height: 1.45),
              textAlign: TextAlign.start,
            ),
          ),
        ],
      ),
    );
  }
}

/// «رصد العمليات» status banner (v2 §09): tinted warningBg when no bank
/// message arrived for a while (with a tinted «تحقق»), successBg when
/// healthy, dangerBg when enabling failed.
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
    final (Color bg, Color tone, Color text) = apnsFailure != null
        ? (c.dangerBg, c.danger, c.danger)
        : status.shouldNudge
            ? (c.warningBg, c.warning, c.warningText)
            : (c.successBg, c.success, c.success);
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SettingsV2Tinted(
      background: bg,
      accent: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: isDark ? 0.22 : 0.18),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Icon(AppLucideIcons.shieldCheck, size: 18, color: text),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.bodyStrong(c.textPrimary)),
                    const SizedBox(height: 2),
                    Text(statusSubtitle,
                        style: AppTypography.caption(c.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          if (status.shouldNudge) ...[
            const SizedBox(height: AppSpacing.s3),
            AppSecondaryButton(
              label: context.l10n.setCheck,
              height: 40,
              onTap:
                  Platform.isIOS ? () => showIosShortcutSheet(context) : null,
            ),
          ],
        ],
      ),
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
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.commitHaptic = false,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool commitHaptic;

  @override
  Widget build(BuildContext context) {
    return SettingsV2SwitchRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      value: value,
      onChanged: onChanged,
      commitHaptic: commitHaptic,
    );
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
