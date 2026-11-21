import 'package:flutter/material.dart';

import 'glass.dart';

/// Under 3-button navigation the back, home and recents buttons sit on their
/// own strip of the app's liquid glass: the same floating lens as the tab bar
/// ([GlassSurface], thick), square and full width. The page scrolls on under
/// it, bent and frosted, so the buttons stay readable over any content.
///
/// Under GESTURE navigation there is no strip. The handle is a thin pill the
/// system re-colours against what is behind it, and a 16-24 dp band of glass
/// under it read as a stray ledge cut off the page; content runs to the edge
/// there, as in native apps.
///
/// Told apart by the REAL inset in dp (the View's, not the tree's scaled
/// MediaQuery): 3-button bars are 48 dp (42 on some phones), gesture bars
/// 16-32 dp. Nothing in the app hides the buttons; they are always on screen.
class NavButtonBacking extends StatelessWidget {
  const NavButtonBacking({super.key});

  static const double threeButtonMinDp = 40;

  static bool threeButton(BuildContext context) {
    final view = View.of(context);
    return view.viewPadding.bottom / view.devicePixelRatio >= threeButtonMinDp;
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).viewPadding.bottom;
    if (h <= 0 || !threeButton(context)) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: h,
      child: const IgnorePointer(
        child: GlassSurface(
          radius: 0,
          thick: true,
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}
