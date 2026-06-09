/*
 * Anthropic provider — ONLINE (Claude).
 *
 * POST {baseUrl}/v1/messages with stream:true. Anthropic differs from the
 * OpenAI shape in two ways handled here: the system prompt is a top-level
 * `system` field (not a message), and auth uses `x-api-key` +
 * `anthropic-version`. The SSE stream carries `content_block_delta` events
 * whose delta.text is the token.
 */

import 'dart:convert';

import '../../connections/internet/http_transport.dart';
import '../ai_config.dart';
import '../ai_message.dart';
import '../ai_provider.dart';
import '../stream_lines.dart';

class AnthropicProvider extends AiProvider {
  @override
  String get id => 'anthropic';

  @override
  String get label => 'Anthropic / Claude (online)';

  @override
  bool get isLocal => false;

  @override
  bool get requiresApiKey => true;

  @override
  String get defaultBaseUrl => 'https://api.anthropic.com';

  @override
  String get defaultModel => 'claude-sonnet-4-6';

  @override
  Stream<String> chat(List<AiMessage> messages, AiConfig config) async* {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/v1/messages');

    // Anthropic takes the system prompt separately and only user/assistant
    // turns in `messages`.
    final system = messages
        .where((m) => m.role == AiRole.system)
        .map((m) => m.content)
        .join('\n\n');
    final turns = [
      for (final m in messages.where((m) => m.role != AiRole.system))
        {'role': m.roleName, 'content': m.content},
    ];

    final body = jsonEncode({
      'model': config.model,
      'max_tokens': 4096,
      'stream': true,
      if (system.isNotEmpty) 'system': system,
      'messages': turns,
    });

    final res = await HttpTransport.shared.postStream(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (config.apiKey.isNotEmpty) 'x-api-key': config.apiKey,
      },
      body: body,
    );
    if (!res.isOk) {
      throw AiException('Anthropic API returned HTTP ${res.statusCode} '
          '(check the model and API key)');
    }

    await for (final line in lineStream(res.stream)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (obj['type'] == 'content_block_delta') {
        final delta = obj['delta'];
        if (delta is Map && delta['text'] is String) {
          yield delta['text'] as String;
        }
      } else if (obj['type'] == 'message_stop') {
        return;
      }
    }
  }
}
