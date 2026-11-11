import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';

/// True while the app is doing blocking startup work the user must not see
/// half-populated — specifically the post-sign-in data restore, when the local
/// DB still holds reseeded defaults until the first pull lands.
///
/// A single full-screen branded loader (identical to the cold-start screen) is
/// shown at the APP ROOT while this is true — above the router, so it stays put
/// through the StartupApp→shell handoff and any route transition. Result: one
/// continuous loading screen from launch to data-ready, not the shell flashing
/// defaults behind a second loader.
final ValueNotifier<bool> appDataRestoring = ValueNotifier<bool>(false);

/// B2-C — the explicit "first usable local financial state" milestone. Flipped
/// true by the bootstrap the moment the SAFETY-CRITICAL phase is done: DB key +
/// encrypted DB open + required migration/repair + process/owner liveness +
/// admission (owner-conflict) resolved + seed — i.e. repositories can run a real
/// owner-scoped query. It does NOT wait for network (remote feature/config
/// refresh, remote-backup metadata), analytics, or non-critical
/// diagnostics/cleanup — those run in the deferred phase AFTER this flips. The
/// financial UI is only shown once the local DB is genuinely the current owner's,
/// never previous-user cached data (that is the [appDataRestoring] gate's job).
final ValueNotifier<bool> localFinancialUiUsable = ValueNotifier<bool>(false);

/// The coin's size in logical pixels. The native launch screens draw the same
/// coin at the same size (118pt / 118dp) centred on [AppBrandBlue.deep], so the
/// first Flutter frame is identical to what the OS showed before it.
const double kBootCoinSize = 118;

// Motion timings, from the approved launch mock-up (`.boot.play` keyframes).
const Duration _flipDelay = Duration(milliseconds: 120);
const Duration _flipLength = Duration(milliseconds: 1050);
const Duration _bloomDelay = Duration(milliseconds: 250);
const Duration _bloomLength = Duration(milliseconds: 1400);
const Duration _sweepDelay = Duration(milliseconds: 950);
const Duration _sweepLength = Duration(milliseconds: 750);

/// The last frame of the flip, bloom and sweep.
const Duration _motionEnd = Duration(milliseconds: 1700);

/// The comet ring only appears if loading is still running this long after
/// the motion ends.
const Duration _ringAt = Duration(milliseconds: 1700 + 1200);
const Duration _ringFadeIn = Duration(milliseconds: 350);

const Cubic _flipCurve = Cubic(0.62, 0.04, 0.3, 1);
const Cubic _exitCurve = Cubic(0.4, 0, 0.2, 1);

/// Process-wide clock shared by every mounted loader, so a loader that is
/// re-mounted during the same launch (StartupApp → MoneyApp, root overlay →
/// router, lock gate → router) continues the same motion instead of
/// replaying it. The flip plays once per process.
abstract final class _BootClock {
  static bool motionPlayed = false;
  static bool firstFrameHeld = false;
  static bool ringOn = false;
  static Duration elapsed = Duration.zero;
  static int mounted = 0;
  static final Stopwatch sinceLastUnmount = Stopwatch();

  /// A loader mounted within this gap after the last one went away is the
  /// same loading screen continuing (a swap between hosts).
  static const Duration _handoffGap = Duration(milliseconds: 800);

  static Duration begin() {
    final continuing = mounted > 0 ||
        (sinceLastUnmount.isRunning &&
            sinceLastUnmount.elapsed < _handoffGap);
    mounted++;
    if (!continuing) {
      // Later loading sessions in the same process start after the motion:
      // the coin is already still, and only the ring may follow.
      elapsed = motionPlayed ? _motionEnd : Duration.zero;
      ringOn = false;
      motionPlayed = true;
    }
    return elapsed;
  }

  static void end() {
    mounted--;
    sinceLastUnmount
      ..reset()
      ..start();
  }

  static void advance(Duration now) {
    if (now > elapsed) elapsed = now;
  }
}

/// The same branded loading view is used for cold start and restore so their
/// handoff never changes the background, logo, or visible language.
class AppBootLoader extends StatelessWidget {
  const AppBootLoader({super.key});

  @override
  Widget build(BuildContext context) {
    // One stable visual across cold boot, account-scope handoff and resume.
    // No language-dependent text or theme-dependent asset can flash here.
    return const _BootLoaderView(
      stableKey: Key('qirsh_stable_loader'),
      ring: true,
    );
  }
}

/// The loader's composition for the app lock: the coin on navy, in the same
/// place, continuing the same motion. [ring] allows the slow-loading ring (the
/// lock's check); [footer] is laid out near the bottom (the lock's "locked"
/// line and unlock button).
class BootCoinStage extends StatelessWidget {
  const BootCoinStage({super.key, this.ring = false, this.footer});

  final bool ring;
  final Widget? footer;

  @override
  Widget build(BuildContext context) =>
      _BootLoaderView(ring: ring, footer: footer);
}

/// Shows [loader] while [loading]; when loading ends, [child] is built at once
/// and the loader leaves on top of it: the coin scales to 0.86, rises 10px
/// and fades while the screen behind fades in. When the ring was showing, it
/// completes first. [child] is never built while [loading].
///
/// Only the look of the swap changes: [loading] still decides alone when the
/// app is shown, and the leaving loader ignores touches.
class AppBootLoaderReveal extends StatefulWidget {
  const AppBootLoaderReveal({
    super.key,
    required this.loading,
    this.child,
    this.loader = const AppBootLoader(),
  });

  final bool loading;
  final Widget? child;
  final Widget loader;

  @override
  State<AppBootLoaderReveal> createState() => _AppBootLoaderRevealState();
}

class _AppBootLoaderRevealState extends State<AppBootLoaderReveal>
    with SingleTickerProviderStateMixin {
  static const Duration _ringComplete = Duration(milliseconds: 280);
  static const Duration _exitLength = Duration(milliseconds: 500);

  late final AnimationController _exit = AnimationController(vsync: this);
  bool _exiting = false;
  int _exitRun = 0;
  double _ringPhase = 0;

  @override
  void didUpdateWidget(AppBootLoaderReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading && !widget.loading) {
      final last = oldWidget.loader;
      final ring = _BootClock.ringOn &&
          (last is AppBootLoader || (last is BootCoinStage && last.ring));
      final total = ring ? _ringComplete + _exitLength : _exitLength;
      _ringPhase = ring
          ? _ringComplete.inMicroseconds / total.inMicroseconds
          : 0;
      _exit.duration = total;
      _exiting = true;
      final run = ++_exitRun;
      _exit.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && _exiting && run == _exitRun) {
          setState(() => _exiting = false);
        }
      });
    } else if (widget.loading && _exiting) {
      _exiting = false;
      _exit.stop();
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.loading ? null : widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (app != null)
          KeyedSubtree(key: const ValueKey('boot-reveal-app'), child: app),
        if (widget.loading)
          KeyedSubtree(
              key: const ValueKey('boot-reveal-loader'), child: widget.loader)
        else if (_exiting)
          KeyedSubtree(
            key: const ValueKey('boot-reveal-exit'),
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: _BootLoaderView(
                  ring: false,
                  exit: _exit,
                  ringPhase: _ringPhase,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BootLoaderView extends StatefulWidget {
  const _BootLoaderView({
    this.stableKey,
    required this.ring,
    this.footer,
    this.exit,
    this.ringPhase = 0,
  });

  final Key? stableKey;

  /// Whether the comet ring may appear while loading runs long.
  final bool ring;
  final Widget? footer;

  /// Non-null while this view is the leaving copy of a loader.
  final Animation<double>? exit;

  /// The share of [exit] spent completing the ring (0 when it was hidden).
  final double ringPhase;

  @override
  State<_BootLoaderView> createState() => _BootLoaderViewState();
}

class _BootLoaderViewState extends State<_BootLoaderView>
    with SingleTickerProviderStateMixin {
  late Duration _base;
  late final Ticker _ticker;
  late final ValueNotifier<Duration> _now;
  Timer? _firstFrameTimeout;
  ImageStream? _firstFrameStream;
  ImageStreamListener? _firstFrameListener;
  bool _holdingFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _base = _BootClock.begin();
    _now = ValueNotifier<Duration>(_base);
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _holdFirstFrameForCoin();
  }

  /// The very first Flutter frame must already carry the coin, or the native
  /// launch screen hands over to a navy frame without it. Hold that one frame
  /// until the asset is decoded (bounded, so startup can never stall on it).
  void _holdFirstFrameForCoin() {
    if (_BootClock.firstFrameHeld) return;
    _BootClock.firstFrameHeld = true;
    final binding = WidgetsBinding.instance;
    if (binding.firstFrameRasterized) return;
    binding.deferFirstFrame();
    _holdingFirstFrame = true;
    final stream = const AssetImage(AppAssets.qirshCoinGold).resolve(
        createLocalImageConfiguration(context,
            size: const Size.square(kBootCoinSize)));
    final listener = ImageStreamListener((_, __) => _releaseFirstFrame(),
        onError: (_, __) => _releaseFirstFrame());
    _firstFrameStream = stream;
    _firstFrameListener = listener;
    _firstFrameTimeout =
        Timer(const Duration(milliseconds: 400), _releaseFirstFrame);
    stream.addListener(listener);
  }

  void _releaseFirstFrame() {
    if (!_holdingFirstFrame) return;
    _holdingFirstFrame = false;
    _firstFrameTimeout?.cancel();
    final listener = _firstFrameListener;
    if (listener != null) _firstFrameStream?.removeListener(listener);
    WidgetsBinding.instance.allowFirstFrame();
  }

  bool get _spins => widget.ring && widget.exit == null;

  void _tick(Duration sinceStart) {
    final now = _base + sinceStart;
    _BootClock.advance(now);
    if (_spins) _BootClock.ringOn = now >= _ringAt;
    _now.value = now;
    // A leaving copy ticks until it is removed (its ring keeps turning while
    // it completes); a still coin without a ring needs no frames.
    if (!_spins && widget.exit == null && now >= _motionEnd) _ticker.stop();
  }

  @override
  void didUpdateWidget(_BootLoaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_spins && !_ticker.isActive) {
      // A restarted ticker counts from zero again.
      _base = _BootClock.elapsed;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _releaseFirstFrame();
    _ticker.dispose();
    _now.dispose();
    _BootClock.end();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final exit = widget.exit;
    final footer = widget.footer;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: AnimatedBuilder(
        animation: exit == null ? _now : Listenable.merge([_now, exit]),
        builder: (context, _) {
          final e = exit?.value ?? 0.0;
          final split = widget.ringPhase;
          final x = exit == null
              ? 0.0
              : split >= 1
                  ? 1.0
                  : ((e - split) / (1 - split)).clamp(0.0, 1.0);
          final bgOpacity = 1 - Curves.ease.transform((x / 0.9).clamp(0, 1));
          final coin = _CoinBox(
            now: _now.value,
            reduce: reduce,
            ringOpacity: exit != null
                ? (split > 0 ? 1.0 : 0.0)
                : widget.ring
                    ? ((_now.value - _ringAt).inMicroseconds /
                            _ringFadeIn.inMicroseconds)
                        .clamp(0.0, 1.0)
                    : 0.0,
            ringFill: exit != null && split > 0
                ? Curves.easeOut.transform((e / split).clamp(0.0, 1.0))
                : 0.0,
          );
          final p = _exitCurve.transform(x);
          final coinOpacity =
              1 - Curves.ease.transform((x / 0.8).clamp(0.0, 1.0));
          return ColoredBox(
            key: widget.stableKey,
            color: AppBrandBlue.deep.withValues(alpha: bgOpacity),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Opacity(
                    opacity: coinOpacity,
                    child: Transform.translate(
                      offset: Offset(0, reduce ? 0 : -10 * p),
                      child: Transform.scale(
                        scale: reduce ? 1 : 1 - 0.14 * p,
                        child: coin,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.paddingOf(context).bottom + 40,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.12),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: footer ?? const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The coin with its glow, light sweep and ring. Its centre is always the
/// centre of the screen: the glow and ring are drawn around it, never beside
/// it, so nothing that appears or disappears can move the coin.
class _CoinBox extends StatelessWidget {
  const _CoinBox({
    required this.now,
    required this.reduce,
    required this.ringOpacity,
    required this.ringFill,
  });

  final Duration now;
  final bool reduce;
  final double ringOpacity;
  final double ringFill;

  static const double _glowSize = kBootCoinSize + 92;
  static const double _ringSize = kBootCoinSize + 28;

  static double _phase(Duration now, Duration delay, Duration length) =>
      ((now - delay).inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    // Flip: rotateY 0 → 250° (scale 1.07) at 55%, → 360° at 100%; the curve
    // applies per keyframe segment, as in CSS.
    var turn = 0.0;
    var scale = 1.0;
    if (!reduce) {
      final f = _phase(now, _flipDelay, _flipLength);
      if (f < 0.55) {
        final q = _flipCurve.transform(f / 0.55);
        turn = 250 * q;
        scale = 1 + 0.07 * q;
      } else {
        final q = _flipCurve.transform((f - 0.55) / 0.45);
        turn = 250 + 110 * q;
        scale = 1.07 - 0.07 * q;
      }
    }

    // Glow: 0 → 1 (scale .6 → 1.05) at 45%, settling at .55.
    double glowOpacity;
    double glowScale;
    if (reduce) {
      glowOpacity =
          0.5 * _phase(now, Duration.zero, const Duration(milliseconds: 400));
      glowScale = 1;
    } else {
      final g = _phase(now, _bloomDelay, _bloomLength);
      if (g < 0.45) {
        final q = Curves.easeOut.transform(g / 0.45);
        glowOpacity = q;
        glowScale = 0.6 + 0.45 * q;
      } else {
        final q = Curves.easeOut.transform((g - 0.45) / 0.55);
        glowOpacity = 1 - 0.45 * q;
        glowScale = 1.05 - 0.05 * q;
      }
    }

    final sweep = reduce ? 0.0 : _phase(now, _sweepDelay, _sweepLength);
    final spinPeriod = reduce ? 2400 : 950;
    final spin = (now.inMilliseconds % spinPeriod) / spinPeriod;

    return SizedBox.square(
      dimension: _glowSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glowOpacity > 0)
            Opacity(
              opacity: glowOpacity,
              child: Transform.scale(
                scale: glowScale,
                child: const SizedBox.square(
                  dimension: _glowSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        // CSS `radial-gradient(circle, …)` sizes to the
                        // farthest corner: √2 × half the side.
                        radius: 0.7071,
                        colors: [
                          Color(0x6BE4BA41),
                          Color(0x1FE4BA41),
                          Color(0x00E4BA41),
                        ],
                        stops: [0, 0.38, 0.66],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (ringOpacity > 0)
            Opacity(
              opacity: ringOpacity,
              child: CustomPaint(
                size: const Size.square(_ringSize),
                painter: _RingPainter(spin: spin, fill: ringFill),
              ),
            ),
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 1 / 600)
              ..rotateY(turn * math.pi / 180)
              ..scaleByDouble(scale, scale, 1, 1),
            child: const Image(
              image: AssetImage(AppAssets.qirshCoinGold),
              width: kBootCoinSize,
              height: kBootCoinSize,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
            ),
          ),
          if (sweep > 0 && sweep < 1)
            ClipOval(
              child: CustomPaint(
                size: const Size.square(kBootCoinSize),
                painter:
                    _SweepPainter(Curves.easeInOut.transform(sweep)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A thin gold comet: transparent tail, bright head, on a faint track.
/// [fill] 0 → 1 completes it into a solid ring.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.spin, required this.fill});

  final double spin;
  final double fill;

  static const Color _head = AppBrandAccent.goldLit;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    canvas.drawCircle(
      center,
      outer - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.07),
    );
    final tail = Color.lerp(
        AppBrandAccent.gold.withValues(alpha: 0), _head, fill)!;
    final rect = Rect.fromCircle(center: center, radius: outer);
    canvas.drawCircle(
      center,
      outer - 1.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = SweepGradient(
          colors: [tail, tail, _head.withValues(alpha: 0.95), _head],
          stops: const [0, 200 / 360, 350 / 360, 1],
          // CSS conic gradients start at 12 o'clock.
          transform: GradientRotation(-math.pi / 2 + spin * 2 * math.pi),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.spin != spin || old.fill != fill;
}

/// One skewed band of light crossing the coin face, left to right.
class _SweepPainter extends CustomPainter {
  const _SweepPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * 0.38;
    final left = size.width * (-0.6 + 1.85 * t);
    final band = Rect.fromLTWH(
        left, -size.height * 0.2, w, size.height * 1.4);
    canvas.save();
    canvas.translate(band.center.dx, band.center.dy);
    canvas.skew(math.tan(-12 * math.pi / 180), 0);
    canvas.translate(-band.center.dx, -band.center.dy);
    canvas.drawRect(
      band,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0x00FFFADC),
            Color(0x00FFFADC),
            Color(0xD9FFFADC),
            Color(0x00FFFADC),
            Color(0x00FFFADC),
          ],
          stops: [0, 0.2, 0.5, 0.8, 1],
        ).createShader(band),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t;
}
