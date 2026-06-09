/*
 * DeepSeek provider — ONLINE.
 *
 * DeepSeek's API is OpenAI Chat-Completions-compatible, so it reuses
 * [OpenAiProvider]'s request/stream handling and only swaps the identity and
 * preconfigured endpoint/model.
 */

import 'openai_provider.dart';

class DeepSeekProvider extends OpenAiProvider {
  @override
  String get id => 'deepseek';

  @override
  String get label => 'DeepSeek (online)';

  @override
  String get defaultBaseUrl => 'https://api.deepseek.com';

  @override
  String get defaultModel => 'deepseek-chat';
}
