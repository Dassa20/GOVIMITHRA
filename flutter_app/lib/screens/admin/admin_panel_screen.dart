// ============================================================
// ADMIN PANEL SCREEN
// Super admin : Price Table | Submit Correction | Requests | Accounts | System | Settings
// DEA staff   : Price Table | Submit Correction | My Requests | Settings
//
// PERFORMANCE NOTE:
// The Price Table uses a lazy ListView.builder (NOT DataTable) so only the
// visible rows are ever built. DataTable lays out every row up front with no
// recycling, which can exhaust memory on low-end phones and get the app killed
// by the OS. This version builds ~20 rows regardless of dataset size.
// ============================================================
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../models/app_models.dart';

class AdminPanelScreen extends StatefulWidget {
  final String username;
  final String role;
  final String fullName;
  final String? district;
  final String? crop;

  const AdminPanelScreen({
    super.key,
    required this.username,
    required this.role,
    required this.fullName,
    this.district,
    this.crop,
  });

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool get isSuperAdmin => widget.role == 'super_admin';

  AppMetadata? _metadata;
  bool _metaLoading = true;

  // Selectors
  String? _selectedCrop;
  String? _selectedDistrict;
  String? _selectedGrade;

  // Price table
  List<PriceHistoryEntry> _filteredHistory = [];
  bool _historyLoading = false;
  DateTime? _fromDate;
  DateTime? _toDate;

  // Submit Correction form
  final _dateController     = TextEditingController();
  final _avgController      = TextEditingController();
  final _highController     = TextEditingController();
  final _rainController     = TextEditingController();
  final _tempController     = TextEditingController();
  final _humidityController = TextEditingController();
  final _notesController    = TextEditingController();
  final _corrFormKey        = GlobalKey<FormState>();
  bool _corrLoading         = false;

  // Requests (super admin)
  List<Map<String, dynamic>> _pendingRequests = [];
  bool _requestsLoading = false;

  // Accounts (super admin)
  List<AdminAccount> _accounts = [];
  bool _accountsLoading = false;
  final _newUserController  = TextEditingController();
  final _newPassController  = TextEditingController();
  final _newNameController  = TextEditingController();
  final _newEmailController = TextEditingController();
  String  _newRole     = 'dea_staff';
  String? _newDistrict;
  String? _newCrop;
  bool _newAccountLoading = false;

  // System
  bool    _retrainLoading = false;
  String? _retrainMessage;
  bool    _fetchLoading   = false;
  String? _fetchMessage;
  bool?   _chatbotConfigured; // null = still checking
  String? _chatbotModel;
  bool    _chatbotTestLoading = false;
  String? _chatbotTestResult;
  bool    _quotaResetLoading = false;
  String? _quotaResetMessage;
  final _chatbotTestController = TextEditingController();

  // Settings
  final _oldPassController = TextEditingController();
  final _newPassChangeCtrl = TextEditingController();
  bool    _cpLoading  = false;
  String? _cpMessage;

  // ── tab count ─────────────────────────────────────────────
  int get _tabCount => isSuperAdmin ? 6 : 4;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    _loadMetadata();
    _checkChatbotStatus();
    if (isSuperAdmin) {
      _loadPendingRequests();
      _loadAccounts();
    }
  }

  Future<void> _checkChatbotStatus() async {
    try {
      final res = await ApiService.getChatbotStatus();
      if (mounted) {
        setState(() {
          _chatbotConfigured = res['configured'] == true;
          _chatbotModel      = res['model'];
        });
      }
    } catch (e) {
      if (mounted) setState(() => _chatbotConfigured = false);
    }
  }

  Future<void> _sendChatbotTest() async {
    final msg = _chatbotTestController.text.trim();
    if (msg.isEmpty) return;
    setState(() { _chatbotTestLoading = true; _chatbotTestResult = null; });
    try {
      final reply = await ApiService.askChatbot(message: msg, language: 'en');
      if (mounted) setState(() => _chatbotTestResult = reply);
    } catch (e) {
      if (mounted) {
        setState(() => _chatbotTestResult =
            'Error: ${e.toString().replaceFirst("Exception: ", "")}');
      }
    } finally {
      if (mounted) setState(() => _chatbotTestLoading = false);
    }
  }

  // Testing convenience only (super admin) — resets THIS device's
  // today chatbot count, so testing isn't blocked by the same daily
  // fair-share limit real farmers are subject to. Does not affect any
  // other device or change the limit itself.
  Future<void> _resetMyChatbotQuota() async {
    setState(() { _quotaResetLoading = true; _quotaResetMessage = null; });
    try {
      final res = await ApiService.resetMyChatbotQuota(
          requestorUsername: widget.username);
      if (mounted) {
        setState(() => _quotaResetMessage = res['success'] == true
            ? "Today's quota reset for this device."
            : (res['error']?.toString() ?? 'Reset failed'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _quotaResetMessage =
            'Error: ${e.toString().replaceFirst("Exception: ", "")}');
      }
    } finally {
      if (mounted) setState(() => _quotaResetLoading = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _dateController.dispose();
    _avgController.dispose();
    _highController.dispose();
    _rainController.dispose();
    _tempController.dispose();
    _humidityController.dispose();
    _notesController.dispose();
    _newUserController.dispose();
    _newPassController.dispose();
    _newNameController.dispose();
    _newEmailController.dispose();
    _oldPassController.dispose();
    _newPassChangeCtrl.dispose();
    _chatbotTestController.dispose();
    super.dispose();
  }

  // ── helpers ───────────────────────────────────────────────
  void _snack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // ── data loaders ──────────────────────────────────────────
  Future<void> _loadMetadata() async {
    AppMetadata meta;
    try {
      meta = await ApiService.getMetadata()
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      if (!mounted) return;
      setState(() => _metaLoading = false);
      _snack('Cannot connect to server. Check Flask is running.',
          color: Colors.red);
      return;
    }
    if (!mounted) return;
    setState(() {
      _metadata    = meta;
      _metaLoading = false;

      // DEA staff: use assigned crop/district
      if (!isSuperAdmin) {
        if (widget.crop     != null) _selectedCrop     = widget.crop;
        if (widget.district != null) _selectedDistrict = widget.district;
      }

      // Auto-select first crop if nothing selected
      if (_selectedCrop == null && meta.crops.isNotEmpty) {
        _selectedCrop = meta.crops.first;
      }
      // Auto-select first district for selected crop
      if (_selectedDistrict == null && _selectedCrop != null) {
        final dists = meta.districtsByCrop[_selectedCrop] ?? [];
        if (dists.isNotEmpty) _selectedDistrict = dists.first;
      }
      // Auto-select first grade for selected crop+district
      if (_selectedGrade == null && _selectedCrop != null && _selectedDistrict != null) {
        final grades = meta.gradesByCropDistrict[_selectedCrop]?[_selectedDistrict] ??
            meta.gradesByCrop[_selectedCrop] ?? [];
        if (grades.isNotEmpty) _selectedGrade = grades.first;
      }

      // Default date range: 3 months back to today
      _fromDate ??= DateTime.now().subtract(const Duration(days: 90));
      _toDate   ??= DateTime.now();
    });

    if (_selectedCrop != null &&
        _selectedDistrict != null &&
        _selectedGrade != null) {
      _loadHistory();
    }
  }

  // Parse a DD.MM.YYYY string safely. Returns null on any malformed input
  // instead of throwing — malformed dates never crash the filter.
  DateTime? _parseDate(String raw) {
    try {
      final p = raw.split('.');
      if (p.length != 3) return null;
      final d = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      final y = int.tryParse(p[2]);
      if (d == null || m == null || y == null) return null;
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadHistory() async {
    if (_selectedCrop == null ||
        _selectedDistrict == null ||
        _selectedGrade == null) return;
    setState(() => _historyLoading = true);

    List<PriceHistoryEntry> h;
    try {
      h = await ApiService.adminGetHistory(
        district: _selectedDistrict!,
        crop: _selectedCrop!,
        grade: _selectedGrade!,
        limit: 200,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _filteredHistory = [];
        _historyLoading = false;
      });
      _snack('Could not load price history. Check the connection.',
          color: Colors.red);
      return;
    }

    // Apply date filter client-side (malformed dates are kept, not dropped).
    List<PriceHistoryEntry> filtered = h.reversed.toList();
    if (_fromDate != null) {
      filtered = filtered.where((e) {
        final d = _parseDate(e.date);
        return d == null ? true : !d.isBefore(_fromDate!);
      }).toList();
    }
    if (_toDate != null) {
      final upper = _toDate!.add(const Duration(days: 1));
      filtered = filtered.where((e) {
        final d = _parseDate(e.date);
        return d == null ? true : !d.isAfter(upper);
      }).toList();
    }

    if (!mounted) return;
    setState(() {
      _filteredHistory = List.from(filtered);
      _historyLoading = false;
    });
  }

  Future<void> _loadPendingRequests() async {
    setState(() => _requestsLoading = true);
    try {
      final r = await ApiService.getPendingRequests(
          requestorUsername: widget.username);
      if (!mounted) return;
      setState(() {
        _pendingRequests =
            List<Map<String, dynamic>>.from(r['requests'] ?? []);
        _requestsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _requestsLoading = false);
    }
  }

  Future<void> _loadAccounts() async {
    setState(() => _accountsLoading = true);
    try {
      final r = await ApiService.listAccounts(
          requestorUsername: widget.username);
      if (!mounted) return;
      setState(() {
        _accounts = (r['accounts'] as List)
            .map((a) => AdminAccount.fromJson(a))
            .toList();
        _accountsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _accountsLoading = false);
    }
  }

  // ── selector callbacks ────────────────────────────────────
  void _onCropChanged(String? c) => setState(() {
        _selectedCrop = c;
        _selectedDistrict = null;
        _selectedGrade = null;
        _filteredHistory = [];
      });

  void _onDistrictChanged(String? d) => setState(() {
        _selectedDistrict = d;
        _selectedGrade = null;
        _filteredHistory = [];
      });

  void _onGradeChanged(String? g) {
    setState(() {
      _selectedGrade = g;
      _filteredHistory = [];
    });
    _loadHistory();
  }

  // ── submit correction ─────────────────────────────────────
  Future<void> _submitCorrection() async {
    if (!_corrFormKey.currentState!.validate()) return;
    if (_selectedCrop == null ||
        _selectedDistrict == null ||
        _selectedGrade == null) return;
    setState(() => _corrLoading = true);
    try {
      Map<String, dynamic> result;
      if (isSuperAdmin) {
        result = await ApiService.editPrice(
          requestorUsername: widget.username,
          date: _dateController.text.trim(),
          district: _selectedDistrict!,
          crop: _selectedCrop!,
          grade: _selectedGrade!,
          avgPrice: double.parse(_avgController.text),
          highPrice: _highController.text.isNotEmpty
              ? double.tryParse(_highController.text) : null,
          rainfallMm: _rainController.text.isNotEmpty
              ? double.tryParse(_rainController.text) : null,
          tempC: _tempController.text.isNotEmpty
              ? double.tryParse(_tempController.text) : null,
          humidityPct: _humidityController.text.isNotEmpty
              ? double.tryParse(_humidityController.text) : null,
        );
      } else {
        result = await ApiService.requestEdit(
          submittedBy: widget.username,
          date: _dateController.text.trim(),
          district: _selectedDistrict!,
          crop: _selectedCrop!,
          grade: _selectedGrade!,
          avgPrice: double.parse(_avgController.text),
          highPrice: _highController.text.isNotEmpty
              ? double.tryParse(_highController.text) : null,
          rainfallMm: _rainController.text.isNotEmpty
              ? double.tryParse(_rainController.text) : null,
          tempC: _tempController.text.isNotEmpty
              ? double.tryParse(_tempController.text) : null,
          humidityPct: _humidityController.text.isNotEmpty
              ? double.tryParse(_humidityController.text) : null,
          notes: _notesController.text,
        );
      }
      if (!mounted) return;
      final ok = result['success'] == true;
      _snack(
        ok
            ? (isSuperAdmin
                ? 'Correction saved successfully'
                : 'Correction submitted for approval')
            : 'Failed: ${result['error']}',
        color: ok ? Colors.green : Colors.red,
      );
      if (ok) {
        _dateController.clear();
        _avgController.clear();
        _highController.clear();
        _rainController.clear();
        _tempController.clear();
        _humidityController.clear();
        _notesController.clear();
        _loadHistory();
      }
    } catch (e) {
      _snack('Error: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _corrLoading = false);
    }
  }

  // ── review request ────────────────────────────────────────
  Future<void> _reviewRequest(int requestId, String action) async {
    String note = '';
    if (action == 'reject') {
      final ctrl = TextEditingController();
      note = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Reason for rejection'),
              content: TextField(
                  controller: ctrl,
                  decoration:
                      const InputDecoration(hintText: 'Optional note')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, ''),
                    child: const Text('Skip')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, ctrl.text),
                    child: const Text('Reject')),
              ],
            ),
          ) ??
          '';
    }
    try {
      final result = await ApiService.reviewRequest(
        requestorUsername: widget.username,
        requestId: requestId,
        action: action,
        reviewNote: note,
      );
      if (!mounted) return;
      _snack(result['message'] ?? 'Done',
          color: action == 'approve' ? Colors.green : Colors.orange);
      _loadPendingRequests();
      _loadHistory();
    } catch (e) {
      _snack('Error: $e', color: Colors.red);
    }
  }

  // ── retrain ───────────────────────────────────────────────
  Future<void> _retrain() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Retrain model'),
              content: const Text('This takes 1–2 minutes. Continue?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Retrain')),
              ],
            ));
    if (ok != true) return;
    setState(() {
      _retrainLoading = true;
      _retrainMessage = null;
    });
    try {
      final r = await ApiService.adminRetrain();
      if (!mounted) return;
      setState(() => _retrainMessage = r['success'] == true
          ? 'Model retrained successfully'
          : 'Failed: ${r["error"]}');
    } catch (e) {
      if (mounted) setState(() => _retrainMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _retrainLoading = false);
    }
  }

  // ── auto fetch ────────────────────────────────────────────
  Future<void> _autoFetchWeather() async {
    setState(() {
      _fetchLoading = true;
      _fetchMessage = null;
    });
    try {
      final r = await ApiService.autoFetchWeather();
      if (mounted) setState(() => _fetchMessage = r['message'] ?? 'Done');
    } catch (e) {
      if (mounted) setState(() => _fetchMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _fetchLoading = false);
    }
  }

  Future<void> _autoFetchDea() async {
    setState(() {
      _fetchLoading = true;
      _fetchMessage = null;
    });
    try {
      final r = await ApiService.autoFetchDea();
      if (mounted) setState(() => _fetchMessage = r['message'] ?? 'Done');
    } catch (e) {
      if (mounted) setState(() => _fetchMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _fetchLoading = false);
    }
  }

  // ── create account ────────────────────────────────────────
  Future<void> _createAccount() async {
    if (_newUserController.text.isEmpty || _newPassController.text.isEmpty) {
      _snack('Username and password are required');
      return;
    }
    setState(() => _newAccountLoading = true);
    try {
      final r = await ApiService.createAccount(
        requestorUsername: widget.username,
        username: _newUserController.text.trim(),
        password: _newPassController.text,
        role: _newRole,
        fullName: _newNameController.text.trim(),
        district: _newDistrict,
        crop: _newCrop,
        email: _newEmailController.text.trim(),
      );
      if (!mounted) return;
      _snack(r['message'] ?? 'Done',
          color: r['success'] == true ? Colors.green : Colors.red);
      if (r['success'] == true) {
        _newUserController.clear();
        _newPassController.clear();
        _newNameController.clear();
        _newEmailController.clear();
        setState(() {
          _newDistrict = null;
          _newCrop = null;
        });
        _loadAccounts();
      }
    } catch (e) {
      _snack('Error: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _newAccountLoading = false);
    }
  }

  // ── change password ───────────────────────────────────────
  Future<void> _changePassword() async {
    setState(() {
      _cpLoading = true;
      _cpMessage = null;
    });
    try {
      final r = await ApiService.changePassword(
        username: widget.username,
        oldPassword: _oldPassController.text,
        newPassword: _newPassChangeCtrl.text,
      );
      if (!mounted) return;
      setState(() => _cpMessage = r['success'] == true
          ? 'Password changed successfully'
          : (r['error'] ?? 'Failed'));
      if (r['success'] == true) {
        _oldPassController.clear();
        _newPassChangeCtrl.clear();
      }
    } catch (e) {
      if (mounted) setState(() => _cpMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _cpLoading = false);
    }
  }

  // ══════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final superTabs = const [
      Tab(icon: Icon(Icons.table_chart_outlined),     text: 'Price Table'),
      Tab(icon: Icon(Icons.edit_note_outlined),       text: 'Submit Correction'),
      Tab(icon: Icon(Icons.pending_actions_outlined), text: 'Requests'),
      Tab(icon: Icon(Icons.people_outline),           text: 'Accounts'),
      Tab(icon: Icon(Icons.settings_suggest_outlined),text: 'System'),
      Tab(icon: Icon(Icons.manage_accounts_outlined), text: 'Settings'),
    ];
    final staffTabs = const [
      Tab(icon: Icon(Icons.table_chart_outlined), text: 'Price Table'),
      Tab(icon: Icon(Icons.edit_note_outlined),   text: 'Submit Correction'),
      Tab(icon: Icon(Icons.history_outlined),     text: 'My Requests'),
      Tab(icon: Icon(Icons.manage_accounts_outlined), text: 'Settings'),
    ];

    // Each tab is wrapped in a small error boundary: if ANY single
    // tab's content throws while building (for any reason), only
    // THAT tab shows an error message — the rest of the admin panel
    // keeps working, instead of the whole screen going blank with no
    // indication of what broke or why.
    Widget safeTab(String name, Widget Function() builder) {
      try {
        return builder();
      } catch (e, st) {
        print('  [$name tab build error] $e\n$st');
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 12),
                Text('$name tab failed to load:\n$e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.red)),
              ],
            ),
          ),
        );
      }
    }

    final superViews = [
      safeTab('Price Table', _buildPriceTable),
      safeTab('Submit Correction', _buildCorrectionForm),
      safeTab('Requests', _buildRequestsTab),
      safeTab('Accounts', _buildAccountsTab),
      safeTab('System', _buildSystemTab),
      safeTab('Settings', _buildSettingsTab),
    ];
    final staffViews = [
      safeTab('Price Table', _buildPriceTable),
      safeTab('Submit Correction', _buildCorrectionForm),
      safeTab('My Requests', _buildMyRequests),
      safeTab('Settings', _buildSettingsTab),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Admin Panel'),
              Text(
                '${widget.fullName.isNotEmpty ? widget.fullName : widget.username}'
                ' — ${isSuperAdmin ? "Super Admin" : "DEA Staff"}',
                style:
                    const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ]),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: isSuperAdmin ? superTabs : staffTabs,
        ),
      ),
      body: _metaLoading
          ? const Center(child: CircularProgressIndicator())
          : _metadata == null
              // This is the actual crash fix: _metaLoading can become
              // false WITHOUT _metadata ever being set (e.g. the network
              // request failed or timed out) — so this case must be
              // handled explicitly instead of assuming metadata is ready
              // just because loading finished. Without this check,
              // _buildSelectors() below force-unwraps a null _metadata
              // and crashes the whole screen.
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text(
                          'Could not load admin panel data.\n'
                          'Check that Flask is running and reachable.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() => _metaLoading = true);
                            _loadMetadata();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(children: [
                  // _buildSelectors() was the ONE piece not wrapped in an
                  // error boundary — it sits shared ABOVE all six tabs, so
                  // if it ever throws, it would blank out a large area
                  // identically regardless of which tab was selected,
                  // matching exactly what was being seen. Wrapping it the
                  // same way as the tabs either fixes this outright, or at
                  // minimum shows the real error text next time instead of
                  // blank space, so it's no longer a mystery either way.
                  safeTab('Selectors', _buildSelectors),
                  const Divider(height: 1),
                  Expanded(
                      child: TabBarView(
                          controller: _tabController,
                          children: isSuperAdmin ? superViews : staffViews)),
                ]),
    );
  }

  // ── shared selectors ──────────────────────────────────────
  Widget _buildSelectors() {
    final meta = _metadata!;
    final crops = isSuperAdmin
        ? meta.crops
        : (widget.crop != null ? [widget.crop!] : meta.crops);
    final allDist = _selectedCrop != null
        ? (meta.districtsByCrop[_selectedCrop] ?? <String>[])
        : <String>[];
    final districts = (!isSuperAdmin && widget.district != null)
        ? (allDist.contains(widget.district) ? [widget.district!] : allDist)
        : allDist;
    final grades = (_selectedCrop != null && _selectedDistrict != null)
        ? (meta.gradesByCropDistrict[_selectedCrop]?[_selectedDistrict] ??
            meta.gradesByCrop[_selectedCrop] ??
            <String>[])
        : <String>[];

    // NOTE: this row is deliberately kept shared across Price Table
    // AND Submit Correction — Submit Correction has no crop/district/
    // grade fields of its own (see the "Select crop, district and
    // grade above first" message in _buildCorrectionForm), it relies
    // entirely on this row above the tabs to know what it's editing.
    // Only the date-range/Search/Reset row below was Price-Table-
    // specific and made no sense on Submit Correction — that part has
    // been moved into _buildDateSearchReset(), called only from
    // _buildPriceTable() now, not shown on every tab any more.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Row(children: [
        Expanded(
            child: _miniDrop(
                'Crop', _selectedCrop, crops, _onCropChanged)),
        const SizedBox(width: 6),
        Expanded(
            child: _miniDrop('District', _selectedDistrict, districts,
                _onDistrictChanged)),
        const SizedBox(width: 6),
        Expanded(
            child: _miniDrop(
                'Grade', _selectedGrade, grades, _onGradeChanged)),
      ]),
    );
  }

  // Date-range filter + Search/Reset — genuinely Price-Table-specific
  // (filtering historical price rows), so this is now called only
  // from _buildPriceTable(), not shared across every tab.
  Widget _buildDateSearchReset() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: _datePick('From', _fromDate, (d) {
                  setState(() => _fromDate = d);
                  _loadHistory();
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _datePick('To', _toDate, (d) {
                  setState(() => _toDate = d);
                  _loadHistory();
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _loadHistory,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Search',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    final resetMeta = _metadata;
                    if (resetMeta == null) return;
                    setState(() {
                      if (!isSuperAdmin) {
                        _selectedCrop = widget.crop;
                        _selectedDistrict = widget.district;
                      } else {
                        _selectedCrop = resetMeta.crops.isNotEmpty
                            ? resetMeta.crops.first : null;
                        final dists = _selectedCrop != null
                            ? (resetMeta.districtsByCrop[_selectedCrop] ?? [])
                            : <String>[];
                        _selectedDistrict =
                            dists.isNotEmpty ? dists.first : null;
                      }
                      final grades = (_selectedCrop != null && _selectedDistrict != null)
                          ? (resetMeta.gradesByCropDistrict[_selectedCrop]?[_selectedDistrict] ??
                              resetMeta.gradesByCrop[_selectedCrop] ??
                              <String>[])
                          : <String>[];
                      _selectedGrade =
                          grades.isNotEmpty ? grades.first : null;
                      _filteredHistory = [];
                      _fromDate = DateTime.now()
                          .subtract(const Duration(days: 90));
                      _toDate = DateTime.now();
                    });
                    _loadHistory();
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Reset', style: TextStyle(fontSize: 12)),
                ),
              ),
            ]),
          ]),
    );
  }

  Widget _datePick(
      String label, DateTime? value, ValueChanged<DateTime> onPick) {
    final text = value != null
        ? '${value.day.toString().padLeft(2, '0')}.'
          '${value.month.toString().padLeft(2, '0')}.${value.year}'
        : label;
    return Semantics(
      label: '$label date picker, currently $text',
      button: true,
      child: InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime.now(),
            firstDate: DateTime(2025),
            lastDate: DateTime.now(),
          );
          if (d != null) onPick(d);
        },
        child: Container(
          // vertical: 14 (not 9) brings the total touch height much
          // closer to the 48dp WCAG/Material minimum than the
          // previous ~30dp, without changing this element's fixed
          // width (set by the SizedBox wrapping it elsewhere).
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[400]!),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            const Icon(Icons.calendar_today_outlined,
                size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: 12,
                        color: value != null
                            ? Colors.black87
                            : Colors.grey[500]))),
          ]),
        ),
      ),
    );
  }

  Widget _miniDrop(String label, String? value, List<String> items,
      ValueChanged<String?> fn) {
    // Guard: if the current value isn't in items, pass null to avoid the
    // "value not in items" assertion crash after crop/district switches.
    final safeValue = (value != null && items.contains(value)) ? value : null;
    return DropdownButtonFormField<String>(
      value: safeValue,
      hint: Text(label, style: const TextStyle(fontSize: 11)),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 11),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        isDense: true,
      ),
      items: items
          .map((i) => DropdownMenuItem(
              value: i,
              child: Text(i, style: const TextStyle(fontSize: 12))))
          .toList(),
      onChanged: fn,
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 1 — PRICE TABLE (lazy-built, memory-safe on low-end phones)
  // ══════════════════════════════════════════════════════════
  // Wrapper: the date/search/reset row must stay visible regardless
  // of the price table's own state (loading, empty, or showing real
  // rows) — moved to a wrapper rather than into the content method
  // itself, since that method has several early returns for those
  // different states.
  Widget _buildPriceTable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDateSearchReset(),
        Expanded(child: _buildPriceTableContent()),
      ],
    );
  }

  Widget _buildPriceTableContent() {
    if (_selectedGrade == null) {
      return const Center(
          child: Text('Select crop, district and grade above to view data',
              style: TextStyle(color: Colors.grey)));
    }
    if (_historyLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filteredHistory.isEmpty) {
      return Center(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('No data found',
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _loadHistory,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ]));
    }

    String season(String date) {
      if (!date.contains('.')) return '—';
      final m = int.tryParse(date.split('.')[1]) ?? 0;
      if (m >= 5 && m <= 9) return 'Yala';
      if (m >= 10 || m <= 2) return 'Maha';
      return 'Inter';
    }

    String harvest(String date, String crop) {
      if (!date.contains('.')) return '—';
      final m = int.tryParse(date.split('.')[1]) ?? 0;
      final harvestMonths = _metadata?.harvestMonths ?? {};
      final h = (harvestMonths[crop] as List?)?.cast<int>() ?? <int>[];
      return h.contains(m) ? '✓' : '—';
    }

    // Fixed column widths so the header aligns with each lazily-built row.
    const widths = <double>[86, 72, 72, 74, 76, 66, 78, 76, 62, 60];
    const gap = 8.0;
    final crop = _selectedCrop ?? '';
    final totalWidth =
        widths.fold<double>(0, (a, b) => a + b) + widths.length * gap + 16;

    Widget cell(String text, int col,
        {bool bold = false, Color? color, double fontSize = 12}) {
      return SizedBox(
        width: widths[col],
        child: Text(text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              color: color,
            )),
      );
    }

    Widget headerRow() {
      const labels = [
        'Date', 'Avg (Rs)', 'High (Rs)', 'Rain (mm)', 'Temp (°C)',
        'Hum (%)', 'Lag-1 (Rs)', 'MA-4 (Rs)', 'Harvest', 'Season',
      ];
      return Container(
        color: Colors.green[50],
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: List.generate(
              labels.length,
              (c) => Padding(
                    padding: const EdgeInsets.only(right: gap),
                    child: cell(labels[c], c, bold: true),
                  )),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              headerRow(),
              const Divider(height: 1),
              Expanded(
                // ListView.builder recycles rows — only visible ones build.
                child: ListView.builder(
                  itemCount: _filteredHistory.length,
                  itemExtent: 40,
                  itemBuilder: (ctx, i) {
                    final e = _filteredHistory[i];
                    final lag1 = i + 1 < _filteredHistory.length
                        ? _filteredHistory[i + 1].avgPrice : null;
                    final ma4 = i + 3 < _filteredHistory.length
                        ? (_filteredHistory[i].avgPrice +
                                _filteredHistory[i + 1].avgPrice +
                                _filteredHistory[i + 2].avgPrice +
                                _filteredHistory[i + 3].avgPrice) /
                            4
                        : null;
                    final harv = harvest(e.date, crop);

                    return Container(
                      decoration: BoxDecoration(
                        color: i.isEven ? Colors.white : Colors.grey[50],
                        border: Border(
                            bottom:
                                BorderSide(color: Colors.grey[200]!)),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      child: Row(children: [
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(e.date, 0)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                e.avgPrice.toStringAsFixed(0), 1,
                                bold: true)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                e.highPrice?.toStringAsFixed(0) ?? '—', 2)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                e.rainfallMm?.toStringAsFixed(1) ?? '—',
                                3)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                e.tempC?.toStringAsFixed(1) ?? '—', 4)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                e.humidityPct?.toStringAsFixed(1) ?? '—',
                                5)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(
                                lag1?.toStringAsFixed(0) ?? '—', 6)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child:
                                cell(ma4?.toStringAsFixed(0) ?? '—', 7)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(harv, 8,
                                bold: harv == '✓',
                                color: harv == '✓'
                                    ? Colors.green[700]
                                    : Colors.grey)),
                        Padding(
                            padding: const EdgeInsets.only(right: gap),
                            child: cell(season(e.date), 9, fontSize: 11)),
                      ]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 2 — SUBMIT CORRECTION
  // ══════════════════════════════════════════════════════════
  Widget _buildCorrectionForm() {
    final ready = _selectedCrop != null &&
        _selectedDistrict != null &&
        _selectedGrade != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _corrFormKey,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Submit Data Correction',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: isSuperAdmin ? Colors.green[50] : Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isSuperAdmin
                          ? Colors.green[200]!
                          : Colors.blue[200]!),
                ),
                child: Text(
                  isSuperAdmin
                      ? 'Use this form only to correct missing or incorrect weekly data. '
                        'Weekly prices are fetched automatically from exagri.info every hour. '
                        'Your correction will be saved directly to the database.'
                      : 'Use this form only to correct missing or incorrect weekly data. '
                        'Your correction will be submitted to the super admin for review before saving.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isSuperAdmin
                        ? Colors.green[800]
                        : Colors.blue[800],
                  ),
                ),
              ),
              if (!ready)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                      'Select crop, district and grade above first.',
                      style: TextStyle(
                          color: Colors.orange, fontSize: 13)),
                ),
              TextFormField(
                controller: _dateController,
                decoration: const InputDecoration(
                  labelText: 'Week date (DD.MM.YYYY) *',
                  prefixIcon: Icon(Icons.calendar_today_outlined),
                  hintText: '30.06.2026',
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  if (!RegExp(r'^\d{2}\.\d{2}\.\d{4}$').hasMatch(v)) {
                    return 'Format: DD.MM.YYYY';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _avgController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Average price (Rs/kg) *',
                  prefixIcon: Icon(Icons.currency_rupee),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  if (double.tryParse(v) == null) {
                    return 'Enter a valid number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _highController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Highest price (Rs/kg)',
                  prefixIcon: Icon(Icons.arrow_upward),
                  hintText: 'Optional',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                  'Weather data — leave blank to auto-fetch from NASA POWER',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: TextFormField(
                  controller: _rainController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Rain (mm)', isDense: true),
                )),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                  controller: _tempController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Temp (°C)', isDense: true),
                )),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                  controller: _humidityController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Humidity (%)', isDense: true),
                )),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: isSuperAdmin
                      ? 'Reason for correction (optional)'
                      : 'Reason for correction *',
                  prefixIcon: const Icon(Icons.edit_note_outlined),
                  hintText:
                      'e.g. Missing week, incorrect price from bulletin',
                ),
                validator: (v) {
                  if (!isSuperAdmin && (v == null || v.isEmpty)) {
                    return 'Required — explain the correction';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed:
                      (ready && !_corrLoading) ? _submitCorrection : null,
                  icon: _corrLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Icon(isSuperAdmin
                          ? Icons.save_outlined
                          : Icons.send_outlined),
                  label: Text(isSuperAdmin
                      ? 'Save Correction'
                      : 'Submit for Approval'),
                ),
              ),
            ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 3 — PENDING REQUESTS (super admin)
  // ══════════════════════════════════════════════════════════
  Widget _buildRequestsTab() {
    if (_requestsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pendingRequests.isEmpty) {
      return Center(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 48, color: Colors.green),
                const SizedBox(height: 12),
                const Text('No pending requests'),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                    onPressed: _loadPendingRequests,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh')),
              ]));
    }

    return RefreshIndicator(
      onRefresh: _loadPendingRequests,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _pendingRequests.length,
        itemBuilder: (ctx, i) {
          final req = _pendingRequests[i];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.pending_outlined,
                          color: Colors.orange, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(
                        '${req['crop']} — ${req['district']} — ${req['grade']}',
                        style:
                            const TextStyle(fontWeight: FontWeight.bold),
                      )),
                      Text(req['date'] ?? '',
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 12)),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      _chip(
                          'Avg',
                          'Rs.${req['avg_price']?.toStringAsFixed(0) ?? '—'}',
                          Colors.green),
                      if (req['high_price'] != null)
                        _chip(
                            'High',
                            'Rs.${req['high_price']?.toStringAsFixed(0)}',
                            Colors.blue),
                      if (req['rainfall_mm'] != null)
                        _chip(
                            'Rain',
                            '${req['rainfall_mm']?.toStringAsFixed(1)} mm',
                            Colors.teal),
                      if (req['temp_c'] != null)
                        _chip(
                            'Temp',
                            '${req['temp_c']?.toStringAsFixed(1)} °C',
                            Colors.orange),
                      if (req['humidity_pct'] != null)
                        _chip(
                            'Hum',
                            '${req['humidity_pct']?.toStringAsFixed(1)} %',
                            Colors.purple),
                    ]),
                    if ((req['notes'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Note: ${req['notes']}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600])),
                    ],
                    const SizedBox(height: 4),
                    Text(
                        'By: ${req['submitted_by']}  •  ${req['created_at']}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[500])),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: () =>
                            _reviewRequest(req['id'], 'reject'),
                        icon: const Icon(Icons.close,
                            color: Colors.red, size: 18),
                        label: const Text('Reject',
                            style: TextStyle(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red)),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                          child: ElevatedButton.icon(
                        onPressed: () =>
                            _reviewRequest(req['id'], 'approve'),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Approve'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green),
                      )),
                    ]),
                  ]),
            ),
          );
        },
      ),
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('$label: $value',
          style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold)),
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 3 (DEA) — MY REQUESTS
  // ══════════════════════════════════════════════════════════
  Widget _buildMyRequests() {
    return FutureBuilder<Map<String, dynamic>>(
      future: ApiService.getMyRequests(username: widget.username),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Could not load your requests',
                        style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                        onPressed: () => setState(() {}),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry')),
                  ]));
        }
        final requests = List<Map<String, dynamic>>.from(
            snap.data?['requests'] ?? []);
        if (requests.isEmpty) {
          return const Center(
              child: Text('No corrections submitted yet',
                  style: TextStyle(color: Colors.grey)));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: requests.length,
          itemBuilder: (ctx, i) {
            final req = requests[i];
            final status = req['status'] as String? ?? 'pending';
            final color = switch (status) {
              'approved' => Colors.green,
              'rejected' => Colors.red,
              _ => Colors.orange,
            };
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Icon(
                  switch (status) {
                    'approved' => Icons.check_circle,
                    'rejected' => Icons.cancel,
                    _ => Icons.pending,
                  },
                  color: color,
                ),
                title: Text(
                    '${req['crop']} — ${req['grade']} — ${req['district']}'),
                subtitle: Text(
                  'Rs.${req['avg_price']?.toStringAsFixed(0)}  |  ${req['date']}\n'
                  '${status.toUpperCase()}'
                  '${req['review_note'] != null && req['review_note'].toString().isNotEmpty ? "  Note: ${req['review_note']}" : ""}',
                ),
                isThreeLine: true,
              ),
            );
          },
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 4 — ACCOUNTS (super admin)
  // ══════════════════════════════════════════════════════════
  Widget _buildAccountsTab() {
    final allDist = (_metadata?.districtsByCrop.values
            .expand((e) => e)
            .toSet()
            .toList()
          ?..sort()) ??
        <String>[];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Create DEA Staff Account',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextFormField(
                controller: _newUserController,
                decoration: const InputDecoration(
                    labelText: 'Username *',
                    isDense: true,
                    prefixIcon: Icon(Icons.person_outline))),
            const SizedBox(height: 10),
            TextFormField(
                controller: _newPassController,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password *',
                    isDense: true,
                    prefixIcon: Icon(Icons.lock_outline))),
            const SizedBox(height: 10),
            TextFormField(
                controller: _newNameController,
                decoration: const InputDecoration(
                    labelText: 'Full name',
                    isDense: true,
                    prefixIcon: Icon(Icons.badge_outlined))),
            const SizedBox(height: 10),
            TextFormField(
                controller: _newEmailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Email',
                    isDense: true,
                    prefixIcon: Icon(Icons.email_outlined))),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _newRole,
              decoration: const InputDecoration(
                  labelText: 'Role', isDense: true),
              items: const [
                DropdownMenuItem(
                    value: 'dea_staff', child: Text('DEA Staff')),
                DropdownMenuItem(
                    value: 'super_admin', child: Text('Super Admin')),
              ],
              onChanged: (v) =>
                  setState(() => _newRole = v ?? 'dea_staff'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: _miniDrop('Assigned District', _newDistrict,
                      allDist, (v) => setState(() => _newDistrict = v))),
              const SizedBox(width: 8),
              Expanded(
                  child: _miniDrop(
                      'Assigned Crop',
                      _newCrop,
                      (_metadata?.crops ?? [])..sort(),
                      (v) => setState(() => _newCrop = v))),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _newAccountLoading ? null : _createAccount,
                icon: _newAccountLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.person_add_outlined),
                label: const Text('Create Account'),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            Text('Existing Accounts',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_accountsLoading)
              const Center(child: CircularProgressIndicator())
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${_accounts.length} accounts',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[600])),
                  TextButton.icon(
                    onPressed: _loadAccounts,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              ..._accounts.map((acc) => ListTile(
                    leading: Icon(
                      acc.role == 'super_admin'
                          ? Icons.admin_panel_settings
                          : Icons.person,
                      color: acc.role == 'super_admin'
                          ? Colors.purple
                          : Colors.green,
                    ),
                    title: Text(acc.fullName?.isNotEmpty == true
                        ? '${acc.fullName} (@${acc.username})'
                        : acc.username),
                    subtitle: Text(
                        '${acc.role}  |  ${acc.district ?? "All districts"}  |  ${acc.crop ?? "All crops"}'),
                    trailing: acc.username != widget.username
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red),
                            tooltip: 'Delete account: ${acc.username}',
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                        title:
                                            const Text('Delete account'),
                                        content: Text(
                                            'Delete ${acc.username}?'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(
                                                      ctx, false),
                                              child:
                                                  const Text('Cancel')),
                                          ElevatedButton(
                                              onPressed: () =>
                                                  Navigator.pop(
                                                      ctx, true),
                                              child:
                                                  const Text('Delete')),
                                        ],
                                      ));
                              if (ok == true) {
                                await ApiService.deleteAccount(
                                  requestorUsername: widget.username,
                                  targetUsername: acc.username,
                                );
                                _loadAccounts();
                              }
                            })
                        : null,
                  )),
            ],
          ]),
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 5 — SYSTEM (super admin)
  // ══════════════════════════════════════════════════════════
  Widget _buildSystemTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Auto Data Fetch',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'Fetch current weather from NASA POWER or scrape latest DEA price bulletin from exagri.info.',
                style:
                    TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: ElevatedButton.icon(
                onPressed: _fetchLoading ? null : _autoFetchWeather,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('NASA Weather'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal),
              )),
              const SizedBox(width: 12),
              Expanded(
                  child: ElevatedButton.icon(
                onPressed: _fetchLoading ? null : _autoFetchDea,
                icon: const Icon(Icons.download_outlined),
                label: const Text('DEA Prices'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue),
              )),
            ]),
            if (_fetchLoading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (_fetchMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8)),
                child: Text(_fetchMessage!,
                    style: TextStyle(
                        color: Colors.blue[800], fontSize: 13)),
              ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Retrain ML Model',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'After approving corrections, retrain the XGBoost model so it learns from the latest prices.',
                style:
                    TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 16),
            if (_retrainMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: _retrainMessage!.contains('success')
                      ? Colors.green[50]
                      : Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_retrainMessage!,
                    style: TextStyle(
                        color: _retrainMessage!.contains('success')
                            ? Colors.green[800]
                            : Colors.red)),
              ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _retrainLoading ? null : _retrain,
                icon: _retrainLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.model_training),
                label: Text(
                    _retrainLoading ? 'Retraining...' : 'Start Retraining'),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),

            // ── AI Chatbot Status — mirrors the same card already on
            // the web admin panel, so both places show this consistently ──
            Text('AI Chatbot Status',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'Checks whether the Gemini API key is configured on the server. Send a test message below to confirm it actually responds.',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 12),
            Row(children: [
              Icon(
                _chatbotConfigured == null
                    ? Icons.hourglass_empty
                    : _chatbotConfigured == true
                        ? Icons.check_circle
                        : Icons.cancel,
                size: 18,
                color: _chatbotConfigured == null
                    ? Colors.grey
                    : _chatbotConfigured == true
                        ? Colors.green[700]
                        : Colors.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _chatbotConfigured == null
                      ? 'Checking...'
                      : _chatbotConfigured == true
                          ? 'Configured — model: ${_chatbotModel ?? "?"}'
                          : 'Not configured — GEMINI_API_KEY is not set on the server',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _chatbotConfigured == true
                        ? Colors.green[800]
                        : (_chatbotConfigured == false ? Colors.red : Colors.grey[700]),
                  ),
                ),
              ),
              TextButton(
                onPressed: _checkChatbotStatus,
                child: const Text('Refresh', style: TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 16),
            TextFormField(
              controller: _chatbotTestController,
              decoration: const InputDecoration(
                labelText: 'Test message',
                hintText: 'e.g. How do I harvest cinnamon?',
                prefixIcon: Icon(Icons.chat_bubble_outline),
              ),
            ),
            const SizedBox(height: 12),
            if (_chatbotTestResult != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: _chatbotTestResult!.startsWith('Error')
                      ? Colors.red[50]
                      : Colors.green[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_chatbotTestResult!,
                    style: TextStyle(
                        fontSize: 13,
                        color: _chatbotTestResult!.startsWith('Error')
                            ? Colors.red
                            : Colors.green[900])),
              ),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _chatbotTestLoading ? null : _sendChatbotTest,
                icon: _chatbotTestLoading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send),
                label: Text(_chatbotTestLoading
                    ? 'Sending...' : 'Send Test Message'),
              ),
            ),
            const SizedBox(height: 12),
            // Testing convenience — resets today's usage count for
            // THIS device only, so testing isn't blocked by the same
            // daily fair-share limit real farmers are subject to.
            // Doesn't affect the limit itself or any other device.
            if (_quotaResetMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_quotaResetMessage!,
                    style: TextStyle(
                        fontSize: 12,
                        color: _quotaResetMessage!.startsWith('Error')
                            ? Colors.red
                            : Colors.green[700])),
              ),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: OutlinedButton.icon(
                onPressed: _quotaResetLoading ? null : _resetMyChatbotQuota,
                icon: _quotaResetLoading
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_quotaResetLoading
                    ? 'Resetting...'
                    : "Reset my device's daily chatbot quota",
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ]),
    );
  }

  // ══════════════════════════════════════════════════════════
  // TAB 6 — SETTINGS (all admins)
  // ══════════════════════════════════════════════════════════
  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Change Password',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _oldPassController,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Current password',
                  prefixIcon: Icon(Icons.lock_outline)),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _newPassChangeCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'New password',
                  prefixIcon: Icon(Icons.lock_open_outlined)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _cpLoading ? null : _changePassword,
                child: _cpLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Change Password'),
              ),
            ),
            if (_cpMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: _cpMessage!.contains('success')
                      ? Colors.green[50]
                      : Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_cpMessage!,
                    style: TextStyle(
                        color: _cpMessage!.contains('success')
                            ? Colors.green[800]
                            : Colors.red)),
              ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Account Info',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(widget.fullName.isNotEmpty
                  ? widget.fullName
                  : widget.username),
              subtitle: Text('${widget.role}'
                  '${widget.district != null ? "  |  ${widget.district}" : ""}'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text('Logout',
                    style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red)),
              ),
            ),
          ]),
    );
  }
}