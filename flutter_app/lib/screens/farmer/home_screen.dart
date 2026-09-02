// ============================================================
// HOME SCREEN — Farmer crop selector
// Login removed: /predict, /metadata, /history etc. are all public
// backend endpoints, so an account was never protecting anything.
// Admin panel access moved here (long-press the profile icon),
// since the login screen it used to live on is gone.
// ============================================================
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/language_service.dart';
import '../../services/weather_service.dart';
import '../../utils/crop_labels.dart';
import '../../models/app_models.dart';
import 'prediction_screen.dart';
import 'chatbot_screen.dart';
import '../admin/admin_login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppMetadata? _metadata;
  bool   _loading = true;
  String? _error;
  String _lang = 'en'; // 'si' or 'en' — from LanguageService

  String? _selectedCrop;
  String? _selectedDistrict;
  String? _selectedGrade;

  // Real weather for the header — null until fetched, or if the fetch
  // fails (no internet, API down); the header falls back to a plain
  // time-of-day icon in that case, so it never breaks the screen.
  WeatherBundle? _weather;
  bool _weatherIsLoading = true;

  bool get _si => _lang == 'si';

  @override
  void initState() {
    super.initState();
    _loadMetadata();
    _loadLanguage();
    _loadWeather();
  }

  Future<void> _loadWeather() async {
    setState(() => _weatherIsLoading = true);
    // Show weather for the farmer's last-used district by default;
    // falls back to Galle if nothing's saved yet. If the user has
    // previously opted into device-location weather, use that instead.
    final saved         = await AuthService.loadSelections();
    final district      = saved['district'] ?? 'Galle';
    final useDeviceLoc  = await WeatherService.getUseDeviceLocation();
    final w = await WeatherService.fetchWeather(
      useDeviceLocation: useDeviceLoc,
      fallbackDistrict: district,
    );
    if (mounted) setState(() { _weather = w; _weatherIsLoading = false; });
  }

  // Called from the detail sheet when the user taps "Use my location".
  Future<bool> _enableDeviceLocationWeather() async {
    // Show the spinner immediately and clear the old reading — without
    // this, the chip kept showing the PREVIOUS district's weather the
    // whole time GPS+geocoding+fetch was running (which can take a
    // few seconds), making it look stuck instead of working.
    if (mounted) setState(() { _weatherIsLoading = true; _weather = null; });
    final saved    = await AuthService.loadSelections();
    final district = saved['district'] ?? 'Galle';
    final w = await WeatherService.fetchWeather(
      useDeviceLocation: true,
      fallbackDistrict: district,
    );
    if (w != null && w.isDeviceLocation) {
      await WeatherService.setUseDeviceLocation(true);
      if (mounted) setState(() { _weather = w; _weatherIsLoading = false; });
      return true;
    }
    if (mounted) setState(() => _weatherIsLoading = false);
    return false; // permission denied, services off, or network failure
  }

  Future<void> _loadLanguage() async {
    final lang = await LanguageService.getLanguage();
    if (mounted) setState(() => _lang = lang ?? 'en');
  }

  Future<void> _loadMetadata() async {
    try {
      setState(() { _loading = true; _error = null; });
      final metadata = await ApiService.getMetadata();
      final saved    = await AuthService.loadSelections();
      setState(() {
        _metadata = metadata;
        _loading  = false;
        final savedCrop = saved['crop'];
        if (savedCrop != null && metadata.crops.contains(savedCrop)) {
          _selectedCrop = savedCrop;
          final districts = metadata.districtsByCrop[savedCrop] ?? [];
          final savedDistrict = saved['district'];
          if (savedDistrict != null && districts.contains(savedDistrict)) {
            _selectedDistrict = savedDistrict;
            final grades = metadata.gradesByCropDistrict[savedCrop]
                    ?[savedDistrict] ??
                metadata.gradesByCrop[savedCrop] ??
                [];
            final savedGrade = saved['grade'];
            if (savedGrade != null && grades.contains(savedGrade)) {
              _selectedGrade = savedGrade;
            }
          }
        }
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error   = _si
            ? 'සර්වරයට සම්බන්ධ විය නොහැක.\nFlask API ක්‍රියාත්මකද යන්න පරීක්ෂා කරන්න.'
            : 'Could not connect to server.\n'
              'Make sure your Flask API is running.';
      });
    }
  }

  void _onCropChanged(String? crop) => setState(() {
    _selectedCrop     = crop;
    _selectedDistrict = null;
    _selectedGrade    = null;
  });

  void _onDistrictChanged(String? d) => setState(() {
    _selectedDistrict = d;
    _selectedGrade    = null;
  });

  Future<void> _navigateToResults() async {
    if (_selectedCrop == null || _selectedDistrict == null || _selectedGrade == null) {
      return;
    }
    await AuthService.saveSelections(
        district: _selectedDistrict!, crop: _selectedCrop!, grade: _selectedGrade!);
    await AuthService.registerDeviceForNotifications(
        district: _selectedDistrict!, crop: _selectedCrop!, grade: _selectedGrade!);
    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PredictionScreen(
          crop:     _selectedCrop!,
          district: _selectedDistrict!,
          grade:    _selectedGrade!,
        )));
    }
  }

  // ── Greeting helpers ───────────────────────────────────────
  String _greeting() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12)  return _si ? 'සුබ උදෑසනක්' : 'Good morning';
    if (h >= 12 && h < 17) return _si ? 'සුබ දහවලක්'  : 'Good afternoon';
    if (h >= 17 && h < 21) return _si ? 'සුබ සැන්දෑවක්' : 'Good evening';
    return _si ? 'සුබ රාත්‍රියක්' : 'Good night';
  }

  IconData _greetingIcon() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 17)  return Icons.wb_sunny_rounded;
    if (h >= 17 && h < 20) return Icons.wb_twilight_rounded;
    return Icons.nightlight_round;
  }

  // Compact, tappable weather chip — icon + temperature side by side.
  // Falls back to the plain time-of-day icon if weather hasn't loaded
  // yet or the fetch failed (no internet, API unreachable) — the
  // header always shows something, never breaks.
  Widget _weatherChip() {
    if (_weather == null) {
      // Previously this was an invisible empty box, so a slow or
      // failed weather fetch looked identical to nothing being wrong
      // at all — no way to tell "still loading" from "gave up".
      // Now it shows a spinner while loading, or a tappable
      // "weather unavailable, tap to retry" state if it's done
      // trying and genuinely failed (e.g. no real internet access,
      // separate from reaching the local Flask server).
      if (_weatherIsLoading) {
        return const SizedBox(
          width: 32, height: 32,
          child: Center(
            child: SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70),
            ),
          ),
        );
      }
      return Semantics(
        label: _si ? 'කාලගුණය, උත්සාහ අසාර්ථකයි, නැවත උත්සාහ කිරීමට තට්ටු කරන්න'
                    : 'Weather unavailable, tap to retry',
        button: true,
        child: Material(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _loadWeather,
            child: Padding(
              // vertical: 13 (not 8) so total height reaches the
              // 48dp WCAG/Material minimum touch target.
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 18, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text(_si ? 'නැවත උත්සාහ කරන්න' : 'Tap to retry',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final iconLabel = WeatherService.iconFor(
        _weather!.current.weatherCode, si: _si, isDay: _weather!.current.isDay);
    return Semantics(
      label: _si
          ? 'කාලගුණය, උෂ්ණත්වය ${_weather!.current.tempC.round()} සෙල්සියස්, විස්තර සඳහා තට්ටු කරන්න'
          : 'Weather, ${_weather!.current.tempC.round()} degrees Celsius, tap for details',
      button: true,
      child: Material(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _showWeatherDetail,
          child: Padding(
            // vertical: 13 (not 8) so total height reaches the 48dp
            // WCAG/Material minimum touch target height.
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconLabel.icon, size: 22, color: Colors.amber[300]),
                const SizedBox(width: 8),
                Text('${_weather!.current.tempC.round()}°C',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                Icon(Icons.info_outline,
                    size: 14, color: Colors.white.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Tapping the weather chip shows current + last-7-days weather, and
  // lets the farmer switch between district-based and real GPS-location
  // weather.
  // The sheet ONLY displays weather and reports which button was
  // tapped ('use_location' | 'use_district' | null) — it does NOT
  // perform the actual location/network work itself. That work runs
  // here, on HomeScreen's own stable context, AFTER the sheet has
  // fully closed. This is the same safe pattern used to fix the
  // earlier sign-out crash: never do async work using state or a
  // context that belongs to a sheet that might already be rebuilding
  // or closing — it created stale-closure timing bugs that could
  // crash the app.
  Future<void> _showWeatherDetail() async {
    if (_weather == null) return;
    final w = _weather!;
    final iconLabel = WeatherService.iconFor(
        w.current.weatherCode, si: _si, isDay: w.current.isDay);

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 20, 24, MediaQuery.of(ctx).viewInsets.bottom + 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(children: [
                Icon(iconLabel.icon, size: 40, color: Colors.amber[700]),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${w.current.tempC.round()}°C',
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                      Text(iconLabel.label,
                          style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    ],
                  ),
                ),
                Icon(
                    w.isDeviceLocation
                        ? Icons.my_location
                        : Icons.location_on_outlined,
                    size: 16, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    w.isDeviceLocation
                        ? (w.placeName ?? (_si ? 'ඔබේ ස්ථානය' : 'Your location'))
                        : localizedDistrict(w.sourceLabel, _si),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              _weatherDetailRow(Icons.water_drop_outlined,
                  _si ? 'ආර්ද්‍රතාවය' : 'Humidity',
                  '${w.current.humidityPct.round()}%'),
              const SizedBox(height: 10),
              _weatherDetailRow(Icons.grain,
                  _si ? 'දැන් වැසි' : 'Rain right now',
                  '${w.current.precipitationMm.toStringAsFixed(1)} mm'),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Text(
                  _si
                      ? '0.0 mm කියන්නේ මේ මොහොතේ වැසි නොවීමයි — පසුගිය දින සතියේ වර්ෂාපතනය පහත බලන්න.'
                      : '0.0 mm just means it isn\'t raining right now — see this week\'s total below.',
                  style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                      fontStyle: FontStyle.italic),
                ),
              ),
              const SizedBox(height: 16),

              if (w.recentDays.isNotEmpty) ...[
                const Divider(height: 28),
                Text(
                  _si ? 'පසුගිය දින 7 වර්ෂාපතනය' : 'Last 7 days rainfall',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _si
                      ? 'මුළු එකතුව: ${w.weekRainfallTotalMm.toStringAsFixed(1)} mm'
                      : 'Week total: ${w.weekRainfallTotalMm.toStringAsFixed(1)} mm',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const SizedBox(height: 10),
                ...w.recentDays.map((d) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 70,
                            child: Text(
                              '${d.date.day}/${d.date.month}',
                              style: TextStyle(color: Colors.grey[700], fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '${d.minTempC.round()}–${d.maxTempC.round()}°C',
                              style: TextStyle(color: Colors.grey[600], fontSize: 12),
                            ),
                          ),
                          Text(
                            '${d.precipitationSumMm.toStringAsFixed(1)} mm',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    )),
              ],

              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 16),

              // Unified location picker — lets the farmer view weather
              // for ANY of the 4 project districts directly, independent
              // of whatever crop/district they've picked elsewhere in
              // the app for price prediction. Previously there was no
              // way to choose a district here at all — only a generic
              // "switch back to district weather" button that always
              // reused the last prediction-selection district.
              Text(_si ? 'ස්ථානය තෝරන්න' : 'Choose location',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...['Galle', 'Matara', 'Kandy', 'Matale'].map((d) {
                    final isCurrent = !w.isDeviceLocation && w.sourceLabel == d;
                    return ChoiceChip(
                      label: Text(localizedDistrict(d, _si)),
                      selected: isCurrent,
                      onSelected: (_) => Navigator.pop(ctx, 'use_district:$d'),
                    );
                  }),
                  ChoiceChip(
                    avatar: Icon(Icons.my_location, size: 16,
                        color: w.isDeviceLocation
                            ? Colors.white
                            : Colors.grey[700]),
                    label: Text(_si ? 'මගේ ස්ථානය' : 'My location'),
                    selected: w.isDeviceLocation,
                    onSelected: (_) => Navigator.pop(ctx, 'use_location'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _si ? 'මූලාශ්‍රය: Open-Meteo' : 'Source: Open-Meteo',
                style: TextStyle(
                    color: Colors.grey[500], fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
    );

    // Sheet is fully closed now — safe to do the real async work using
    // HomeScreen's own stable context.
    if (action == 'use_location') {
      final ok = await _enableDeviceLocationWeather();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? (_si ? 'ස්ථාන කාලගුණය සක්‍රීයයි' : 'Location weather enabled')
              : (_si
                  ? 'ස්ථානය ලබාගත නොහැක. ස්ථාන අවසරය දෙන්න.'
                  : 'Could not get location. Please grant location permission.')),
        ));
      }
    } else if (action != null && action.startsWith('use_district:')) {
      final chosenDistrict = action.split(':')[1];
      await _showWeatherForDistrict(chosenDistrict);
    }
  }

  // Fetches and displays weather for a SPECIFIC district the farmer
  // picked directly in the location picker — independent of whatever
  // district they've selected elsewhere for crop price prediction.
  Future<void> _showWeatherForDistrict(String district) async {
    // Same fix as _enableDeviceLocationWeather — show the spinner and
    // clear old data right away instead of leaving the previous
    // district's weather visible while the new one is still fetching.
    if (mounted) setState(() { _weatherIsLoading = true; _weather = null; });
    await WeatherService.setUseDeviceLocation(false);
    final w = await WeatherService.fetchWeather(
      useDeviceLocation: false,
      fallbackDistrict: district,
    );
    if (mounted) setState(() { _weather = w; _weatherIsLoading = false; });
  }

  Widget _weatherDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: TextStyle(color: Colors.grey[700]))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }

  // Long-press on the profile icon opens admin login — this is where
  // that hidden gesture lives now that the farmer login screen (which
  // used to host it via its logo) has been removed.
  void _openAdminLogin() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
  }

  // ── Settings sheet ─────────────────────────────────────────
  // No more account to manage here — just the language preference.
  // Biometric quick-login and sign-out were removed along with the
  // login screen, since there's no account to unlock into or sign
  // out of anymore.
  void _openProfileSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _SettingsSheet(
        si: _si,
        onLanguageChanged: () {
          if (mounted) _loadLanguage();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _buildError(theme)
                : _buildContent(theme),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ChatbotScreen())),
        backgroundColor: theme.colorScheme.primary,
        icon: const Icon(Icons.chat_bubble_outline, color: Colors.white),
        label: Text(
          _si ? 'AI සහාය' : 'AI Help',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // ── Header banner ─────────────────────────────────────────
  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.colorScheme.primary, const Color(0xFF163F2A)],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: weather chip (left) + time-of-day icon + profile
          // button (right) — all compact, vertically centered against
          // each other. The sun/moon icon is decorative (always shows
          // the time of day) and sits separately from the weather chip
          // (which is tappable and shows the real fetched conditions).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _weatherChip(),
              const Spacer(),
              Icon(_greetingIcon(), size: 26, color: Colors.amber[300]),
              const SizedBox(width: 14),
              _headerIconButton(
                icon: Icons.person_outline,
                tooltip: _si ? 'සැකසුම්' : 'Settings',
                onTap: _openProfileSheet,
                onLongPress: _openAdminLogin,
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Greeting text — full width, own row, no longer competing
          // vertically against the weather block.
          Text(_greeting(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.bold,
              )),
          const SizedBox(height: 6),
          Text(
            _si
                ? 'ඔබේ භෝගයේ මිල අනාවැකිය බලන්න'
                : 'Check your crop price prediction',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    // NOTE: deliberately NOT wrapping the icon in a Tooltip widget.
    // Tooltip responds to long-press by default on touch devices (to
    // show its text bubble), which competed with onLongPress below
    // and silently swallowed it — that's why long-press for admin
    // login wasn't working. A tooltip isn't essential here, so it's
    // simplest and safest to just not have one on this button.
    //
    // Semantics (screen-reader label) is added separately here —
    // it's unrelated to Tooltip and has no gesture behaviour of its
    // own, so it doesn't reintroduce the conflict above. Without
    // this, a TalkBack/VoiceOver user would hear only "button" with
    // no indication of what it does — a real WCAG gap on an
    // icon-only control.
    return Semantics(
      label: tooltip,
      button: true,
      child: Material(
        color: Colors.white.withValues(alpha: 0.15),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            // 13 (not 10) so the total tappable area is 48x48dp —
            // the WCAG/Material Design minimum touch target size.
            // At the previous padding of 10 this button was 42x42,
            // genuinely under the minimum, not just a rounding gap.
            padding: const EdgeInsets.all(13),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Column(
      children: [
        _buildHeader(theme),
        Expanded(
          child: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                  onPressed: _loadMetadata,
                  icon: const Icon(Icons.refresh),
                  label: Text(_si ? 'නැවත උත්සාහ කරන්න' : 'Try again')),
            ]),
          )),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    final meta      = _metadata!;
    final crops     = meta.crops;
    final districts = _selectedCrop != null
        ? (meta.districtsByCrop[_selectedCrop] ?? [])
        : <String>[];
    // IMPORTANT: grades depend on BOTH crop AND district — a grade like
    // Cinnamon's M-5 only exists for Matara, never for Galle. Using the
    // old crop-only list would offer a grade that has zero rows for the
    // chosen district, guaranteeing a prediction failure. Falls back to
    // the old crop-only list only if the backend hasn't been restarted
    // yet with the new field (so the app never crashes either way).
    final grades = (_selectedCrop != null && _selectedDistrict != null)
        ? (meta.gradesByCropDistrict[_selectedCrop]?[_selectedDistrict] ??
            meta.gradesByCrop[_selectedCrop] ??
            <String>[])
        : <String>[];
    final canProceed = _selectedCrop != null &&
        _selectedDistrict != null && _selectedGrade != null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(theme),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(_si ? 'භෝගය තෝරන්න' : 'Select crop'),
                const SizedBox(height: 10),

                // Crop chips (replaces plain radio buttons)
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: crops.map((crop) {
                    final selected = crop == _selectedCrop;
                    final label = localizedCrop(crop, _si);
                    return Semantics(
                      label: label,
                      selected: selected,
                      button: true,
                      child: GestureDetector(
                      onTap: () => _onCropChanged(crop),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 15),
                        decoration: BoxDecoration(
                          color: selected
                              ? theme.colorScheme.primary
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? theme.colorScheme.primary
                                : Colors.grey[300]!,
                            width: 1.4,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              crop.toLowerCase().contains('cinnamon')
                                  ? Icons.eco
                                  : Icons.grain,
                              size: 18,
                              color: selected ? Colors.white : Colors.grey[600],
                            ),
                            const SizedBox(width: 8),
                            Text(localizedCrop(crop, _si),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: selected ? Colors.white : Colors.black87,
                                )),
                          ],
                        ),
                      ),
                    ),
                    );
                  }).toList(),
                ),

                if (_selectedCrop != null) ...[
                  const SizedBox(height: 28),
                  _sectionLabel(_si ? 'දිස්ත්‍රික්කය' : 'District'),
                  const SizedBox(height: 10),
                  _dropdownCard(
                      _si ? 'දිස්ත්‍රික්කය තෝරන්න' : 'Select district',
                      _selectedDistrict, districts, _onDistrictChanged,
                      labelFor: (d) => localizedDistrict(d, _si)),
                ],

                // Grade only becomes choosable once a district is picked
                // too, since grade options genuinely differ by district
                // (e.g. Cinnamon's M-5 only exists for Matara).
                if (_selectedCrop != null && _selectedDistrict != null) ...[
                  const SizedBox(height: 24),
                  _sectionLabel(_si ? 'ශ්‍රේණිය' : 'Grade'),
                  const SizedBox(height: 10),
                  _dropdownCard(
                      _si ? 'ශ්‍රේණිය තෝරන්න' : 'Select grade',
                      _selectedGrade, grades,
                      (v) => setState(() => _selectedGrade = v)),
                ],

                const SizedBox(height: 32),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: canProceed ? _navigateToResults : null,
                    icon: const Icon(Icons.analytics_outlined),
                    label: Text(
                      _si ? 'මිල අනාවැකිය බලන්න' : 'Get price prediction',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) => Text(label,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold));

  Widget _dropdownCard(String hint, String? value, List<String> items,
      ValueChanged<String?> onChanged, {String Function(String)? labelFor}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: DropdownButtonFormField<String>(
        value: value, hint: Text(hint), isExpanded: true,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        items: items
            .map((i) => DropdownMenuItem(
                value: i, child: Text(labelFor != null ? labelFor(i) : i)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }
}

// ============================================================
// SETTINGS BOTTOM SHEET
// No account to manage anymore — login was removed. Just lets the
// farmer switch between Sinhala and English.
// ============================================================
class _SettingsSheet extends StatefulWidget {
  final bool si;
  final VoidCallback onLanguageChanged;
  const _SettingsSheet({required this.si, required this.onLanguageChanged});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _si;

  @override
  void initState() {
    super.initState();
    _si = widget.si;
  }

  Future<void> _setLanguage(String lang) async {
    await LanguageService.setLanguage(lang);
    setState(() => _si = lang == 'si');
    widget.onLanguageChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(_si ? 'සැකසුම්' : 'Settings',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Text(_si ? 'භාෂාව' : 'Language',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _langOption(
                  label: 'සිංහල',
                  selected: _si,
                  onTap: () => _setLanguage('si'),
                  theme: theme,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _langOption(
                  label: 'English',
                  selected: !_si,
                  onTap: () => _setLanguage('en'),
                  theme: theme,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _langOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : Colors.grey[100],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.grey[300]!,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? theme.colorScheme.primary : Colors.black87,
              )),
        ),
      ),
    );
  }
}