// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:finalreco/main.dart';

void main() {
  testWidgets('SmartRecyclingApp starts without crashing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const SmartRecyclingApp());

    // Verify that our app loads properly
    expect(find.byType(MaterialApp), findsOneWidget);

    // 카메라가 없는 경우 에러 스크린이 표시되는지 확인
    expect(find.byType(CameraErrorScreen), findsOneWidget);
    expect(find.text('카메라 접근 오류'), findsOneWidget);
  });
}