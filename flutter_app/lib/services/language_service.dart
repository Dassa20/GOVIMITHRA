// ============================================================
// LANGUAGE SERVICE
// Stores the user's chosen app language (Sinhala / English) and
// whether the onboarding carousel has been seen.
// Uses shared_preferences, consistent with AuthService.
// ============================================================
import 'package:shared_preferences/shared_preferences.dart';

class LanguageService {
  static const _kLang       = 'app_language';       // 'si' or 'en'
  static const _kOnboarded  = 'onboarding_seen';    // bool

  // ── Language ──────────────────────────────────────────────
  /// Returns the saved language code, or null if not chosen yet.
  static Future<String?> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLang);
  }

  static Future<void> setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLang, code); // 'si' | 'en'
  }

  static Future<bool> hasLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_kLang) ?? '').isNotEmpty;
  }

  // ── Onboarding seen flag ──────────────────────────────────
  static Future<bool> hasSeenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOnboarded) ?? false;
  }

  static Future<void> markOnboardingSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboarded, true);
  }
}
