// ============================================================
// MAIN.DART — App entry point
// Farmer-side login removed: /predict, /metadata, /history etc. on
// the backend are all public endpoints with no auth requirement, so
// an account was never actually protecting anything — it was just a
// UI gate. The app now goes straight from onboarding/language into
// HomeScreen, every launch, with no account required. Notifications
// still work fully — NotificationService/registerForAlerts already
// supported an anonymous (no-email) device registration.
// ============================================================
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/farmer/home_screen.dart';
import 'screens/farmer/onboarding_screen.dart';
import 'screens/farmer/language_screen.dart';
import 'services/language_service.dart';
import 'services/notification_service.dart';
import 'config/app_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // still needed for push notifications
  await NotificationService.initialize();
  runApp(const CropPriceApp());
}

class CropPriceApp extends StatelessWidget {
  const CropPriceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2E7D32),
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      home: const _IntroGate(),
    );
  }
}

// Decides what the farmer sees on launch — no login/account involved:
//   • First ever launch (onboarding not seen)  → OnboardingScreen
//   • Onboarding seen but no language chosen    → LanguageScreen
//   • Both done                                 → HomeScreen, straight in,
//                                                  every launch, forever.
class _IntroGate extends StatelessWidget {
  const _IntroGate();

  Future<Map<String, dynamic>> _load() async {
    final seenOnboarding = await LanguageService.hasSeenOnboarding();
    final lang           = await LanguageService.getLanguage();
    return {'seen': seenOnboarding, 'lang': lang};
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _load(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final seen = snap.data!['seen'] as bool;
        final lang = snap.data!['lang'] as String?;

        if (!seen) return const OnboardingScreen();
        if (lang == null || lang.isEmpty) return const LanguageScreen();
        return const HomeScreen();
      },
    );
  }
}