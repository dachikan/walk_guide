// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';

import 'package:walk_guide/main.dart';

void main() {
  testWidgets('WalkingGuideApp creates', (WidgetTester tester) async {
    // Mock camera for testing
    const mockCamera = CameraDescription(
        name: 'Test Camera', 
        lensDirection: CameraLensDirection.back, 
        sensorOrientation: 90
    );

    // Build our app and trigger a frame.
    await tester.pumpWidget(MaterialApp(
      home: WalkingGuideApp(camera: mockCamera),
    ));

    // Verify that we can create the widget without crashing
    expect(find.byType(WalkingGuideApp), findsOneWidget);
  });
}
