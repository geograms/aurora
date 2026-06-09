/*
 * Resolved AI configuration handed to a provider for one request.
 *
 * Built from PreferencesService (the user's saved settings) with the
 * selected provider's defaults filling any blanks (see AiService).
 */

class AiConfig {
  final String providerId;
  final String baseUrl;
  final String model;
  final String apiKey;
  final String systemPrompt;

  const AiConfig({
    required this.providerId,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    required this.systemPrompt,
  });
}
