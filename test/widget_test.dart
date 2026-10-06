import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arm/main.dart';

void main() {
  testWidgets('Robotic Arm Cockpit renders all controls properly', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('ARM COCKPIT'), findsOneWidget);
    expect(find.text('PIN 21 - JOYSTICK'), findsOneWidget);
    expect(find.text('PIN 18 - ANGKAT BOX'), findsOneWidget);
    expect(find.text('PIN 19'), findsOneWidget);
    expect(find.text('BUKA 30°'), findsOneWidget);
    expect(find.text('TUTUP 0°'), findsOneWidget);
  });

  testWidgets('Box lifter buttons toggle between 0 and 30 degrees', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    // Default angle for Pin 18 is 0° (TUTUP)
    expect(find.text('TUTUP (0°)'), findsOneWidget);

    // Tap "BUKA 30°" button
    await tester.tap(find.text('BUKA 30°'));
    await tester.pumpAndSettle();

    // Now angle should be 30° (BUKA)
    expect(find.text('BUKA (30°)'), findsOneWidget);

    // Tap "TUTUP 0°" button
    await tester.tap(find.text('TUTUP 0°'));
    await tester.pumpAndSettle();

    // Now angle should be back to 0° (TUTUP)
    expect(find.text('TUTUP (0°)'), findsOneWidget);

    // Tap primary action button to toggle open
    await tester.tap(find.text('ANGKAT BOX (BUKA 30°)'));
    await tester.pumpAndSettle();
    expect(find.text('BUKA (30°)'), findsOneWidget);

    // Tap primary action button to toggle close
    await tester.tap(find.text('TURUNKAN BOX (TUTUP 0°)'));
    await tester.pumpAndSettle();
    expect(find.text('TUTUP (0°)'), findsOneWidget);
  });

  testWidgets('Virtual joystick remembers last dragged angle and does not reset to 0,0', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ServoCockpitApp());
    await tester.pumpAndSettle();

    // Find the CustomPaint for circular joystick
    final joystickFinder = find.byType(CustomPaint).first;
    expect(joystickFinder, findsOneWidget);

    // Perform a pan gesture dragging to the right
    final center = tester.getCenter(joystickFinder);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(40, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // After gesture is released, status should reflect locked/idle with stored angle
    expect(find.textContaining('DIAM'), findsOneWidget);
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
      debugPrint('OVERFLOW CONTEXT: ${caughtDetails?.context?.toDescription()}');
      debugPrint('INFO: ${caughtDetails?.informationCollector?.call().map((e) => e.toString()).join('\n')}');
    }
    expect(caughtDetails, isNull);
  });
}
