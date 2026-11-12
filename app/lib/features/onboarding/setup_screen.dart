import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../l10n/app_localizations.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/native_capture_bridge.dart';
import '../capture/widgets/sms_auto_capture_enable.dart';
import '../settings/settings_providers.dart';
import 'onboarding_account_step.dart';
import 'onboarding_consent_steps.dart';
import 'onboarding_options.dart';
import 'shortcut_setup_actions.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/theme/app_colors.dart';
import '../common/repo_error_messages.dart';

/// Page 4 of the redesigned onboarding: one activation step at a time.
///
/// Steps, in order:
///   0. Country / currency   → saves the base currency (no account is created)
///   1. Cloud Sync and Smart Analysis → one explicit disclosed choice
///   2. Readiness            → live registration status (never blocks)
///   3. Account Setup        → the user creates their first account (local,
///                             works offline); there is no default account
///   4. Notifications        → OS permission prompt
///   5. iOS: Shortcut install → instructions carousel, self-declared
///      Android: automatic bank-SMS capture → the same opt-in as the
///      Settings switch (disclosure first); "Not now" leaves it off
///
/// Cloud and AI processing consent default OFF (NULL state = off, MALI-059n);
/// each is only granted by its explicit opt-in here or in the privacy
/// settings. It stays the USER's revocable choice (MALI-001): the toggles live
/// in الإعدادات ← الأمان والخصوصية and every capture/sync/AI path honors the
/// stored value.
///
/// Completing a step auto-advances to the next one. The final "ابدأ" finishes
/// onboarding and enters the app once all steps are done AND an account exists.
enum OnboardingSetupEntry { full, captureGuide }

class OnboardingSetupScreen extends ConsumerStatefulWidget {
  const OnboardingSetupScreen({
    super.key,
    this.entry = OnboardingSetupEntry.full,
  });

  final OnboardingSetupEntry entry;

  @override
  ConsumerState<OnboardingSetupScreen> createState() =>
      _OnboardingSetupScreenState();
}

class _CountryChoice {
  _CountryChoice(this.code, this.flag, this.name, this.currency);
  final String code;
  final String flag;
  final String name;
  final String currency;
}

/// Country names come from the ARB, so the list is built per-locale rather
/// than being a `const` frozen at class-load.
///
/// Resolving by code keeps the SELECTION stable while the LABEL follows the
/// language.
List<_CountryChoice> _countriesIn(BuildContext context) => <_CountryChoice>[
      _CountryChoice('SA', '🇸🇦', context.l10n.countrySA, 'SAR'),
      _CountryChoice('AE', '🇦🇪', context.l10n.countryAE, 'AED'),
      _CountryChoice('EG', '🇪🇬', context.l10n.countryEG, 'EGP'),
      _CountryChoice('KW', '🇰🇼', context.l10n.countryKW, 'KWD'),
      _CountryChoice('QA', '🇶🇦', context.l10n.countryQA, 'QAR'),
      _CountryChoice('BH', '🇧🇭', context.l10n.countryBH, 'BHD'),
      _CountryChoice('OM', '🇴🇲', context.l10n.countryOM, 'OMR'),
      _CountryChoice('JO', '🇯🇴', context.l10n.countryJO, 'JOD'),
    ];

class _OnboardingSetupScreenState extends ConsumerState<OnboardingSetupScreen> {
  static const _stepCount = 6;
  static const _accountStep = 3;

  final _done = List<bool>.filled(_stepCount, false);
  // The CODE is state; the label is not. Storing a `_CountryChoice` meant
  // holding a localized name in state, which would keep whichever language was
  // active when the screen was first built.
  String _countryCode = 'SA';
  _CountryChoice _selectedCountry(BuildContext context) =>
      _countriesIn(context).firstWhere((c) => c.code == _countryCode,
          orElse: () => _countriesIn(context).first);

  bool _busy = false;
  int _currentStep = 0;

  @override
  void initState() {
    super.initState();
    if (widget.entry == OnboardingSetupEntry.captureGuide) {
      // Restored user: everything up to and including notifications is done;
      // only the capture step remains. (`_finish` still verifies an account.)
      for (var i = 0; i < _stepCount - 1; i++) {
        _done[i] = true;
      }
      _currentStep = _stepCount - 1;
      unawaited(_loadRestoredCurrency());
    }
  }

  Future<void> _loadRestoredCurrency() async {
    final settings =
        await ref.read(userSettingsRepositoryProvider).getSettings();
    if (!mounted) return;
    final currency = settings.currency.trim().toUpperCase();
    final match =
        _countriesIn(context).where((item) => item.currency == currency);
    if (match.isNotEmpty) {
      setState(() => _countryCode = match.first.code);
    }
  }

  bool get _canFinish => _done.every((done) => done);
  int get _completed => _done.where((d) => d).length;

  void _markDone(int step) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _done[step] = true);
    if (step == _currentStep && step < _stepCount - 1) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted || _currentStep != step) return;
        setState(() => _currentStep = step + 1);
      });
    }
  }

  void _goBack() {
    if (_currentStep == 0) return;
    HapticFeedback.selectionClick();
    setState(() => _currentStep--);
  }

  // ── Step 0: country / currency ────────────────────────────────────────
  Future<void> _saveCountry(_CountryChoice choice) async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _countryCode = choice.code;
      _busy = true;
    });
    try {
      ref.read(onboardingSelectionProvider.notifier).state = OnboardingCountry(
        code: choice.code,
        name: choice.name,
        currency: choice.currency,
        currencyCode: choice.currency,
      );
      await ref
          .read(saveCountryCurrencyUseCaseProvider)
          .call(choice.code, choice.currency);
      _markDone(0);
    } catch (error) {
      if (!mounted) return;
      final message = error is RepoException
          ? repoErrorMessage(context, error)
          : context.l10n.setupSaveFailed;
      AppToast.showError(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Step 2: notifications ─────────────────────────────────────────────
  Future<void> _enableNotifications() async {
    setState(() => _busy = true);
    try {
      await LocalNotificationService.instance.requestPermissionsIfNeeded();
      _markDone(4);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Finish ────────────────────────────────────────────────────────────
  Future<void> _finish() async {
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      // Onboarding ends only once an account exists locally.
      final accounts = await ref.read(accountRepositoryProvider).getAll();
      if (accounts.isEmpty) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _done[_accountStep] = false;
          _currentStep = _accountStep;
        });
        AppToast.showError(context, context.l10n.onbAccountRequired);
        return;
      }
      await AppSession.instance.finishOnboarding();
      if (mounted) context.go('/');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.showError(context, context.l10n.setupFinishFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: context.colors.bg,
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.s2),
                const ExcludeSemantics(
                  child: Image(
                    image: AssetImage(AppAssets.qirshLogoFull),
                    height: 32,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                _header(l10n),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.03),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_currentStep),
                      child: _stepPage(l10n, _currentStep),
                    ),
                  ),
                ),
                _finishBar(l10n),
              ],
            ),
          ),
        ));
  }

  Widget _header(AppL10n l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 12, AppSpacing.gutter, 8),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: _currentStep > 0
                ? IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _busy ? null : _goBack,
                    tooltip:
                        MaterialLocalizations.of(context).backButtonTooltip,
                    icon: const BackButtonIcon(),
                    color: context.colors.textPrimary,
                  )
                : null,
          ),
          const SizedBox(width: AppSpacing.s3),
          // v2: «الخطوة 1 من 6» sits above the bar's leading edge; each
          // segment fills from the leading edge (dur.moderate) when reached.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.setupStepLabel(_currentStep + 1, _stepCount),
                  style: AppTypography.caption(context.colors.textMuted)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (var i = 0; i < _stepCount; i++) ...[
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: SizedBox(
                            height: 4,
                            child: ColoredBox(
                              color: context.colors.surfaceMuted,
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(
                                    end: _done[i] || i <= _currentStep
                                        ? 1
                                        : 0),
                                duration: AppMotion.moderate,
                                curve: AppMotion.easeOut,
                                builder: (context, fill, _) =>
                                    FractionallySizedBox(
                                  alignment: AlignmentDirectional.centerStart,
                                  widthFactor: fill,
                                  child: ColoredBox(color: context.colors.cta),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (i < _stepCount - 1) const SizedBox(width: 6),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepPage(AppL10n l10n, int step) {
    switch (step) {
      case 0:
        return _countryStep(l10n);
      case 1:
        return OnboardingConsentStep(
          kind: OnboardingConsentKind.cloud,
          onDark: false,
          onDone: (_) => _markDone(1),
        );
      case 2:
        return OnboardingReadinessStep(
            onDark: false, onDone: () => _markDone(2));
      case _accountStep:
        return OnboardingAccountStep(
          currency: _selectedCountry(context).currency,
          onDark: false,
          onDone: () => _markDone(_accountStep),
        );
      case 4:
        return _actionStep(
          step: 4,
          icon: AppLucideIcons.bellRing,
          title: l10n.setupNotificationsTitle,
          body: l10n.setupNotificationsBody,
          cta: l10n.setupNotificationsCta,
          onTap: _enableNotifications,
        );
      default:
        // Android has no Shortcuts app; it captures bank SMS itself once the
        // user opts in, so the last step offers that opt-in instead.
        return defaultTargetPlatform == TargetPlatform.android
            ? _smsCaptureStep(l10n)
            : _shortcutStep(l10n);
    }
  }

  /// Shared hero layout for a single step: its original flat illustration, a centered
  /// title/body, then the step's own control underneath.
  Widget _stepHero({
    required int step,
    required IconData icon,
    required String title,
    required String body,
    required Widget control,
    Widget? eyebrow,
  }) {
    final done = _done[step];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (eyebrow != null) ...[
            eyebrow,
            const SizedBox(height: AppSpacing.s7),
          ],
          Center(
              child: Column(children: [
            QirshIllustration(
                name: step == 0
                    ? 'welcome'
                    : step == 4
                        ? 'notifications'
                        : 'capture',
                width: 220,
                height: 165),
            if (done)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Icon(AppLucideIcons.check,
                      color: context.colors.success, size: 24)),
          ])),
          const SizedBox(height: AppSpacing.s6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.custom(
              size: 26,
              weight: FontWeight.w800,
              height: 1.22,
              color: context.colors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.body(context.colors.textSecondary)
                .copyWith(height: 1.55),
          ),
          const SizedBox(height: AppSpacing.s7),
          control,
        ],
      ),
    );
  }

  Widget _countryStep(AppL10n l10n) {
    return _stepHero(
      step: 0,
      icon: AppLucideIcons.globe,
      title: l10n.setupCountryTitle,
      body: l10n.setupCountryBody,
      eyebrow: Column(
        children: [
          Text(
            l10n.setupHeaderTitle,
            textAlign: TextAlign.center,
            style: AppTypography.custom(
              size: 20,
              weight: FontWeight.w700,
              height: 1.2,
              color: context.colors.actionText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.setupHeaderSubtitle,
            textAlign: TextAlign.center,
            style: AppTypography.caption(context.colors.textMuted),
          ),
        ],
      ),
      // Explicit pill surfaces keep selected and unselected contrast independent
      // of Material chip defaults in both themes.
      // v2: a fixed 3-column grid of equal 52pt chips (was ragged 2/3/3).
      control: LayoutBuilder(builder: (context, constraints) {
        const gap = 8.0;
        final width = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final choice in _countriesIn(context))
              SizedBox(
                width: width,
                height: 52,
                child: _CountryPill(
                  choice: choice,
                  selected: _countryCode == choice.code,
                  onTap: _busy ? null : () => _saveCountry(choice),
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _actionStep({
    required int step,
    required IconData icon,
    required String title,
    required String body,
    required String cta,
    required Future<void> Function() onTap,
  }) {
    return _stepHero(
      step: step,
      icon: icon,
      title: title,
      body: body,
      control: _done[step]
          ? const SizedBox.shrink()
          : SizedBox(
              width: double.infinity,
              height: AppSpacing.buttonHeight,
              child: FilledButton(
                onPressed: _busy ? null : () => onTap(),
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.cta,
                  foregroundColor: context.colors.onCta,
                ),
                child: Text(cta,
                    style: AppTypography.bodyStrong(context.colors.onCta)),
              ),
            ),
    );
  }

  Widget _shortcutStep(AppL10n l10n) {
    const step = _stepCount - 1;
    final steps = <(String, String)>[
      (l10n.setupShortcutStep1Title, l10n.setupShortcutStep1Body),
      (l10n.setupShortcutStep2Title, l10n.setupShortcutStep2Body),
      (
        l10n.setupShortcutStep3Title,
        l10n.setupShortcutStep3Body(_selectedCountry(context).currency)
      ),
      (l10n.setupShortcutStep4Title, l10n.setupShortcutStep4Body),
      (l10n.setupShortcutStep5Title, l10n.setupShortcutStep5Body),
      (l10n.setupShortcutStep6Title, l10n.setupShortcutStep6Body),
    ];
    return _stepHero(
      step: step,
      icon: AppLucideIcons.share,
      title: l10n.setupShortcutTitle,
      body: l10n.setupShortcutBody,
      control: _done[step]
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ShortcutSetupActions(currencyCode: _selectedCountry(context).currency),
                const SizedBox(height: 12),
                ExpansionTile(
                  title: Text(l10n.shortcutManualSteps),
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < steps.length; i++) ...[
                              Container(
                                width: 220,
                                padding: const EdgeInsets.all(AppSpacing.s3),
                                decoration: BoxDecoration(
                                  color: context.colors.surface,
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${i + 1}. ${steps[i].$1}',
                                        style: AppTypography.bodyStrong(
                                            context.colors.textPrimary)),
                                    const SizedBox(height: 6),
                                    Text(steps[i].$2,
                                        style: AppTypography.caption(
                                            context.colors.textMuted)),
                                  ],
                                ),
                              ),
                              if (i != steps.length - 1)
                                const SizedBox(width: 10),
                            ],
                          ],
                        ),
                      ),
                    )
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  width: double.infinity,
                  height: AppSpacing.buttonHeight,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _markDone(step),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.colors.cta,
                      foregroundColor: context.colors.onCta,
                    ),
                    child: Text(l10n.setupShortcutCta,
                        style: AppTypography.bodyStrong(context.colors.onCta)),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Step 5 (Android): automatic bank-SMS capture ──────────────────────
  Future<void> _refreshCaptureCapabilities() async {
    ref.invalidate(captureCapabilitiesProvider);
    await ref.read(captureCapabilitiesProvider.future);
  }

  Future<void> _enableSmsCapture() async {
    setState(() => _busy = true);
    try {
      final status = await enableAutomaticSmsCapture(context,
          onRequested: _refreshCaptureCapabilities);
      if (status == SmsPermissionStatus.granted) _markDone(_stepCount - 1);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _smsCaptureStep(AppL10n l10n) {
    const step = _stepCount - 1;
    final caps = ref.watch(captureCapabilitiesProvider).valueOrNull;
    // The platform's effective state, never a local flag (see the Settings
    // switch): a permission revoked or an opt-in reset elsewhere shows as off.
    final enabled = caps?.isAutomaticSmsCaptureEnabled ?? false;
    final canEnable = !enabled && (caps?.receiveSmsDeclared ?? false);
    return _stepHero(
      step: step,
      icon: AppLucideIcons.messageSquare,
      title: l10n.smsAutoCaptureTitle,
      body: l10n.setupSmsCaptureBody,
      control: _done[step]
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (enabled)
                  Text(
                    l10n.smsAutoCaptureSubtitleOn,
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyStrong(context.colors.success),
                  ),
                if (canEnable)
                  SizedBox(
                    width: double.infinity,
                    height: AppSpacing.buttonHeight,
                    child: FilledButton(
                      key: const ValueKey('setup-sms-enable'),
                      onPressed: _busy ? null : _enableSmsCapture,
                      style: FilledButton.styleFrom(
                        backgroundColor: context.colors.cta,
                        foregroundColor: context.colors.onCta,
                      ),
                      child: Text(l10n.setupSmsCaptureCta,
                          style: AppTypography.bodyStrong(context.colors.onCta)),
                    ),
                  ),
                const SizedBox(height: AppSpacing.s2),
                // Optional: declining keeps share and manual capture working.
                TextButton(
                  key: const ValueKey('setup-sms-skip'),
                  onPressed: _busy ? null : () => _markDone(step),
                  child: Text(enabled ? l10n.setupSmsCaptureContinue : l10n.notNow),
                ),
              ],
            ),
    );
  }

  Widget _finishBar(AppL10n l10n) {
    final ready = _canFinish && !_busy;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 8, AppSpacing.gutter, 16),
      child: SizedBox(
        width: double.infinity,
        height: AppSpacing.buttonHeight,
        child: FilledButton(
          onPressed: ready ? _finish : null,
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.cta,
            foregroundColor: context.colors.onCta,
            disabledBackgroundColor: context.colors.disabled,
          ),
          // v2 disabled label = text.muted (readable, still clearly off).
          child: Text(l10n.setupFinishCta,
              style: AppTypography.bodyStrong(
                ready ? context.colors.onCta : context.colors.textMuted,
              )),
        ),
      ).animate(target: _completed == _stepCount ? 1 : 0).scaleXY(
            begin: 1,
            end: 1.03,
            duration: 260.ms,
            curve: Curves.easeOutBack,
          ),
    );
  }
}

/// One country/currency choice on the setup step.
///
/// Deliberately not a `ChoiceChip`: see the note at its call site. Material's
/// chip defaults must not override the explicit selected/unselected surfaces.
class _CountryPill extends StatelessWidget {
  const _CountryPill({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final _CountryChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // v2 chip: card + soft stroke; selected = action.soft fill, 1.5pt action
    // stroke, action.text label (§3.0 02–03).
    final fill = selected ? c.ctaSoft : c.surface;
    final border = selected ? c.cta : c.strokeSoft;
    final foreground = selected ? c.actionText : c.textPrimary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: Ink(
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
              side: BorderSide(color: border, width: selected ? 1.5 : 1),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '${choice.name}\n'),
                    TextSpan(
                      text: '${choice.flag} ${choice.currency}',
                      style: AppTypography.overline(
                          selected ? c.actionText : c.textMuted),
                    ),
                  ]),
                  textAlign: TextAlign.center,
                  style: AppTypography.caption(foreground)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
