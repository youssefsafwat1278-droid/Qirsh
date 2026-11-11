import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/widgets/glass_sheet.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/session/app_session.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/app_motion.dart';
import '../common/app_button.dart';
import '../common/motion.dart';
import '../settings/widgets/settings_v2.dart';

/// V1 guidance, Layer B (charter: REQUIRED_PRODUCT_CHANGE_5).
///
/// The persistent, re-openable half of the guidance contract. Layer A's coach
/// marks appear once on first use and then get out of the way; this screen is
/// where someone comes back after they have forgotten something, so it is
/// reachable from Settings at any time and is never dismissed permanently.
///
/// Every string is localised. This is the one screen where a hardcoded Arabic
/// literal would be most obviously wrong, since its entire purpose is to explain
/// the product to someone who may be reading it in either language.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;

    final sections = <_HelpSection>[
      _HelpSection(l10n.helpSectionBasics, [
        _HelpEntry(AppLucideIcons.plus, l10n.helpAddTransactionTitle,
            l10n.helpAddTransactionBody),
        _HelpEntry(AppLucideIcons.inbox, l10n.helpSmartInboxTitle,
            l10n.helpSmartInboxBody),
        _HelpEntry(
            AppLucideIcons.tag, l10n.helpCategoriesTitle, l10n.helpCategoriesBody),
      ]),
      _HelpSection(l10n.helpSectionReports, [
        _HelpEntry(AppLucideIcons.calendarCheck, l10n.helpPeriodTitle,
            l10n.helpPeriodBody),
        _HelpEntry(
            AppLucideIcons.lineChart, l10n.helpAnnualTitle, l10n.helpAnnualBody),
      ]),
      _HelpSection(l10n.helpSectionPlanning, [
        _HelpEntry(AppLucideIcons.wallet, l10n.helpAccountsTitle,
            l10n.helpAccountsBody),
        _HelpEntry(
            AppLucideIcons.target, l10n.helpBudgetsTitle, l10n.helpBudgetsBody),
        _HelpEntry(AppLucideIcons.flag, l10n.helpGoalsTitle, l10n.helpGoalsBody),
      ]),
      _HelpSection(l10n.helpSectionPrivacy, [
        _HelpEntry(AppLucideIcons.shieldCheck, l10n.helpPrivacyTitle,
            l10n.helpPrivacyBody),
        _HelpEntry(AppLucideIcons.download, l10n.helpBackupTitle,
            l10n.helpBackupBody),
      ]),
    ];

    void contactUs() => showGlassSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (sheetContext) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.setContactUs,
                    style: AppTypography.sectionTitle(c.textPrimary)),
                const SizedBox(height: 12),
                Text(l10n.setSupportBody,
                    style: AppTypography.callout(c.textSecondary)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(
                        text: 'support@money-companion.app'));
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  },
                  child: Text(l10n.setCopyEmail),
                ),
              ],
            ),
          ),
        );

    // v2 §25: QNavBar + QLargeTitle, 140pt illustration, accordion Groups
    // inside the 20pt gutters, then the two actions 12pt apart.
    return SettingsV2Page(
      title: l10n.helpTitle,
      subtitle: l10n.helpSubtitle,
      children: [
        const SizedBox(height: AppSpacing.s3),
        const Center(
          child: QirshIllustration(name: 'help', width: 187, height: 140),
        ),
        for (var i = 0; i < sections.length; i++)
          SettingsV2Group(
            label: sections[i].title,
            children: [
              _HelpAccordion(
                entries: sections[i].entries,
                initiallyOpen: i == 0 ? 0 : null,
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.s7),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppPrimaryButton(
                label: l10n.setContactUs,
                icon: AppLucideIcons.messageSquare,
                onTap: contactUs,
              ),
              const SizedBox(height: AppSpacing.s3),
              // Someone who dismissed the first-use tour should not be locked
              // out of it forever — this is the only way back to Layer A.
              AppSecondaryButton(
                label: l10n.helpReplayTour,
                icon: AppLucideIcons.refreshCw,
                onTap: () async {
                  await AppSession.instance.resetCoachMarks();
                  if (!context.mounted) return;
                  AppToast.show(context, l10n.helpReplayTourDone);
                },
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                l10n.helpFooter,
                textAlign: TextAlign.center,
                style: AppTypography.caption(c.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One Group's questions. Opening one closes the other in the same Group; the
/// chevron turns 180° over dur.base, the height moves over dur.moderate and
/// the answer fades in during the last 60%.
class _HelpAccordion extends StatefulWidget {
  const _HelpAccordion({required this.entries, this.initiallyOpen});

  final List<_HelpEntry> entries;
  final int? initiallyOpen;

  @override
  State<_HelpAccordion> createState() => _HelpAccordionState();
}

class _HelpAccordionState extends State<_HelpAccordion> {
  late int? _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduce = shouldReduceMotion(context);
    final moderate = reduce ? AppMotion.micro : AppMotion.moderate;
    return Column(
      children: [
        for (var i = 0; i < widget.entries.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: 60, color: c.divider),
          Semantics(
            button: true,
            expanded: _open == i,
            child: InkWell(
              splashFactory: NoSplash.splashFactory,
              highlightColor: c.surfaceElevated,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _open = _open == i ? null : i);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                      AppSpacing.s4, AppSpacing.s2, AppSpacing.s3, AppSpacing.s2),
                  child: Row(children: [
                    SettingsV2Tile(icon: widget.entries[i].icon),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Text(widget.entries[i].title,
                          style: AppTypography.bodyStrong(c.textPrimary)),
                    ),
                    AnimatedRotation(
                      turns: _open == i ? 0.5 : 0,
                      duration: reduce ? AppMotion.micro : AppMotion.base,
                      curve: AppMotion.easeInOut,
                      child: Icon(AppLucideIcons.chevronDown,
                          size: 20, color: c.textMuted),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: moderate,
              curve: AppMotion.easeInOut,
              alignment: AlignmentDirectional.topStart,
              child: _open == i
                  ? TweenAnimationBuilder<double>(
                      key: ValueKey('help-answer-$i'),
                      tween: Tween(begin: 0, end: 1),
                      duration: moderate,
                      builder: (context, t, child) => Opacity(
                        opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                        child: child,
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                            60, 0, AppSpacing.s4, AppSpacing.s4),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            widget.entries[i].body,
                            style: AppTypography.callout(c.textSecondary)
                                .copyWith(height: 26 / 15),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ],
    );
  }
}

class _HelpSection {
  const _HelpSection(this.title, this.entries);
  final String title;
  final List<_HelpEntry> entries;
}

class _HelpEntry {
  const _HelpEntry(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}
