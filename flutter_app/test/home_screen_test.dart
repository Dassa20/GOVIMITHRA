// ============================================================
// test/home_screen_test.dart  (v2 — weather coverage added)
//
// Same honesty/setup note as the other test files applies.
//
// CHANGE FROM THE PREVIOUS VERSION: weather_service.dart was shared,
// so weather chip behaviour is now covered. Two real findings from
// actually reading its source (not present in the previous version
// of this file, which was written without it):
//
// 1. WeatherService.fetchWeather() in DISTRICT mode (the default —
//    useDeviceLocation defaults to false via SharedPreferences) calls
//    Open-Meteo directly via a plain http.get() to
//    api.open-meteo.com/v1/forecast — the SAME http package mechanism
//    ApiService uses, so it's interceptable with the same
//    http.runWithClient() approach already used elsewhere in this
//    suite. That's what the tests below actually exercise.
//
// 2. Device-location (GPS) mode additionally calls the `geolocator`
//    and `geocoding` packages, which talk to the OS through PLATFORM
//    CHANNELS, not HTTP — a fundamentally different mocking mechanism
//    (TestWidgetsFlutterBinding channel mocks, not http.runWithClient).
//    That path is deliberately NOT covered here; the tests below all
//    exercise the default district-based path, which is what a fresh
//    install actually uses. If GPS-mode coverage matters to you, say
//    so specifically and I'll write it as a separate, clearly-scoped
//    addition rather than guessing at channel-mock setup blind.
//
// ALSO FIXED HERE: home_screen.dart's _loadWeather() calls
// AuthService.loadSelections() and WeatherService.getUseDeviceLocation(),
// both of which read SharedPreferences — without mocking that,
// EVERY test in this file (including the metadata-only ones from the
// previous version) risks a MissingPluginException, not just the new
// weather-specific tests. SharedPreferences.setMockInitialValues({})
// is now called at the top of every test to fix this.
//
// Run with: flutter test test/home_screen_test.dart
// ============================================================
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:price_prediction_app/screens/farmer/home_screen.dart';

final _metadataJson = jsonEncode({
  'crops': ['Cinnamon', 'Pepper'],
  'districts_by_crop': {
    'Cinnamon': ['Galle', 'Matara'],
    'Pepper': ['Kandy', 'Matale'],
  },
  'grades_by_crop': {
    'Cinnamon': ['Alba', 'C-5 Sp'],
    'Pepper': ['GR-1', 'GR-2'],
  },
  'grades_by_crop_district': {
    'Cinnamon': {'Galle': ['Alba'], 'Matara': ['C-5 Sp']},
    'Pepper': {'Kandy': ['GR-1'], 'Matale': ['GR-2']},
  },
  'harvest_months': {'Cinnamon': [5, 6, 7, 8], 'Pepper': [1, 2, 3]},
  'all_districts': ['Galle', 'Matara', 'Kandy', 'Matale'],
  'all_grades': ['Alba', 'C-5 Sp', 'GR-1', 'GR-2'],
});

// Matches the real shape WeatherService._fetchFromCoords() expects
// from Open-Meteo's response — 'current' and 'daily' blocks with the
// exact field names it reads.
String _openMeteoJson({int weatherCode = 0, bool isDay = true, double tempC = 28.5}) {
  return jsonEncode({
    'current': {
      'temperature_2m': tempC,
      'relative_humidity_2m': 78.0,
      'precipitation': 0.0,
      'weather_code': weatherCode,
      'is_day': isDay ? 1 : 0,
    },
    'daily': {
      'time': ['2026-08-10', '2026-08-11'],
      'temperature_2m_max': [30.0, 29.5],
      'temperature_2m_min': [24.0, 23.5],
      'precipitation_sum': [5.0, 12.0],
    },
  });
}

http.Response _mockRoute(http.Request request) {
  if (request.url.host.contains('open-meteo.com')) {
    return http.Response(_openMeteoJson(), 200);
  }
  if (request.url.path.contains('/metadata')) {
    return http.Response(_metadataJson, 200);
  }
  return http.Response('{}', 200);
}

void main() {
  group('HomeScreen', () {
    testWidgets('shows Cinnamon and Pepper crop chips once metadata loads',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((req) async => _mockRoute(req));

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Cinnamon'), findsOneWidget);
        expect(find.text('Pepper'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('selecting Pepper updates the district dropdown to Pepper districts',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((req) async => _mockRoute(req));

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Pepper'));
        await tester.pumpAndSettle();

        // FIX applied after an actual test run: confirmed via the
        // real home_screen.dart source that the district selector is
        // a DropdownButtonFormField, which only renders its current
        // hint/selected value as visible text — menu items like
        // "Kandy" don't exist in the widget tree at all until the
        // dropdown is actually tapped open. The district dropdown is
        // the first DropdownButtonFormField built in the widget tree
        // (before the grade one), so .first reliably targets it.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();

        expect(find.text('Kandy'), findsWidgets);
      }, () => mockClient);
    });

    testWidgets('metadata load failure does not crash the screen',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/metadata')) {
          return http.Response('Server Error', 500);
        }
        return _mockRoute(request);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      }, () => mockClient);
    });

    group('weather chip — district mode (the default)', () {
      testWidgets('shows the temperature once Open-Meteo responds successfully',
          (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        final mockClient = MockClient((req) async => _mockRoute(req));

        await http.runWithClient(() async {
          await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
          await tester.pumpAndSettle();

          expect(find.text('29°C'), findsOneWidget);
        }, () => mockClient);
      });

      testWidgets('shows "Tap to retry" when Open-Meteo fails (network error)',
          (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        final mockClient = MockClient((request) async {
          if (request.url.host.contains('open-meteo.com')) {
            return http.Response('Service Unavailable', 503);
          }
          return _mockRoute(request);
        });

        await http.runWithClient(() async {
          await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
          await tester.pumpAndSettle();

          expect(find.text('Tap to retry'), findsOneWidget);
          expect(find.byIcon(Icons.cloud_off), findsOneWidget);
        }, () => mockClient);
      });

      testWidgets('tapping "Tap to retry" triggers a fresh weather request',
          (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        var openMeteoCallCount = 0;
        final mockClient = MockClient((request) async {
          if (request.url.host.contains('open-meteo.com')) {
            openMeteoCallCount++;
            if (openMeteoCallCount == 1) {
              return http.Response('Service Unavailable', 503);
            }
            return http.Response(_openMeteoJson(), 200);
          }
          return _mockRoute(request);
        });

        await http.runWithClient(() async {
          await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
          await tester.pumpAndSettle();

          expect(find.text('Tap to retry'), findsOneWidget);

          await tester.tap(find.text('Tap to retry'));
          await tester.pumpAndSettle();

          expect(openMeteoCallCount, 2);
          expect(find.text('29°C'), findsOneWidget);
        }, () => mockClient);
      });

      testWidgets('clear-sky weather code shows the sun icon during the day',
          (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        final mockClient = MockClient((request) async {
          if (request.url.host.contains('open-meteo.com')) {
            return http.Response(_openMeteoJson(weatherCode: 0, isDay: true), 200);
          }
          return _mockRoute(request);
        });

        await http.runWithClient(() async {
          await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
          await tester.pumpAndSettle();

          expect(find.byIcon(Icons.wb_sunny), findsOneWidget);
        }, () => mockClient);
      });
    });
  });
}
