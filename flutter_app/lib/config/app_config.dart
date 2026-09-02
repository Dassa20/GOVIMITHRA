// ============================================================
// APP CONFIG — single place for all configuration
// Update apiBaseUrl when your PC's IP changes
// ============================================================

class AppConfig {
  // ── Flask backend URL ─────────────────────────────────────
  // Find your current IP from Flask startup log:
  // "Running on http://X.X.X.X:5000"
  // Your phone must be on the SAME network as your PC
  static const String apiBaseUrl = 'http://192.168.1.69:5000';

  // App info
  static const String appName = 'Crop Price Predictor';
  static const String appVersion = '1.0.0';

  // Admin access: long-press the profile icon on the Home screen
  // (moved here after the farmer login screen was removed).
  static const int adminLongPressDuration = 3;

  // Notification threshold (matches Flask backend)
  static const double priceChangeThresholdPct = 3.0;
}