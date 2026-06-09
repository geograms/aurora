/*
 * RobotChatController — chat state + streaming for the editor's Robot tab.
 *
 * Holds the visible conversation, drives the selected AI provider (resolved
 * from PreferencesService), and streams the assistant's reply token-by-token.
 * The wapp's current files are injected as context on every turn so the model
 * can propose edits; it returns whole-file replacements in fenced
 * `geogram-file:<name>` blocks that the Robot UI turns into Apply buttons.
 *
 * UI-agnostic: a ChangeNotifier the Robot widget rebuilds from.
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/ai.dart';
import '../services/preferences_service.dart';

/// A whole-file replacement the AI proposed, parsed from a fenced
/// `geogram-file:<name>` block in an assistant message.
class ProposedFile {
  final String name; // 'main.c' | 'home.ui.json' | ...
  final String content;
  const ProposedFile(this.name, this.content);
}

/// One visible chat turn.
class RobotTurn {
  final AiRole role; // user | assistant
  String text;
  RobotTurn(this.role, this.text);
}

class RobotChatController extends ChangeNotifier {
  final List<RobotTurn> turns = [];

  /// The assistant text accumulating during a live stream (empty otherwise).
  String streaming = '';
  bool get busy => _sub != null;

  /// Last error, shown inline under the chat. Cleared on the next send.
  String? error;

  StreamSubscription<String>? _sub;

  /// Send [userText] to the model with the wapp's current files as context.
  Future<void> send(
    String userText, {
    required String currentMainC,
    required String currentUiJson,
  }) async {
    if (busy) return;
    final text = userText.trim();
    if (text.isEmpty) return;

    error = null;
    turns.add(RobotTurn(AiRole.user, text));
    streaming = '';
    notifyListeners();

    final prefs = PreferencesService.instanceSync;
    final provider = aiProviderById(prefs?.aiProviderId);
    final base = (prefs?.aiBaseUrl ?? '').trim();
    final model = (prefs?.aiModel ?? '').trim();
    final sysOverride = (prefs?.aiSystemPrompt ?? '').trim();
    final config = AiConfig(
      providerId: provider.id,
      baseUrl: base.isEmpty ? provider.defaultBaseUrl : base,
      model: model.isEmpty ? provider.defaultModel : model,
      apiKey: prefs?.aiApiKey ?? '',
      systemPrompt: sysOverride,
    );

    if (provider.requiresApiKey && config.apiKey.isEmpty) {
      error = '${provider.label} needs an API key — set it in the settings '
          'above.';
      notifyListeners();
      return;
    }

    final system = (sysOverride.isEmpty ? _defaultSystemPrompt : sysOverride) +
        _contextBlock(currentMainC, currentUiJson);
    final request = <AiMessage>[
      AiMessage.system(system),
      for (final t in turns) AiMessage(t.role, t.text),
    ];

    final service = AiService(provider: provider, config: config);
    final buffer = StringBuffer();
    _sub = service.sendChat(request).listen(
      (delta) {
        buffer.write(delta);
        streaming = buffer.toString();
        notifyListeners();
      },
      onError: (Object e) {
        error = e is AiException ? e.message : 'AI request failed: $e';
        _finishStream(buffer.toString());
      },
      onDone: () => _finishStream(buffer.toString()),
      cancelOnError: true,
    );
  }

  /// Stop an in-flight stream, keeping whatever streamed so far.
  void stop() {
    if (_sub == null) return;
    _finishStream(streaming);
  }

  void _finishStream(String finalText) {
    _sub?.cancel();
    _sub = null;
    if (finalText.trim().isNotEmpty) {
      turns.add(RobotTurn(AiRole.assistant, finalText));
    }
    streaming = '';
    notifyListeners();
  }

  void clear() {
    if (busy) return;
    turns.clear();
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ── File-block parsing ────────────────────────────────────────────────

  static final _fileBlock = RegExp(
    r'```geogram-file:([^\s`]+)[ \t]*\r?\n(.*?)```',
    dotAll: true,
  );

  /// Extract whole-file proposals from an assistant message.
  static List<ProposedFile> parseProposedFiles(String content) {
    return [
      for (final m in _fileBlock.allMatches(content))
        ProposedFile(m.group(1)!.trim(), (m.group(2) ?? '').trimRight()),
    ];
  }

  static String _contextBlock(String mainC, String uiJson) => '''

--- CURRENT WAPP FILES ---
The wapp being edited currently contains these files. Modify them as requested.

main.c:
$mainC

home.ui.json:
$uiJson
''';

  static const _defaultSystemPrompt = '''
You are the assistant inside Aurora's wapp editor. A "wapp" is a small app written in C (compiled to WebAssembly) whose screens are described declaratively in a GeoUI file, home.ui.json. The C `main.c` implements module_init/module_tick/module_handle_event against the geogram HAL; home.ui.json is a JSON array of screen blocks (\$:"screen") containing groups, fields and actions.

Help the user change the wapp. Be concise.

When you change a file, output its COMPLETE new contents (not a diff) in a fenced code block whose info string is `geogram-file:<filename>`, where <filename> is exactly `main.c` or `home.ui.json`. Example:

```geogram-file:home.ui.json
[ ... full updated JSON ... ]
```

Only include a file block for files you actually changed. Keep prose outside the blocks short.''';
}
