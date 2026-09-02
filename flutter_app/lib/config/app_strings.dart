// ============================================================
// APP STRINGS — minimal Sinhala/English strings for the
// onboarding + language + welcome flow.
//
// This is intentionally small: it covers ONLY the new intro
// screens. Your existing screens keep their current text.
// Full app-wide translation can be added later as future work.
//
// Usage:  AppStrings.get('welcome_title', lang)
// ============================================================
class AppStrings {
  // lang is 'si' (Sinhala) or 'en' (English)
  static String get(String key, String lang) {
    final map = (lang == 'si') ? _si : _en;
    return map[key] ?? _en[key] ?? key;
  }

  static const Map<String, String> _en = {
    // Onboarding slides
    'ob1_title': 'Agricultural Knowledge',
    'ob1_body' : 'Cultivation, maintenance and disease remedies for export crops — all in one place.',
    'ob2_title': 'Support from Officers',
    'ob2_body' : 'An easy way to discuss your issues with agriculture officers.',
    'ob3_title': 'Digital Marketplace',
    'ob3_body' : 'A digital space to sell your produce and buy at the best prices.',
    'ob4_title': 'Grow Knowledge & Skills',
    'ob4_body' : 'A chance to grow your knowledge and skills through a digital system.',
    'ob_skip'  : 'Skip',
    'ob_next'  : 'Next',
    'ob_start' : 'Get Started',

    // Language screen
    'choose_language': 'Choose your language',
    'lang_sinhala'   : 'සිංහල',
    'lang_english'   : 'English',
    'continue'       : 'Continue',

    // Welcome / account screen
    'welcome_title'  : 'Welcome',
    'welcome_sub'    : 'Cinnamon & Pepper — Sri Lanka',
    'create_account' : 'Create a new account',
    'existing_account': 'Go to existing account',
  };

  static const Map<String, String> _si = {
    // Onboarding slides
    'ob1_title': 'කෘෂි භෝග දැනුම',
    'ob1_body' : 'අපනයන කෘෂි භෝග වගාව, නඩත්තු කිරීම, රෝග වලට පිළියම් ඇතුළු බොහෝ දැනුම එක තැනකින්',
    'ob2_title': 'කෘෂි නිලධාරීන්ගේ සහාය',
    'ob2_body' : 'ඔබගේ ගැටළු කෘෂි නිලධාරීන් සමඟ සාකච්ඡා කිරීමට පහසුම ක්‍රමය',
    'ob3_title': 'ඩිජිටල් වෙළඳපොළ',
    'ob3_body' : 'ඔබගේ නිෂ්පාදන විකිණීමටත්, හොඳම නිෂ්පාදන මිලදී ගැනීමටත්, ඩිජිටල් අවකාශය',
    'ob4_title': 'දැනුම සහ කුසලතා වර්ධනය',
    'ob4_body' : 'ඩිජිටල් ක්‍රමයෙන් ඔබේ දැනුම සහ කුසලතා වර්ධනයට අවස්ථාව',
    'ob_skip'  : 'මඟ හරින්න',
    'ob_next'  : 'ඊළඟ',
    'ob_start' : 'පටන් ගන්න',

    // Language screen
    'choose_language': 'ඔබගේ භාෂාව තෝරන්න',
    'lang_sinhala'   : 'සිංහල',
    'lang_english'   : 'English',
    'continue'       : 'ඉදිරියට',

    // Welcome / account screen
    'welcome_title'  : 'සාදරයෙන් පිළිගනිමු',
    'welcome_sub'    : 'කුරුඳු සහ ගම්මිරිස් — ශ්‍රී ලංකාව',
    'create_account' : 'අලුත් ගිණුමක් සාදන්න',
    'existing_account': 'පරණ ගිණුමට යන්න',
  };
}
