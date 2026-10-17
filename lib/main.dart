import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

// Run with: flutter run --dart-define=GEMINI_API_KEY=your_key
// (For a public release, proxy Gemini through your own backend instead of shipping a key.)
const _apiKey = String.fromEnvironment('GEMINI_API_KEY');
/// Models to try in order, best first. When one hits its quota (or is unavailable),
/// the next is used. Replace these names with ones from AI Studio's model list.
const _modelChain = <String>[
  'gemini-3.8-flash',
  'gemini-3.5-flash-lite',
  'gemini-3.6-flash',
];

/// How long to skip a model after it fails with a quota/availability error.
const _cooldown = Duration(minutes: 5);

/// Master prompt: edit this to change how the assistant behaves.
const _masterPrompt = '''
You are a screen assistant. The image is a screenshot of the user's phone.
Your job: find every question visible on the screen (quiz, form, chat, document, etc.) and answer it.

Rules:
- For each question, write the question number or a short quote of it, then the answer.
- For multiple choice, give the correct option's letter and text.
- Add a one-line explanation only when it helps.
- If the question is unclear or cut off, say what is missing instead of guessing.
- If no question is visible, say so in one sentence and briefly describe what is on screen.
- Ignore the status bar and any floating assistant icon.
- Be concise. Reply in the same language as the question.
''';

/// Sent together with the screenshot.
const _userPrompt = 'Answer the question(s) shown in this screenshot.';
const _channel = MethodChannel('ai_assistant/screen_capture');

const double _iconSize = 70;
const double _cardW = 340;
const double _cardH = 480;

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: HomePage(),
));

/// Overlay entry point: runs in its own Flutter engine/isolate.
@pragma("vm:entry-point")
void overlayMain() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(color: Colors.transparent, child: FloatingChatHead()),
  ));
}

// ───────────────────────── Main app ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '';

  Future<void> _overlayPermission() async {
    var ok = await FlutterOverlayWindow.isPermissionGranted();
    if (!ok) ok = await FlutterOverlayWindow.requestPermission() ?? false;
    setState(() => _status = ok ? 'Overlay permission granted' : 'Overlay permission denied');
  }

  Future<void> _start() async {
    if (_apiKey.isEmpty) {
      setState(() => _status = 'Missing --dart-define=GEMINI_API_KEY');
      return;
    }
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      setState(() => _status = 'Grant overlay permission first');
      return;
    }
    // Screen capture starts here and stops when you press "Stop assistant".
    final ok = await _channel.invokeMethod<bool>('requestPermission') ?? false;
    if (!ok) {
      setState(() => _status = 'Screen capture denied');
      return;
    }
    if (await FlutterOverlayWindow.isActive()) await FlutterOverlayWindow.closeOverlay();
    await FlutterOverlayWindow.showOverlay(
      width: _iconSize.toInt(),
      height: _iconSize.toInt(),
      alignment: OverlayAlignment.centerRight,
      enableDrag: true,
      flag: OverlayFlag.defaultFlag,
      positionGravity: PositionGravity.auto,
      overlayTitle: 'AI Assistant',
      overlayContent: 'Floating assistant is running',
    );
    final attached = await _channel.invokeMethod<bool>('attachOverlay') ?? false;
    setState(() => _status = attached
        ? 'Assistant running'
        : 'Overlay started, but its engine was not found (check overlayEngineTag in MainActivity)');
  }

  Future<void> _stop() async {
    await FlutterOverlayWindow.closeOverlay();
    await _channel.invokeMethod('stopCapture'); // ends the screen-capture session
    setState(() => _status = 'Assistant stopped');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Floating AI Assistant')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(onPressed: _overlayPermission, child: const Text('1. Grant overlay permission')),
            const SizedBox(height: 12),
            FilledButton(onPressed: _start, child: const Text('2. Start assistant')),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _stop, child: const Text('Stop assistant')),
            const SizedBox(height: 24),
            Text(_status, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Overlay UI (does capture + Gemini itself) ─────────────────────────

enum _Mode { idle, loading, expanded }

class FloatingChatHead extends StatefulWidget {
  const FloatingChatHead({super.key});
  @override
  State<FloatingChatHead> createState() => _FloatingChatHeadState();
}

class _FloatingChatHeadState extends State<FloatingChatHead> {
  final Map<String, DateTime> _coolDownUntil = {};
  String _usedModel = '';
  _Mode _mode = _Mode.idle;
  String _text = '';

  Future<void> _onTap() async {
    if (_mode != _Mode.idle) return;
    try {
      // Hide ourselves so we're not in the screenshot.
      await FlutterOverlayWindow.resizeOverlay(1, 1, false);
      await Future.delayed(const Duration(milliseconds: 400));
      final Uint8List? bytes = await _channel
          .invokeMethod<Uint8List>('capture')
          .timeout(const Duration(seconds: 5));
      if (bytes == null) {
        throw 'Screen capture is not active. Open the app and tap "Allow screen capture".';
      }
      setState(() => _mode = _Mode.loading);
      await FlutterOverlayWindow.resizeOverlay(_iconSize.toInt(), _iconSize.toInt(), true);
      await _show(await _askGemini(bytes));
    } catch (e) {
      await _show('Error: $e');
    }
  }

  /// Quota, overload and "model not found" errors move on to the next model.
  /// Anything else (bad API key, etc.) is shown immediately.
  bool _canFallBack(Object e) {
    if (e is TimeoutException) return true;
    final m = e.toString().toLowerCase();
    return ['429', 'quota', 'resource_exhausted', 'rate limit', '503', 'unavailable',
      'overloaded', '404', 'not found', 'not supported']
        .any(m.contains);
  }

  Future<String> _askGemini(Uint8List bytes) async {
    Object? lastError;
    for (final name in _modelChain) {
      final until = _coolDownUntil[name];
      if (until != null && DateTime.now().isBefore(until)) continue;
      try {
        final model = GenerativeModel(
          model: name,
          apiKey: _apiKey,
          systemInstruction: Content.system(_masterPrompt),
        );
        final res = await model.generateContent([
          Content.multi([TextPart(_userPrompt), DataPart('image/jpeg', bytes)]),
        ]).timeout(const Duration(seconds: 45));
        _usedModel = name;
        return res.text ?? 'No response.';
      } catch (e) {
        if (!_canFallBack(e)) rethrow;
        lastError = e;
        _coolDownUntil[name] = DateTime.now().add(_cooldown);
      }
    }
    throw 'All models are unavailable right now. Last error: $lastError';
  }

  Future<void> _show(String text) async {
    _text = text;
    await FlutterOverlayWindow.resizeOverlay(_cardW.toInt(), _cardH.toInt(), false);
    if (mounted) setState(() => _mode = _Mode.expanded);
  }

  Future<void> _minimize() async {
    setState(() => _mode = _Mode.idle);
    await FlutterOverlayWindow.resizeOverlay(_iconSize.toInt(), _iconSize.toInt(), true);
  }

  @override
  Widget build(BuildContext context) =>
      _mode == _Mode.expanded ? _card() : _icon();

  Widget _icon() {
    return Center(
      child: GestureDetector(
        onTap: _onTap,
        child: Container(
          width: 60,
          height: 60,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(0xFF4285F4), Color(0xFF9B72CB)]),
            boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black38)],
          ),
          child: _mode == _Mode.loading
              ? const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
          )
              : const Icon(Icons.auto_awesome, color: Colors.white, size: 30),
        ),
      ),
    );
  }

  Widget _card() {
    return Card(
      margin: const EdgeInsets.all(4),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Color(0xFF4285F4)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gemini',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      if (_usedModel.isNotEmpty)
                        Text(_usedModel,
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: _minimize),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(_text, style: const TextStyle(fontSize: 15, height: 1.4)),
            ),
          ),
        ],
      ),
    );
  }
}