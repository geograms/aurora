/*
 * Chat message model shared across AI providers.
 *
 * Provider-neutral: each provider maps these to its own wire format
 * (OpenAI {role,content}, Anthropic system+messages, Ollama messages).
 */

enum AiRole { system, user, assistant }

class AiMessage {
  final AiRole role;
  final String content;

  const AiMessage(this.role, this.content);

  const AiMessage.system(this.content) : role = AiRole.system;
  const AiMessage.user(this.content) : role = AiRole.user;
  const AiMessage.assistant(this.content) : role = AiRole.assistant;

  String get roleName => role.name;
}
