/*
 * OpenAI-compatible provider — ONLINE.
 *
 * Works with any backend that speaks the Chat Completions API: OpenAI,
 * OpenRouter, LM Studio, llama.cpp's server, Ollama's /v1 shim, etc. POST
 * {baseUrl}/v1/chat/completions with stream:true returns Server-Sent Events
 * — `data: {json}` lines whose choices[0].delta.content carries each token,
 * terminated by `data: [DONE]`.
 */

import 'dart:convert';

import '../../connections/internet/http_transport.dart';
import '../ai_config.dart';
import '../ai_message.dart';
import '../ai_provider.dart';
import '../stream_lines.dart';

class OpenAiProvider extends AiProvider {
  @override
  String get id => 'openai';

  @override
  String get label => 'OpenAI-compatible (online)';

  @override
  bool get isLocal => false;

  @override
  bool get requiresApiKey => true;

  @override
  String get defaultBaseUrl => 'https://api.openai.com';

  @override
  String get defaultModel => 'gpt-4o-mini';

  @override
  Stream<String> chat(List<AiMessage> messages, AiConfig config) async* {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/v1/chat/completions');
    final body = jsonEncode({
      'model': config.model,
      'stream': true,
      'messages': [
        for (final m in messages) {'role': m.roleName, 'content': m.content},
      ],
    });

    final res = await HttpTransport.shared.postStream(
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      },
      body: body,
    );
    if (!res.isOk) {
      throw AiException('$label returned HTTP ${res.statusCode} '
          '(check the base URL, model and API key)');
    }

    await for (final line in lineStream(res.stream)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') return;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final choices = obj['choices'];
      if (choices is List && choices.isNotEmpty) {
        final delta = (choices.first as Map)['delta'];
        if (delta is Map && delta['content'] is String) {
          yield delta['content'] as String;
        }
      }
    }
  }
}
