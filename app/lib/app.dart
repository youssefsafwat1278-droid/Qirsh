import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'core/router/app_router.dart';
import 'core/session/app_session.dart';
import 'core/startup/automatic_session_recovery.dart';
import 'core/security/app_lock_gate.dart';
import 'features/app/app_boot_loader.dart';
import 'features/app/local_read_cleanup_notice.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_controller.dart';
import 'core/i18n/locale_provider.dart';
import 'core/utils/l10n_ext.dart';
import 'core/theme/widgets/glass_scaffold_messenger.dart';

/// جذر التطبيق. Arabic-first / RTL.
class MoneyApp extends ConsumerWidget {
  const MoneyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeLocale = ref.watch(localeProvider);
    // Keeps lock-screen notification copy in the user's language.
    ref.watch(notificationLanguageSyncProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: appRouter,
      scrollBehavior:
          const MaterialScrollBehavior().copyWith(scrollbars: false),

      // تدويل اللغة والاتجاهات ديناميكياً
      locale: activeLocale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            // The user's system text size is RESPECTED, bounded to the range
            // the financial layouts are verified against (see the 1.25x
            // overflow tests). Never a fixed scale — that would silently
            // disable Dynamic Type for everyone.
            textScaler: mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.25,
            ),
          ),
          // Root-level restore loader: one continuous branded screen from
          // launch to data-ready (see [appDataRestoring]) — sits above the
          // router so the shell never flashes reseeded defaults behind it.
          // Every snackbar in the app renders on the glass material.
          // The status bar follows the theme wherever a screen sets nothing
          // itself. Without this fallback the last style a screen set (Home's
          // blue hero, onboarding) stays on after it scrolls or navigates away.
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: Theme.of(context).brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            child: GlassScaffoldMessenger(
              child: Stack(
                children: [
                  AppLockGate(child: child!),
                  const RemovalNoticeHost(),
                  const DenyIncompleteNoticeHost(),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      appDataRestoring,
                      AutomaticSessionRecovery.restoringSession,
                    ]),
                    // The loader leaves with its exit motion over the app
                    // (already built behind it); the condition is unchanged.
                    builder: (context, _) => Positioned.fill(
                      child: AppBootLoaderReveal(
                        loading: appDataRestoring.value ||
                            AutomaticSessionRecovery.restoringSession.value,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// §4.4 step 6 — shows "Data removed from this device" once, on the first screen
/// after a completed removal. Lives under the app's `ScaffoldMessenger`, so the
/// snackbar waits for the next screen's scaffold.
class RemovalNoticeHost extends StatefulWidget {
  const RemovalNoticeHost({super.key});

  @override
  State<RemovalNoticeHost> createState() => RemovalNoticeHostState();
}

class RemovalNoticeHostState extends State<RemovalNoticeHost> {
  final _pending = AppSession.instance.removalNoticePending;

  @override
  void initState() {
    super.initState();
    _pending.addListener(_maybeShow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  @override
  void dispose() {
    _pending.removeListener(_maybeShow);
    super.dispose();
  }

  void _maybeShow() {
    if (!mounted || !_pending.value) return;
    _pending.value = false;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.setDataRemovedNotice)),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
