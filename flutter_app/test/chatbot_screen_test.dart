// ============================================================
// test/chatbot_screen_test.dart
//
// Same honesty/setup note as admin_login_screen_test.dart applies —
// not executed here, needs http.runWithClient() support.
//
// Run with: flutter test test/chatbot_screen_test.dart
// ============================================================
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:price_prediction_app/screens/farmer/chatbot_screen.dart';

void main() {
  group('ChatbotScreen', () {
    testWidgets('shows the greeting message on load',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: ChatbotScreen()));
      await tester.pump();

      expect(find.textContaining("Hi! I'm your farming assistant"), findsOneWidget);
    });

    testWidgets('sending a message shows it immediately, then shows the reply',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/chatbot')) {
          return http.Response(jsonEncode({
            'reply': 'Cinnamon harvest season is typically May to August.',
          }), 200);
        }
        return http.Response('Not Found', 404);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: ChatbotScreen()));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'When should I harvest cinnamon?');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump(); // user message appears immediately

        expect(find.text('When should I harvest cinnamon?'), findsOneWidget);

        await tester.pumpAndSettle(); // wait for the mocked reply
        expect(find.textContaining('May to August'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('daily limit error shows the farmer-friendly message, not raw JSON',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({
          'error': "You've reached today's chat limit. Please try again tomorrow.",
          'reason': 'device_daily_limit',
        }), 429);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: ChatbotScreen()));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'Another question');
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();

        // NOTE: this assumes ApiService.askChatbot() throws with the
        // backend's real error message in the exception text (matching
        // the "surfaces the REAL backend error message" pattern seen
        // elsewhere in api_service.dart) — if askChatbot() instead
        // throws a generic message on non-200 status, this specific
        // assertion needs adjusting to match. Worth checking directly
        // against your api_service.dart's askChatbot() implementation.
        expect(find.textContaining("reached today's chat limit"), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('send button is disabled while a request is in flight',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((request) async {
        await Future.delayed(const Duration(milliseconds: 100));
        return http.Response(jsonEncode({'reply': 'Answer'}), 200);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: ChatbotScreen()));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'Question');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump(); // request now in flight, not yet resolved

        final sendButton = tester.widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.send));
        expect(sendButton.onPressed, isNull,
            reason: 'button should disable while _sending is true');

        await tester.pumpAndSettle();
      }, () => mockClient);
    });
  });
}
