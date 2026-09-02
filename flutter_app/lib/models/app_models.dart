// ============================================================
// DATA MODELS — all fields from API, nothing hardcoded
// ============================================================

class AppMetadata {
  final List<String> crops;
  final Map<String, List<String>> districtsByCrop;
  final Map<String, List<String>> gradesByCrop;
  // NEW: grades tracked per (crop, district) pair — e.g.
  // gradesByCropDistrict['Cinnamon']['Galle'] only lists grades that
  // ACTUALLY have data for Galle specifically. The old gradesByCrop
  // above is a union across every district for that crop, which let
  // the app offer a grade (e.g. Cinnamon M-5, which only exists for
  // Matara) as a choice even for a district (Galle) where it has zero
  // rows — always a guaranteed prediction failure. Use this field for
  // the grade dropdown; gradesByCrop is kept only for backward
  // compatibility with any older code still reading it.
  final Map<String, Map<String, List<String>>> gradesByCropDistrict;
  final Map<String, List<int>> harvestMonths;

  AppMetadata({
    required this.crops,
    required this.districtsByCrop,
    required this.gradesByCrop,
    required this.gradesByCropDistrict,
    required this.harvestMonths,
  });

  factory AppMetadata.fromJson(Map<String, dynamic> json) {
    // Parse the new crop+district-aware grade structure. Falls back to
    // an empty map (never crashes) if the backend hasn't been restarted
    // yet with the updated /metadata route and this key is missing.
    final gbcd = <String, Map<String, List<String>>>{};
    if (json['grades_by_crop_district'] != null) {
      (json['grades_by_crop_district'] as Map).forEach((crop, districtsMap) {
        final inner = <String, List<String>>{};
        (districtsMap as Map).forEach((district, grades) {
          inner[district.toString()] = List<String>.from(grades);
        });
        gbcd[crop.toString()] = inner;
      });
    }

    return AppMetadata(
      crops: List<String>.from(json['crops']),
      districtsByCrop: Map<String, List<String>>.from(
        (json['districts_by_crop'] as Map).map(
          (k, v) => MapEntry(k.toString(), List<String>.from(v)),
        ),
      ),
      gradesByCrop: Map<String, List<String>>.from(
        (json['grades_by_crop'] as Map).map(
          (k, v) => MapEntry(k.toString(), List<String>.from(v)),
        ),
      ),
      gradesByCropDistrict: gbcd,
      harvestMonths: Map<String, List<int>>.from(
        (json['harvest_months'] as Map).map(
          (k, v) => MapEntry(k.toString(), List<int>.from(v)),
        ),
      ),
    );
  }
}

class PredictionResult {
  final String crop;
  final String district;
  final String grade;
  final double lastKnownPrice;
  final String lastKnownDate;
  final double predictedPrice;
  final String predictedForDate;
  final double priceChange;
  final double priceChangePct;
  final String season;
  final bool isHarvestSeason;
  // Weather fields
  final double? rainfallMm;
  final double? tempC;
  final double? humidityPct;
  final double? rain3mAvg;

  PredictionResult({
    required this.crop,
    required this.district,
    required this.grade,
    required this.lastKnownPrice,
    required this.lastKnownDate,
    required this.predictedPrice,
    required this.predictedForDate,
    required this.priceChange,
    required this.priceChangePct,
    required this.season,
    required this.isHarvestSeason,
    this.rainfallMm,
    this.tempC,
    this.humidityPct,
    this.rain3mAvg,
  });

  factory PredictionResult.fromJson(Map<String, dynamic> json) {
    return PredictionResult(
      crop:             json['crop'],
      district:         json['district'],
      grade:            json['grade'],
      lastKnownPrice:   (json['last_known_price'] as num).toDouble(),
      lastKnownDate:    json['last_known_date'],
      predictedPrice:   (json['predicted_price'] as num).toDouble(),
      predictedForDate: json['predicted_for_date'],
      priceChange:      (json['price_change'] as num).toDouble(),
      priceChangePct:   (json['price_change_pct'] as num).toDouble(),
      season:           json['season'],
      isHarvestSeason:  json['is_harvest_season'],
      rainfallMm:  json['rainfall_mm']  != null ? (json['rainfall_mm']  as num).toDouble() : null,
      tempC:       json['temp_c']        != null ? (json['temp_c']        as num).toDouble() : null,
      humidityPct: json['humidity_pct']  != null ? (json['humidity_pct']  as num).toDouble() : null,
      rain3mAvg:   json['rain_3m_avg']   != null ? (json['rain_3m_avg']   as num).toDouble() : null,
    );
  }
}

class RecommendationResult {
  final String crop;
  final String district;
  final String grade;
  final String recommendation;
  final String reason;
  final double predictedPrice;
  final double lastKnownPrice;
  final double priceChangePct;
  final bool isHarvestSeason;

  RecommendationResult({
    required this.crop,
    required this.district,
    required this.grade,
    required this.recommendation,
    required this.reason,
    required this.predictedPrice,
    required this.lastKnownPrice,
    required this.priceChangePct,
    required this.isHarvestSeason,
  });

  factory RecommendationResult.fromJson(Map<String, dynamic> json) {
    return RecommendationResult(
      crop:            json['crop'],
      district:        json['district'],
      grade:           json['grade'],
      recommendation:  json['recommendation'],
      reason:          json['reason'],
      predictedPrice:  (json['predicted_price'] as num).toDouble(),
      lastKnownPrice:  (json['last_known_price'] as num).toDouble(),
      priceChangePct:  (json['price_change_pct'] as num).toDouble(),
      isHarvestSeason: json['is_harvest_season'],
    );
  }
}

class HarvestStatus {
  final String crop;
  final String district;
  final String currentMonth;
  final bool isHarvestSeason;
  final List<String> harvestMonths;
  final String status;

  HarvestStatus({
    required this.crop,
    required this.district,
    required this.currentMonth,
    required this.isHarvestSeason,
    required this.harvestMonths,
    required this.status,
  });

  factory HarvestStatus.fromJson(Map<String, dynamic> json) {
    return HarvestStatus(
      crop:            json['crop'],
      district:        json['district'],
      currentMonth:    json['current_month'],
      isHarvestSeason: json['is_harvest_season'],
      harvestMonths:   List<String>.from(json['harvest_months']),
      status:          json['status'],
    );
  }
}

class PriceHistoryEntry {
  final String date;
  final double avgPrice;
  final double? highPrice;
  final double? rainfallMm;
  final double? tempC;
  final double? humidityPct;

  PriceHistoryEntry({
    required this.date,
    required this.avgPrice,
    this.highPrice,
    this.rainfallMm,
    this.tempC,
    this.humidityPct,
  });

  factory PriceHistoryEntry.fromJson(Map<String, dynamic> json) {
    return PriceHistoryEntry(
      date:        json['date'],
      avgPrice:    (json['avg_price'] as num).toDouble(),
      highPrice:   json['high_price']   != null ? (json['high_price']   as num).toDouble() : null,
      rainfallMm:  json['rainfall_mm']  != null ? (json['rainfall_mm']  as num).toDouble() : null,
      tempC:       json['temp_c']        != null ? (json['temp_c']        as num).toDouble() : null,
      humidityPct: json['humidity_pct']  != null ? (json['humidity_pct']  as num).toDouble() : null,
    );
  }
}

class AdminAccount {
  final int id;
  final String username;
  final String role;
  final String? fullName;
  final String? district;
  final String? crop;
  final String createdAt;

  AdminAccount({
    required this.id,
    required this.username,
    required this.role,
    this.fullName,
    this.district,
    this.crop,
    required this.createdAt,
  });

  factory AdminAccount.fromJson(Map<String, dynamic> json) {
    return AdminAccount(
      id:        json['id'],
      username:  json['username'],
      role:      json['role'],
      fullName:  json['full_name'],
      district:  json['district'],
      crop:      json['crop'],
      createdAt: json['created_at'] ?? '',
    );
  }
}