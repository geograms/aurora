/*
 * Built-in provider — STUB for a future on-device model.
 *
 * The roadmap is for each client to ship its own local LLM so the editor's
 * Robot works with no setup and no network. That model isn't here yet; this
 * placeholder keeps the abstraction honest (it shows in the dropdown as
 * unavailable) so wiring it up later is a drop-in.
 */

import '../ai_config.dart';
import '../ai_message.dart';
import '../ai_provider.dart';

class BuiltinProvider extends AiProvider {
  @override
  String get id => 'builtin';

  @override
  String get label => 'Built-in model (coming soon)';

  @override
  bool get isLocal => true;

  @override
  bool get requiresApiKey => false;

  @override
  String get defaultBaseUrl => '';

  @override
  String get defaultModel => '';

  @override
  Stream<String> chat(List<AiMessage> messages, AiConfig config) {
    throw AiException(
        'The built-in on-device model is not available yet — pick Ollama '
        '(offline) or an online provider in the settings above.');
  }
}
