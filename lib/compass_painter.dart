import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'heading.dart';

/// What one frame of the dial draws.
class DialState {
  const DialState({
    this.heading = 0,
    this.pitch = 0,
    this.roll = 0,
    this.locked,
  });

  final double heading;
  final double pitch;
  final double roll;

  /// Heading the user locked by tapping, or null.
  final double? locked;

  bool get level => pitch.abs() < 1.5 && roll.abs() < 1.5;
}

/// iOS system colours for each appearance.
class CompassPalette {
  const CompassPalette._({
    required this.background,
    required this.foreground,
    required this.grey,
    required this.dim,
    required this.accent,
    required this.orange,
    required this.blue,
  });

  final Color background, foreground, grey, dim, accent, orange, blue;

  static const dark = CompassPalette._(
    background: Color(0xFF000000),
    foreground: Color(0xFFFFFFFF),
    grey: Color(0xFF8E8E93),
    dim: Color(0xFF48484A),
    accent: Color(0xFFFF9F0A),
    orange: Color(0xFFFF9F0A),
    blue: Color(0xFF0A84FF),
  );

  static const light = CompassPalette._(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF000000),
    grey: Color(0xFF8E8E93),
    dim: Color(0xFFC7C7CC),
    accent: Color(0xFFFF9500),
    orange: Color(0xFFC93400),
    blue: Color(0xFF007AFF),
  );

  static CompassPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// The compass dial. Ticks, numbers and letters turn with the world; the
/// heading line at the top and the centre crosshair are fixed to the phone.
/// Numbers and letters stay upright as the dial turns.
class CompassPainter extends CustomPainter {
  CompassPainter(this.state, this.p) : super(repaint: state);

  final ValueNotifier<DialState> state;
  final CompassPalette p;

  static final Map<String, TextPainter> _text = {};

  TextPainter _label(String s, double size, FontWeight w, Color c) {
    final key = '$s|$size|${w.value}|${c.toARGB32()}';
    return _text.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: 'Inter',
            color: c,
            fontSize: size,
            fontWeight: w,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = state.value;
    final c = size.center(Offset.zero);
    // Ring radius, leaving room outside it for the degree numbers.
    final r = size.shortestSide / 2 * 0.76;
    final rot = -s.heading * math.pi / 180;

    Offset at(double deg, double radius) {
      final a = deg * math.pi / 180 + rot - math.pi / 2;
      return c + Offset(math.cos(a), math.sin(a)) * radius;
    }

    // Lock arc: from the locked bearing to where the phone points now.
    if (s.locked != null) {
      final d = angleDelta(s.locked!, s.heading);
      final start = (s.locked! - 90) * math.pi / 180 + rot;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r - r * 0.045),
        start,
        d * math.pi / 180,
        false,
        Paint()
          ..color = p.accent.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.09,
      );
    }

    // Ticks every 2 degrees; every 30 is long and bold.
    final minor = Paint()
      ..color = p.grey
      ..strokeWidth = r * 0.008
      ..strokeCap = StrokeCap.butt;
    final major = Paint()
      ..color = p.foreground
      ..strokeWidth = r * 0.016
      ..strokeCap = StrokeCap.butt;
    for (var deg = 0; deg < 360; deg += 2) {
      final isMajor = deg % 30 == 0;
      if (deg == 0) continue; // north gets the accent marker below
      final len = isMajor ? r * 0.11 : r * 0.07;
      canvas.drawLine(
        at(deg.toDouble(), r),
        at(deg.toDouble(), r - len),
        isMajor ? major : minor,
      );
    }

    // North: an accent triangle pointing in at the top of the ring.
    final tip = at(0, r - r * 0.12);
    final baseL = at(-3.2, r + r * 0.005);
    final baseR = at(3.2, r + r * 0.005);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(baseL.dx, baseL.dy)
        ..lineTo(baseR.dx, baseR.dy)
        ..close(),
      Paint()..color = p.accent,
    );

    // Degree numbers outside the ring, upright.
    for (var deg = 0; deg < 360; deg += 30) {
      final tp = _label('$deg', r * 0.085, FontWeight.w400, p.foreground);
      tp.paint(
        canvas,
        at(deg.toDouble(), r + r * 0.15) - tp.size.center(Offset.zero),
      );
    }

    // Cardinal letters inside the ring, upright.
    const letters = {0: 'N', 90: 'E', 180: 'S', 270: 'W'};
    letters.forEach((deg, l) {
      final tp = _label(l, r * 0.17, FontWeight.w400, p.foreground);
      tp.paint(
        canvas,
        at(deg.toDouble(), r * 0.68) - tp.size.center(Offset.zero),
      );
    });

    // Fixed heading line at the top, across the ring.
    canvas.drawLine(
      c + Offset(0, -r - r * 0.07),
      c + Offset(0, -r + r * 0.15),
      Paint()
        ..color = p.foreground
        ..strokeWidth = r * 0.022
        ..strokeCap = StrokeCap.round,
    );

    // Fixed crosshair, and the level crosshair that drifts to the high side.
    final arm = r * 0.16;
    final fixed = Paint()
      ..color = p.dim
      ..strokeWidth = r * 0.008;
    canvas.drawLine(c - Offset(arm, 0), c + Offset(arm, 0), fixed);
    canvas.drawLine(c - Offset(0, arm), c + Offset(0, arm), fixed);

    final reach = r * 0.38;
    final off = Offset(
      (-s.roll / 30).clamp(-1.0, 1.0) * reach,
      (s.pitch / 30).clamp(-1.0, 1.0) * reach,
    );
    final lc = c + off;
    final level = s.level;
    final bubble = Paint()
      ..color = level ? p.foreground : p.foreground.withValues(alpha: 0.85)
      ..strokeWidth = r * 0.014
      ..strokeCap = StrokeCap.round;
    final a2 = arm * 0.55;
    canvas.drawLine(lc - Offset(a2, 0), lc + Offset(a2, 0), bubble);
    canvas.drawLine(lc - Offset(0, a2), lc + Offset(0, a2), bubble);
    if (level) {
      canvas.drawCircle(
        c,
        arm * 0.42,
        Paint()
          ..color = p.foreground
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.01,
      );
    }
  }

  @override
  bool shouldRepaint(CompassPainter old) => old.state != state || old.p != p;
}

/// The small north triangle, for use beside text.
class NorthMark extends CustomPainter {
  const NorthMark(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(s.width, 0)
        ..lineTo(s.width / 2, s.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(NorthMark old) => old.color != color;
}
