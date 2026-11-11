import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../app_motion.dart';
import '../mali_tokens.dart';

/// One slice of a [DonutChart].
class DonutSegment {
  const DonutSegment({required this.value, required this.color, this.label});

  final double value;
  final Color color;
  final String? label;
}

/// DonutChart — category spend breakdown as a ring of proportional arcs, with
/// an optional [center] slot (e.g. total). Pure presentation. When all values
/// are zero it renders the neutral track only (no-data state).
///
/// v2 `m.chart`: the arcs sweep in clockwise from 12 o'clock, segments chained,
/// over `dur.chart` on `ease.out` — once, when at least 30% of the chart is on
/// screen ([revealWhenVisible]). Gaps are left transparent so they read in the
/// card colour; caps are round. Reduce Motion renders it complete.
///
/// [centerBuilder] receives the draw-in progress (0..1) so a centre total can
/// count up in sync with the sweep. [selectedIndex] lifts that arc outward 6pt
/// and dims the others to 35% (`spring.snappy`).
class DonutChart extends StatefulWidget {
  const DonutChart({
    super.key,
    required this.segments,
    this.size = 118,
    this.strokeWidth = 20,
    this.center,
    this.gapDegrees = 3,
    this.animate = true,
    this.centerBuilder,
    this.selectedIndex,
    this.onSegmentTap,
    this.revealWhenVisible = true,
  });

  final List<DonutSegment> segments;
  final double size;
  final double strokeWidth;
  final Widget? center;
  final double gapDegrees;
  final bool animate;

  /// Builds the centre from the draw-in progress; wins over [center].
  final Widget Function(BuildContext context, double progress)? centerBuilder;

  /// Index into [segments] of the lifted arc, or null for none.
  final int? selectedIndex;

  /// Called with the tapped segment's index (taps on the ring only).
  final ValueChanged<int>? onSegmentTap;

  /// Start the draw-in only once ≥30% of the chart is visible.
  final bool revealWhenVisible;

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> with TickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: AppMotion.chartAnimation,
  );
  late final AnimationController _select = AnimationController(
    vsync: this,
    duration: AppMotion.base,
    value: widget.selectedIndex == null ? 0 : 1,
  );
  late final Animation<double> _drawCurve =
      CurvedAnimation(parent: _draw, curve: AppMotion.easeOut);
  late final Animation<double> _selectCurve =
      CurvedAnimation(parent: _select, curve: AppMotion.springSnappyCurve);
  int? _lifted;
  bool _started = false;
  final List<ScrollPosition> _positions = [];

  double get _total =>
      widget.segments.fold<double>(0, (s, seg) => s + math.max(seg.value, 0));

  @override
  void initState() {
    super.initState();
    _lifted = widget.selectedIndex;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!widget.animate || reduce || _total <= 0) {
      _complete();
      return;
    }
    if (_started) return;
    if (!widget.revealWhenVisible) {
      _start();
      return;
    }
    _attach();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
  }

  @override
  void didUpdateWidget(covariant DonutChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.selectedIndex;
    if (next != oldWidget.selectedIndex) {
      if (next != null) {
        _lifted = next;
        _select.forward();
      } else {
        _select.reverse();
      }
    }
  }

  void _complete() {
    _started = true;
    _detach();
    _draw.value = 1;
  }

  void _start() {
    if (_started) return;
    _started = true;
    _detach();
    _draw.forward();
  }

  void _attach() {
    _detach();
    BuildContext? ctx = context;
    while (ctx != null) {
      final scrollable = Scrollable.maybeOf(ctx);
      if (scrollable == null) break;
      _positions.add(scrollable.position);
      scrollable.position.addListener(_checkVisible);
      ctx = scrollable.context;
    }
  }

  void _detach() {
    for (final p in _positions) {
      p.removeListener(_checkVisible);
    }
    _positions.clear();
  }

  void _checkVisible() {
    if (_started || !mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final visible = rect.intersect(screen);
    if (rect.height <= 0 || visible.width <= 0 || visible.height <= 0) return;
    if (visible.height >= rect.height * .3) _start();
  }

  @override
  void dispose() {
    _detach();
    _draw.dispose();
    _select.dispose();
    super.dispose();
  }

  int? _hitSegment(Offset local) {
    final total = _total;
    if (total <= 0) return null;
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = local - c;
    final radius = (widget.size - widget.strokeWidth) / 2;
    final distance = d.distance;
    final slack = widget.strokeWidth / 2 + 10;
    if ((distance - radius).abs() > slack) return null;
    // Clockwise angle from 12 o'clock (y points down on the canvas).
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    var start = 0.0;
    for (var i = 0; i < widget.segments.length; i++) {
      final v = math.max(widget.segments[i].value, 0);
      final full = v / total * 2 * math.pi;
      if (v > 0 && angle >= start && angle < start + full) return i;
      start += full;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final total = _total;
    Widget chart = AnimatedBuilder(
      animation: Listenable.merge([_drawCurve, _selectCurve]),
      builder: (context, _) {
        final progress = _drawCurve.value;
        final centre = widget.centerBuilder?.call(context, progress) ??
            widget.center;
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _DonutPainter(
            segments: widget.segments,
            total: total,
            strokeWidth: widget.strokeWidth,
            gapDegrees: widget.gapDegrees,
            trackColor: t.ringTrackNeutral,
            progress: progress,
            lifted: _lifted,
            selection: _selectCurve.value,
          ),
          child: centre == null
              ? null
              : SizedBox.square(
                  dimension: widget.size, child: Center(child: centre)),
        );
      },
    );
    if (widget.onSegmentTap != null) {
      chart = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (details) {
          final hit = _hitSegment(details.localPosition);
          if (hit == null) return;
          HapticFeedback.selectionClick();
          widget.onSegmentTap!(hit);
        },
        child: chart,
      );
    }
    return RepaintBoundary(child: chart);
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.total,
    required this.strokeWidth,
    required this.gapDegrees,
    required this.trackColor,
    required this.progress,
    required this.lifted,
    required this.selection,
  });

  final List<DonutSegment> segments;
  final double total;
  final double strokeWidth;
  final double gapDegrees;
  final Color trackColor;
  final double progress;
  final int? lifted;
  final double selection;

  static const double _lift = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // Leave room for the lifted arc so it never clips.
    final radius = (size.shortestSide - strokeWidth) / 2 -
        (lifted == null ? 0 : _lift * selection);
    const startBase = -math.pi / 2;
    final gap = gapDegrees * math.pi / 180;

    if (total <= 0) {
      final track = Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, track);
      return;
    }

    // Chained clockwise sweep: everything up to [limit] radians is drawn.
    final limit = progress.clamp(0.0, 1.0) * 2 * math.pi;
    // A round cap adds strokeWidth/2 of arc at each end; compensate so the
    // visible gap stays [gapDegrees] wide.
    final capAngle = radius <= 0 ? 0.0 : (strokeWidth / 2) / radius;
    // A single slice is a whole ring: no gap, no caps.
    final single = segments.where((s) => s.value > 0).length == 1;
    var start = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.value <= 0) continue;
      final full = (seg.value / total) * (2 * math.pi);
      final segStart = start;
      start += full;
      if (segStart >= limit) continue;
      final round = !single && full - gap - 2 * capAngle > 0.02;
      final inset = single ? 0.0 : gap / 2 + (round ? capAngle : 0);
      final from = segStart + inset;
      final to = math.min(segStart + full - inset, limit);
      final sweep = to - from;
      if (sweep <= 0) continue;
      final isLifted = lifted == i;
      final alpha = lifted == null || isLifted
          ? 1.0
          : 1.0 - .65 * selection;
      final paint = Paint()
        ..color = seg.color.withValues(alpha: seg.color.a * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = round ? StrokeCap.round : StrokeCap.butt;
      var c = center;
      if (isLifted && selection > 0) {
        final mid = startBase + segStart + full / 2;
        c = center +
            Offset(math.cos(mid), math.sin(mid)) * (_lift * selection);
      }
      canvas.drawArc(Rect.fromCircle(center: c, radius: radius),
          startBase + from, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress ||
      old.total != total ||
      old.segments != segments ||
      old.lifted != lifted ||
      old.selection != selection ||
      old.strokeWidth != strokeWidth;
}
