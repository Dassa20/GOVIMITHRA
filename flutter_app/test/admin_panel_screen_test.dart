// ============================================================
// test/admin_panel_screen_test.dart
//
// Same honesty/setup note as the other new test files applies.
//
// IMPORTANT — this is deliberately the most LIMITED test file of the
// set. AdminPanelScreen is genuinely the most complex screen in the
// app (multiple tabs, multiple roles, many concurrent API calls on
// load — metadata, history, requests, accounts, chatbot status).
// Rather than write a large number of tests I have low confidence in
// without being able to run them, this file focuses on the specific,
// concrete things that were actually fixed and discussed during
// development — the regression-test approach — rather than
// attempting exhaustive coverage of every tab.
//
// Run with: flutter test test/admin_panel_screen_test.dart
// ============================================================
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:price_prediction_app/screens/admin/admin_panel_screen.dart';

// Minimal metadata response shared across tests — matches the real
// shape returned by app.py's /metadata route.
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
    'Cinnamon': {
      'Galle': ['Alba'],
      'Matara': ['C-5 Sp'],
    },
    'Pepper': {
      'Kandy': ['GR-1'],
      'Matale': ['GR-2'],
    },
  },
  'harvest_months': {'Cinnamon': [5, 6, 7, 8], 'Pepper': [1, 2, 3]},
  'all_districts': ['Galle', 'Matara', 'Kandy', 'Matale'],
  'all_grades': ['Alba', 'C-5 Sp', 'GR-1', 'GR-2'],
});

http.Response _mockRoute(http.Request request) {
  final path = request.url.path;
  if (path.contains('/metadata')) {
    return http.Response(_metadataJson, 200);
  }
  if (path.contains('/history')) {
    // FIX applied proactively: the real /history route in app.py
    // returns {'count': N, 'data': [...]}, not a raw array — the
    // same mismatch found and fixed in prediction_screen_test.dart
    // after an actual test run there. Applying the same fix here
    // before it causes the identical failure.
    return http.Response(jsonEncode({'count': 0, 'data': []}), 200);
  }
  if (path.contains('/admin/pending-requests') ||
      path.contains('/admin/all-requests') ||
      path.contains('/admin/my-requests')) {
    return http.Response(jsonEncode({'requests': []}), 200);
  }
  if (path.contains('/admin/list-accounts')) {
    return http.Response(jsonEncode({'accounts': []}), 200);
  }
  if (path.contains('/admin/chatbot-status')) {
    return http.Response(jsonEncode({'used_today': 0, 'limit': 25}), 200);
  }
  return http.Response('{}', 200);
}

void main() {
  group('AdminPanelScreen — regression tests for previously-fixed bugs', () {
    testWidgets(
        'Price Table tab shows the date/search/reset row; Submit Correction tab does not',
        (WidgetTester tester) async {
      // Direct regression test for the real bug: the date/search/reset
      // row used to be shared across every tab via a Column above the
      // TabBarView, so it incorrectly appeared on Submit Correction,
      // Requests, Accounts, System, and Settings too. It was fixed by
      // moving it into _buildDateSearchReset(), called only from
      // _buildPriceTable(). This test exists specifically to catch
      // that bug coming back.
      final mockClient = MockClient((req) async => _mockRoute(req));

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
          home: AdminPanelScreen(
            username: 'admin',
            role: 'super_admin',
            fullName: 'System Administrator',
          ),
        ));
        await tester.pumpAndSettle();

        // On the default (Price Table) tab, Search/Reset should be visible.
        expect(find.text('Search'), findsOneWidget);
        expect(find.text('Reset'), findsOneWidget);

        // Switch to Submit Correction tab.
        await tester.tap(find.text('Submit Correction'));
        await tester.pumpAndSettle();

        // The date/search/reset row must NOT appear here.
        expect(find.text('Search'), findsNothing);
        expect(find.text('Reset'), findsNothing);
      }, () => mockClient);
    });

    testWidgets('Submit Correction tab still shows the shared Crop/District/Grade selectors',
        (WidgetTester tester) async {
      // Companion test to the one above — confirms the FIX didn't
      // overcorrect by removing the selectors Submit Correction
      // actually needs (it has no crop/district/grade fields of its
      // own; it depends entirely on the shared row above the tabs).
      final mockClient = MockClient((req) async => _mockRoute(req));

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
          home: AdminPanelScreen(
            username: 'admin',
            role: 'super_admin',
            fullName: 'System Administrator',
          ),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Submit Correction'));
        await tester.pumpAndSettle();

        // These dropdown labels come from the shared _buildSelectors()
        // row, which should still be visible on this tab.
        expect(find.text('Crop'), findsOneWidget);
        expect(find.text('District'), findsOneWidget);
        expect(find.text('Grade'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('staff (non-super-admin) role does not see the Accounts tab',
        (WidgetTester tester) async {
      final mockClient = MockClient((req) async => _mockRoute(req));

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
          home: AdminPanelScreen(
            username: 'test_staff',
            role: 'dea_staff',
            fullName: 'Test Staff',
            district: 'Galle',
            crop: 'Cinnamon',
          ),
        ));
        await tester.pumpAndSettle();

        // NOTE: this assumes Accounts is conditionally shown only for
        // isSuperAdmin — if staff CAN see an Accounts tab in a
        // read-only way in your actual implementation, this
        // assertion needs flipping. Worth confirming directly against
        // the tab-building logic in admin_panel_screen.dart if this
        // fails.
        expect(find.text('Accounts'), findsNothing);
      }, () => mockClient);
    });
  });
}
