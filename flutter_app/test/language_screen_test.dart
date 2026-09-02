// ============================================================
// test/language_screen_test.dart
//
// IMPORTANT — honesty note about this file specifically:
// Unlike the backend pytest suite (which was actually run and
// verified to pass against the real app.py), I do not have the
// Flutter SDK available in my environment, so this file could NOT
// be executed or verified here. It's written carefully against your
// real language_screen.dart source and correct Flutter testing API
// usage to the best of my knowledge, but you should run it yourself
// and treat the first run as a real check, not a formality —
// there's a real chance of a small syntax/import issue needing a
// fix, in a way the backend tests already ruled out for themselves.
//
// Run with: flutter test test/language_screen_test.dart
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:price_prediction_app/screens/farmer/language_screen.dart';

void main() {
  group('LanguageScreen', () {
    testWidgets('shows both Sinhala and English language cards',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      expect(find.text('සිංහල'), findsOneWidget);
      expect(find.text('Sinhala'), findsOneWidget);
      expect(find.text('English'), findsWidgets); // appears as both label and subtitle
    });

    testWidgets('Continue button is disabled until a language is selected',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull,
          reason: 'button should be disabled with no selection yet');
    });

    testWidgets('selecting Sinhala visually marks that card as selected',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      // Tap the Sinhala card via its Semantics label, matching the
      // real accessibility label set on it: '$label, $subtitle'
      await tester.tap(find.text('සිංහල'));
      await tester.pump(); // let setState rebuild complete

      // A check_circle icon appears only on the selected card
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('Continue button becomes enabled after selecting a language',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      await tester.tap(find.text('English').first);
      await tester.pump();

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('selecting English shows the English continue label, not Sinhala',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      await tester.tap(find.text('English').first);
      await tester.pump();

      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('ඉදිරියට'), findsNothing);
    });

    testWidgets('only one language card can be selected at a time',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LanguageScreen()));

      await tester.tap(find.text('සිංහල'));
      await tester.pump();
      await tester.tap(find.text('English').first);
      await tester.pump();

      // Only one check_circle should ever be visible — switching
      // selection must deselect the previous card, not accumulate.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });
}
