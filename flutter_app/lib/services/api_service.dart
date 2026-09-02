// ============================================================
// API SERVICE — all Flask backend calls
// ============================================================
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/app_models.dart';

class ApiService {
  // Reverted back to the simple, original pattern: fixed at compile
  // time from AppConfig, nothing cached or overridable at runtime.
  // There used to be a Settings-screen feature letting this be
  // changed and saved without a rebuild, but a stale/wrong saved
  // value was silently used by every API call afterward (including
  // ones inside the admin panel) with no obvious way to tell — this
  // is simpler and safer: to point the app at a different server,
  // edit AppConfig.apiBaseUrl and rebuild, so there's only ever one
  // source of truth for where the app connects.
  static final String _base = AppConfig.apiBaseUrl;

  static Future<bool> isBackendAlive() async {
    try {
      final res = await http.get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }

  static Future<AppMetadata> getMetadata() async {
    final res = await http.get(Uri.parse('$_base/metadata'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return AppMetadata.fromJson(jsonDecode(res.body));
    throw Exception('Failed to load metadata: ${res.statusCode}');
  }

  // Model accuracy metrics (MAE/RMSE/R2 per model compared during
  // training) — public, no auth required, same endpoint the admin
  // panel already uses. Used for a small, honest accuracy note on the
  // farmer prediction screen. Callers should treat failure as "just
  // don't show the note" rather than a hard error — this is
  // supplementary info, not something that should ever block or
  // break the main prediction display.
  static Future<Map<String, dynamic>> getModelMetrics() async {
    final res = await http.get(Uri.parse('$_base/admin/model-metrics'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(res.body);
    throw Exception('Failed to load model metrics: ${res.statusCode}');
  }

  // Surfaces the REAL backend error message instead of a generic
  // "400" — the throw must live outside the try, otherwise it's
  // immediately caught by this same block's catch and discarded.
  static Future<PredictionResult> predict({
      required String district, required String crop, required String grade}) async {
    final res = await http.post(Uri.parse('$_base/predict'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'district': district, 'crop': crop, 'grade': grade}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return PredictionResult.fromJson(jsonDecode(res.body));

    String message = 'Prediction failed: ${res.statusCode}';
    try {
      final e = jsonDecode(res.body);
      if (e is Map && e['error'] != null) message = e['error'].toString();
    } catch (_) {
      // response body wasn't valid JSON — keep the generic message
    }
    throw Exception(message);
  }

  static Future<RecommendationResult> getRecommendation({
      required String district, required String crop, required String grade}) async {
    final res = await http.post(Uri.parse('$_base/recommendation'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'district': district, 'crop': crop, 'grade': grade}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return RecommendationResult.fromJson(jsonDecode(res.body));

    String message = 'Recommendation failed: ${res.statusCode}';
    try {
      final e = jsonDecode(res.body);
      if (e is Map && e['error'] != null) message = e['error'].toString();
    } catch (_) {
      // response body wasn't valid JSON — keep the generic message
    }
    throw Exception(message);
  }

  static Future<HarvestStatus> getHarvestStatus({
    required String crop, required String district}) async {
    final res = await http.post(Uri.parse('$_base/harvest-status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'crop': crop, 'district': district}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return HarvestStatus.fromJson(jsonDecode(res.body));
    throw Exception('Harvest status failed: ${res.statusCode}');
  }

  static Future<List<PriceHistoryEntry>> getHistory({
    required String district, required String crop,
    required String grade, int limit = 20}) async {
    final uri = Uri.parse(
        '$_base/history?district=$district&crop=$crop&grade=$grade&limit=$limit');
    final res = await http.get(uri)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return (data['data'] as List)
          .map((e) => PriceHistoryEntry.fromJson(e)).toList();
    }
    throw Exception('History failed: ${res.statusCode}');
  }

  static Future<void> registerDevice({
    String email = '',
    required String fcmToken,
    required String district,
    required String crop,
    required String grade}) async {
    await http.post(Uri.parse('$_base/register-device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'fcm_token': fcmToken,
            'district': district, 'crop': crop, 'grade': grade}))
        .timeout(const Duration(seconds: 15));
  }

  // ── Device ID (for fair-share chatbot rate limiting) ───────
  // A simple, persisted, per-installation identifier — NOT used for
  // anything security-sensitive, only so the backend can tell "this
  // is the same device" across chatbot messages and cap each device
  // to a fair daily share of the shared Gemini quota. Generated once
  // and cached in shared_preferences; no new package needed.
  static String? _cachedDeviceId;

  static Future<String> _getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('device_id');
    if (id == null) {
      final rand = Random();
      id = '${DateTime.now().millisecondsSinceEpoch}-${rand.nextInt(999999)}';
      await prefs.setString('device_id', id);
    }
    _cachedDeviceId = id;
    return id;
  }

  // ── AI Chatbot (farming help) ──────────────────────────────
  // The Gemini API key lives ONLY on the Flask backend — never in
  // this app — so it can't be extracted from the compiled APK.
  static Future<String> askChatbot({
      required String message, required String language}) async {
    final deviceId = await _getDeviceId();
    final res = await http.post(Uri.parse('$_base/chatbot'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': message,
          'language': language,
          'device_id': deviceId,
        }))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      return (data['reply'] ?? '').toString();
    }
    String message2 = 'Chatbot failed: ${res.statusCode}';
    try {
      final e = jsonDecode(res.body);
      if (e is Map && e['error'] != null) message2 = e['error'].toString();
    } catch (_) {
      // response body wasn't valid JSON — keep the generic message
    }
    throw Exception(message2);
  }

  // Super admin only: resets THIS device's today chatbot usage count,
  // so testing isn't blocked by the same daily limit real farmers are
  // subject to. Uses the same device_id askChatbot() already sends,
  // so this always resets the quota actually being hit while testing
  // from this device/app install.
  static Future<Map<String, dynamic>> resetMyChatbotQuota({
      required String requestorUsername}) async {
    final deviceId = await _getDeviceId();
    final res = await http.post(Uri.parse('$_base/admin/reset-chatbot-quota'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'requestor_username': requestorUsername,
          'device_id': deviceId,
        }))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  // Checks whether the chatbot is configured on the server (i.e.
  // GEMINI_API_KEY is set) — never exposes the actual key, just
  // whether it's present and which model is configured.
  static Future<Map<String, dynamic>> getChatbotStatus() async {
    final res = await http.get(Uri.parse('$_base/admin/chatbot-status'))
        .timeout(const Duration(seconds: 10));
    return jsonDecode(res.body);
  }

  // ── Admin: Auth ───────────────────────────────────────────
  static Future<Map<String, dynamic>> adminLogin({
    required String username, required String password}) async {
    try {
      final res = await http.post(Uri.parse('$_base/admin/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}))
        .timeout(const Duration(seconds: 15));
      return jsonDecode(res.body);
    } catch (_) { return {'success': false, 'message': 'Connection failed'}; }
  }

  static Future<Map<String, dynamic>> changePassword({
    required String username, required String oldPassword,
    required String newPassword}) async {
    final res = await http.post(Uri.parse('$_base/admin/change-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'old_password': oldPassword,
            'new_password': newPassword}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> forgotPasswordRequest({
    required String username}) async {
    final res = await http.post(Uri.parse('$_base/admin/forgot-password/request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> forgotPasswordReset({
    required String username, required String otp,
    required String newPassword}) async {
    final res = await http.post(Uri.parse('$_base/admin/forgot-password/reset'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'otp': otp,
            'new_password': newPassword}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  // ── Admin: Price management ───────────────────────────────
  static Future<Map<String, dynamic>> adminUploadPrice({
    required String date, required String district,
    required String crop, required String grade,
    required double avgPrice, double? highPrice,
    double? rainfallMm, double? tempC, double? humidityPct}) async {
    final body = <String, dynamic>{
      'date': date, 'district': district, 'crop': crop,
      'grade': grade, 'avg_price': avgPrice,
    };
    if (highPrice   != null) body['high_price']   = highPrice;
    if (rainfallMm  != null) body['rainfall_mm']  = rainfallMm;
    if (tempC       != null) body['temp_c']        = tempC;
    if (humidityPct != null) body['humidity_pct']  = humidityPct;
    final res = await http.post(Uri.parse('$_base/admin/upload-price'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> submitPriceRequest({
    required String submittedBy, required String date,
    required String district, required String crop, required String grade,
    required double avgPrice, double? highPrice, double? rainfallMm,
    double? tempC, double? humidityPct, String notes = ''}) async {
    final body = <String, dynamic>{
      'submitted_by': submittedBy, 'date': date,
      'district': district, 'crop': crop, 'grade': grade,
      'avg_price': avgPrice, 'notes': notes,
    };
    if (highPrice   != null) body['high_price']   = highPrice;
    if (rainfallMm  != null) body['rainfall_mm']  = rainfallMm;
    if (tempC       != null) body['temp_c']        = tempC;
    if (humidityPct != null) body['humidity_pct']  = humidityPct;
    final res = await http.post(Uri.parse('$_base/admin/submit-price-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> getPendingRequests({
    required String requestorUsername}) async {
    final res = await http.post(Uri.parse('$_base/admin/pending-requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'requestor_username': requestorUsername}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> getMyRequests({
    required String username}) async {
    final res = await http.post(Uri.parse('$_base/admin/my-requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> reviewRequest({
    required String requestorUsername, required int requestId,
    required String action, String reviewNote = ''}) async {
    final res = await http.post(Uri.parse('$_base/admin/review-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'requestor_username': requestorUsername,
            'request_id': requestId, 'action': action, 'review_note': reviewNote}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<List<PriceHistoryEntry>> adminGetHistory({
    required String district, required String crop,
    required String grade, int limit = 50}) async {
    return getHistory(district: district, crop: crop, grade: grade, limit: limit);
  }

  // ── Admin: Account management ─────────────────────────────
  static Future<Map<String, dynamic>> createAccount({
    required String requestorUsername, required String username,
    required String password, String role = 'dea_staff',
    String fullName = '', String? district, String? crop, String? email}) async {
    final res = await http.post(Uri.parse('$_base/admin/create-account'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'requestor_username': requestorUsername,
          'username': username, 'password': password,
          'role': role, 'full_name': fullName,
          'district': district, 'crop': crop, 'email': email,
        }))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> listAccounts({
    required String requestorUsername}) async {
    final res = await http.post(Uri.parse('$_base/admin/list-accounts'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'requestor_username': requestorUsername}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> deleteAccount({
    required String requestorUsername, required String targetUsername}) async {
    final res = await http.post(Uri.parse('$_base/admin/delete-account'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'requestor_username': requestorUsername,
            'target_username': targetUsername}))
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body);
  }

  // ── Auto-fetch ────────────────────────────────────────────
  static Future<Map<String, dynamic>> autoFetchWeather() async {
    final res = await http.post(Uri.parse('$_base/auto-fetch/weather'),
        headers: {'Content-Type': 'application/json'}).timeout(
        const Duration(seconds: 60));
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> autoFetchDea() async {
    final res = await http.post(Uri.parse('$_base/auto-fetch/dea-prices'),
        headers: {'Content-Type': 'application/json'}).timeout(
        const Duration(seconds: 60));
    return jsonDecode(res.body);
  }

  // ── Retrain ───────────────────────────────────────────────
  static Future<Map<String, dynamic>> adminRetrain() async {
    final res = await http.post(Uri.parse('$_base/admin/retrain'),
        headers: {'Content-Type': 'application/json'}).timeout(
        const Duration(minutes: 5));
    return jsonDecode(res.body);
  }

  // ── Edit price row (super admin — saves directly) ─────────
  static Future<Map<String, dynamic>> editPrice({
    required String requestorUsername,
    required String date,
    required String district,
    required String crop,
    required String grade,
    required double avgPrice,
    double? highPrice,
    double? rainfallMm,
    double? tempC,
    double? humidityPct,
  }) async {
    final body = <String, dynamic>{
      'requestor_username': requestorUsername,
      'date': date, 'district': district, 'crop': crop, 'grade': grade,
      'avg_price': avgPrice,
    };
    if (highPrice   != null) body['high_price']   = highPrice;
    if (rainfallMm  != null) body['rainfall_mm']  = rainfallMm;
    if (tempC       != null) body['temp_c']        = tempC;
    if (humidityPct != null) body['humidity_pct']  = humidityPct;
    final res = await http.post(Uri.parse('$_base/admin/edit-price'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body)).timeout(const Duration(seconds: 30));
    return jsonDecode(res.body);
  }

  // ── Request edit (DEA staff → pending for super admin approval) ──
  static Future<Map<String, dynamic>> requestEdit({
    required String submittedBy,
    required String date,
    required String district,
    required String crop,
    required String grade,
    required double avgPrice,
    double? highPrice,
    double? rainfallMm,
    double? tempC,
    double? humidityPct,
    required String notes,
  }) async {
    final body = <String, dynamic>{
      'submitted_by': submittedBy,
      'date': date, 'district': district, 'crop': crop, 'grade': grade,
      'avg_price': avgPrice,
      'notes': notes,
    };
    if (highPrice   != null) body['high_price']   = highPrice;
    if (rainfallMm  != null) body['rainfall_mm']  = rainfallMm;
    if (tempC       != null) body['temp_c']        = tempC;
    if (humidityPct != null) body['humidity_pct']  = humidityPct;
    final res = await http.post(Uri.parse('$_base/admin/request-edit'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body)).timeout(const Duration(seconds: 30));
    return jsonDecode(res.body);
  }

  // ── Next fetch info (DEA + NASA status) ───────────────────
  static Future<Map<String, dynamic>> getNextFetchInfo() async {
    final res = await http.get(
        Uri.parse('$_base/admin/next-fetch-info'),
        headers: {'Content-Type': 'application/json'}).timeout(
        const Duration(seconds: 15));
    return jsonDecode(res.body);
  }
}