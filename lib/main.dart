import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'compass_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A compass reads in portrait only; rotation would spin the dial with it.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    );
    return MaterialApp(
      title: 'Compass',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      builder: (context, child) => _ScaleToWidth(child: child!),
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

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final f = (mq.size.shortestSide / _designWidth).clamp(0.8, 1.3);
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
