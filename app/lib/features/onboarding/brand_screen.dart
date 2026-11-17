import 'widgets/onboarding_language_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/app_colors.dart';

/// Same flat navy the native launch screen uses (`flutter_native_splash.yaml`,
/// `color: "#021B79"`) and the same shade the story pages use.
const _brandBlue = AppBrandBlue.brand;
const _brandAccent = AppBrandBlue.pale;

/// Page 2 of onboarding — the brand reveal that closes the cinematic sequence
/// started by the story screen.
///
/// Always renders on the same flat navy background as the native launch
/// screen and the story pages (not the app's light/dark theme), with a
/// small fixed logo up top — no gradient, no big hero coin — so the
/// /welcome → /onboarding/brand hand-off reads as one continuous scene
/// instead of a flash to a visually different screen. This is where the
/// welcome-seen flag is set, right before handing off to mandatory auth.
class OnboardingBrandScreen extends StatefulWidget {
  const OnboardingBrandScreen({super.key});

  @override
  State<OnboardingBrandScreen> createState() => _OnboardingBrandScreenState();
}

class _OnboardingBrandScreenState extends State<OnboardingBrandScreen> {
  bool _navigating = false;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  Future<void> _continue() async {
    if (_navigating) return;
    setState(() => _navigating = true);
    HapticFeedback.lightImpact();
    try {
      await AppSession.instance.markWelcomeManifestoSeen();
      if (mounted) context.go('/onboarding/auth');
    } catch (_) {
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final reduceMotion = _reduceMotion;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      backgroundColor: _brandBlue,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            children: [
              const Align(
                alignment: AlignmentDirectional.centerEnd,
                child: OnboardingLanguageButton(),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ExcludeSemantics(
                        child: Image(
                          image: AssetImage(AppAssets.qirshLogoFull),
                          height: 100,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      _fadeIn(
                        Text(
                          l10n.appTitle,
                          style: AppTypography.custom(
                            size: 40,
                            weight: FontWeight.w800,
                            height: 1.1,
                            color: Colors.white,
                          ),
                        ),
                        reduceMotion: reduceMotion,
                        delay: const Duration(milliseconds: 200),
                      ),
                      const SizedBox(height: 8),
                      _fadeIn(
                        Text(
                          l10n.brandTagline,
                          textAlign: TextAlign.center,
                          style: AppTypography.body(_brandAccent),
                        ),
                        reduceMotion: reduceMotion,
                        delay: const Duration(milliseconds: 400),
                      ),
                    ],
                  ),
                ),
              ),
              _fadeIn(
                SizedBox(
                  width: double.infinity,
                  height: AppSpacing.buttonHeight,
                  child: FilledButton(
                    onPressed: _navigating ? null : _continue,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white70,
                      foregroundColor: _brandBlue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: Text(
                      l10n.brandContinueCta,
                      style: AppTypography.bodyStrong(_brandBlue),
                    ),
                  ),
                ),
                reduceMotion: reduceMotion,
                delay: const Duration(milliseconds: 700),
              ),
              const SizedBox(height: AppSpacing.s5),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _fadeIn(
    Widget child, {
    required bool reduceMotion,
    required Duration delay,
  }) {
    if (reduceMotion) return child;
    return child.animate().fadeIn(delay: delay, duration: 600.ms);
  }
}
