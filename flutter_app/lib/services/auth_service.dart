// ============================================================
// AUTH SERVICE
// Farmer-side login has been removed. The Flask backend's /predict,
// /metadata, /history, /harvest-status, /recommendation routes are
// all public — no auth requirement — so an account was never
// actually protecting anything; it was purely a UI gate. This
// service now only handles two things that already worked without a
// signed-in user: saved crop/district/grade selections, and device
// notification registration.
// ============================================================
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class AuthService {
  // ── Register device for notifications ─────────────────────
  // No account needed — NotificationService already supported this
  // as an anonymous (no-email) registration, keyed only by the
  // device's FCM token plus the chosen crop/district/grade.
  static Future<void> registerDeviceForNotifications({
    required String district,
    required String crop,
    required String grade,
  }) async {
    await NotificationService.registerForAlerts(
      crop:     crop,
      district: district,
      grade:    grade,
      email:    '', // no accounts anymore — always anonymous
    );
  }

  // ── Save/load selections ──────────────────────────────────
  static Future<void> saveSelections({
    required String district,
    required String crop,
    required String grade,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_district', district);
    await prefs.setString('selected_crop',     crop);
    await prefs.setString('selected_grade',    grade);
  }

  static Future<Map<String, String?>> loadSelections() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'district': prefs.getString('selected_district'),
      'crop':     prefs.getString('selected_crop'),
      'grade':    prefs.getString('selected_grade'),
    };
  }
}