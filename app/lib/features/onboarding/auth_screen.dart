import 'widgets/onboarding_language_button.dart';
import '../../core/session/admission_authority.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_coordinator.dart';
import '../../core/auth/auth_service.dart';
import '../../core/auth/auth_methods_config.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import 'widgets/email_code_sheet.dart';
import '../../core/auth/supabase_auth_service.dart'
    show AuthCancelledException, googleSignInConfigured;
import '../../core/backend/supabase_config.dart';
import '../../core/privacy/cloud_egress_gate.dart' show EgressDeniedException;
import '../../core/privacy/consent_authority.dart' show ConsentAuthority;
import '../../core/router/app_router.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';

const _authDeepNavy = Color(0xFF031322);

/// Whether this platform can complete Sign in with Apple.
///
/// V1 is iOS-only by decision (`Qirsh Production/17_Apple_Production/`). The
/// implementation uses the NATIVE flow — `SignInWithApple.getAppleIDCredential`
/// with no `webAuthenticationOptions`, exchanged via `signInWithIdToken` — which
/// cannot complete on Android. Showing the button there offers a control that
/// always fails.
///
/// Supporting Android would need a Services ID, the Supabase callback URL as a
/// Return URL, and `webAuthenticationOptions` in the credential request. None of
/// those exist, so the button is gated rather than half-supported.
///
/// Uses `defaultTargetPlatform` rather than `dart:io` so a test can drive it
/// through `debugDefaultTargetPlatformOverride`.
@visibleForTesting
bool get appleSignInSupported => defaultTargetPlatform == TargetPlatform.iOS;

String _egressCode(String reason) {
  final tag = ConsentAuthority.egressFreezeTag;
  return reason == 'frozen' && tag.isNotEmpty
      ? 'EgressDenied:frozen/$tag'
      : 'EgressDenied:$reason';
}

/// A short, non-sensitive reason code for a failed sign-in, appended to the
/// generic toast so a field report can be diagnosed: the exception type and, for
/// an egress refusal, the gate's reason string. Never the exception message, a
/// token, an email or a uid. The Supabase client wraps a refused request in its
/// own exception type, so the reason is read from the stable `egress_denied:`
/// prefix that [EgressDeniedException] puts in its message (reason strings are
/// lower-case identifiers).
@visibleForTesting
String signInFailureCode(Object error) {
  if (error is EgressDeniedException) return _egressCode(error.reason);
  final wrapped = RegExp(r'egress_denied:([a-z_]+)').firstMatch('$error');
  if (wrapped != null) return _egressCode(wrapped.group(1)!);
  return error.runtimeType.toString();
}

/// Entry point for both first sign-in and recovery of an existing account.
class OnboardingAuthScreen extends ConsumerStatefulWidget {
  const OnboardingAuthScreen({super.key});

  @override
  ConsumerState<OnboardingAuthScreen> createState() =>
      _OnboardingAuthScreenState();
}

class _OnboardingAuthScreenState extends ConsumerState<OnboardingAuthScreen> {
  // Publishing the admitted account can remount this screen before routing.
  // Keep the active method busy until that same attempt hands off to setup.
  static final _pendingMethod = ValueNotifier<String?>(null);

  bool get _busy => _pendingMethod.value != null;
  bool _creatingAccount = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the hero art so it doesn't flash in on first frame.
    precacheImage(const AssetImage(AppAssets.authHero), context);
  }

  Future<bool> _signIn(Future<AuthIdentity> Function() method,
      {required String provider, bool showFailureToast = true}) async {
    if (_busy) return false;
    HapticFeedback.lightImpact();
    _pendingMethod.value = provider;
    // F2: the attempt is captured BEFORE the provider is awaited. If Remove data
    // is accepted while the provider sheet is open, this attempt is stale and
    // cannot authorize (re)creating anything once it completes.
    final attempt = AppSession.instance.beginAuthAttempt();
    try {
      // ASR §4.4: the exchange carries this attempt's intent.
      final identity = attempt.intent == 0
          ? await method()
          : await AuthAttemptZone.run(attempt.intent, method);
      if (SupabaseConfig.isConfigured && identity.isCurrent == null) {
        throw const StaleAdmissionException();
      }
      // Admission publishes capture ownership through bootstrap's service for
      // the newly committed account scope. This screen's provider graph is
      // retired by that swap, so it must not retain a database-bound service.
      await AppSession.instance.setIdentity(
        method: identity.method,
        email: identity.email,
        userId: identity.userId,
        attempt: attempt,
        sessionCurrent: identity.isCurrent,
      );
      if (SupabaseConfig.isConfigured) {
        if (!AppSession.instance.hasCompletedOnboarding) {
          appRouter.go('/onboarding/check');
          return true;
        }
        await AppSession.instance.reconcileAccountOnboarding(
          supabase.Supabase.instance.client,
        );
      }
      if (AppSession.instance.hasCompletedOnboarding) {
        appRouter.go('/');
        return true;
      }

      appRouter.go('/onboarding/setup');
      return true;
    } catch (error, stackTrace) {
      // ASR §4.6: an exchange that never reached its commit releases the
      // exclusion after aligning SDK memory (no-op otherwise).
      if (attempt.intent != 0) {
        await AuthCoordinator.active?.abandonExplicit(attempt.intent);
      }
      if (kDebugMode) {
        debugPrint(
          '[Auth] interactive sign-in failed: ${signInFailureCode(error)}',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
      if (mounted && showFailureToast) {
        // A CONFIGURATION failure is permanent: "try again" would be a lie the
        // user could follow forever. Surface the service's own message for
        // those; keep the generic retry copy for transient failures.
        if (error is AuthCancelledException) {
          // The user closed the sheet. Nothing failed; say nothing.
        } else {
          final needsGoogleSignup = provider == 'google' &&
              error is supabase.AuthApiException &&
              error.message == 'Use Create an account to register with Google.';
          AppToast.showError(
            context,
            needsGoogleSignup
                ? context.l10n.authGoogleSignupRequired
                : '${context.l10n.authSignInError} (E: ${signInFailureCode(error)})',
          );
        }
      }
      return false;
    } finally {
      _pendingMethod.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final methods = ref.watch(authMethodsConfigProvider);
    final google = methods.google &&
        googleSignInConfigured() &&
        {TargetPlatform.iOS, TargetPlatform.android}
            .contains(defaultTargetPlatform);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        systemNavigationBarColor: _authDeepNavy,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: _authDeepNavy,
        body: LayoutBuilder(builder: (context, viewport) {
          final compact = viewport.maxHeight < 730;
          final photoHeight = viewport.maxHeight * .72;
          final breathingRoom = viewport.maxHeight * (compact ? .25 : .35);
          return Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: photoHeight,
                child: const ExcludeSemantics(
                  child: Image(
                    image: AssetImage(AppAssets.authHero),
                    fit: BoxFit.cover,
                    alignment: Alignment(0, .76),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x55031322),
                        Color(0x00031322),
                        Color(0xD9031322),
                        _authDeepNavy,
                        _authDeepNavy,
                      ],
                      stops: [0, .18, compact ? .38 : .45, .65, 1],
                    ),
                  ),
                ),
              ),
              CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: breathingRoom)),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: SafeArea(
                      top: false,
                      minimum: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: _authPanel(
                            google: google,
                            email: methods.email,
                            compact: compact,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const PositionedDirectional(
                top: 0,
                end: AppSpacing.gutter,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: OnboardingLanguageButton(compact: true),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _authPanel(
      {required bool google, required bool email, required bool compact}) {
    final l = context.l10n;
    const foreground = Colors.white;
    const secondary = Color(0xFFB8C6D9);
    const outline = Color(0xFF747775);
    const appleFill = Colors.white;
    const appleInk = Colors.black;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_creatingAccount ? l.authCreateAccount : l.authTitle,
            style: AppTypography.custom(
              size: compact ? 28 : 32,
              weight: FontWeight.w700,
              height: 1.2,
              color: foreground,
            )),
        const SizedBox(height: 5),
        Text(_creatingAccount ? l.authCreateAccountSubtitle : l.authSubtitle,
            style: AppTypography.caption(secondary)
                .copyWith(fontSize: 14, height: 1.45)),
        const SizedBox(height: 22),
        ValueListenableBuilder<String?>(
            valueListenable: _pendingMethod,
            builder: (context, pending, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (appleSignInSupported)
                      FilledButton.icon(
                        key: const ValueKey('auth-apple'),
                        onPressed: pending == null
                            ? () => _signIn(
                                ref.read(authServiceProvider).signInWithApple,
                                provider: 'apple')
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: appleFill,
                          foregroundColor: appleInk,
                          disabledBackgroundColor: appleFill,
                          disabledForegroundColor: appleInk,
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: _methodIcon(pending == 'apple', appleInk,
                            const Icon(Icons.apple, size: 23)),
                        label: Text(
                            pending == 'apple'
                                ? l.startPreparing
                                : l.authAppleCta,
                            style: AppTypography.bodyStrong(appleInk)),
                      ),
                    if (google) ...[
                      if (appleSignInSupported) const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('auth-google'),
                        onPressed: pending == null
                            ? () => _signIn(
                                _creatingAccount
                                    ? ref
                                        .read(authServiceProvider)
                                        .signUpWithGoogle
                                    : ref
                                        .read(authServiceProvider)
                                        .signInWithGoogle,
                                provider: 'google')
                            : null,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF1F1F1F),
                          side: const BorderSide(color: outline),
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: _methodIcon(
                            pending == 'google',
                            const Color(0xFF172339),
                            SvgPicture.asset('assets/brands/google.svg',
                                width: 19, height: 19)),
                        label: Text(
                            pending == 'google'
                                ? l.startPreparing
                                : l.authGoogleCta,
                            style: AppTypography.bodyStrong(
                                const Color(0xFF1F1F1F))),
                      ),
                    ],
                    if (email) ...[
                      if (appleSignInSupported || google)
                        const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('auth-email'),
                        onPressed: pending == null ? _emailSignIn : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: foreground,
                          backgroundColor: const Color(0x80233850),
                          side: const BorderSide(color: Color(0xFF60748F)),
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.mail_outline, size: 19),
                        label: Text(l.continueWithEmail,
                            style: AppTypography.bodyStrong(foreground)),
                      ),
                    ],
                  ],
                )),
        if (ref.watch(authMethodsConfigProvider).signup && (google || email))
          TextButton(
            key: const ValueKey('auth-toggle-signup'),
            onPressed: () {
              if (!_busy) setState(() => _creatingAccount = !_creatingAccount);
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF4CB6C),
              minimumSize: const Size.fromHeight(44),
            ),
            child: Text(
                _creatingAccount ? l.authBackToSignIn : l.authCreateAccount),
          ),
        if (!_creatingAccount && appleSignInSupported && (google || email)) ...[
          const SizedBox(height: 5),
          Text(l.authExistingAccountHint,
              textAlign: TextAlign.center,
              style: AppTypography.micro(secondary).copyWith(height: 1.35)),
        ],
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(AppLucideIcons.shieldCheck, size: 15, color: secondary),
          const SizedBox(width: 6),
          Flexible(
              child: Text(l.authTrustLocalEncryption,
                  style: AppTypography.micro(secondary))),
        ]),
        const SizedBox(height: 6),
        Text(l.authTermsNotice,
            textAlign: TextAlign.center,
            style: AppTypography.micro(secondary).copyWith(height: 1.35)),
      ],
    );
  }

  Widget _methodIcon(bool pending, Color color, Widget icon) => pending
      ? SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: color))
      : icon;

  Future<void> _emailSignIn() async {
    final service = ref.read(authServiceProvider);
    await showGlassSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => EmailCodeSheet(
              onSend: _creatingAccount
                  ? service.sendEmailSignupCode
                  : service.sendEmailCode,
              creatingAccount: _creatingAccount,
              onVerify: (email, code, _) async {
                final ok = await _signIn(() async {
                  final identity =
                      await service.verifyEmailCode(email: email, code: code);
                  if (identity == null) throw const StaleAdmissionException();
                  return identity;
                }, provider: 'email', showFailureToast: false);
                return ok ? EmailCodeResult.verified : EmailCodeResult.invalid;
              },
            ));
  }
}
