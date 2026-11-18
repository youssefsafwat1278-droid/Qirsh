import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/di/app_providers.dart';
import '../../core/i18n/locale_provider.dart';
import '../../core/security/lock_prompt_language.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../settings/settings_providers.dart';

/// First interactive screen; completion is local to this installation.
class OnboardingLanguageScreen extends ConsumerStatefulWidget {
  const OnboardingLanguageScreen({super.key});
  @override
  ConsumerState<OnboardingLanguageScreen> createState() => _LanguageState();
}

class _LanguageState extends ConsumerState<OnboardingLanguageScreen> {
  // Nothing is preselected (owner decision 3.6): Continue stays disabled
  // until the user picks a language explicitly.
  String? _selected;
  bool _saving = false;
  Future<void> _continue() async {
    final selected = _selected;
    if (_saving || selected == null) return;
    setState(() => _saving = true);
    try {
      try {
        await ref.read(saveLanguageUseCaseProvider).call(selected);
        ref.invalidate(userSettingsProvider);
      } catch (_) {
        // Signed-out settings may be read-only. This device mirror seeds the
        // account's settings after sign-in; it grants no account authority.
        await LockPromptLanguage.set(selected);
      }
      if (!mounted) return;
      ref.read(preSignInLanguageProvider.notifier).state = selected;
      await AppSession.instance.markOnboardingLanguageChosen();
      if (mounted) context.go('/welcome');
    } catch (_) {
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppBrandBlue.brand,
        body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                          child:
                              Image.asset(AppAssets.qirshLogoFull, width: 88)),
                      const SizedBox(height: 36),
                      Text(l.languageFirstTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      Text(l.languageFirstBody,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                              height: 1.6)),
                      const SizedBox(height: 32),
                      _language('en', 'English', 'EN'),
                      const SizedBox(height: 12),
                      _language('ar', 'العربية', 'ع'),
                      const SizedBox(height: 32),
                      FilledButton(
                          key: const ValueKey('language-first-continue'),
                          onPressed:
                              _saving || _selected == null ? null : _continue,
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: AppBrandBlue.brand,
                              disabledBackgroundColor:
                                  Colors.white.withValues(alpha: .24),
                              disabledForegroundColor: Colors.white70,
                              minimumSize: const Size.fromHeight(54),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18))),
                          child: Text(l.storyContinueCta)),
                    ])),
          )),
        ),
      ),
    );
  }

  Widget _language(String code, String label, String short) {
    final selected = _selected == code;
    final color = selected ? AppBrandBlue.brand : Colors.white;
    return Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? Colors.white : Colors.white.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            key: ValueKey('language-first-$code'),
            borderRadius: BorderRadius.circular(20),
            onTap: _saving
                ? null
                : () {
                    setState(() => _selected = code);
                    ref.read(preSignInLanguageProvider.notifier).state = code;
                  },
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(children: [
                  Text(short,
                      style: TextStyle(
                          color: color,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(width: 18),
                  Expanded(
                      child: Text(label,
                          style: TextStyle(
                              color: color,
                              fontSize: 20,
                              fontWeight: FontWeight.w700))),
                  Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: color),
                ])),
          ),
        ));
  }
}
