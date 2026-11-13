import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'compass_painter.dart';
import 'glass.dart';
import 'heading.dart';

TextStyle _title(CompassPalette p) => TextStyle(
  color: p.foreground,
  fontSize: 24,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.4,
);

TextStyle _body(CompassPalette p) =>
    TextStyle(color: p.grey, fontSize: 15, height: 1.4);

/// The one prominent action in a sheet: `.glassProminent`, tinted glass.
class _Primary extends StatelessWidget {
  const _Primary(this.label, this.p, this.onTap, {this.tint});

  final String label;
  final CompassPalette p;
  final VoidCallback onTap;

  /// Overrides the default blue — the calibrate sheet turns it green once the
  /// sensor is ready, so the button itself confirms you can use the compass.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      tint: tint ?? p.blue,
      height: 50,
      semanticLabel: label,
      onPressed: onTap,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Secondary extends StatelessWidget {
  const _Secondary(this.label, this.p, this.onTap);

  final String label;
  final CompassPalette p;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      height: 50,
      semanticLabel: label,
      onPressed: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: p.foreground,
          fontSize: 17,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon, this.tint);

  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 26, color: tint),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Location

/// Explains what location adds BEFORE the OS prompt, which comes only on the
/// user's tap. A permanently refused grant offers Settings instead, since the
/// OS will not ask again.
Future<void> showLocationSheet(
  BuildContext context,
  CompassPalette p, {
  required bool blocked,
  required Future<void> Function() onAllow,
}) {
  return showGlassSheet(
    context,
    Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Badge(CupertinoIcons.location_fill, p.blue),
          const SizedBox(height: 16),
          Text('Show Your Location', style: _title(p)),
          const SizedBox(height: 8),
          Text(
            blocked
                ? 'Location is turned off for Compass. Turn it on in Settings '
                      '› Permissions › Location to see where you are.'
                : 'See your address, coordinates and elevation, and point to '
                      'true north instead of magnetic north. Your location '
                      'stays on this phone.',
            style: _body(p),
          ),
          const SizedBox(height: 24),
          _Primary(blocked ? 'Open Settings' : 'Allow Location', p, () {
            Navigator.of(context).pop();
            onAllow();
          }),
          const SizedBox(height: 10),
          _Secondary('Not Now', p, () => Navigator.of(context).pop()),
        ],
      ),
    ),
  );
}

/// After a one-time refusal: what happened, that the compass still works,
/// and one way back. (A refusal for good gets [showLocationSheet] with
/// Open Settings instead, since the OS will not ask again.)
Future<void> showLocationDeniedSheet(
  BuildContext context,
  CompassPalette p, {
  required VoidCallback onRetry,
}) {
  return showGlassSheet(
    context,
    Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Badge(CupertinoIcons.location_slash_fill, p.grey),
          const SizedBox(height: 16),
          Text('Location Not Allowed', style: _title(p)),
          const SizedBox(height: 8),
          Text(
            'The compass works without it, pointing to magnetic north. '
            'Allow location to see your address and true north.',
            style: _body(p),
          ),
          const SizedBox(height: 24),
          _Primary('Try Again', p, () {
            Navigator.of(context).pop();
            onRetry();
          }),
          const SizedBox(height: 10),
          _Secondary('Not Now', p, () => Navigator.of(context).pop()),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Calibrate

/// A figure 8 with a phone travelling round it, and the live accuracy under
/// it. Closes itself once the sensor reports high accuracy.
Future<void> showCalibrateSheet(
  BuildContext context,
  CompassPalette p,
  ValueListenable<Stats> stats,
) {
  return showGlassSheet(context, _Calibrate(p, stats));
}

class _Calibrate extends StatefulWidget {
  const _Calibrate(this.p, this.stats);

  final CompassPalette p;
  final ValueListenable<Stats> stats;

  @override
  State<_Calibrate> createState() => _CalibrateState();
}

class _CalibrateState extends State<_Calibrate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final bool _startedWeak = widget.stats.value.accuracy < 3;
  bool _done = false;
  Timer? _close;

  @override
  void initState() {
    super.initState();
    widget.stats.addListener(_onStats);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.disableAnimationsOf(context) && !_loop.isAnimating) {
      _loop.repeat();
    }
  }

  void _onStats() {
    if (_done || !_startedWeak || widget.stats.value.accuracy < 3) return;
    setState(() => _done = true);
    HapticFeedback.mediumImpact();
    _loop.stop();
    // Long enough to read the "ready — use it normally" line. The sheet was
    // closing in 1.4s while the user was still moving the phone, so the
    // confirmation went unseen and calibrating felt like it did nothing.
    _close = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    widget.stats.removeListener(_onStats);
    _close?.cancel();
    _loop.dispose();
    super.dispose();
  }

  /// Opened while the sensor was already High — nothing to do, so the sheet
  /// reassures instead of asking for a figure 8 that changes nothing.
  bool get _openedGood => !_startedWeak;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    // "Ready" covers both arriving here with a good sensor and finishing a
    // calibration — either way the user should be told, in words, to carry on.
    final ready = _done || _openedGood;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Calibrate Compass', style: _title(p)),
        const SizedBox(height: 8),
        Text(
          _openedGood
              ? 'Your compass is already accurate. Move it in a figure 8 only '
                    'if readings start to drift.'
              : 'Hold your phone and move it in a figure 8 a few times, away '
                    'from metal, magnets and laptops.',
          style: _body(p),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 150,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: ready ? 0.25 : 1,
            child: CustomPaint(painter: _FigureEight(_loop, p)),
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder(
          valueListenable: widget.stats,
          builder: (_, s, _) {
            final good = s.accuracy >= 3;
            const green = Color(0xFF34C759);
            // Show the calm "ready" line whenever the compass is usable —
            // whether it just finished or was already fine when opened.
            final showReady = good && ready;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: Column(
                key: ValueKey('${s.accuracy}$_done$_openedGood'),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        good
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.infinite,
                        size: 18,
                        color: good ? green : p.orange,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        good
                            ? (_done
                                  ? 'Calibrated'
                                  : (_openedGood
                                        ? 'Already calibrated'
                                        : 'Accuracy is high'))
                            : 'Accuracy: ${accuracyLabel(s.accuracy)}',
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  // The reassurance the sheet was missing: say in words that the
                  // compass is ready, so calibrating doesn't just silently close
                  // and re-opening an already-good compass isn't confusing.
                  if (showReady) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Your compass is ready — use it normally.',
                      textAlign: TextAlign.center,
                      style: _body(p),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        _Primary(
          'Done',
          p,
          () => Navigator.of(context).pop(),
          tint: ready ? const Color(0xFF34C759) : null,
        ),
      ],
    );
  }
}

/// A lemniscate with a phone glyph riding it and a fading trail behind.
class _FigureEight extends CustomPainter {
  _FigureEight(this.t, this.p) : super(repaint: t);

  final Animation<double> t;
  final CompassPalette p;

  Offset _at(double u, Size s) {
    final a = u * 2 * math.pi;
    final d = 1 + math.sin(a) * math.sin(a);
    final w = s.width * 0.30, h = s.height * 0.75;
    return s.center(Offset.zero) +
        Offset(w * math.cos(a) / d, h * math.sin(a) * math.cos(a) / d);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final path = Path();
    for (var i = 0; i <= 120; i++) {
      final o = _at(i / 120, s);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p.dim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Trail.
    for (var i = 1; i <= 14; i++) {
      final o = _at(t.value - i * 0.012, s);
      canvas.drawCircle(
        o,
        3.2 - i * 0.15,
        Paint()..color = p.blue.withValues(alpha: (1 - i / 15) * 0.5),
      );
    }

    // The phone, turned along the path.
    final here = _at(t.value, s);
    final ahead = _at(t.value + 0.004, s);
    final angle = math.atan2(ahead.dy - here.dy, ahead.dx - here.dx);
    canvas.save();
    canvas.translate(here.dx, here.dy);
    canvas.rotate(angle + math.pi / 2);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 18, height: 32),
      const Radius.circular(5),
    );
    canvas.drawRRect(body, Paint()..color = p.foreground);
    canvas.drawRRect(body.deflate(2), Paint()..color = p.background);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FigureEight old) => old.p != p;
}

// ---------------------------------------------------------------------------
// Info

Future<void> showInfoSheet(
  BuildContext context,
  CompassPalette p, {
  required bool trueNorth,
  required VoidCallback onCalibrate,
}) {
  Widget row(
    IconData icon,
    Color tint,
    String title,
    String body, {
    VoidCallback? onTap,
  }) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(color: p.grey, fontSize: 14, height: 1.35),
                ),
              ],
            ),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 8),
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: p.grey,
              ),
            ),
        ],
      ),
    );
    return onTap == null
        ? content
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: content,
          );
  }

  return showGlassSheet(
    context,
    Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Compass', style: _title(p)),
          const SizedBox(height: 10),
          row(
            CupertinoIcons.compass,
            p.accent,
            trueNorth ? 'True north' : 'Magnetic north',
            trueNorth
                ? 'Corrected for your location, so N points to the geographic '
                      'North Pole.'
                : 'N points to magnetic north. Show your location to switch '
                      'to true north.',
          ),
          row(
            CupertinoIcons.lock_fill,
            p.foreground,
            'Lock a heading',
            'Tap the dial or Lock Heading. The orange arc shows how far you have '
                'turned from it.',
          ),
          row(
            CupertinoIcons.plus,
            p.foreground,
            'Level',
            'The small cross drifts to the higher side. A ring appears when '
                'the phone lies flat.',
          ),
          row(
            CupertinoIcons.infinite,
            p.orange,
            'Calibrate',
            'If readings drift or an orange warning appears under the heading, '
                'recalibrate.',
            onTap: () {
              Navigator.of(context).pop();
              onCalibrate();
            },
          ),
        ],
      ),
    ),
  );
}
