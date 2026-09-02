// ============================================================
// test/admin_login_screen_test.dart
//
// Same honesty note as language_screen_test.dart and
// onboarding_screen_test.dart: written against your real
// admin_login_screen.dart and api_service.dart source, but NOT
// executed/verified here (no Flutter SDK in my environment).
//
// ApiService makes bare http.get()/http.post() calls (not through an
// injectable client), so mocking requires http.runWithClient() from
// package:http/testing.dart to intercept them at the zone level —
// this needs http package version 0.13.5 or later. If your pubspec
// pins an older version, these tests will need a different mocking
// approach; check `flutter pub deps` for your actual http version
// first if this file doesn't compile.
//
// Run with: flutter test test/admin_login_screen_test.dart
// ============================================================
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:price_prediction_app/screens/admin/admin_login_screen.dart';

void main() {
  group('AdminLoginScreen', () {
    testWidgets('successful login navigates away from the login form',
        (WidgetTester tester) async {
      // FIX applied after an actual test run: on successful login,
      // the real app navigates to AdminPanelScreen, whose own
      // initState() immediately fires off several MORE API calls
      // (metadata, my-requests/pending-requests depending on role,
      // etc.) — the original mock only handled /admin/login and
      // returned a plain 'Not Found' string for everything else,
      // which crashed ApiService.getMyRequests() trying to
      // jsonDecode() a non-JSON string. This mock now returns valid,
      // generic JSON for the other endpoints AdminPanelScreen is
      // likely to call right after navigating in.
      final mockClient = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/admin/login')) {
          return http.Response(jsonEncode({
            'success': true,
            'username': 'test_staff',
            'role': 'dea_staff',
            'full_name': 'Test Staff',
            'district': 'Galle',
            'crop': 'Cinnamon',
          }), 200);
        }
        if (path.contains('/metadata')) {
          return http.Response(jsonEncode({
            'crops': ['Cinnamon', 'Pepper'],
            'districts_by_crop': {'Cinnamon': ['Galle'], 'Pepper': ['Kandy']},
            'grades_by_crop': {'Cinnamon': ['Alba'], 'Pepper': ['GR-1']},
            'grades_by_crop_district': {'Cinnamon': {'Galle': ['Alba']}, 'Pepper': {'Kandy': ['GR-1']}},
            'harvest_months': {'Cinnamon': [5, 6, 7, 8], 'Pepper': [1, 2, 3]},
            'all_districts': ['Galle', 'Kandy'],
            'all_grades': ['Alba', 'GR-1'],
          }), 200);
        }
        if (path.contains('/history')) {
          return http.Response(jsonEncode({'count': 0, 'data': []}), 200);
        }
        if (path.contains('/admin/my-requests') ||
            path.contains('/admin/pending-requests') ||
            path.contains('/admin/all-requests')) {
          return http.Response(jsonEncode({'requests': []}), 200);
        }
        if (path.contains('/admin/list-accounts')) {
          return http.Response(jsonEncode({'accounts': []}), 200);
        }
        if (path.contains('/admin/chatbot-status')) {
          return http.Response(jsonEncode({'used_today': 0, 'limit': 25}), 200);
        }
        // Any other unanticipated call still gets valid (empty) JSON
        // rather than a plain string, so an unexpected endpoint fails
        // as a missing key/data, not an unrelated JSON parse crash.
        return http.Response('{}', 200);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

        await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'test_staff');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'TestPass123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
        await tester.pumpAndSettle();

        // On success the screen navigates to AdminPanelScreen — the
        // login form's own "DEA Staff / Admin Login" heading should
        // no longer be present.
        expect(find.text('DEA Staff / Admin Login'), findsNothing);
      }, () => mockClient);
    });

    testWidgets('failed login shows the error message and stays on the form',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/admin/login')) {
          return http.Response(jsonEncode({
            'success': false,
            'message': 'Invalid credentials',
          }), 401);
        }
        return http.Response('Not Found', 404);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

        await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'test_staff');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'WrongPassword');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
        await tester.pumpAndSettle();

        expect(find.text('Invalid credentials'), findsOneWidget);
        // Should NOT have navigated away
        expect(find.text('DEA Staff / Admin Login'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('password visibility toggle shows/hides the password and announces correctly',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

      // FIX applied after an actual compile error: TextFormField does
      // NOT expose obscureText as a public getter on the widget
      // itself (it's used internally to build a TextField, but isn't
      // stored as a readable field on TextFormField) — confirmed by
      // the Dart compiler directly, not a runtime guess. The
      // underlying TextField it builds DOES expose it, so we locate
      // that descendant specifically instead.
      final passwordFormField = find.widgetWithText(TextFormField, 'Password');
      final passwordTextField = find.descendant(
          of: passwordFormField, matching: find.byType(TextField));

      final field = tester.widget<TextField>(passwordTextField);
      expect(field.obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();

      final fieldAfter = tester.widget<TextField>(passwordTextField);
      expect(fieldAfter.obscureText, isFalse);
      expect(find.byTooltip('Hide password'), findsOneWidget);
    });

    testWidgets('empty username shows validation error, does not call the API',
        (WidgetTester tester) async {
      var apiWasCalled = false;
      final mockClient = MockClient((request) async {
        apiWasCalled = true;
        return http.Response('{}', 200);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'TestPass123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
        await tester.pump();

        expect(find.text('Enter username'), findsOneWidget);
        expect(apiWasCalled, isFalse,
            reason: 'form validation should block the API call entirely');
      }, () => mockClient);
    });

    testWidgets('tapping Forgot Password switches to the reset flow',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

      await tester.tap(find.text('Forgot password?'));
      await tester.pump();

      expect(find.text('Reset Password'), findsOneWidget);
      expect(find.text('Generate OTP'), findsOneWidget);
    });

    testWidgets('back button in forgot-password flow returns to the login form',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));

      await tester.tap(find.text('Forgot password?'));
      await tester.pump();
      expect(find.text('Reset Password'), findsOneWidget);

      await tester.tap(find.byTooltip('Back to login'));
      await tester.pump();

      expect(find.text('DEA Staff / Admin Login'), findsOneWidget);
    });
  });
}
