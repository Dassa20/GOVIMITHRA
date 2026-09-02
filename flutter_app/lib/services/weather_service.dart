// ============================================================
// WEATHER SERVICE
// Fetches REAL current + recent weather from Open-Meteo
// (open-meteo.com) — free, no API key, no rate limits at this
// scale. Two modes:
//   • District mode (default) — uses the same 4 project district
//     coordinates as the Flask backend's NASA_COORDS. Always works,
//     no permission needed.
//   • Location mode (opt-in) — uses the phone's real GPS position,
//     reverse-geocoded to a real place name (e.g. "Pathinwatta")
//     via the device's own OS geocoder (the `geocoding` package —
//     free, no API key, same service native phone apps use).
//     Requires the user to explicitly tap "Use my location" and
//     grant the Android location permission. Remembered for next
//     time via shared_preferences.
//
// Also fetches the last 7 days of daily rainfall/temperature in the
// SAME network call (Open-Meteo's `past_days` parameter), and the
// `is_day` flag so a clear-sky icon correctly shows sun during the
// day and moon at night, instead of always showing sun.
// ============================================================
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:shared_preferences/shared_preferences.dart';

class WeatherNow {
  final double tempC;
  final double humidityPct;
  final double precipitationMm; // instantaneous, at the moment fetched
  final int weatherCode;
  final bool isDay;

  WeatherNow({
    required this.tempC,
    required this.humidityPct,
    required this.precipitationMm,
    required this.weatherCode,
    required this.isDay,
  });
}

class DailyWeather {
  final DateTime date;
  final double maxTempC;
  final double minTempC;
  final double precipitationSumMm;

  DailyWeather({
    required this.date,
    required this.maxTempC,
    required this.minTempC,
    required this.precipitationSumMm,
  });
}

class WeatherBundle {
  final WeatherNow current;
  final List<DailyWeather> recentDays; // oldest → newest, ~7 days
  final String sourceLabel; // district name, or 'device_location'
  final bool isDeviceLocation;
  final String? placeName; // reverse-geocoded name, device-location only

  WeatherBundle({
    required this.current,
    required this.recentDays,
    required this.sourceLabel,
    required this.isDeviceLocation,
    this.placeName,
  });

  double get weekRainfallTotalMm =>
      recentDays.fold(0.0, (sum, d) => sum + d.precipitationSumMm);
}

class WeatherIconLabel {
  final IconData icon;
  final String label;
  WeatherIconLabel(this.icon, this.label);
}

class WeatherService {
  static const _kUseLocation = 'weather_use_device_location';

  // Same coordinates as the Flask backend's NASA_COORDS.
  static const Map<String, Map<String, double>> _districtCoords = {
    'Galle':  {'lat': 6.03,  'lon': 80.22},
    'Matara': {'lat': 5.95,  'lon': 80.54},
    'Kandy':  {'lat': 7.29,  'lon': 80.64},
    'Matale': {'lat': 7.47,  'lon': 80.62},
  };

  // ── Persisted preference: has the user opted into GPS location? ──
  static Future<bool> getUseDeviceLocation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kUseLocation) ?? false;
  }

  static Future<void> setUseDeviceLocation(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUseLocation, value);
  }

  // ── GPS permission + position ──────────────────────────────
  /// Requests location permission if needed and returns the current
  /// position, or null if location services are off, permission was
  /// denied, or anything else goes wrong. Never throws.
  static Future<Position?> requestDeviceLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// Reverse-geocodes coordinates into a short place name (e.g.
  /// "Pathinwatta") using the device's own OS geocoder — free, no API
  /// key. Returns null on any failure so the caller can fall back to
  /// a generic "Your location" label instead of breaking.
  static Future<String?> reverseGeocodePlaceName(double lat, double lon) async {
    try {
      final placemarks = await geocoding.placemarkFromCoordinates(lat, lon)
          .timeout(const Duration(seconds: 8));
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;
      if (p.subLocality != null && p.subLocality!.trim().isNotEmpty) {
        return p.subLocality!.trim();
      }
      if (p.locality != null && p.locality!.trim().isNotEmpty) {
        return p.locality!.trim();
      }
      if (p.name != null && p.name!.trim().isNotEmpty) {
        return p.name!.trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Main entry point used by the home screen ─────────────────
  /// Fetches weather using GPS location if [useDeviceLocation] is true
  /// AND permission is available; otherwise falls back to the given
  /// [fallbackDistrict]'s fixed coordinates. Returns null only if BOTH
  /// paths fail (e.g. no internet at all).
  static Future<WeatherBundle?> fetchWeather({
    required bool useDeviceLocation,
    required String fallbackDistrict,
  }) async {
    if (useDeviceLocation) {
      final pos = await requestDeviceLocation();
      if (pos != null) {
        final bundle = await _fetchFromCoords(
          pos.latitude, pos.longitude,
          sourceLabel: 'device_location',
          isDeviceLocation: true,
        );
        if (bundle != null) {
          // Try to resolve a real place name; if it fails, the sheet
          // just shows a generic "Your location" label instead.
          final name = await reverseGeocodePlaceName(pos.latitude, pos.longitude);
          return WeatherBundle(
            current: bundle.current,
            recentDays: bundle.recentDays,
            sourceLabel: bundle.sourceLabel,
            isDeviceLocation: true,
            placeName: name,
          );
        }
      }
      // Location failed (denied / services off / network) — fall
      // through to district-based weather so something still shows.
    }

    final coords = _districtCoords[fallbackDistrict];
    if (coords == null) return null;
    return _fetchFromCoords(
      coords['lat']!, coords['lon']!,
      sourceLabel: fallbackDistrict,
      isDeviceLocation: false,
    );
  }

  static Future<WeatherBundle?> _fetchFromCoords(
    double lat, double lon, {
    required String sourceLabel,
    required bool isDeviceLocation,
  }) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,relative_humidity_2m,precipitation,weather_code,is_day'
      '&daily=temperature_2m_max,temperature_2m_min,precipitation_sum'
      '&past_days=7&timezone=Asia%2FColombo',
    );

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);

      final current = data['current'];
      if (current == null) return null;
      final now = WeatherNow(
        tempC:           (current['temperature_2m'] as num).toDouble(),
        humidityPct:     (current['relative_humidity_2m'] as num).toDouble(),
        precipitationMm: (current['precipitation'] as num).toDouble(),
        weatherCode:     (current['weather_code'] as num).toInt(),
        isDay:           (current['is_day'] as num).toInt() == 1,
      );

      final daily = data['daily'];
      final List<DailyWeather> days = [];
      if (daily != null) {
        final times = List<String>.from(daily['time'] ?? []);
        final maxT  = List<num>.from(daily['temperature_2m_max'] ?? []);
        final minT  = List<num>.from(daily['temperature_2m_min'] ?? []);
        final rain  = List<num>.from(daily['precipitation_sum'] ?? []);
        final nowDt = DateTime.now();
        final todayMidnight = DateTime(nowDt.year, nowDt.month, nowDt.day);
        for (var i = 0; i < times.length; i++) {
          final d = DateTime.tryParse(times[i]);
          if (d == null) continue;
          if (!d.isBefore(todayMidnight)) continue; // keep PAST days only
          days.add(DailyWeather(
            date: d,
            maxTempC: i < maxT.length ? maxT[i].toDouble() : 0,
            minTempC: i < minT.length ? minT[i].toDouble() : 0,
            precipitationSumMm: i < rain.length ? rain[i].toDouble() : 0,
          ));
        }
      }

      return WeatherBundle(
        current: now,
        recentDays: days,
        sourceLabel: sourceLabel,
        isDeviceLocation: isDeviceLocation,
      );
    } catch (_) {
      return null;
    }
  }

  /// Maps WMO weather codes (the standard Open-Meteo uses) to a
  /// simple icon + label, now DAY/NIGHT aware — a clear sky shows sun
  /// during the day and moon at night, instead of always showing sun.
  /// Only classic, long-stable Material icon names are used to avoid
  /// any risk of an unavailable icon.
  /// Reference: https://open-meteo.com/en/docs (WMO codes)
  static WeatherIconLabel iconFor(int code, {required bool si, required bool isDay}) {
    if (code == 0) {
      return isDay
          ? WeatherIconLabel(Icons.wb_sunny, si ? 'පැහැදිලි අහස' : 'Clear sky')
          : WeatherIconLabel(
              Icons.nightlight_round, si ? 'පැහැදිලි රාත්‍රිය' : 'Clear night');
    }
    if (code >= 1 && code <= 3) {
      return WeatherIconLabel(
          isDay ? Icons.cloud : Icons.nights_stay,
          si ? 'වළාකුළු සහිතයි' : 'Cloudy');
    }
    if (code == 45 || code == 48) {
      return WeatherIconLabel(Icons.cloud, si ? 'මීදුම' : 'Fog');
    }
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return WeatherIconLabel(Icons.grain, si ? 'වැසි' : 'Rain');
    }
    if (code >= 95) {
      return WeatherIconLabel(
          Icons.flash_on, si ? 'ගිගුරුම් සහිත වැසි' : 'Thunderstorm');
    }
    return WeatherIconLabel(
        isDay ? Icons.wb_sunny : Icons.nightlight_round,
        si ? 'සාමාන්‍ය' : 'Normal');
  }
}