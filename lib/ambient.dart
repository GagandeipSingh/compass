import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'compass_painter.dart';

/// The live background, two layers:
///
/// * a sky that follows the time of day: deep navy at night, rose at dawn,
///   blue by day, gold in the late afternoon, violet at dusk. A deep version
///   in dark mode and a pale one in light mode, blended smoothly between
///   moments and re-read once a minute;
/// * faint topographic contour lines, a map turning under the phone as the
///   heading changes (the textured backdrop Telegram's chat wallpaper gives
///   its glass).
///
/// Both give the glass above something real to blur, which a flat black or
/// white screen does not. Kept quiet so the dial stays the hero.
class AmbientSky extends CustomPainter {
  AmbientSky(this.state, this.p, {required this.still}) : super(repaint: state);

  final ValueNotifier<DialState> state;
  final CompassPalette p;
  final bool still;

  static ui.Picture? _topo;
  static String? _topoKey;

  static (Color, Color)? _sky;
  static int? _skyMinute;
  static bool? _skyDark;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = p == CompassPalette.dark;
    final h = state.value.heading * math.pi / 180;
    final c = Offset(size.width / 2, size.height * 0.42);

    final now = DateTime.now();
    final minute = now.hour * 60 + now.minute;
    if (_skyMinute != minute || _skyDark != dark) {
      _sky = skyAt(now.hour + now.minute / 60, dark: dark);
      _skyMinute = minute;
      _skyDark = dark;
    }
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_sky!.$1, _sky!.$2],
        ).createShader(rect),
    );

    // Contours: drawn once for this size and appearance, then only rotated.
    final side = math
        .sqrt(size.width * size.width + size.height * size.height)
        .ceilToDouble();
    final key = '$side|$dark';
    if (_topoKey != key) {
      _topo = _drawTopo(
        side,
        dark ? Colors.white : Colors.black,
        dark ? 0.07 : 0.06,
      );
      _topoKey = key;
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-h);
    canvas.translate(-side / 2, -side / 2);
    canvas.drawPicture(_topo!);
    canvas.restore();
  }

  /// Iso-lines of a smooth hilly field, by marching squares.
  static ui.Picture _drawTopo(double side, Color color, double alpha) {
    double f(double x, double y) =>
        math.sin(x / 95 + math.sin(y / 140) * 1.3) +
        math.cos(y / 115 - math.sin(x / 175) * 1.1) +
        0.6 * math.sin((x + y) / 75);

    const step = 10.0;
    final n = (side / step).ceil() + 1;
    final v = List.generate(
      n,
      (i) => List.generate(n, (j) => f(i * step, j * step)),
    );

    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var level = -2.4; level <= 2.4; level += 0.4) {
      final path = Path();
      for (var i = 0; i < n - 1; i++) {
        for (var j = 0; j < n - 1; j++) {
          final a = v[i][j], b = v[i + 1][j];
          final cc = v[i + 1][j + 1], d = v[i][j + 1];
          final x = i * step, y = j * step;
          final pts = <Offset>[];
          void edge(double p0, double p1, Offset o0, Offset o1) {
            if ((p0 < level) != (p1 < level)) {
              final t = (level - p0) / (p1 - p0);
              pts.add(Offset.lerp(o0, o1, t)!);
            }
          }

          edge(a, b, Offset(x, y), Offset(x + step, y));
          edge(b, cc, Offset(x + step, y), Offset(x + step, y + step));
          edge(cc, d, Offset(x + step, y + step), Offset(x, y + step));
          edge(d, a, Offset(x, y + step), Offset(x, y));
          for (var k = 0; k + 1 < pts.length; k += 2) {
            path
              ..moveTo(pts[k].dx, pts[k].dy)
              ..lineTo(pts[k + 1].dx, pts[k + 1].dy);
          }
        }
      }
      canvas.drawPath(path, paint);
    }
    return rec.endRecording();
  }

  @override
  bool shouldRepaint(AmbientSky old) =>
      old.state != state || old.p != p || old.still != still;
}

/// (top, bottom) sky colours for an hour of the day, 0..24.
(Color, Color) skyAt(double hour, {required bool dark}) {
  final keys = dark ? _darkSky : _lightSky;
  for (var i = 0; i < keys.length - 1; i++) {
    final (h0, t0, b0) = keys[i];
    final (h1, t1, b1) = keys[i + 1];
    if (hour >= h0 && hour <= h1) {
      final t = Curves.easeInOut.transform((hour - h0) / (h1 - h0));
      return (Color.lerp(t0, t1, t)!, Color.lerp(b0, b1, t)!);
    }
  }
  return (keys.first.$2, keys.first.$3);
}

// (hour, top, bottom). Last entry repeats the first at 24 so midnight wraps.
const _darkSky = [
  (0.0, Color(0xFF070B1C), Color(0xFF000000)),
  (5.0, Color(0xFF141233), Color(0xFF040308)),
  (6.5, Color(0xFF2E1E45), Color(0xFF4A2420)),
  (8.5, Color(0xFF0C2440), Color(0xFF070F1C)),
  (13.0, Color(0xFF0D2A4C), Color(0xFF081424)),
  (17.0, Color(0xFF2A2240), Color(0xFF4A2A12)),
  (19.0, Color(0xFF231A3E), Color(0xFF2A1014)),
  (21.0, Color(0xFF0B0F28), Color(0xFF020206)),
  (24.0, Color(0xFF070B1C), Color(0xFF000000)),
];

// A soft tint rather than a pale wash: light glass needs some colour
// behind it to be visible, but not so much that the screen reads as blue.
const _lightSky = [
  (0.0, Color(0xFFD8DDF1), Color(0xFFF0F3FA)),
  (5.0, Color(0xFFDED8EF), Color(0xFFF6F2F9)),
  (6.5, Color(0xFFF8D2C0), Color(0xFFFDEEE4)),
  (8.5, Color(0xFFD0E2F8), Color(0xFFF0F6FE)),
  (13.0, Color(0xFFC3DCF8), Color(0xFFEDF5FE)),
  (17.0, Color(0xFFF8D2AD), Color(0xFFFDEDDD)),
  (19.0, Color(0xFFE0CCEC), Color(0xFFF7EDF2)),
  (21.0, Color(0xFFD5D9F0), Color(0xFFEFF1FA)),
  (24.0, Color(0xFFD8DDF1), Color(0xFFF0F3FA)),
];
