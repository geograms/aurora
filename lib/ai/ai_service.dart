/*
 * AiService — the seam between the app and a chosen provider.
 *
 * Deliberately thin: it pairs a resolved [AiProvider] with the [AiConfig] to
 * use and forwards chat requests. Keeping it provider-neutral (no dependency
 * on app preferences) lets lib/ai stay a reusable subsystem — the caller
 * resolves config from wherever it likes (the editor reads PreferencesService).
 */

import 'ai_config.dart';
import 'ai_message.dart';
import 'ai_provider.dart';

class AiService {
  final AiProvider provider;
  final AiConfig config;

  const AiService({required this.provider, required this.config});

  /// Stream the assistant reply for the full [messages] list.
  Stream<String> sendChat(List<AiMessage> messages) =>
      provider.chat(messages, config);
}
