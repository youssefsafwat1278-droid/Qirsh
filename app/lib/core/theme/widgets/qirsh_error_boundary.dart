import 'package:flutter/widgets.dart';

/// v2 error boundary: what a widget that throws during build renders in
/// profile/release instead of the framework's grey/red box. Calm, theme-
/// neutral, and it never shows the exception text (which can carry data).
Widget qirshErrorWidget(FlutterErrorDetails details) =>
    const _QirshBuildError();

class _QirshBuildError extends StatelessWidget {
  const _QirshBuildError();

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.maybeLocaleOf(context)?.languageCode != 'en';
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0x29FF6B5E),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: const Text('!',
                    style: TextStyle(
                        fontFamily: 'Vazirmatn',
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFE0574B))),
              ),
              const SizedBox(height: 12),
              Text(
                ar
                    ? 'تعذّر عرض هذا الجزء. ارجع وافتحه تاني.'
                    : 'This section could not be shown. Go back and try again.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'Vazirmatn',
                    fontSize: 15,
                    height: 1.6,
                    color: Color(0xFF8D94A2)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
