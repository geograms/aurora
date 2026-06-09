/*
 * The set of AI providers the editor knows about. Ordered for the provider
 * dropdown (offline first). Add a backend by implementing AiProvider and
 * appending it here — the Robot UI and AiService pick it up automatically.
 */

import 'ai_provider.dart';
import 'providers/anthropic_provider.dart';
import 'providers/builtin_provider.dart';
import 'providers/deepseek_provider.dart';
import 'providers/ollama_provider.dart';
import 'providers/openai_provider.dart';

/// All providers, in display order.
final List<AiProvider> aiProviders = [
  OllamaProvider(),
  OpenAiProvider(),
  AnthropicProvider(),
  DeepSeekProvider(),
  BuiltinProvider(),
];

/// Look a provider up by [AiProvider.id], falling back to the first (Ollama)
/// for an unknown/blank id so the editor always has a working default.
AiProvider aiProviderById(String? id) => aiProviders.firstWhere(
      (p) => p.id == id,
      orElse: () => aiProviders.first,
    );
