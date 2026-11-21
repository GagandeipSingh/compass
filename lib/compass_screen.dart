import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'ambient.dart';
import 'compass_painter.dart';
import 'glass.dart';
import 'heading.dart';
import 'motion.dart';
import 'nav_backing.dart';
import 'place.dart';
import 'sheets.dart';

class CompassScreen extends StatefulWidget {
  const CompassScreen({super.key});

  @override
  State<CompassScreen> createState() => _CompassScreenState();
}

class _CompassScreenState extends State<CompassScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _dial = ValueNotifier(const DialState());
  final _place = PlaceController();
  late final Ticker _ticker;
  StreamSubscription<HeadingReading>? _sub;

  HeadingReading? _target;
  double _heading = 0, _pitch = 0, _roll = 0;
  Duration _last = Duration.zero;
  bool _first = true;
  int? _lastSector;
  bool _wasLevel = false;

  // Text that changes with the heading is rebuilt only when it says something
  // new, never per frame.
  final _readout = ValueNotifier<(int, String)>((0, 'N'));
  final _stats = ValueNotifier<Stats>(const Stats(0, 0, 3));
  final _lockNote = ValueNotifier<String?>(null);
  String? _error;
  double? _locked;

  /// Degrees added for true north; null while magnetic.
  double? get _declination => _place.value.place?.declination;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    _listen();
    _place.addListener(_onPlace);
    _place.refresh();
  }

  double _appliedDecl = 0;

  void _onPlace() {
    final decl = _declination ?? 0;
    if (decl != _appliedDecl) {
      // The reading jumps by the declination when true north turns on or
      // off; a locked bearing must move with it or the lock jumps away from
      // the direction the user locked.
      if (_locked != null) _locked = (_locked! + decl - _appliedDecl) % 360;
      _appliedDecl = decl;
    }
    if (mounted) setState(() {});
  }

  void _listen() {
    _sub?.cancel();
    _sub = headingStream().listen(
      (r) {
        _target = r;
        if (!_ticker.isActive) _ticker.start();
      },
      onError: (Object e) {
        setState(
          () => _error = e is PlatformException
              ? (e.message ?? 'Compass unavailable.')
              : 'Compass unavailable.',
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sensors and location off in the background: nothing to draw.
    if (state == AppLifecycleState.resumed) {
      _listen();
      _place.refresh();
    } else if (state == AppLifecycleState.paused) {
      _sub?.cancel();
      _sub = null;
      _ticker.stop();
      _last = Duration.zero;
      _place.pause();
    }
  }

  void _tick(Duration now) {
    final t = _target;
    if (t == null) return;
    final dt = _last == Duration.zero
        ? 1 / 60
        : (now - _last).inMicroseconds / 1e6;
    _last = now;

    final aim = (t.azimuth + (_declination ?? 0)) % 360;
    if (_first || MediaQuery.disableAnimationsOf(context)) {
      _heading = aim;
      _pitch = t.pitch;
      _roll = t.roll;
      _first = false;
    } else {
      // Exponential ease toward the sensor: fluid, never laggy.
      final k = 1 - math.exp(-dt * 14);
      _heading = (_heading + angleDelta(_heading, aim) * k) % 360;
      _pitch += (t.pitch - _pitch) * k;
      _roll += (t.roll - _roll) * k;
    }

    final shown = _heading.round() % 360;
    _dial.value = DialState(
      heading: _heading,
      pitch: _pitch,
      roll: _roll,
      locked: _locked,
    );

    // A light tick each time the heading crosses a 30 degree mark.
    final sector = (((_heading + 15) % 360) / 30).floor();
    if (_lastSector != null && sector != _lastSector) {
      HapticFeedback.selectionClick();
    }
    _lastSector = sector;

    final level = _dial.value.level;
    if (level && !_wasLevel) HapticFeedback.lightImpact();
    _wasLevel = level;

    final text = (shown, cardinalOf(shown.toDouble()));
    if (_readout.value != text) _readout.value = text;

    final tilt = math.sqrt(_pitch * _pitch + _roll * _roll).round();
    final stats = Stats(tilt, t.field.round(), t.accuracy);
    if (_stats.value != stats) _stats.value = stats;

    String? note;
    if (_locked != null) {
      final d = angleDelta(_locked!, _heading).round();
      note = d == 0
          ? 'On your locked heading'
          : '${d.abs()}° ${d > 0 ? 'right' : 'left'} of locked heading';
    }
    if (_lockNote.value != note) _lockNote.value = note;
  }

  void _toggleLock() {
    HapticFeedback.mediumImpact();
    setState(() => _locked = _locked == null ? _heading : null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _ticker.dispose();
    _dial.dispose();
    _readout.dispose();
    _stats.dispose();
    _lockNote.dispose();
    _place.removeListener(_onPlace);
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = CompassPalette.of(context);
    final style = p == CompassPalette.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return AnnotatedRegion(
      value: style.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        // The presets draw white nav buttons (they assume a black bar);
        // ours is transparent, so follow the status icons.
        systemNavigationBarIconBrightness: style.statusBarIconBrightness,
      ),
      child: Scaffold(
        backgroundColor: p.background,
        body: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: AmbientSky(
                    _dial,
                    p,
                    still: MediaQuery.disableAnimationsOf(context),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.grey, fontSize: 17),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, c) =>
                          _sideBySide(c) ? _wide(p, c) : _tall(context, p, c),
                    ),
            ),
            // The nav buttons always sit on a frosted strip, as in the
            // other Blessing apps.
            const NavButtonBacking(),
          ],
        ),
      ),
    );
  }

  /// A landscape tablet, an unfolded foldable on its side or a desktop
  /// window: a stacked layout there would shrink the dial to a third of the
  /// height, so the dial and its readings sit side by side.
  static bool _sideBySide(BoxConstraints c) =>
      c.maxWidth >= 600 && c.maxWidth > c.maxHeight * 1.15;

  Widget _dialView(CompassPalette p, double dimension) => Semantics(
    button: true,
    label: _locked == null ? 'Lock heading' : 'Clear locked heading',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleLock,
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: dimension,
            child: CustomPaint(painter: CompassPainter(_dial, p)),
          ),
        ),
      ),
    ),
  );

  /// Everything under the dial: the reading, its one-line caption and the
  /// location.
  List<Widget> _readings(CompassPalette p) => [
    _Readout(_readout, p.foreground),
    SizedBox(height: 38, child: Center(child: _caption(p))),
    const SizedBox(height: 12),
    ConstrainedBox(
      // Tall enough for the address and its coordinates; a long address
      // takes a second line rather than being cut short.
      constraints: const BoxConstraints(minHeight: 52),
      child: _PlaceLine(
        state: _place.value,
        palette: p,
        onAsk: _askLocation,
        onRetry: _place.retry,
        onTurnOn: _place.turnOnService,
        onPrecise: _place.askPrecise,
      ),
    ),
  ];

  /// The floating controls rise into place on a spring when the screen
  /// opens.
  Widget _toolbar(CompassPalette p) => SpringIn(
    key: const ValueKey('toolbar'),
    from: const Offset(0, 90),
    child: _Toolbar(
      locked: _locked != null,
      palette: p,
      onLock: _toggleLock,
      onInfo: () => showInfoSheet(
        context,
        p,
        trueNorth: _declination != null,
        onCalibrate: _openCalibrate,
      ),
    ),
  );

  Widget _header(CompassPalette p) => SpringIn(
    key: const ValueKey('header'),
    from: const Offset(0, -24),
    child: _Header(p, trueNorth: _declination != null),
  );

  /// A phone, or a portrait tablet / unfolded foldable: one centred column.
  Widget _tall(BuildContext context, CompassPalette p, BoxConstraints c) {
    final bottom = math.max(MediaQuery.paddingOf(context).bottom + 12, 24.0);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          children: [
            const SizedBox(height: 14),
            _header(p),
            // The dial takes all the height the header, readings and
            // controls leave, so a tall or square screen gets a big dial
            // instead of big buttons. On a phone the width is what binds.
            Expanded(
              child: LayoutBuilder(
                builder: (context, room) => Center(
                  child: _dialView(
                    p,
                    math.max(
                      0.0,
                      math.min(
                        math.min(c.maxWidth - 40, 580.0),
                        room.maxHeight - 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ..._readings(p),
            const SizedBox(height: 18),
            _toolbar(p),
            SizedBox(height: bottom),
          ],
        ),
      ),
    );
  }

  /// Wide: the dial on the left, as large as the height allows; the
  /// reading, location and controls beside it.
  Widget _wide(CompassPalette p, BoxConstraints c) {
    const pad = 32.0;
    // Two equal halves on one centre line. The dial takes a fair share of
    // its half (it was 84% of the height and dwarfed everything beside it),
    // and the readings and controls are drawn at the same proportion to the
    // dial as on the phone the app was designed on, so neither side looks
    // oversized next to the other.
    final dial = math.min(c.maxHeight * 0.70, (c.maxWidth - 3 * pad) * 0.42);
    // On the phone the dial is ~380 wide beside these controls at 1x.
    final k = (dial / 380).clamp(1.0, 1.45);
    const panel = 340.0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: pad, vertical: 12),
          child: Row(
            children: [
              Expanded(child: Center(child: _dialView(p, dial))),
              const SizedBox(width: pad),
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: panel * k,
                    // Scaled as one piece, so text, glass buttons and gaps
                    // keep the phone's proportions; shrinks if the window
                    // is too short for it.
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: panel,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _header(p),
                            const SizedBox(height: 18),
                            ..._readings(p),
                            const SizedBox(height: 28),
                            _toolbar(p),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One line under the reading, and only when it has something to say: a
  /// sensor that needs calibrating, then magnetic interference (both open
  /// Calibrate), then the locked-heading offset.
  Widget _caption(CompassPalette p) {
    final style = TextStyle(fontSize: 15, letterSpacing: -0.2, color: p.grey);
    return ValueListenableBuilder(
      valueListenable: _stats,
      builder: (context, s, _) {
        final warning = s.accuracy < 2
            ? 'Compass needs calibrating'
            : s.disturbed
            ? 'Magnetic interference nearby'
            : null;
        final Widget child = warning != null
            ? GlassButton(
                key: ValueKey(warning),
                height: 34,
                semanticLabel: warning,
                onPressed: _openCalibrate,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(warning, style: style.copyWith(color: p.orange)),
                    const SizedBox(width: 4),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 13,
                      color: p.orange,
                    ),
                  ],
                ),
              )
            : ValueListenableBuilder(
                key: const ValueKey('lock'),
                valueListenable: _lockNote,
                builder: (_, note, _) =>
                    Text(note ?? '', style: style.copyWith(color: p.accent)),
              );
        return springSwitcher(context, child);
      },
    );
  }

  void _openCalibrate() {
    showCalibrateSheet(context, CompassPalette.of(context), _stats);
  }

  void _askLocation() {
    showLocationSheet(
      context,
      CompassPalette.of(context),
      blocked: _place.value.status == PlaceStatus.blocked,
      onAllow: _requestLocation,
    );
  }

  /// Straight to the OS prompt. The explanation sheet calls this, and so does
  /// "Try Again" after a refusal: the user has read why already, so a second
  /// explanation before the prompt is one screen too many.
  Future<void> _requestLocation() async {
    final p = CompassPalette.of(context);
    final wasBlocked = _place.value.status == PlaceStatus.blocked;
    final r = await _place.enable();
    if (!mounted) return;
    // As the Clock app does: a refusal is answered with a sheet saying
    // what happened and what still works, never silence.
    switch (r) {
      case EnableResult.denied:
        showLocationDeniedSheet(context, p, onRetry: _requestLocation);
      case EnableResult.blocked when !wasBlocked:
        // Refused for good just now (Android stops asking after the second
        // refusal, or a refusal from an earlier session): Settings only.
        showLocationSheet(context, p, blocked: true, onAllow: _place.enable);
      case EnableResult.dismissed:
      case EnableResult.gpsOff:
      case EnableResult.busy:
      case EnableResult.blocked:
      case EnableResult.granted:
        break;
    }
  }
}

/// "MAGNETIC NORTH" or "TRUE NORTH", with the dial's north mark.
class _Header extends StatelessWidget {
  const _Header(this.p, {required this.trueNorth});

  final CompassPalette p;
  final bool trueNorth;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CustomPaint(size: const Size(9, 8), painter: NorthMark(p.accent)),
        const SizedBox(width: 7),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: Text(
            trueNorth ? 'TRUE NORTH' : 'MAGNETIC NORTH',
            key: ValueKey(trueNorth),
            style: TextStyle(
              color: p.grey,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// Location, in one place and one state at a time: an offer to show it, then
/// "Locating", then the address with coordinates and elevation.
class _PlaceLine extends StatelessWidget {
  const _PlaceLine({
    required this.state,
    required this.palette,
    required this.onAsk,
    required this.onRetry,
    required this.onTurnOn,
    required this.onPrecise,
  });

  final PlaceState state;
  final CompassPalette palette;
  final VoidCallback onAsk;
  final VoidCallback onRetry;
  final VoidCallback onTurnOn;
  final VoidCallback onPrecise;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final Widget child = switch (state.status) {
      PlaceStatus.off || PlaceStatus.blocked => _Chip(
        key: const ValueKey('chip'),
        palette: p,
        label: 'Show location',
        onTap: onAsk,
      ),
      PlaceStatus.gpsOff => _Chip(
        key: const ValueKey('gps'),
        palette: p,
        label: 'Turn on location',
        onTap: onTurnOn,
      ),
      PlaceStatus.unavailable => _Chip(
        key: const ValueKey('retry'),
        palette: p,
        label: 'Location unavailable · Try again',
        onTap: onRetry,
      ),
      PlaceStatus.locating => Row(
        key: const ValueKey('loc'),
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoActivityIndicator(radius: 8, color: p.grey),
          const SizedBox(width: 8),
          Text('Locating…', style: TextStyle(color: p.grey, fontSize: 15)),
        ],
      ),
      PlaceStatus.ready => _Address(
        key: const ValueKey('ready'),
        place: state.place!,
        palette: p,
        onPrecise: onPrecise,
      ),
    };
    return Center(child: springSwitcher(context, child));
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.palette,
    required this.label,
    required this.onTap,
  });

  final CompassPalette palette;
  final String label;
  final VoidCallback onTap;

  /// A control, so it is glass like the toolbar; smaller, so the toolbar
  /// stays the primary one.
  @override
  Widget build(BuildContext context) {
    final p = palette;
    return GlassButton(
      height: 40,
      semanticLabel: label,
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.location_fill, size: 13, color: p.blue),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: p.foreground,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Address extends StatelessWidget {
  const _Address({
    super.key,
    required this.place,
    required this.palette,
    required this.onPrecise,
  });

  final Place place;
  final CompassPalette palette;
  final VoidCallback onPrecise;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final fine = !place.approximate;
    final coords =
        '${fine ? '' : '≈'}${dms(place.lat, lat: true, seconds: fine)}   '
        '${dms(place.lon, lat: false, seconds: fine)}';
    final alt = place.altitude;
    final elevation = alt == null ? null : '${alt.round()} m elevation';
    final small = TextStyle(
      color: p.grey,
      fontSize: 13,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.location_fill, size: 13, color: p.blue),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                place.address ?? coords,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  [if (place.address != null) coords, ?elevation].join('  ·  '),
                  maxLines: 1,
                  style: small,
                ),
              ),
            ),
            // An approximate grant is a choice the user can undo; say so,
            // and make the word the way to undo it.
            if (place.approximate)
              Semantics(
                button: true,
                label: 'Approximate location. Use precise location',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onPrecise,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '  ·  Approximate',
                        style: small.copyWith(color: p.blue),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The floating glass layer: Lock, and the info button.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.locked,
    required this.palette,
    required this.onLock,
    required this.onInfo,
  });

  final bool locked;
  final CompassPalette palette;
  final VoidCallback onLock;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final fg = palette.foreground;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Flexible, and the label shrinks rather than overflowing: a narrow
        // window with the largest text still fits both buttons.
        Flexible(
          child: GlassButton(
            semanticLabel: locked ? 'Unlock heading' : 'Lock heading',
            onPressed: onLock,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Row(
                key: ValueKey(locked),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    locked
                        ? CupertinoIcons.lock_fill
                        : CupertinoIcons.lock_open,
                    size: 19,
                    color: locked ? palette.accent : fg,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        locked ? 'Unlock' : 'Lock Heading',
                        style: TextStyle(
                          color: fg,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        GlassButton(
          circle: true,
          semanticLabel: 'About the compass',
          onPressed: onInfo,
          child: Icon(CupertinoIcons.info, size: 22, color: fg),
        ),
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout(this.value, this.color);

  final ValueNotifier<(int, String)> value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: value,
      builder: (context, v, _) => Semantics(
        label: '${v.$1} degrees ${v.$2}',
        child: ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${v.$1}°',
                style: TextStyle(
                  fontFamily: 'InterDisplay',
                  color: color,
                  fontSize: 60,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -1.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                v.$2,
                style: TextStyle(
                  fontFamily: 'InterDisplay',
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Swaps one piece of UI for another by MOVING it (the new one springs up
/// from small, the old one shrinks away), never by fading: glass inside a
/// fade has nothing behind it to bend and flashes white.
Widget springSwitcher(BuildContext context, Widget child) {
  final still = MediaQuery.disableAnimationsOf(context);
  return AnimatedSwitcher(
    duration: Duration(milliseconds: still ? 0 : kSpringMs),
    reverseDuration: Duration(milliseconds: still ? 0 : 200),
    switchInCurve: kSpring,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, anim) =>
        ScaleTransition(scale: anim, child: child),
    child: child,
  );
}
