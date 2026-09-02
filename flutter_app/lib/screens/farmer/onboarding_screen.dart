// ============================================================
// ONBOARDING SCREEN
// Two intro slides (Cinnamon + Pepper), Sinhala text.
// Auto-advancing, shown ONLY on first launch → language screen.
// Images are landscape, shown as a top banner with text below.
// Images load from assets/onboarding/ (see pubspec.yaml).
// ============================================================
import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/language_service.dart';
import 'language_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  // Two slides: Cinnamon (n.jpg) and Pepper (n2.jpg).
  final List<_Slide> _slides = const [
    _Slide(
      image: 'assets/onboarding/n.jpg',
      title: 'කුරුඳු',
      body : 'ශ්‍රී ලංකාවේ අපනයන කෘෂි භෝගයක් වන කුරුඳු වගාව, අස්වනු නෙලීම, '
             'වියළීම සහ වෙළඳපොළ මිල පිළිබඳ දැනුම එක තැනකින්.',
    ),
    _Slide(
      image: 'assets/onboarding/n2.jpg',
      title: 'ගම්මිරිස්',
      body : 'ගම්මිරිස් වගාව, අස්වනු නෙලීම සහ දිනපතා වෙළඳපොළ මිල ගණන් '
             'ඔබේ දුරකථනයෙන්ම බලා ගන්න.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _startAutoAdvance();
  }

  void _startAutoAdvance() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      final next = (_page + 1) % _slides.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    _timer?.cancel();
    await LanguageService.markOnboardingSeen();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LanguageScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = _page == _slides.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12, top: 8),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('මඟ හරින්න'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) {
                  setState(() => _page = i);
                  _startAutoAdvance();
                },
                itemBuilder: (ctx, i) {
                  final s = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: AspectRatio(
                            aspectRatio: 16 / 10,
                            child: Image.asset(
                              s.image,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              // Without this, a screen reader gets
                              // nothing meaningful from this image at
                              // all — the slide's own title already
                              // names the crop, so it's reused here
                              // as a reasonable text alternative.
                              semanticLabel: s.title,
                              errorBuilder: (c, e, st) => Container(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.08),
                                child: Icon(Icons.image_outlined,
                                    size: 56,
                                    color: theme.colorScheme.primary
                                        .withValues(alpha: 0.4)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          s.title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          s.body,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.grey[700],
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Semantics(
              label: 'පිටුව ${_page + 1} න් ${_slides.length}',
              child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_slides.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    if (isLast) {
                      _finish();
                    } else {
                      _controller.nextPage(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                  child: Text(isLast ? 'පටන් ගන්න' : 'ඊළඟ'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slide {
  final String image;
  final String title;
  final String body;
  const _Slide({required this.image, required this.title, required this.body});
}