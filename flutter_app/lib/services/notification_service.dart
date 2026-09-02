// ============================================================
// NOTIFICATION SERVICE
// Handles FCM push notifications for price updates
// Works WITHOUT login — farmers get price alerts automatically
// Uses Firebase Messaging only (no flutter_local_notifications needed)
// ============================================================
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

// Background message handler — must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // FCM handles display automatically in background — no extra code needed
  debugPrint('[FCM Background] ${message.notification?.title}');
}

class NotificationService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  // ── Initialize once at app start (before login) ───────────
  static Future<void> initialize() async {
    // Register background handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Request permission (iOS + Android 13+)
    final settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[FCM] Permission denied');
      return;
    }

    // Handle foreground messages (show as heads-up notification via FCM)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final n = message.notification;
      debugPrint('[FCM Foreground] ${n?.title}: ${n?.body}');
      // FCM on Android 8+ shows heads-up notifications automatically
      // when channel is configured in AndroidManifest.xml
    });

    // Handle tap when app was in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('[FCM Opened] ${message.data}');
    });

    // Check if app launched from a notification tap
    final initial = await _fcm.getInitialMessage();
    if (initial != null) {
      debugPrint('[FCM Initial] Opened from notification: ${initial.data}');
    }

    // Set foreground notification presentation options (iOS)
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    debugPrint('[FCM] Notification service initialized ✅');
  }

  // ── Register for alerts — works WITHOUT login ─────────────
  static Future<bool> registerForAlerts({
    required String crop,
    required String district,
    required String grade,
    String email = '',
  }) async {
    try {
      final token = await _fcm.getToken();
      if (token == null) return false;

      await ApiService.registerDevice(
        email:    email,
        fcmToken: token,
        district: district,
        crop:     crop,
        grade:    grade,
      );

      debugPrint('[FCM] Registered for $crop $grade $district ✅');
      return true;
    } catch (e) {
      debugPrint('[FCM] Registration error: $e');
      return false;
    }
  }

  static Future<String?> getToken() => _fcm.getToken();
  static Future<void> deleteToken() => _fcm.deleteToken();
}