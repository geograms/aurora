/*
 * Ollama provider — OFFLINE / local.
 *
 * Talks to a locally-running Ollama daemon (`ollama serve`) over its native
 * chat API: POST {baseUrl}/api/chat with stream:true, which returns NDJSON —
 * one JSON object per line, each carrying a `message.content` delta and a
 * `done` flag. No API key, no internet.
 */

import 'dart:convert';

import '../../connections/internet/http_transport.dart';
import '../ai_config.dart';
import '../ai_message.dart';
import '../ai_provider.dart';
import '../stream_lines.dart';

class OllamaProvider extends AiProvider {
  @override
  String get id => 'ollama';

  @override
  String get label => 'Ollama (offline)';

  @override
  bool get isLocal => true;

  @override
  bool get requiresApiKey => false;

  @override
  String get defaultBaseUrl => 'http://localhost:11434';

  @override
  String get defaultModel => 'qwen2.5-coder';

  @override
  Stream<String> chat(List<AiMessage> messages, AiConfig config) async* {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/api/chat');
    final body = jsonEncode({
      'model': config.model,
      'stream': true,
      'messages': [
        for (final m in messages) {'role': m.roleName, 'content': m.content},
      ],
    });

    final res = await HttpTransport.shared.postStream(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: body,
    );
    if (!res.isOk) {
      throw AiException('Ollama returned HTTP ${res.statusCode} '
          '(is `ollama serve` running at $base?)');
    }

    await for (final line in lineStream(res.stream)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(trimmed) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final msg = obj['message'];
      if (msg is Map && msg['content'] is String) {
        yield msg['content'] as String;
      }
      if (obj['done'] == true) return;
    }
  }
}
