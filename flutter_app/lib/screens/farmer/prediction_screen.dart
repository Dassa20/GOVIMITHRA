// ============================================================
// PREDICTION SCREEN — Price + Weather + Recommendation + Chart
// Text follows the language chosen on the Language screen.
// Note: biometric login lives on the Login screen only.
// ============================================================
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../services/api_service.dart';
import '../../services/notification_service.dart';
import '../../services/language_service.dart';
import '../../models/app_models.dart';
import '../../utils/crop_labels.dart';

class PredictionScreen extends StatefulWidget {
  final String crop;
  final String district;
  final String grade;

  const PredictionScreen({
    super.key,
    required this.crop,
    required this.district,
    required this.grade,
  });

  @override
  State<PredictionScreen> createState() => _PredictionScreenState();
}

class _PredictionScreenState extends State<PredictionScreen> {
  String _lang = 'en'; // 'si' or 'en'
  bool get _si => _lang == 'si';

  // Format any date string to DD.MM.YYYY for display
  // Handles: DD.MM.YYYY, YYYY-MM-DD, YYYY/MM/DD
  String _formatDate(String? date) {
    if (date == null || date.isEmpty) return '—';
    try {
      if (RegExp(r'^\d{2}\.\d{2}\.\d{4}$').hasMatch(date)) return date;
      final parts = date.split(RegExp(r'[-/]'));
      if (parts.length == 3 && parts[0].length == 4) {
        return '${parts[2]}.${parts[1]}.${parts[0]}';
      }
      return date;
    } catch (_) { return date; }
  }

  // ── Translation helpers for backend-origin fixed-set values ──
  // Fixed-set labels from the backend are translated below. The reason
  // sentence (rec.reason) is rebuilt in Sinhala by _reasonText().
  String _recLabelSi(String rec) => switch (rec) {
    'Sell Now'    => 'දැන් විකුණන්න',
    'Wait'        => 'රැඳී සිටින්න',
    'Harvest Now' => 'දැන් අස්වනු නෙලන්න',
    _ => rec,
  };

  String _seasonSi(String season) => switch (season) {
    'Yala'          => 'යල',
    'Maha'          => 'මහ',
    'Inter-Monsoon' => 'අන්තර් මෝසම',
    _ => season,
  };

  String _harvestStatusSi(String status) => switch (status) {
    'Ready to Harvest'   => 'අස්වනු නෙලීමට සූදානම්',
    'Not Harvest Season' => 'අස්වනු කාලය නොවේ',
    _ => status,
  };

  static const Map<String, String> _monthSi = {
    'January': 'ජනවාරි', 'February': 'පෙබරවාරි', 'March': 'මාර්තු',
    'April': 'අප්‍රේල්', 'May': 'මැයි', 'June': 'ජූනි',
    'July': 'ජූලි', 'August': 'අගෝස්තු', 'September': 'සැප්තැම්බර්',
    'October': 'ඔක්තෝබර්', 'November': 'නොවැම්බර්', 'December': 'දෙසැම්බර්',
  };
  String _monthLabel(String month) => _si ? (_monthSi[month] ?? month) : month;

  // ── Price formatting that follows the selected language ──
  // English: "Rs. 1800/kg"   Sinhala: "රු. 1800/කි.ග්‍රෑ."
  String _money(double v) =>
      _si ? 'රු. ${v.toStringAsFixed(0)}' : 'Rs. ${v.toStringAsFixed(0)}';
  String _moneyPerKg(double v) => _si
      ? 'රු. ${v.toStringAsFixed(0)}/කි.ග්‍රෑ.'
      : 'Rs. ${v.toStringAsFixed(0)}/kg';

  // ── Recommendation reason in the selected language ──
  // The backend sends an English sentence with live numbers
  // (e.g. "Price predicted to rise by 9.2% next week."). The four
  // possible sentence shapes are recognised and rebuilt in Sinhala
  // with the same number; anything unrecognised is shown unchanged.
  String _reasonText(String reason) {
    if (!_si) return reason;
    final rise = RegExp(r'rise by ([0-9]+(?:\.[0-9]+)?)%').firstMatch(reason);
    if (rise != null) {
      return 'ඊළඟ සතියේ මිල ${rise.group(1)}%කින් ඉහළ යනු ඇතැයි අනුමාන කෙරේ.';
    }
    final fall = RegExp(r'fall by ([0-9]+(?:\.[0-9]+)?)%').firstMatch(reason);
    if (fall != null) {
      return 'ඊළඟ සතියේ මිල ${fall.group(1)}%කින් පහත වැටෙනු ඇතැයි අනුමාන කෙරේ.';
    }
    if (reason.contains('remain stable')) {
      return 'ඊළඟ සතියේ මිල ස්ථාවරව පවතිනු ඇතැයි අපේක්ෂා කෙරේ.';
    }
    final harvest =
        RegExp(r'^(.*) is in its harvest season \((.*)\)\.?$').firstMatch(reason);
    if (harvest != null) {
      return '${localizedCrop(harvest.group(1)!, true)} දැන් අස්වනු කාලයයි '
             '(${_seasonSi(harvest.group(2)!)}).';
    }
    return reason;
  }

  PredictionResult?     _prediction;
  RecommendationResult? _recommendation;
  HarvestStatus?        _harvestStatus;
  List<PriceHistoryEntry> _allHistory  = []; // full dataset
  List<PriceHistoryEntry> _history     = []; // filtered subset
  bool   _loading = true;
  String? _error;

  // Date filter
  DateTime? _filterFrom;
  DateTime? _filterTo;
  String    _filterLabel = 'Last 16 weeks';

  @override
  void initState() {
    super.initState();
    _filterLabel = _si ? 'පසුගිය සති 16' : 'Last 16 weeks';
    _loadAll();
    _loadLanguage();
    // Register for price alerts — works without login
    _registerNotifications();
  }

  Future<void> _loadLanguage() async {
    final lang = await LanguageService.getLanguage();
    if (mounted) {
      setState(() {
        _lang = lang ?? 'en';
        _filterLabel = _si ? 'පසුගිය සති 16' : 'Last 16 weeks';
      });
    }
  }

  bool _notifRegistered = false;

  Future<void> _registerNotifications() async {
    if (_notifRegistered) return;
    _notifRegistered = true;
    try {
      final permission = await _askNotificationPermission();
      if (!permission) { _notifRegistered = false; return; }

      await NotificationService.registerForAlerts(
        crop:     widget.crop,
        district: widget.district,
        grade:    widget.grade,
      );
    } catch (_) { _notifRegistered = false; }
  }

  Future<bool> _askNotificationPermission() async {
    final current = await FirebaseMessaging.instance.getNotificationSettings();
    if (current.authorizationStatus == AuthorizationStatus.authorized) return true;
    if (current.authorizationStatus == AuthorizationStatus.denied)     return false;

    if (!mounted) return false;
    final allow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Text('🌿', style: TextStyle(fontSize: 28)),
          const SizedBox(width: 10),
          Text(_si ? 'මිල දැනුම්දීම්' : 'Price Alerts',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _si
                  ? 'DEA විසින් නව ගොවිපොළ මිල ප්‍රකාශයට පත් කරන විට ඔබට දැනුම් දෙනු ලැබේ.'
                  : 'Get notified when new farm-gate prices are published by DEA.',
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            _notifFeature(Icons.notifications_active_outlined,
                _si ? 'සතිපතා මිල යාවත්කාලීන' : 'Weekly price updates'),
            _notifFeature(Icons.trending_up_outlined,
                _si ? 'ඊළඟ සතියේ අනාවැකි මිල' : 'Predicted next week price'),
            _notifFeature(Icons.agriculture_outlined,
                _si
                    ? 'දැනුම්දීම් — ${localizedCrop(widget.crop, true)} — ${localizedDistrict(widget.district, true)}'
                    : 'Alerts for ${widget.crop} — ${widget.district}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_si ? 'දැන් නොවේ' : 'Not now',
                style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32)),
            child: Text(_si ? 'දැනුම්දීම් ඉඩ දෙන්න' : 'Allow Notifications',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return allow ?? false;
  }

  Widget _notifFeature(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: const Color(0xFF2E7D32)),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }

  Future<void> _loadAll() async {
    try {
      setState(() { _loading = true; _error = null; });
      final results = await Future.wait([
        ApiService.predict(
            district: widget.district, crop: widget.crop, grade: widget.grade),
        ApiService.getRecommendation(
            district: widget.district, crop: widget.crop, grade: widget.grade),
        ApiService.getHarvestStatus(
            crop: widget.crop, district: widget.district),
        ApiService.getHistory(
            district: widget.district, crop: widget.crop,
            grade: widget.grade, limit: 80),
      ]);
      setState(() {
        _prediction     = results[0] as PredictionResult;
        _recommendation = results[1] as RecommendationResult;
        _harvestStatus  = results[2] as HarvestStatus;
        _allHistory     = results[3] as List<PriceHistoryEntry>;
        _loading        = false;
      });
      _applyFilter();
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // ── Date filter logic ─────────────────────────────────────
  DateTime _parseDate(String d) {
    final parts = d.split('.');
    if (parts.length != 3) return DateTime.now();
    return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
  }

  void _applyFilter() {
    List<PriceHistoryEntry> filtered = List.from(_allHistory);
    if (_filterFrom != null) {
      filtered = filtered.where((e) =>
          !_parseDate(e.date).isBefore(_filterFrom!)).toList();
    }
    if (_filterTo != null) {
      filtered = filtered.where((e) =>
          !_parseDate(e.date).isAfter(_filterTo!)).toList();
    }
    if (_filterFrom == null && _filterTo == null) {
      filtered = filtered.length > 16
          ? filtered.sublist(filtered.length - 16)
          : filtered;
    }
    setState(() => _history = filtered);
  }

  Future<void> _showFilterSheet() async {
    DateTime? tempFrom = _filterFrom;
    DateTime? tempTo   = _filterTo;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
              left: 24, right: 24, top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(_si ? 'මිල ඉතිහාසය පෙරහන් කරන්න' : 'Filter Price History',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx)),
              ]),
              const SizedBox(height: 16),

              Text(_si ? 'ඉක්මන් පරාසය' : 'Quick range',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                _filterChip(_si ? 'පසුගිය සති 4' : 'Last 4 weeks', ctx, setModalState, () {
                  tempFrom = DateTime.now().subtract(const Duration(days: 28));
                  tempTo   = null;
                }),
                _filterChip(_si ? 'පසුගිය මාස 3' : 'Last 3 months', ctx, setModalState, () {
                  tempFrom = DateTime.now().subtract(const Duration(days: 90));
                  tempTo   = null;
                }),
                _filterChip(_si ? 'පසුගිය මාස 6' : 'Last 6 months', ctx, setModalState, () {
                  tempFrom = DateTime.now().subtract(const Duration(days: 180));
                  tempTo   = null;
                }),
                _filterChip(_si ? 'සියලු දත්ත' : 'All data', ctx, setModalState, () {
                  tempFrom = null; tempTo = null;
                }),
              ]),

              const SizedBox(height: 16),
              Text(_si ? 'අභිරුචි පරාසය' : 'Custom range',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              const SizedBox(height: 8),

              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined, size: 20),
                title: Text(tempFrom != null
                    ? '${_si ? "සිට" : "From"}: ${tempFrom!.day.toString().padLeft(2,'0')}.${tempFrom!.month.toString().padLeft(2,'0')}.${tempFrom!.year}'
                    : (_si ? 'සිට: සියලු කාලය' : 'From: all time')),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: tempFrom ?? DateTime(2025, 1, 1),
                    firstDate: DateTime(2025, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setModalState(() => tempFrom = d);
                },
                trailing: tempFrom != null
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setModalState(() => tempFrom = null))
                    : null,
              ),

              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined, size: 20),
                title: Text(tempTo != null
                    ? '${_si ? "දක්වා" : "To"}: ${tempTo!.day.toString().padLeft(2,'0')}.${tempTo!.month.toString().padLeft(2,'0')}.${tempTo!.year}'
                    : (_si ? 'දක්වා: නවතම' : 'To: latest')),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: tempTo ?? DateTime.now(),
                    firstDate: DateTime(2025, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setModalState(() => tempTo = d);
                },
                trailing: tempTo != null
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setModalState(() => tempTo = null))
                    : null,
              ),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: () {
                    _filterFrom = tempFrom;
                    _filterTo   = tempTo;
                    _filterLabel = _buildFilterLabel(tempFrom, tempTo);
                    _applyFilter();
                    Navigator.pop(ctx);
                  },
                  child: Text(_si ? 'පෙරහන යොදන්න' : 'Apply filter'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String label, BuildContext ctx, StateSetter setModalState, VoidCallback fn) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () {
        fn();
        _filterFrom = null; _filterTo = null;
        setModalState(() {});
      },
      backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
    );
  }

  String _buildFilterLabel(DateTime? from, DateTime? to) {
    if (from == null && to == null) return _si ? 'පසුගිය සති 16' : 'Last 16 weeks';
    final f = from != null
        ? '${from.day.toString().padLeft(2,'0')}.${from.month.toString().padLeft(2,'0')}.${from.year}'
        : (_si ? 'සියල්ල' : 'All');
    final t = to != null
        ? '${to.day.toString().padLeft(2,'0')}.${to.month.toString().padLeft(2,'0')}.${to.year}'
        : (_si ? 'නවතම' : 'Latest');
    return '$f — $t';
  }

  Color _recColor(String rec) => switch (rec) {
    'Sell Now'    => Colors.orange[700]!,
    'Wait'        => Colors.blue[700]!,
    'Harvest Now' => Colors.green[700]!,
    _ => Colors.grey,
  };

  IconData _recIcon(String rec) => switch (rec) {
    'Sell Now'    => Icons.sell_outlined,
    'Wait'        => Icons.hourglass_empty,
    'Harvest Now' => Icons.agriculture_outlined,
    _ => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${localizedCrop(widget.crop, _si)} — ${localizedDistrict(widget.district, _si)}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
                _si ? 'ශ්‍රේණිය: ${widget.grade}' : 'Grade: ${widget.grade}',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_si ? 'දෝෂයකි: $_error' : 'Error: $_error',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: _loadAll,
                        child: Text(_si ? 'නැවත උත්සාහ කරන්න' : 'Retry')),
                  ],
                ))
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildRecommendationCard(),
                        const SizedBox(height: 16),
                        _buildPredictionCard(),
                        const SizedBox(height: 16),
                        _buildWeatherCard(),
                        const SizedBox(height: 16),
                        _buildHarvestCard(),
                        const SizedBox(height: 16),
                        _buildHistoryChart(),
                        const SizedBox(height: 8),
                        Center(child: Text(
                            _si ? 'නැවුම් කිරීමට පහළට අදින්න' : 'Pull down to refresh',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12))),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildRecommendationCard() {
    final rec   = _recommendation!;
    final color = _recColor(rec.recommendation);
    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 2),
        ),
        child: Column(children: [
          Icon(_recIcon(rec.recommendation), size: 48, color: color),
          const SizedBox(height: 12),
          Text(_si ? _recLabelSi(rec.recommendation) : rec.recommendation,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 8),
          // rec.reason comes from the backend in English with live numbers;
          // _reasonText() shows it in Sinhala when Sinhala is selected.
          Text(_reasonText(rec.reason),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[700])),
        ]),
      ),
    );
  }

  Widget _buildPredictionCard() {
    final pred = _prediction!;
    final isUp = pred.priceChangePct >= 0;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_si ? 'මිල අනාවැකිය' : 'Price Prediction',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _buildPriceCell(
                _si ? 'දන්නා අවසන් මිල' : 'Last known price',
                _moneyPerKg(pred.lastKnownPrice),
                _formatDate(pred.lastKnownDate),
                Colors.grey[700]!)),
            const SizedBox(width: 12),
            Expanded(child: _buildPriceCell(
                _si ? 'ඊළඟ සතියේ අනාවැකිය' : 'Predicted next week',
                _moneyPerKg(pred.predictedPrice),
                _formatDate(pred.predictedForDate),
                isUp ? Colors.green[700]! : Colors.red[700]!)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Icon(isUp ? Icons.trending_up : Icons.trending_down,
                color: isUp ? Colors.green : Colors.red),
            const SizedBox(width: 8),
            Text(
              '${isUp ? '+' : ''}${pred.priceChangePct.toStringAsFixed(2)}% '
              '(${_money(pred.priceChange)})',
              style: TextStyle(
                  color: isUp ? Colors.green[700] : Colors.red[700],
                  fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
                _si ? 'මෝසම: ${_seasonSi(pred.season)}' : 'Season: ${pred.season}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          ]),
        ]),
      ),
    );
  }

  Widget _buildPriceCell(String label, String price, String date, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        const SizedBox(height: 4),
        Text(price,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        Text(date, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      ]),
    );
  }

  Widget _buildWeatherCard() {
    final pred = _prediction!;
    if (pred.rainfallMm == null && pred.tempC == null && pred.humidityPct == null) {
      return const SizedBox.shrink();
    }
    final items = <String>[];
    if (pred.rainfallMm  != null) {
      items.add(_si
          ? 'වර්ෂාපතනය: ${pred.rainfallMm!.toStringAsFixed(1)} මි.මී.'
          : 'Rainfall: ${pred.rainfallMm!.toStringAsFixed(1)} mm');
    }
    if (pred.tempC != null) {
      items.add(_si
          ? 'උෂ්ණත්වය: ${pred.tempC!.toStringAsFixed(1)} °C'
          : 'Temperature: ${pred.tempC!.toStringAsFixed(1)} °C');
    }
    if (pred.humidityPct != null) {
      items.add(_si
          ? 'ආර්ද්‍රතාවය: ${pred.humidityPct!.toStringAsFixed(1)} %'
          : 'Humidity: ${pred.humidityPct!.toStringAsFixed(1)} %');
    }
    if (pred.rain3mAvg != null) {
      items.add(_si
          ? 'මාස 3ක සාමාන්‍ය වර්ෂාපතනය: ${pred.rain3mAvg!.toStringAsFixed(1)} මි.මී.'
          : '3-month avg rainfall: ${pred.rain3mAvg!.toStringAsFixed(1)} mm');
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_si ? 'වර්තමාන කාලගුණය' : 'Current Weather',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...items.map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(item,
                style: TextStyle(fontSize: 13, color: Colors.grey[800])),
          )),
          const SizedBox(height: 4),
          Text(
              _si
                  ? 'මූලාශ්‍රය: NASA POWER Agroclimatology'
                  : 'Source: NASA POWER Agroclimatology',
              style: TextStyle(fontSize: 11, color: Colors.grey[400],
                  fontStyle: FontStyle.italic)),
        ]),
      ),
    );
  }

  Widget _buildHarvestCard() {
    final harvest = _harvestStatus!;
    final color   = harvest.isHarvestSeason ? Colors.green[700]! : Colors.grey[600]!;
    final harvestMonthsLabel =
        harvest.harvestMonths.map((m) => _monthLabel(m)).join(', ');
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(harvest.isHarvestSeason ? Icons.agriculture : Icons.access_time,
              color: color, size: 40),
          const SizedBox(width: 16),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_si ? 'අස්වනු තත්ත්වය' : 'Harvest Status',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              Text(_si ? _harvestStatusSi(harvest.status) : harvest.status,
                  style: TextStyle(fontWeight: FontWeight.bold,
                      color: color, fontSize: 16)),
              Text(
                _si
                    ? 'වර්තමාන: ${_monthLabel(harvest.currentMonth)}  |  '
                      'අස්වනු: $harvestMonthsLabel'
                    : 'Current: ${harvest.currentMonth}  |  '
                      'Harvest: ${harvest.harvestMonths.join(', ')}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          )),
        ]),
      ),
    );
  }

  Widget _buildHistoryChart() {
    if (_allHistory.isEmpty) return const SizedBox.shrink();

    final spots = _history.asMap().entries.map((e) =>
        FlSpot(e.key.toDouble(), e.value.avgPrice)).toList();
    final prices = _history.map((e) => e.avgPrice);
    final minY   = prices.isEmpty ? 0.0 : prices.reduce((a, b) => a < b ? a : b);
    final maxY   = prices.isEmpty ? 0.0 : prices.reduce((a, b) => a > b ? a : b);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                _si ? 'මිල ඉතිහාසය' : 'Price History',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _showFilterSheet,
              icon: const Icon(Icons.filter_list, size: 16),
              label: Text(_filterLabel,
                  style: const TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          if (_filterFrom != null || _filterTo != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Chip(
                label: Text(
                    _si
                        ? 'සති ${_history.length}ක් පෙන්වා ඇත'
                        : '${_history.length} weeks shown',
                    style: const TextStyle(fontSize: 11)),
                backgroundColor: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.1),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () {
                  _filterFrom = null;
                  _filterTo   = null;
                  _filterLabel = _si ? 'පසුගිය සති 16' : 'Last 16 weeks';
                  _applyFilter();
                },
              ),
            ]),
          ],
          const SizedBox(height: 12),
          if (_history.isEmpty)
            Center(child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(_si ? 'තෝරාගත් පරාසය තුළ දත්ත නොමැත' : 'No data in selected range'),
            ))
          else
            SizedBox(
              height: 200,
              child: LineChart(LineChartData(
                minY: minY - 200, maxY: maxY + 200,
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(
                    showTitles: true, reservedSize: 56,
                    getTitlesWidget: (v, _) => Text(
                        _si ? 'රු.${v.toInt()}' : 'Rs.${v.toInt()}',
                        style: const TextStyle(fontSize: 9)),
                  )),
                  bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [LineChartBarData(
                  spots: spots, isCurved: true,
                  color: Theme.of(context).colorScheme.primary,
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: 0.1),
                  ),
                )],
              )),
            ),
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statPill(_si ? 'අවම' : 'Min', _money(minY), Colors.red[700]!),
                _statPill(_si ? 'උපරිම' : 'Max', _money(maxY), Colors.green[700]!),
                _statPill(_si ? 'සාමාන්‍ය' : 'Avg',
                    _money(_history.map((e) => e.avgPrice).reduce((a,b) => a+b) / _history.length),
                    Colors.blue[700]!),
              ],
            ),
          ],
        ]),
      ),
    );
  }

  Widget _statPill(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        Text(value, style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}