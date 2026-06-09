/*
 * AiProvider — the abstraction over chat backends.
 *
 * Aurora talks to whatever model the user configured (offline Ollama, online
 * OpenAI/Anthropic, and — later — an on-device built-in model) through this
 * one interface. Adding a backend means implementing AiProvider and listing
 * it in ai_providers.dart; nothing else in the app needs to know the wire
 * format.
 *
 * Pure Dart (no Flutter) so it can be reused outside the launcher UI.
 */

import 'ai_config.dart';
import 'ai_message.dart';

/// Thrown by providers on a non-2xx response or unusable config, with a
/// human-readable message the chat surface shows inline.
class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

abstract class AiProvider {
  /// Stable id persisted in preferences (e.g. `ollama`).
  String get id;

  /// Human label for the provider dropdown.
  String get label;

  /// True for backends that run on the user's machine (no internet, no key).
  bool get isLocal;

  /// True when [AiConfig.apiKey] must be set (online hosted APIs).
  bool get requiresApiKey;

  /// Default endpoint base URL, used when the user leaves it blank.
  String get defaultBaseUrl;

  /// Default model id, used when the user leaves it blank.
  String get defaultModel;

  /// Stream the assistant's reply for [messages] as incremental text deltas.
  /// Implementations request streaming from the backend and yield each chunk
  /// of `content` as it arrives. Throws [AiException] on error.
  Stream<String> chat(List<AiMessage> messages, AiConfig config);
}
