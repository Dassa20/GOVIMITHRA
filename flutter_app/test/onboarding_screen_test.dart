// ============================================================
// test/onboarding_screen_test.dart
//
// FIX APPLIED after a real run against your actual code: the
// default Flutter test viewport is 800x600 logical pixels — shorter
// than a real phone screen. onboarding_screen.dart's slide content
// (image + title + body text, inside the PageView) needs more
// vertical room than that default gives it, causing a genuine
// RenderFlex overflow that fails every test immediately on pump.
//
// This is very likely NOT a bug in your actual app on a real device
// — real phones have noticeably taller viewports than the test
// default — but it does need fixing here so the tests can run at
// all. The fix: every test now sets a realistic phone-sized viewport
// (412x915, a common Android reference size) before pumping the
// widget, and resets it afterward via addTearDown.
//
// One test ("tapping Skip navigates away") had a second, separate
// failure in the original run — likely a cascading effect of the
// same overflow exception interrupting pumpAndSettle() rather than a
// distinct bug; it should resolve once the viewport fix above is
// applied, but treat this specific test's result as worth a second
// look if it still fails after the fix.
//
// Run with: flutter test test/onboarding_screen_test.dart
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:price_prediction_app/screens/farmer/onboarding_screen.dart';

void _setRealisticPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('OnboardingScreen', () {
    testWidgets('shows the first slide (Cinnamon) on initial launch',
        (WidgetTester tester) async {
      _setRealisticPhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));

      expect(find.text('කුරුඳු'), findsOneWidget);
      expect(find.text('ගම්මිරිස්'), findsNothing);
    });

    testWidgets('page indicator shows 2 dots for 2 slides',
        (WidgetTester tester) async {
      _setRealisticPhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));

      expect(find.bySemanticsLabel('පිටුව 1 න් 2'), findsOneWidget);
    });

    testWidgets('manual swipe advances to the second slide',
        (WidgetTester tester) async {
      _setRealisticPhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('ගම්මිරිස්'), findsOneWidget);
      expect(find.bySemanticsLabel('පිටුව 2 න් 2'), findsOneWidget);
    });

    testWidgets('button label changes from "ඊළඟ" to "පටන් ගන්න" on the last slide',
        (WidgetTester tester) async {
      _setRealisticPhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));

      expect(find.text('ඊළඟ'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('පටන් ගන්න'), findsOneWidget);
      expect(find.text('ඊළඟ'), findsNothing);
    });

    testWidgets('tapping Skip navigates away from OnboardingScreen',
        (WidgetTester tester) async {
      // CONFIRMED, applied fix: LanguageService.markOnboardingSeen()
      // calls SharedPreferences.getInstance() internally. Without
      // mocking it, that call either throws or never resolves inside
      // _finish()'s fire-and-forget onPressed callback — so
      // Navigator.pushReplacement() never runs, and the onboarding
      // title is still visible after the tap. This was confirmed by
      // an actual test run: 4/5 tests in this file passed cleanly
      // once the viewport fix was applied, and this was the one
      // remaining failure, with exactly this symptom.
      SharedPreferences.setMockInitialValues({});
      _setRealisticPhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));

      await tester.tap(find.text('මඟ හරින්න'));
      await tester.pumpAndSettle();

      expect(find.text('කුරුඳු'), findsNothing);
    });
  });
}
