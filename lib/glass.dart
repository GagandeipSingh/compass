import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

/// The liquid glass lens shader (`shaders/lens.frag`), loaded once at
/// startup. It needs Impeller's shader image filters; where they are
/// missing, or the load fails, every surface falls back to frost.
class GlassLens {
  GlassLens._();

  static ui.FragmentProgram? _program;

  static Future<void> load() async {
    if (!ImageFilter.isShaderFilterSupported) return;
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/lens.frag');
    } catch (_) {
      _program = null;
    }
  }

  static bool get ready => _program != null;
}

/// Liquid Glass after iOS 26, the same material Breeze uses:
///
/// * Only the FLOATING layer (controls, toolbars, sheets) is glass; content
///   never is.
/// * Where Impeller is available the glass is a LENS (`shaders/lens.frag`):
///   its curved edge bends the sky behind it inward, a specular hairline
///   catches the light from the top left, and colour is lifted through the
///   frost. Elsewhere it is frost: blur, a clear body and a lit hairline.
/// * `thick` is the more frosted variant that larger, text-heavy surfaces
///   use so their text stays legible.
/// * `tint` is `.glassProminent`: the one primary action in a view, drawn as
///   TINTED glass, deep enough to read as solid while the rim still catches
///   the light over it.
/// * High contrast is the `.identity` fallback: an opaque surface with a firm
///   border (Flutter has no reduce-transparency signal; the HIG names high
///   contrast as the cue).
///
/// Glass inside glass is frost: a lens samples the screen, and inside
/// another glass layer the screen it would sample is that layer's.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 999,
    this.padding = EdgeInsets.zero,
    this.lit = false,
    this.thick = false,
    this.tint,
    this.glassColor,
    this.blur,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Under a finger: the glass brightens, as `.interactive()` glass does.
  final bool lit;
  final bool thick;

  /// The prominent fill (a primary button).
  final Color? tint;

  /// The glass's own colour in place of the default clear glass (sheets
  /// sit a shade deeper than the controls under them).
  final Color? glassColor;

  /// Blur strength, overriding the default.
  final double? blur;

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

    final nested = _GlassNest.inside(context);
    if (!nested && GlassLens.ready) return _lens(context, dark, shape);
    return _frost(dark, shape);
  }

  /// The floating material: a lens over the screen.
  Widget _lens(BuildContext context, bool dark, BorderRadius shape) {
    final fill = tint;
    final Color glass = fill != null
        ? Color.lerp(fill, Colors.black, 0.12)!.withValues(alpha: 0.9)
        : glassColor ??
              (dark
                  ? const Color(0xFF3C3F46).withValues(alpha: 0.38)
                  : const Color(0xFFF8F9FB).withValues(alpha: 0.42));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        // Light glass lifts off the page on a faint, even halo, as iOS
        // light glass does: centred, so it never shows as a grey ledge.
        // On dark it reads as banding, so none.
        boxShadow: dark
            ? const []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.035),
                  blurRadius: 22,
                  offset: const Offset(0, 2),
                  blurStyle: BlurStyle.outer,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: _Lens(
          radius: radius,
          dark: dark,
          lit: lit,
          floating: true,
          tint: glass,
          blur: blur ?? (thick ? 12 : 5.5),
          child: _GlassNest(
            child: DecoratedBox(
              // Tinted glass is a shade lighter at the top, where the light
              // falls on it; plain glass needs nothing on top.
              decoration: BoxDecoration(
                gradient: fill == null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.09),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
              ),
              child: _TouchGlow(
                glow: PressGlow.of(context),
                dark: dark,
                // Only this glass glows: anything glass inside is shielded.
                child: PressGlow(
                  point: null,
                  strength: 0,
                  child: Padding(padding: padding, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The quiet material: frost, where there is no lens or inside glass.
  Widget _frost(bool dark, BorderRadius shape) {
    final Color fill;
    if (tint != null) {
      fill = tint!.withValues(alpha: lit ? 1 : 0.88);
    } else if (glassColor != null) {
      fill = glassColor!;
    } else {
      fill = dark
          ? const Color(
              0xFF222634,
            ).withValues(alpha: lit ? 0.36 : (thick ? 0.28 : 0.20))
          : Colors.white.withValues(alpha: lit ? 0.80 : (thick ? 0.70 : 0.58));
    }

    final shadows = dark
        ? const <BoxShadow>[]
        : [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: thick ? 18 : 12,
              blurStyle: BlurStyle.outer,
            ),
          ];

    final sigma = blur ?? (thick ? 12.0 : 10.0);

    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: shape, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
          child: CustomPaint(
            foregroundPainter: _FrostRim(
              radius: radius,
              dark: dark,
              lit: lit,
              hasCustomFill: tint != null,
            ),
            child: _GlassNest(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(color: fill, borderRadius: shape),
                padding: padding,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.interactive()`: swells under the finger on a real spring and settles
/// back with a bounce, keeping its speed if pressed again mid-bounce; the
/// glass lights up around the finger. The whole surface is the hit region
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
  bool _hover = false;
  Offset? _at; // the finger, in this control's own coordinates

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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hover) setState(() => _hover = true);
        },
        onExit: (_) {
          if (_hover) setState(() => _hover = false);
        },
        child: Listener(
          onPointerDown: (e) => setState(() => _at = e.localPosition),
          onPointerMove: (e) {
            if (_down) setState(() => _at = e.localPosition);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _set(true),
            onTapCancel: () => _set(false),
            onTapUp: (_) => _set(false),
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onTap();
            },
            child: SpringValue(
              value: _down && !still ? 1 : (_hover && !still ? 0.33 : 0),
              stiffness: _down ? 420 : 180,
              dampingRatio: _down ? 0.8 : 0.5,
              child: widget.builder(_down),
              builder: (context, v, child) => Transform.scale(
                scale: 1 + 0.06 * v,
                child: PressGlow(
                  point: _at,
                  strength: v.clamp(0.0, 1.0),
                  child: child!,
                ),
              ),
            ),
          ),
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

/// The sheets' glass: the same glass as the controls, more frosted so its
/// words read over the sky, and a shade deeper so it sits above them.
Color _sheetGlass(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF16181C).withValues(alpha: 0.30)
    : const Color(0xFFEEF0F4).withValues(alpha: 0.55);

/// A glass sheet. On a phone it rises from the bottom on a soft spring, with
/// a grabber and swipe to dismiss; on a tablet, an unfolded foldable or a
/// desktop window it is a centred floating card that springs in.
Future<void> showGlassSheet(BuildContext context, Widget child) {
  if (isWideLayout(context)) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: motion(context, kSpringMs),
      pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, secondary, _) {
        // The card is moved, never faded: glass inside a fade flashes white.
        // The dim behind it is the barrier's own fade.
        final pop = CurvedAnimation(
          parent: anim,
          curve: kSpring,
          reverseCurve: Curves.easeInCubic,
        );
        final screenH = MediaQuery.sizeOf(ctx).height;
        return Center(
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1.0).animate(pop),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.08),
                end: Offset.zero,
              ).animate(pop),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  maxHeight: math.min(640, screenH - 32),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GlassSurface(
                    radius: 34,
                    thick: true,
                    blur: 12,
                    glassColor: _sheetGlass(ctx),
                    padding: const EdgeInsets.all(24),
                    child: Material(
                      type: MaterialType.transparency,
                      child: SingleChildScrollView(child: child),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    // A soft dim behind, as iOS sets a sheet apart from the screen under it.
    barrierColor: Colors.black.withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? 0.28 : 0.12,
    ),
    isScrollControlled: true,
    // Rises on a soft spring and settles, as an iOS sheet does.
    sheetAnimationStyle: AnimationStyle(
      duration: motion(context, kSpringMs),
      reverseCurve: Curves.easeInCubic,
      reverseDuration: motion(context, 240),
    ),
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (context) {
      final screenH = MediaQuery.sizeOf(context).height;
      return _SheetSpring(
        child: _SheetStretch(
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(640, screenH - 32),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: GlassSurface(
                  radius: 34,
                  thick: true,
                  blur: 12,
                  glassColor: _sheetGlass(context),
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
                      Flexible(child: SingleChildScrollView(child: child)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Flutter's sheet rises on a fixed decelerate and ignores the curve it is
/// given, so the sheet arrived flat. This adds the difference between that
/// curve and the spring while it opens: the sheet runs a little past its
/// resting place and settles back, as an iOS sheet does. A drag or the
/// close is left alone.
class _SheetSpring extends StatelessWidget {
  const _SheetSpring({required this.child});
  final Widget child;

  // Flutter's own opening curve for a modal sheet (bottom_sheet.dart).
  static const Curve _flutter = Cubic(0.0, 0.0, 0.2, 1.0);

  @override
  Widget build(BuildContext context) {
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (context, child) {
        final t = anim.value;
        final dy = anim.status == AnimationStatus.forward
            ? _flutter.transform(t) - kSpring.transform(t)
            : 0.0;
        return FractionalTranslation(translation: Offset(0, dy), child: child);
      },
    );
  }
}

/// Pulling an open sheet UP stretches it a little on rubber, with more
/// resistance the further it goes, and it springs back on release, as an
/// iOS sheet does. Pulling down is the sheet's own drag to close.
class _SheetStretch extends StatefulWidget {
  const _SheetStretch({required this.child});
  final Widget child;

  @override
  State<_SheetStretch> createState() => _SheetStretchState();
}

class _SheetStretchState extends State<_SheetStretch> {
  double _pull = 0; // raw finger travel upward, in dp
  double _from = 0; // where the release springs back from
  int _release = 0;
  bool _held = false;

  // Rubber: the first few dp follow the finger, then it stiffens.
  static double _rubber(double d) => 48 * (1 - math.exp(-d / 110));

  void _up() {
    if (!_held) return;
    setState(() {
      _held = false;
      _from = _rubber(_pull);
      _pull = 0;
      _release++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    Widget body;
    if (_held) {
      body = Transform.translate(
        offset: Offset(0, -_rubber(_pull)),
        child: widget.child,
      );
    } else if (_from > 0 && !still) {
      body = TweenAnimationBuilder<double>(
        key: ValueKey(_release),
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: kSpringMs),
        curve: kSpring,
        child: widget.child,
        builder: (context, v, child) =>
            Transform.translate(offset: Offset(0, -_from * v), child: child),
      );
    } else {
      body = widget.child;
    }
    return Listener(
      onPointerMove: (e) {
        final next = _pull - e.delta.dy;
        if (next <= 0 && !_held) return;
        setState(() {
          _held = next > 0;
          _pull = math.max(0, next);
        });
      },
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: body,
    );
  }
}

/// Marks a subtree as already inside glass.
class _GlassNest extends InheritedWidget {
  const _GlassNest({required super.child});

  static bool inside(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlassNest>() != null;

  @override
  bool updateShouldNotify(_GlassNest old) => false;
}

class _Lens extends SingleChildRenderObjectWidget {
  const _Lens({
    required this.radius,
    required this.dark,
    required this.lit,
    required this.floating,
    required this.tint,
    required this.blur,
    super.child,
  });

  /// A floating control (deeper bevel, stronger bend) or a card in a list.
  final bool floating;

  final double radius;
  final bool dark;
  final bool lit;
  final Color tint;
  final double blur;

  /// Everything that can move the glass without repainting it: the
  /// scrollables it sits in and its screen's transitions. A scroll moves the glass on
  /// screen without repainting it, and the shader must follow in the same
  /// frame or its rim is drawn where the card was a frame ago (a trail).
  static Listenable? _scrolls(BuildContext context) {
    final positions = <Listenable>[];
    var ctx = context;
    while (true) {
      final s = Scrollable.maybeOf(ctx);
      if (s == null) break;
      positions.add(s.position);
      ctx = s.context;
    }
    // A screen sliding in or out (and the one under it, sliding aside)
    // moves its glass without repainting it too.
    final route = ModalRoute.of(context);
    if (route?.animation != null) positions.add(route!.animation!);
    if (route?.secondaryAnimation != null) {
      positions.add(route!.secondaryAnimation!);
    }
    return positions.isEmpty ? null : Listenable.merge(positions);
  }

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLens()
    ..scrolls = _scrolls(context)
    ..pixelRatio = View.of(context).devicePixelRatio
    ..radius = radius
    ..dark = dark
    ..lit = lit
    ..floating = floating
    ..tint = tint
    ..blur = blur;

  @override
  void updateRenderObject(BuildContext context, _RenderLens r) {
    r
      ..scrolls = _scrolls(context)
      ..pixelRatio = View.of(context).devicePixelRatio
      ..radius = radius
      ..dark = dark
      ..lit = lit
      ..floating = floating
      ..tint = tint
      ..blur = blur;
  }
}

/// Pushes the lens as a backdrop filter: blur first, then the shader
/// bends, lifts and lights the blurred screen inside the clip.
///
/// The shader works in screen pixels, so it is told where the glass is on
/// screen. A surface can move without repainting (a sheet sliding up, a
/// page transition), so after every frame it checks where it is and
/// repaints if it moved.
class _RenderLens extends RenderProxyBox {
  _RenderLens() : _shader = GlassLens._program!.fragmentShader();

  final ui.FragmentShader _shader;
  final LayerHandle<BackdropFilterLayer> _layer =
      LayerHandle<BackdropFilterLayer>();
  Rect? _painted;
  bool _watching = false;

  Listenable? _scrolls;
  set scrolls(Listenable? v) {
    if (identical(v, _scrolls)) return;
    if (attached) _scrolls?.removeListener(markNeedsPaint);
    _scrolls = v;
    if (attached) _scrolls?.addListener(markNeedsPaint);
  }

  double _pixelRatio = 1;
  set pixelRatio(double v) => _set(_pixelRatio != v, () => _pixelRatio = v);
  double _radius = 0;
  set radius(double v) => _set(_radius != v, () => _radius = v);
  bool _dark = false;
  set dark(bool v) => _set(_dark != v, () => _dark = v);
  bool _lit = false;
  set lit(bool v) => _set(_lit != v, () => _lit = v);
  bool _floating = true;
  set floating(bool v) => _set(_floating != v, () => _floating = v);
  Color _tint = Colors.transparent;
  set tint(Color v) => _set(_tint != v, () => _tint = v);
  double _blur = 7;
  set blur(double v) => _set(_blur != v, () => _blur = v);

  void _set(bool changed, VoidCallback apply) {
    if (!changed) return;
    apply();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  /// Where [box] is, in physical pixels: global logical coordinates (the
  /// app's scaling included) times the screen's real pixel ratio.
  Rect _physical(RenderBox box) {
    final r = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    return Rect.fromLTWH(
      r.left * _pixelRatio,
      r.top * _pixelRatio,
      r.width * _pixelRatio,
      r.height * _pixelRatio,
    );
  }

  /// The backdrop the shader sees is the nearest offscreen pass: the screen,
  /// or an ancestor that draws into a layer of its own (a fade mask, a
  /// translucent fade, another backdrop). Its coordinates start at that
  /// layer's corner, so the glass is placed relative to it.
  Offset _passOrigin() {
    for (var node = parent; node != null; node = node.parent) {
      final passes =
          node is RenderShaderMask ||
          node is RenderBackdropFilter ||
          (node is RenderOpacity && node.opacity < 1) ||
          (node is RenderAnimatedOpacity && node.opacity.value < 1);
      if (passes && node is RenderBox && node.hasSize) {
        return _physical(node).topLeft;
      }
    }
    return Offset.zero;
  }

  Rect _onScreen() => _physical(this).shift(-_passOrigin());

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scrolls?.addListener(markNeedsPaint);
    _watching = true;
    _watch();
  }

  @override
  void detach() {
    _watching = false;
    _scrolls?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _layer.layer = null;
    _shader.dispose();
    super.dispose();
  }

  // Runs only when a frame is drawn anyway, so an idle screen costs nothing.
  void _watch() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_watching || !attached) return;
      if (hasSize && _painted != null && _onScreen() != _painted) {
        markNeedsPaint();
      } else if (_fadedLast != _inFade()) {
        markNeedsPaint();
      }
      _watch();
    });
  }

  bool _fadedLast = false;

  /// Inside a fade (a cross-fade between list layouts, a fading page) the
  /// backdrop is the fade's own empty layer, and glass over it flashes
  /// white. Fading glass is drawn as a plain fill until the fade ends.
  bool _inFade() {
    for (var node = parent; node != null; node = node.parent) {
      if (node is RenderAnimatedOpacity && node.opacity.value < 1) return true;
      if (node is RenderOpacity && node.opacity < 1) return true;
    }
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!hasSize || size.isEmpty) {
      super.paint(context, offset);
      return;
    }
    _fadedLast = _inFade();
    if (_fadedLast) {
      _layer.layer = null;
      _painted = null;
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(offset & size, Radius.circular(_radius)),
        Paint()
          ..color = _dark ? const Color(0x1AFFFFFF) : const Color(0xB3FFFFFF),
      );
      super.paint(context, offset);
      return;
    }
    final rect = _onScreen();
    _painted = rect;
    final px = rect.width / size.width;

    // A card is thinner glass than a floating control: a shallower edge
    // that bends less, so a screen of them stays calm.
    final bevel = math.min(_floating ? 12.0 : 9.0, _radius * 0.5) * px;
    final boost = _lit ? 1.35 : 1.0;
    final tintAlpha = (_tint.a + (_lit ? 0.08 : 0.0)).clamp(0.0, 1.0);

    _shader
      ..setFloat(2, rect.left)
      ..setFloat(3, rect.top)
      ..setFloat(4, rect.width)
      ..setFloat(5, rect.height)
      ..setFloat(6, _radius * px)
      ..setFloat(7, bevel)
      ..setFloat(8, _floating ? 0.24 : 0.16)
      ..setFloat(9, _tint.r)
      ..setFloat(10, _tint.g)
      ..setFloat(11, _tint.b)
      ..setFloat(12, tintAlpha)
      ..setFloat(13, _dark ? 0.10 : 0.0)
      ..setFloat(14, _dark ? 1.6 : 1.25)
      ..setFloat(15, (_dark ? 1.1 : 1.0) * boost)
      ..setFloat(16, px)
      ..setFloat(17, _dark ? 1.0 : 0.0);

    final filter = ImageFilter.compose(
      outer: ImageFilter.shader(_shader),
      inner: ImageFilter.blur(
        sigmaX: _blur,
        sigmaY: _blur,
        tileMode: TileMode.clamp,
      ),
    );
    final layer = _layer.layer ??= BackdropFilterLayer();
    layer.filter = filter;
    context.pushLayer(layer, super.paint, offset);
  }
}

/// The frost's rim: a lit hairline, brightest along the top.
class _FrostRim extends CustomPainter {
  const _FrostRim({
    required this.radius,
    required this.dark,
    this.lit = false,
    this.hasCustomFill = false,
  });

  final double radius;
  final bool dark;
  final bool lit;
  final bool hasCustomFill;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final r = math.min(radius, math.min(size.width, size.height) / 2);
    final rr = RRect.fromRectAndRadius(
      rect.deflate(0.4),
      Radius.circular(math.max(0, r - 0.4)),
    );

    final boost = lit ? 1.25 : 1.0;
    double a(double light, double darkA, double custom) =>
        ((dark ? darkA : light) * (hasCustomFill ? custom : 1.0) * boost).clamp(
          0.0,
          1.0,
        );

    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: a(0.60, 0.22, 0.7)),
        Colors.white.withValues(alpha: a(0.35, 0.12, 0.5)),
        Colors.white.withValues(alpha: a(0.22, 0.08, 0.4)),
      ],
      stops: const [0.0, 0.35, 1.0],
    ).createShader(rect);

    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_FrostRim old) =>
      old.radius != radius ||
      old.dark != dark ||
      old.lit != lit ||
      old.hasCustomFill != hasCustomFill;
}

/// The light a finger makes in iOS glass: a soft bright pool where it
/// presses, fading out toward the edges, growing as the glass swells.
class _TouchGlow extends StatelessWidget {
  const _TouchGlow({
    required this.glow,
    required this.dark,
    required this.child,
  });
  final PressGlow? glow;
  final bool dark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final g = glow;
    if (g == null || g.point == null || g.strength <= 0.001) return child;
    return CustomPaint(
      foregroundPainter: _GlowPainter(g.point!, g.strength, dark),
      child: child,
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.at, this.strength, this.dark);
  final Offset at;
  final double strength;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.max(size.shortestSide * 1.1, 60.0);
    final a = (dark ? 0.16 : 0.32) * strength;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: a),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: at, radius: r)),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.at != at || old.strength != strength || old.dark != dark;
}
