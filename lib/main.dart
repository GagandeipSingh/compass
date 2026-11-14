import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'compass_screen.dart';
import 'glass.dart' show GlassLens;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A phone compass reads in portrait only; rotation would spin the dial
  // with it. A tablet, an unfolded foldable or a desktop window (shortest
  // side >= 600 dp) is held any way up, and lays the dial beside its
  // readings in landscape.
  final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
  final large =
      view != null &&
      view.physicalSize.shortestSide > 0 &&
      view.physicalSize.shortestSide / view.devicePixelRatio >= 600;
  if (!large) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // The liquid glass lens; without it (no Impeller) glass is frost only.
  await GlassLens.load();
  runApp(const CompassApp());
}

class CompassApp extends StatelessWidget {
  const CompassApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Follows the system appearance; the native splash does the same
    // (plain white in light mode, plain black in dark).
    ThemeData theme(Brightness b) => ThemeData(
      brightness: b,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: b == Brightness.dark
          ? Colors.black
          : Colors.white,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      // Screens slide in from the right and can be swiped back, as on iOS,
      // on every platform.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    return MaterialApp(
      title: 'Compass',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      scrollBehavior: const _StillScroll(),
      builder: (context, child) {
        // The phone's font size is honoured up to 1.25x: the app already
        // scales to the screen, and the buttons have fixed heights that
        // larger text would overflow. Never smaller than 1x.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: 1.0,
              maxScaleFactor: 1.25,
            ),
          ),
          child: _ScaleToWidth(child: child!),
        );
      },
      home: const CompassScreen(),
    );
  }
}

/// Lays the app out for a [_designWidth]-dp screen and scales the result to
/// the real one, so every phone shows the same proportions. Sizes are dp and
/// sp, which keep a control the same PHYSICAL size everywhere: on a 360 dp
/// phone that left the dial, the text and the buttons crowding the screen.
/// One scale for the whole tree (sheets included, as they live under the
/// navigator this wraps), clamped so a small phone does not shrink text past
/// reading and a tablet does not balloon it.
class _ScaleToWidth extends StatelessWidget {
  const _ScaleToWidth({required this.child});
  final Widget child;

  // The Motorola Edge 60 this was tuned on (1220 px at ~2.92 px/dp).
  static const _designWidth = 418.0;
  static const _designHeight = 860.0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // The SHORTER side, never the width: in landscape the width is the long
    // side, and scaling by it zoomed the whole UI up to the clamp.
    //
    // The LONGER side bounds it too. The design is a tall phone (418 x ~860),
    // and an unfolded foldable is nearly square: zooming it by its short side
    // alone (1.3x) left so little height that the controls were huge and the
    // dial small. On a phone the long side never binds.
    final f = math
        .min(
          mq.size.shortestSide / _designWidth,
          mq.size.longestSide / _designHeight,
        )
        // The cap grows with the screen: up to ~1280 wide (tablets, a
        // desktop window) it stays 1.15x (1.3x looked oversized in a tablet window); a 1920-wide desktop gets ~1.6x
        // instead of a small UI in the middle of empty space.
        .clamp(0.8, (mq.size.longestSide / 1200).clamp(1.15, 2.0));
    if ((f - 1).abs() < 0.01) return child;
    final size = mq.size / f;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MediaQuery(
            data: mq.copyWith(
              size: size,
              devicePixelRatio: mq.devicePixelRatio * f,
              padding: mq.padding / f,
              viewPadding: mq.viewPadding / f,
              viewInsets: mq.viewInsets / f,
              systemGestureInsets: mq.systemGestureInsets / f,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Sheets give a very slight bounce at their ends instead of Android's
/// stretch. The stretch redraws through an image filter, which switches off
/// the glass blur while it lasts, so the glass flashed clear when
/// overscrolled. iOS's own bounce felt too elastic, so this one barely
/// moves: a hint that the end was reached, not rubber.
class _StillScroll extends MaterialScrollBehavior {
  const _StillScroll();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _SubtleBounce(parent: RangeMaintainingScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _SubtleBounce extends BouncingScrollPhysics {
  const _SubtleBounce({super.parent});

  @override
  _SubtleBounce applyTo(ScrollPhysics? ancestor) =>
      _SubtleBounce(parent: buildParent(ancestor));

  // iOS uses 0.52; 0.035 lets the content move only a few points past its end.
  @override
  double frictionFactor(double overscrollFraction) =>
      0.035 * (1 - overscrollFraction) * (1 - overscrollFraction);

  // Stiff and fully damped: back in place at once, no wobble.
  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 0.5, stiffness: 700, ratio: 1.0);
}
