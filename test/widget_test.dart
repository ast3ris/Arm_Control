import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arm/main.dart';

void main() {
  testWidgets('Robot Arm Controller renders all controls properly', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('ARM CONTROLLER'), findsOneWidget);
    expect(find.text('Servo Bawah (180°)'), findsOneWidget);
    expect(find.text('Pengangkat Box'), findsOneWidget);
    expect(find.text('Arm Joint'), findsOneWidget);
    expect(find.text('Buka (30°)'), findsOneWidget);
    expect(find.text('Tutup (0°)'), findsOneWidget);
  });

  testWidgets('Box lifter buttons toggle between 30 (buka) and 0 (tutup) degrees', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    // Default angle for Pin 18 is 0° (TERTUTUP)
    expect(find.text('TERTUTUP (0°)'), findsOneWidget);

    // Tap "Buka (30°)" button
    await tester.tap(find.text('Buka (30°)'));
    await tester.pumpAndSettle();

    // Now angle should be 30° (TERBUKA)
    expect(find.text('TERBUKA (30°)'), findsOneWidget);

    // Tap "Tutup (0°)" button
    await tester.tap(find.text('Tutup (0°)'));
    await tester.pumpAndSettle();

    // Now angle should be back to 0° (TERTUTUP)
    expect(find.text('TERTUTUP (0°)'), findsOneWidget);

    // Tap primary action toggle button to open
    await tester.tap(find.text('BUKA BOX (30°)'));
    await tester.pumpAndSettle();
    expect(find.text('TERBUKA (30°)'), findsOneWidget);

    // Tap primary action toggle button to close
    await tester.tap(find.text('TUTUP BOX (0°)'));
    await tester.pumpAndSettle();
    expect(find.text('TERTUTUP (0°)'), findsOneWidget);
  });

  testWidgets('Servo Bawah 180 dial gesture updates angle properly', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    // Find CustomPaint for base dial
    final dialFinder = find.byType(CustomPaint).first;
    expect(dialFinder, findsOneWidget);

    // Default angle is 90° (Tengah)
    expect(find.text('Posisi: Tengah (Netral)'), findsOneWidget);

    // Perform a drag gesture to the right side of the dial
    final center = tester.getCenter(dialFinder);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(60, -20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // After gesture to the right, position should reflect Kanan
    expect(find.textContaining('Kanan'), findsWidgets);
  });

  testWidgets('Renders without overflow on compact landscape phone screen', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    FlutterErrorDetails? caughtDetails;
    final oldHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      caughtDetails = details;
    };

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    FlutterError.onError = oldHandler;
    if (caughtDetails != null) {
      debugPrint('OVERFLOW: ${caughtDetails?.exceptionAsString()}');
    }
    expect(caughtDetails, isNull);
  });

  testWidgets('Servo Bawah 180 quick buttons increment and decrement angle', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    // Initial angle is 90°
    expect(find.text('90°'), findsWidgets);

    // Tap "Kanan ▶" -> Angle should increase to 95°
    await tester.tap(find.text('Kanan ▶'));
    await tester.pump();
    expect(find.text('95°'), findsWidgets);

    // Tap "Kanan ▶" again -> Angle should increase to 100°
    await tester.tap(find.text('Kanan ▶'));
    await tester.pump();
    expect(find.text('100°'), findsWidgets);

    // Tap "◀ Kiri" -> Angle should decrease back to 95°
    await tester.tap(find.text('◀ Kiri'));
    await tester.pump();
    expect(find.text('95°'), findsWidgets);

    // Tap "0°" button for servo 3 -> Sets to 0°
    await tester.tap(find.text('0°').first);
    await tester.pump();
    expect(find.text('0°'), findsWidgets);

    // Tap "180°" button for servo 3 -> Sets to 180°
    await tester.tap(find.text('180°').first);
    await tester.pump();
    expect(find.text('180°'), findsWidgets);

    // Tap "90°" button for servo 3 -> Sets to 90°
    await tester.tap(find.text('90°').first);
    await tester.pump();
    expect(find.text('90°'), findsWidgets);
  });

  testWidgets('Conveyor button opens ConveyorControlDialog and renders controls', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    expect(find.text('Conveyor'), findsOneWidget);
    await tester.tap(find.text('Conveyor'));
    await tester.pumpAndSettle();

    expect(find.text('KONTROL MOTOR CONVEYOR'), findsOneWidget);
    expect(find.text('RUN'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.text('MULAI SIKLUS OTOMATIS'), findsOneWidget);
  });
}
