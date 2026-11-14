import 'package:compass/compass_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The compass laid out on a phone, an unfolded foldable, a tablet on its
/// side and a desktop window, in light and dark: nothing may overflow, and
/// the wide screens must put the dial beside its readings.
///
/// Sensors and location are stubbed: the heading channel sends one steady
/// reading, and location answers "not allowed", which is the state a first
/// launch is in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockStreamHandler(
      const EventChannel('compass/heading'),
      MockStreamHandler.inline(
        onListen: (args, sink) =>
            sink.success(<Object>[42.0, 0.0, 0.0, 3, 45.0]),
      ),
    );
    for (final name in [
      'flutter.baseflow.com/geolocator_service_updates',
      'flutter.baseflow.com/geolocator_service_updates_android',
    ]) {
      messenger.setMockStreamHandler(
        EventChannel(name),
        MockStreamHandler.inline(onListen: (args, sink) {}),
      );
    }
    for (final name in [
      'flutter.baseflow.com/geolocator',
      'flutter.baseflow.com/geolocator_android',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (call.method == 'checkPermission') return 0; // denied
        if (call.method == 'isLocationServiceEnabled') return true;
        return null;
      });
    }
  });

  const sizes = {
    'phone 360x780': Size(360, 780),
    'phone 418x900': Size(418, 900),
    'unfolded fold 600x900': Size(600, 900),
    'unfolded fold 850x880': Size(850, 880),
    'tablet landscape 1194x834': Size(1194, 834),
    'desktop 1280x800': Size(1280, 800),
  };

  testWidgets('phone 360x780 at 1.25x text: no overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const MaterialApp(home: CompassScreen()));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.tap(find.bySemanticsLabel('About the compass'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final dark in [false, true]) {
    for (final e in sizes.entries) {
      testWidgets('${e.key} ${dark ? 'dark' : 'light'}: no overflow', (
        tester,
      ) async {
        tester.view.physicalSize = e.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: const CompassScreen(),
          ),
        );
        // Let the springs settle and the first reading land.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(seconds: 1));

        expect(tester.takeException(), isNull);
        expect(find.text('Lock Heading'), findsOneWidget);
        expect(_reading, findsOneWidget);

        // The dial (the "Lock heading" control) sits left of the reading on
        // a wide landscape screen, above it otherwise.
        final dial = tester.getCenter(
          find.bySemanticsLabel('Lock heading').first,
        );
        final reading = tester.getCenter(_reading);
        final wide = e.value.width >= 600 && e.value.width > e.value.height;
        if (wide) {
          expect(dial.dx, lessThan(reading.dx));
        } else {
          expect(dial.dy, lessThan(reading.dy));
        }

        // The info sheet opens (a centred card on wide screens) and fits.
        await tester.tap(find.bySemanticsLabel('About the compass'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        expect(find.text('Lock a heading'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}

/// The big heading number, whatever it reads.
final _reading = find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^\d+°$').hasMatch(w.data ?? ''),
);
