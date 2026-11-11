import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/i18n/locale_provider.dart';
import '../../../core/security/lock_prompt_language.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/widgets/app_toast.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../settings/settings_providers.dart';

/// Available before sign-in; uses the same persisted choice as Settings.
class OnboardingLanguageButton extends StatefulWidget {
  const OnboardingLanguageButton({super.key, this.compact = false, this.onDark = true});
  final bool onDark;

  /// Globe and a short label only, for crowded headers (the story progress row).
  final bool compact;

  @override
  State<OnboardingLanguageButton> createState() =>
      _OnboardingLanguageButtonState();
}

class _OnboardingLanguageButtonState extends State<OnboardingLanguageButton> {
  bool _saving = false;

  Future<void> _select(String language) async {
    if (_saving || Localizations.localeOf(context).languageCode == language) {
      return;
    }
    setState(() => _saving = true);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      try {
        await container.read(saveLanguageUseCaseProvider).call(language);
        if (!mounted) return;
        container.invalidate(userSettingsProvider);
      } catch (_) {
        // Signed out after an earlier session the scope is read-only, so the
        // settings row cannot be written here. The language is a device
        // preference before sign-in: keep it in the mirror and show it now.
        await LockPromptLanguage.set(language);
        if (!mounted) return;
        container.read(preSignInLanguageProvider.notifier).state = language;
      }
    } catch (_) {
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = Localizations.localeOf(context).languageCode;
    final foreground = widget.onDark ? Colors.white : context.colors.textPrimary;
    // Glass pill + glass menu, matching the sign-in card below it.
    return PopupMenuButton<String>(
      key: const ValueKey('onboarding-language'),
      tooltip: context.l10n.setLanguage,
      enabled: !_saving,
      initialValue: current,
      onSelected: _select,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 8),
      elevation: 0,
      color: widget.onDark ? const Color(0xE6122A4A) : context.colors.surface,
      constraints: const BoxConstraints(minWidth: 168),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: widget.onDark
            ? Colors.white.withValues(alpha: 0.16) : context.colors.border),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      itemBuilder: (_) => [
        _item('en', 'English', current),
        _item('ar', 'العربية', current),
      ],
      // v2: a 40pt glass pill (was ~32pt and hard to hit).
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: widget.onDark ? Colors.white.withValues(alpha: .14) : context.colors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: widget.onDark ? Colors.white.withValues(alpha: .2) : context.colors.strokeSoft),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppLucideIcons.globe, color: foreground, size: 18),
            const SizedBox(width: 6),
            Text(
              widget.compact
                  ? (current == 'ar' ? 'ع' : 'EN')
                  : (current == 'ar' ? 'العربية' : 'English'),
              style: AppTypography.bodyStrong(foreground)
                  .copyWith(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (!widget.compact) ...[
              const SizedBox(width: 4),
              Icon(AppLucideIcons.chevronDown,
                  color: foreground.withValues(alpha: .7), size: 14),
            ],
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(String value, String label, String current) {
    final selected = value == current;
    final foreground = widget.onDark ? Colors.white : context.colors.textPrimary;
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTypography.body(
                selected ? foreground : foreground.withValues(alpha: 0.72),
              ).copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (selected)
            Icon(AppLucideIcons.check, color: foreground, size: 16),
        ],
      ),
    );
  }
}
