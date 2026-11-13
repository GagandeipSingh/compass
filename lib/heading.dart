import 'package:flutter/services.dart';

/// One reading from the native rotation-vector sensor.
class HeadingReading {
  const HeadingReading(
    this.azimuth,
    this.pitch,
    this.roll,
    this.accuracy,
    this.field,
  );

  /// Degrees clockwise from magnetic north, 0..360.
  final double azimuth;

  /// Tilt in degrees. Top edge raised gives negative pitch; right edge raised
  /// gives negative roll (Android `getOrientation` convention).
  final double pitch;
  final double roll;

  /// `SensorManager.SENSOR_STATUS_*`: 3 high, 2 medium, 1 low, 0 unreliable.
  final int accuracy;

  /// Magnetic field strength in microtesla.
  final double field;

  bool get needsCalibration => accuracy < 2;
}

const _channel = EventChannel('compass/heading');

Stream<HeadingReading> headingStream() =>
    _channel.receiveBroadcastStream().map((e) {
      final v = e as List<Object?>;
      return HeadingReading(
        (v[0]! as num).toDouble(),
        (v[1]! as num).toDouble(),
        (v[2]! as num).toDouble(),
        (v[3]! as num).toInt(),
        (v[4]! as num).toDouble(),
      );
    });

/// The 8-point name for a heading: N, NE, E, ...
String cardinalOf(double deg) {
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return names[((deg % 360) / 45 + 0.5).floor() % 8];
}

/// Shortest signed difference `to - from`, in -180..180.
double angleDelta(double from, double to) {
  var d = (to - from) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

/// Words for a `SensorManager.SENSOR_STATUS_*` value.
String accuracyLabel(int a) => switch (a) {
  3 => 'High',
  2 => 'Medium',
  1 => 'Low',
  _ => 'Poor',
};

/// Tilt, field strength and sensor accuracy, as shown under the reading.
class Stats {
  const Stats(this.tilt, this.field, this.accuracy);

  final int tilt, field, accuracy;

  /// Earth's field is 25-65 uT; well outside that, something nearby (metal,
  /// a magnet, a laptop) is pulling the needle.
  bool get disturbed => field > 0 && (field > 80 || field < 15);

  @override
  bool operator ==(Object other) =>
      other is Stats &&
      other.tilt == tilt &&
      other.field == field &&
      other.accuracy == accuracy;

  @override
  int get hashCode => Object.hash(tilt, field, accuracy);
}
