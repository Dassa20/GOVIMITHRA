// ============================================================
// CHATBOT SCREEN — simple AI farming assistant
// Talks to the Flask backend's /chatbot route, which proxies to
// Gemini. The API key lives only on the backend — never shipped
// inside this app — so it can't be extracted from the APK.
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/language_service.dart';

class _ChatMessage {
  final String text;
  final bool isUser;
  _ChatMessage({required this.text, required this.isUser});
}

class ChatbotScreen extends StatefulWidget {
  const ChatbotScreen({super.key});
  @override
  State<ChatbotScreen> createState() => _ChatbotScreenState();
}

class _ChatbotScreenState extends State<ChatbotScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _sending = false;
  String _lang = 'en';
  bool get _si => _lang == 'si';

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final lang = await LanguageService.getLanguage();
    if (mounted) {
      setState(() {
        _lang = lang ?? 'en';
        _messages.add(_ChatMessage(
          text: _si
              ? 'ආයුබෝවන්! මම ඔබේ කෘෂිකාර්මික සහායකයා. කුරුඳු හෝ ගම්මිරිස් ගැන ඕනෑම ප්‍රශ්නයක් අහන්න.'
              : "Hi! I'm your farming assistant. Ask me anything about cinnamon or pepper farming.",
          isUser: false,
        ));
      });
    }
  }

  // DEA contact details are sent by the backend as a normal chat reply when the
  // farmer asks to contact a DEA officer (English or Sinhala). Phone numbers in
  // a reply such as "081 238 8651" are shown as tappable links that open the dialer.
  static final RegExp _phonePattern = RegExp(r'\b0\d{2} \d{3} \d{4}\b');

  Future<void> _callNumber(String number) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri(scheme: 'tel', path: number));
    } catch (_) {}
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: number));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_si ? 'අංකය පිටපත් කළා: $number' : 'Number copied: $number')));
      }
    }
  }

  Widget _messageText(_ChatMessage m) {
    final style = TextStyle(color: m.isUser ? Colors.white : Colors.black87);
    if (m.isUser) return Text(m.text, style: style);
    final matches = _phonePattern.allMatches(m.text).toList();
    if (matches.isEmpty) return Text(m.text, style: style);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final x in matches) {
      if (x.start > last) spans.add(TextSpan(text: m.text.substring(last, x.start)));
      final shown = x.group(0)!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => _callNumber(shown.replaceAll(' ', '')),
          child: Text(shown,
              style: style.copyWith(
                  color: Colors.blue[800], decoration: TextDecoration.underline)),
        ),
      ));
      last = x.end;
    }
    if (last < m.text.length) spans.add(TextSpan(text: m.text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _sending = true;
      _controller.clear();
    });
    _scrollToBottom();
    try {
      final reply = await ApiService.askChatbot(message: text, language: _lang);
      setState(() => _messages.add(_ChatMessage(
          text: reply.isNotEmpty
              ? reply
              : (_si ? 'සමාවන්න, උත්තරයක් නැත.' : 'Sorry, no answer came back.'),
          isUser: false)));
    } catch (e) {
      // The backend's error messages are already written to be
      // farmer-friendly (e.g. "You've reached today's chat limit,
      // try again tomorrow") — showing them directly is more useful
      // than always hiding them behind one generic message. Only
      // fall back to the generic message for raw technical failures
      // that never reached the backend at all (e.g. no internet).
      final raw = e.toString().replaceFirst('Exception: ', '');
      final looksTechnical = raw.isEmpty ||
          raw.contains('SocketException') ||
          raw.contains('TimeoutException') ||
          raw.contains('Failed host lookup');
      setState(() => _messages.add(_ChatMessage(
          text: looksTechnical
              ? (_si
                  ? 'සමාවන්න, දැන් උත්තර දෙන්න බැහැ. නැවත උත්සාහ කරන්න. DEA නිලධාරියෙකු අමතන්න ඕනේ නම්, "DEA නිලධාරියෙකු අමතන්න" කියා ටයිප් කරන්න.'
                  : "Sorry, I couldn't answer that right now. Please try again. To reach a DEA officer, type: contact DEA officer.")
              : raw,
          isUser: false)));
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_si ? 'කෘෂිකාර්මික AI සහායක' : 'Farming AI Assistant'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i == _messages.length) {
                  // Typing indicator while waiting for a reply
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final m = _messages[i];
                return Align(
                  alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: m.isUser
                          ? theme.colorScheme.primary
                          : Colors.grey[200],
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: _messageText(m),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText:
                            _si ? 'ප්‍රශ්නයක් ටයිප් කරන්න...' : 'Type a question...',
                        filled: true,
                        fillColor: Colors.grey[100],
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: theme.colorScheme.primary,
                    shape: const CircleBorder(),
                    child: IconButton(
                      // The tooltip is the spoken label for TalkBack and the
                      // handle the widget tests use to find this button.
                      tooltip: _si ? 'යවන්න' : 'Send',
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: _sending ? null : _send,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}