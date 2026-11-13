import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Liquid Glass, as far as Flutter can draw it, following the liquid-glass
/// and apple-design skills:
///
/// * Only the FLOATING layer (controls, toolbars, sheets) is glass; content
///   never is.
/// * `regular`: blur in a ClipRRect, a translucent fill, a one-pixel light
///   border. `thick` is the more opaque variant that larger, text-heavy
///   surfaces (sheets) use so their text stays legible.
/// * `tint` is `.glassProminent`: the one primary action in a view.
/// * High contrast is the `.identity` fallback: an opaque surface with a firm
///   border (Flutter has no reduce-transparency signal; the HIG names high
///   contrast as the cue).
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 999,
    this.padding = EdgeInsets.zero,
    this.lit = false,
    this.thick = false,
    this.tint,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Under a finger: the glass brightens, as `.interactive()` glass does.
  final bool lit;
  final bool thick;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);

    if (MediaQuery.highContrastOf(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color:
              tint ??
              (dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7)),
          borderRadius: shape,
          border: Border.all(
            color: dark ? Colors.white70 : Colors.black54,
            width: 1.2,
          ),
        ),
        child: Padding(padding: padding, child: child),
      );
    }

    // Smoky see-through glass in dark mode, clear white glass in light.
    final Color fill;
    if (tint != null) {
      fill = tint!.withValues(alpha: lit ? 1 : 0.88);
    } else if (thick) {
      fill = dark
          ? Colors.black.withValues(alpha: 0.30)
          : Colors.white.withValues(alpha: 0.58);
    } else {
      fill = dark
          ? Colors.black.withValues(alpha: lit ? 0.10 : 0.22)
          : Colors.white.withValues(alpha: lit ? 0.65 : 0.42);
    }

    return DecoratedBox(
      // No shadow under see-through glass: it shows through the pane and
      // reads as a dark background. Only opaque tinted glass casts one.
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: tint == null
            ? [
                // Light glass needs a shadow to stand off a pale background.
                // OUTER only: drawn outside the shape, so nothing shows
                // through the pane and greys it.
                if (!dark)
                  BoxShadow(
                    // Centred: an outer shadow cuts off sharply at the edge,
                    // so any offset shows as a second, shifted pill.
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 18,
                    blurStyle: BlurStyle.outer,
                  ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.30 : 0.10),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: thick ? 12 : 8,
            sigmaY: thick ? 12 : 8,
          ),
          child: CustomPaint(
            foregroundPainter: _Rim(
              radius: radius,
              dark: dark,
              strength: tint != null ? 0.6 : (lit ? 1.4 : 1.0),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(color: fill, borderRadius: shape),
              padding: padding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The edge that makes glass read as glass: a one-pixel line that catches
/// light at the top left and again at the bottom right and fades between,
/// as on iOS 26 controls.
class _Rim extends CustomPainter {
  const _Rim({required this.radius, required this.dark, this.strength = 1});

  final double radius;
  final bool dark;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );
    final hi = ((dark ? 0.42 : 0.85) * strength).clamp(0.0, 1.0);
    Color w(double a) => Colors.white.withValues(alpha: a);

    // Circles and sheets: a straight diagonal gradient (the look the info
    // button and the sheets have, kept exactly).
    if (size.shortestSide / size.longestSide > 0.5) {
      final lo = ((dark ? 0.08 : 0.30) * strength).clamp(0.0, 1.0);
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [w(hi), w(lo), w(lo), w((hi * 0.7).clamp(0.0, 1.0))],
            stops: const [0, 0.4, 0.6, 1],
          ).createShader(rect),
      );
      return;
    }

    // Long pills: the info button's corner light, once in each corner. A
    // gradient across the whole pill lit an entire end; here each light is
    // sized to the pill's HEIGHT and anchored in its own corner, so the
    // top-left and bottom-right corners glow exactly as the circle does and
    // the long edges between keep only the faint base line.
    final lo = ((dark ? 0.08 : 0.30) * strength).clamp(0.0, 1.0);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final h = size.height;
    canvas.drawRRect(rr, stroke..color = w(lo));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [w(hi), w(0)],
        ).createShader(Rect.fromLTWH(0, 0, h * 0.8, h * 0.8)),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader =
            LinearGradient(
              begin: Alignment.bottomRight,
              end: Alignment.topLeft,
              colors: [w((hi * 0.7).clamp(0.0, 1.0)), w(0)],
            ).createShader(
              Rect.fromLTWH(size.width - h * 0.8, h * 0.2, h * 0.8, h * 0.8),
            ),
    );
  }

  @override
  bool shouldRepaint(_Rim old) =>
      old.radius != radius || old.dark != dark || old.strength != strength;
}

/// `.interactive()`: swells under the finger, brightens, and settles back
/// with a small bounce on release. The whole surface is the hit region
/// (`contentShape`), not just the label.
class _Interactive extends StatefulWidget {
  const _Interactive({
    required this.onTap,
    required this.builder,
    required this.label,
  });

  final VoidCallback onTap;
  final Widget Function(bool down) builder;
  final String label;

  @override
  State<_Interactive> createState() => _InteractiveState();
}

class _InteractiveState extends State<_Interactive> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapCancel: () => _set(false),
        onTapUp: (_) => _set(false),
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _down && !still ? 1.06 : 1,
          duration: Duration(milliseconds: _down ? 140 : 320),
          curve: _down ? Curves.easeOutCubic : Curves.easeOutBack,
          child: widget.builder(_down),
        ),
      ),
    );
  }
}

/// A single glass button. `tint` makes it the prominent one.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    required this.semanticLabel,
    this.circle = false,
    this.tint,
    this.height = 52,
  });

  final VoidCallback onPressed;
  final Widget child;
  final String semanticLabel;
  final bool circle;
  final Color? tint;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _Interactive(
      onTap: onPressed,
      label: semanticLabel,
      builder: (down) => GlassSurface(
        lit: down,
        tint: tint,
        child: SizedBox(
          height: height,
          width: circle ? height : null,
          child: Padding(
            padding: circle
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 22),
            // widthFactor 1: hug the label, never stretch to the parent.
            child: Center(widthFactor: circle ? null : 1, child: child),
          ),
        ),
      ),
    );
  }
}

class GlassGroupItem {
  const GlassGroupItem({
    required this.onPressed,
    required this.child,
    required this.semanticLabel,
    this.square = false,
  });

  final VoidCallback onPressed;
  final Widget child;
  final String semanticLabel;

  /// Icon-only: as wide as it is tall.
  final bool square;
}

/// `GlassEffectContainer`: neighbouring controls share ONE glass surface
/// rather than each drawing its own. Glass cannot sample glass, so separate
/// capsules side by side read as two materials; one blur is also cheaper. A
/// pressed item lifts a highlight inside the shared glass.
class GlassGroup extends StatelessWidget {
  const GlassGroup({super.key, required this.items, this.height = 52});

  final List<GlassGroupItem> items;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GlassSurface(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            _Interactive(
              onTap: item.onPressed,
              label: item.semanticLabel,
              builder: (down) => AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                height: height - 8,
                width: item.square ? height - 8 : null,
                padding: item.square
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: down
                      ? (dark
                            ? Colors.white.withValues(alpha: 0.14)
                            : Colors.black.withValues(alpha: 0.06))
                      : Colors.transparent,
                ),
                child: Center(child: item.child),
              ),
            ),
        ],
      ),
    );
  }
}

/// A glass bottom sheet: grabber, rounded top, swipe to dismiss.
Future<void> showGlassSheet(BuildContext context, Widget child) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    // No dimming (Material's default is 54% black): the glass needs the
    // screen behind it, at its own brightness, to read as glass. A tap
    // outside still closes the sheet.
    barrierColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: GlassSurface(
          radius: 34,
          thick: true,
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ),
    ),
  );
}
