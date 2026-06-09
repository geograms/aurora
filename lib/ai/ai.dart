/*
 * lib/ai/ — pluggable AI chat backends.
 *
 * One provider abstraction (AiProvider) over offline (Ollama, future built-in
 * on-device model) and online (OpenAI-compatible, Anthropic) chat APIs, with
 * streaming replies. Used by the wapp editor's Robot tab. Pure Dart.
 */

export 'ai_config.dart';
export 'ai_message.dart';
export 'ai_provider.dart';
export 'ai_providers.dart';
export 'ai_service.dart';
