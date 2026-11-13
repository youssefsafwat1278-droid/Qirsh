import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';

/// The silent "set up the Shortcut" walkthrough, bundled with the app (Arabic
/// and English). Nothing is loaded until the person taps play.
class ShortcutGuideVideo extends StatefulWidget {
  const ShortcutGuideVideo({super.key});

  static String assetFor(String languageCode) => languageCode == 'ar'
      ? 'assets/shortcut_guide/qirsh_shortcut_setup_ar.mp4'
      : 'assets/shortcut_guide/qirsh_shortcut_setup_en.mp4';

  @override
  State<ShortcutGuideVideo> createState() => _ShortcutGuideVideoState();
}

class _ShortcutGuideVideoState extends State<ShortcutGuideVideo> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _failed = false;

  Future<void> _start() async {
    if (_loading || _controller != null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final controller = VideoPlayerController.asset(ShortcutGuideVideo.assetFor(
        Localizations.localeOf(context).languageCode));
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final controller = _controller;
    if (controller == null) {
      return Semantics(
        button: true,
        label: context.l10n.shortcutVideoTitle,
        child: InkWell(
          key: const Key('shortcutVideoPlay'),
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: _loading ? null : _start,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.primary.withValues(alpha: 0.18)),
            ),
            child: Row(children: [
              SizedBox(
                width: 40,
                height: 40,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.s2),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _failed
                            ? AppLucideIcons.alertCircle
                            : AppLucideIcons.playCircle,
                        color: c.primary,
                        size: 32),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.shortcutVideoTitle,
                        style: AppTypography.bodyStrong(c.textMain)),
                    const SizedBox(height: 2),
                    Text(context.l10n.shortcutVideoSubtitle,
                        style: AppTypography.footnote(c.textLight)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: GestureDetector(
        key: const Key('shortcutVideoSurface'),
        onTap: _toggle,
        child: Stack(alignment: Alignment.center, children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          if (!controller.value.isPlaying)
            const Icon(AppLucideIcons.playCircle,
                color: Colors.white, size: 64),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(controller, allowScrubbing: true),
          ),
        ]),
      ),
    );
  }
}
