// ============================================================
// LANGUAGE SCREEN
// Choose Sinhala or English (no Tamil). Saves the choice, then
// routes straight to Home — login was removed, so there's no
// account/welcome screen to route to anymore.
// ============================================================
import 'package:flutter/material.dart';
import '../../services/language_service.dart';
import 'home_screen.dart';

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  String? _selected; // 'si' or 'en'

  Future<void> _continue() async {
    if (_selected == null) return;
    await LanguageService.setLanguage(_selected!);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Widget _langCard(String code, String label, String subtitle) {
    final theme = Theme.of(context);
    final selected = _selected == code;
    return Semantics(
      label: '$label, $subtitle',
      selected: selected,
      button: true,
      child: GestureDetector(
      onTap: () => setState(() => _selected = code),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.08)
              : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : Colors.grey[300]!,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.language,
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.grey[500]),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: selected
                              ? theme.colorScheme.primary
                              : Colors.black87)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
          ],
        ),
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Icon(Icons.eco,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 20),
              Text('ඔබගේ භාෂාව තෝරන්න',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Choose your language',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 32),

              _langCard('si', 'සිංහල', 'Sinhala'),
              _langCard('en', 'English', 'English'),

              const Spacer(),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _selected == null ? null : _continue,
                  child: Text(_selected == 'en' ? 'Continue' : 'ඉදිරියට'),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}