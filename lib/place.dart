import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:location/location.dart' as loc;

/// Where location stands. The compass works fully without it; location only
/// adds the address, coordinates, elevation and true north.
enum PlaceStatus {
  /// Not granted yet. Shows the "Show location" chip; nothing is asked.
  off,

  /// Refused for good: the OS will not ask again, so the chip opens Settings.
  blocked,

  /// Allowed, but the phone's location services are switched off.
  gpsOff,

  /// Granted, waiting for the first fix.
  locating,

  /// Granted, but no fix arrived in time (indoors, no signal). Offers a
  /// retry rather than spinning forever; updates keep running meanwhile.
  unavailable,

  /// Have a fix.
  ready,
}

class Place {
  const Place({
    required this.lat,
    required this.lon,
    this.altitude,
    this.address,
    this.declination,
    this.approximate = false,
  });

  final double lat, lon;

  /// Android 12+ "Approximate" grant: the fix is only good to ~3 km, so the
  /// screen must not show it with second-level precision.
  final bool approximate;

  /// Metres above sea level; null when the fix carries none (a network or
  /// Wi-Fi fix reports 0 with no accuracy, which is not a real elevation).
  final double? altitude;

  /// "Sector 17, Chandigarh"; null offline or before the lookup lands.
  final String? address;

  /// Degrees to add to a magnetic heading for true north.
  final double? declination;

  Place copyWith({String? address, double? declination}) => Place(
    lat: lat,
    lon: lon,
    altitude: altitude,
    address: address ?? this.address,
    declination: declination ?? this.declination,
    approximate: approximate,
  );
}

class PlaceState {
  const PlaceState(this.status, [this.place]);

  final PlaceStatus status;
  final Place? place;
}

const _native = MethodChannel('compass/native');

/// What came of the user's "Allow" tap, so the screen can say so.
enum EnableResult {
  granted,
  denied,
  blocked,
  gpsOff,
  busy,

  /// The OS prompt was closed with Back: not an answer, so nothing is said
  /// and the next tap asks again.
  dismissed,
}

/// Location, the way the Clock app does it, minus its Mapbox fallback:
/// permission and position through `geolocator`, the in-app "turn on
/// location" dialog through `location.requestService()`, the address through
/// the phone's own geocoder only.
///
/// Edge cases, each handled below:
/// * a second tap while a permission or service dialog is up (single-flight);
/// * the in-app turn-on dialog unavailable (no Play Services) -> Settings;
/// * location services switched off/on from quick settings mid-use;
/// * the grant revoked in Settings while away (re-checked on every resume)
///   or mid-stream (the stream errors; the grant is re-checked);
/// * no fix indoors -> "unavailable" with a retry, updates still running;
/// * a stale last-known position (another city, days old) -> ignored;
/// * fixes arriving out of order -> only a newer one replaces the shown one;
/// * the address lookup failing offline -> retried every 30 s and on resume
///   until it lands, without waiting for the user to move;
/// * a network-only fix -> no fake "0 m elevation".
class PlaceController extends ValueNotifier<PlaceState> {
  PlaceController() : super(const PlaceState(PlaceStatus.off));

  StreamSubscription<Position>? _sub;
  StreamSubscription<ServiceStatus>? _service;
  Timer? _giveUp;
  Timer? _addressRetry;
  double? _geoLat, _geoLon;
  DateTime? _lastFix;
  bool _busy = false;
  bool _reduced = false;
  bool _preciseAsked = false;

  static const _staleLastKnown = Duration(minutes: 30);

  static bool _granted(LocationPermission p) =>
      p == LocationPermission.whileInUse || p == LocationPermission.always;

  void _watchService() {
    _service ??= Geolocator.getServiceStatusStream().listen((st) {
      if (st == ServiceStatus.disabled) {
        _stop();
        if (value.status != PlaceStatus.off &&
            value.status != PlaceStatus.blocked) {
          value = const PlaceState(PlaceStatus.gpsOff);
        }
      } else if (value.status == PlaceStatus.gpsOff) {
        refresh();
      }
    }, onError: (_) {});
  }

  /// Called at launch and on every resume: the grant can change in Settings
  /// while the app is away, so a cached answer is never trusted.
  Future<void> refresh() async {
    _watchService();
    LocationPermission p;
    try {
      p = await Geolocator.checkPermission();
    } catch (_) {
      return;
    }
    if (!_granted(p)) {
      _stop();
      value = PlaceState(
        p == LocationPermission.deniedForever
            ? PlaceStatus.blocked
            : PlaceStatus.off,
      );
      return;
    }
    if (!await _serviceOn()) {
      _stop();
      value = const PlaceState(PlaceStatus.gpsOff);
      return;
    }
    // Back from being away with an address still owed: try again now.
    if (value.status == PlaceStatus.ready && value.place?.address == null) {
      _geoLat = null;
    }
    _start();
  }

  /// A blocked permission returns at once with no prompt; a person cannot
  /// answer one this fast.
  static const _promptShownAfterMs = 400;

  /// Null when unknown (the channel failed): geolocator's answer is used.
  static Future<bool?> _rationale() async {
    try {
      return await _native.invokeMethod<bool>('locationRationale');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _serviceOn() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return true; // Unknown: try, and let the stream report the truth.
    }
  }

  /// The user tapped "Allow" in the explanation sheet.
  Future<EnableResult> enable() async {
    if (_busy) return EnableResult.busy;
    _busy = true;
    try {
      if (value.status == PlaceStatus.blocked) {
        await Geolocator.openAppSettings();
        return EnableResult.blocked;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        // geolocator calls any refusal with no rationale "denied forever",
        // which is also what closing the prompt with Back looks like. The
        // rationale before and after, and whether a prompt was on screen at
        // all, tell the cases apart.
        final before = await _rationale();
        final asked = Stopwatch()..start();
        p = await Geolocator.requestPermission();
        final shown = asked.elapsedMilliseconds > _promptShownAfterMs;
        final after = await _rationale();
        if (before != null && after != null) {
          // Back on the first prompt: no rationale before or after.
          if (p == LocationPermission.deniedForever &&
              shown &&
              !before &&
              !after) {
            value = const PlaceState(PlaceStatus.off);
            return EnableResult.dismissed;
          }
          // Back on a later prompt: one refusal before, still one after.
          if (p == LocationPermission.denied && before && after) {
            value = const PlaceState(PlaceStatus.off);
            return EnableResult.dismissed;
          }
        }
      }
      if (p == LocationPermission.deniedForever) {
        value = const PlaceState(PlaceStatus.blocked);
        return EnableResult.blocked;
      }
      if (!_granted(p)) {
        value = const PlaceState(PlaceStatus.off);
        return EnableResult.denied;
      }
    } catch (_) {
      // A request already in flight, or the plugin unavailable.
      return EnableResult.busy;
    } finally {
      _busy = false;
    }
    if (!await turnOnService()) return EnableResult.gpsOff;
    return EnableResult.granted;
  }

  /// Location services off: Android's own in-app dialog turns them on
  /// without leaving the app. Where that dialog cannot run (no Play
  /// Services), the location settings page opens instead; the service
  /// stream picks up the change when the user comes back.
  Future<bool> turnOnService() async {
    if (_busy) return false;
    _busy = true;
    try {
      _watchService();
      var on = await _serviceOn();
      if (!on) {
        try {
          on = await loc.Location().requestService();
        } catch (_) {
          await Geolocator.openLocationSettings();
          on = false;
        }
      }
      if (!on) {
        value = const PlaceState(PlaceStatus.gpsOff);
        return false;
      }
      _start();
      return true;
    } finally {
      _busy = false;
    }
  }

  /// The user tapped "Approximate": ask Android to upgrade to precise (it
  /// shows its own "Change to precise location" dialog). Once refused, the
  /// OS stops asking, so later taps open the app's settings page instead.
  Future<void> askPrecise() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_preciseAsked) {
        await Geolocator.openAppSettings();
        return;
      }
      _preciseAsked = true;
      await Geolocator.requestPermission();
    } catch (_) {
    } finally {
      _busy = false;
    }
    // Back with precise: restart so the next fix is the exact one.
    if (await _readReduced() == false && _reduced) {
      _reduced = false;
      _preciseAsked = false;
      _lastFix = null;
      _geoLat = null;
      retry();
    }
  }

  static Future<bool> _readReduced() async {
    try {
      return await Geolocator.getLocationAccuracy() ==
          LocationAccuracyStatus.reduced;
    } catch (_) {
      return false;
    }
  }

  /// "Try again" after [PlaceStatus.unavailable].
  void retry() {
    _stop();
    _start();
  }

  Future<void> _start() async {
    if (_sub != null) return;
    // Precise can be switched on or off in Settings while away; this runs
    // again on every resume.
    _readReduced().then((r) {
      if (r == _reduced) return;
      _reduced = r;
      if (!r) _preciseAsked = false;
      // Precise turned on while away: drop the coarse fix and its address.
      if (!r) {
        _lastFix = null;
        _geoLat = null;
      }
      final at = value.place;
      if (at != null) {
        value = PlaceState(
          value.status,
          Place(
            lat: at.lat,
            lon: at.lon,
            altitude: at.altitude,
            address: r ? at.address : null,
            declination: at.declination,
            approximate: r,
          ),
        );
      }
    });
    if (value.status != PlaceStatus.ready) {
      // Starting from no place (GPS was off, grant was revoked): the old
      // lookup spot no longer has an address on screen, so the next fix must
      // look it up again even if the phone has not moved.
      _geoLat = null;
      value = const PlaceState(PlaceStatus.locating);
    }
    _giveUp?.cancel();
    _giveUp = Timer(const Duration(seconds: 25), () {
      if (value.status == PlaceStatus.locating) {
        value = const PlaceState(PlaceStatus.unavailable);
      }
    });

    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 25,
        intervalDuration: const Duration(seconds: 10),
      ),
    ).listen(_onFix, onError: (_) => _streamFailed());

    // The last known position answers at once, long before a fresh fix
    // indoors, but only if it is recent: one from days ago in another city
    // would name the wrong place.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          DateTime.now().difference(last.timestamp) < _staleLastKnown) {
        _onFix(last);
      }
    } catch (_) {}
    try {
      final now = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 20),
        ),
      );
      _onFix(now);
    } catch (_) {
      // The stream and the give-up timer cover it.
    }
  }

  /// The stream died: usually the grant was revoked mid-use. Re-check, so
  /// the screen drops to the right chip instead of a frozen place.
  Future<void> _streamFailed() async {
    _stop();
    final p = await Geolocator.checkPermission().catchError(
      (_) => LocationPermission.denied,
    );
    if (!_granted(p)) {
      value = PlaceState(
        p == LocationPermission.deniedForever
            ? PlaceStatus.blocked
            : PlaceStatus.off,
      );
    } else if (!await _serviceOn()) {
      // Location switched off from quick settings: the stream errors too,
      // and must not overwrite "Turn on location" with "unavailable".
      value = const PlaceState(PlaceStatus.gpsOff);
    } else if (value.status != PlaceStatus.ready) {
      value = const PlaceState(PlaceStatus.unavailable);
    }
  }

  /// Battery: nothing runs while the app is in the background.
  void pause() {
    _stop();
    _service?.cancel();
    _service = null;
  }

  void _stop() {
    _giveUp?.cancel();
    _addressRetry?.cancel();
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _onFix(Position d) async {
    // Fixes can arrive out of order (last-known, one-shot, stream). A fix
    // stamped in the future (a bad GPS clock) is read as now, or it would
    // make every later fix look older and freeze the place.
    final now = DateTime.now();
    final at = d.timestamp.isAfter(now) ? now : d.timestamp;
    if (_lastFix != null && at.isBefore(_lastFix!)) return;
    _lastFix = at;
    _giveUp?.cancel();

    final lat = d.latitude, lon = d.longitude;
    final alt = (d.altitude == 0 && d.altitudeAccuracy == 0)
        ? null
        : d.altitude;
    final prev = value.place;
    value = PlaceState(
      PlaceStatus.ready,
      Place(
        lat: lat,
        lon: lon,
        altitude: alt ?? prev?.altitude,
        address: prev?.address,
        declination: prev?.declination,
        approximate: _reduced,
      ),
    );

    // Declination and address barely change over a few streets; look them
    // up again only after a real move.
    final moved =
        _geoLat == null || _metres(_geoLat!, _geoLon!, lat, lon) > 150;
    if (!moved) return;
    _geoLat = lat;
    _geoLon = lon;

    try {
      final decl = await _native.invokeMethod<double>('declination', {
        'lat': lat,
        'lon': lon,
        'alt': alt ?? 0,
      });
      // A lookup for an older spot landing after a newer one must not win.
      if (value.place != null && _isCurrent(lat, lon)) {
        value = PlaceState(
          PlaceStatus.ready,
          value.place!.copyWith(declination: decl),
        );
      }
    } on PlatformException {
      // Stays magnetic.
    }
    if (_isCurrent(lat, lon)) await _lookUpAddress(lat, lon);
  }

  Future<void> _lookUpAddress(double lat, double lon) async {
    _addressRetry?.cancel();
    try {
      final marks = await geo.Geocoding()
          .placemarkFromCoordinates(lat, lon)
          .timeout(const Duration(seconds: 8));
      final line = marks.isEmpty ? '' : shortAddress(marks.first);
      if (!_isCurrent(lat, lon)) return; // Moved on; a newer lookup owns it.
      if (line.isNotEmpty && value.place != null) {
        value = PlaceState(
          PlaceStatus.ready,
          value.place!.copyWith(address: line),
        );
        return;
      }
    } catch (_) {
      // Offline or no geocoder: fall through to the retry.
    }
    // The coordinates still show; keep trying for the name while the user
    // stands still, since the next fix may be a long walk away.
    _addressRetry = Timer(const Duration(seconds: 30), () {
      final at = value.place;
      if (_sub != null && at != null && at.address == null) {
        _geoLat = at.lat;
        _geoLon = at.lon;
        _lookUpAddress(at.lat, at.lon);
      }
    });
  }

  bool _isCurrent(double lat, double lon) => _geoLat == lat && _geoLon == lon;

  @override
  void dispose() {
    pause();
    super.dispose();
  }
}

double _metres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final a =
      math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

final _plusCode = RegExp(
  r'^[23456789CFGHJMPQRVWX]{2,8}\+[23456789CFGHJMPQRVWX]{2,3}$',
  caseSensitive: false,
);

/// The two most specific parts of an address: "Sector 17, Chandigarh".
///
/// Android often puts the whole address line into `street` and a Plus Code
/// into `name`, so the fields are split on commas, Plus Codes dropped, and a
/// piece already contained in a longer one skipped (the Clock app's rule).
String shortAddress(geo.Placemark p) {
  final pieces = <String>[];
  for (final part in [
    p.subLocality,
    p.locality,
    p.subAdministrativeArea,
    p.administrativeArea,
    p.country,
  ]) {
    if (part == null) continue;
    for (final raw in part.split(',')) {
      final piece = raw.trim();
      if (piece.isEmpty || _plusCode.hasMatch(piece)) continue;
      final lower = piece.toLowerCase();
      if (pieces.any((o) => o.toLowerCase().contains(lower))) continue;
      pieces.add(piece);
    }
  }
  return pieces.take(2).join(', ');
}

/// 30°54′12″ N; with [seconds] false, 30°54′ N (for an approximate fix,
/// where seconds would claim a precision the fix does not have).
String dms(double v, {required bool lat, bool seconds = true}) {
  final hemi = lat ? (v >= 0 ? 'N' : 'S') : (v >= 0 ? 'E' : 'W');
  final a = v.abs();
  final d = a.floor();
  final mFull = (a - d) * 60;
  if (!seconds) return '$d°${mFull.round().clamp(0, 59)}′ $hemi';
  final m = mFull.floor();
  final s = ((mFull - m) * 60).round().clamp(0, 59);
  return '$d°$m′$s″ $hemi';
}
