import "../../../domain/provider_usage.dart";
import "rate_limit_client.dart";

/// OpenAI's own API. Its documented `x-ratelimit-*` reply headers carry the
/// requests and tokens a minute, and the project's tokens a minute where a
/// project-scoped limit applies. All of them are paces; OpenAI's spend is in
/// usage reports that want an admin key.
class OpenAiPlatformClient extends RateLimitClient {
  OpenAiPlatformClient({
    required super.baseUrl,
    super.apiKey,
    super.httpClient,
  });

  /// OpenAI renamed the field, and its reasoning models refuse the old one.
  @override
  String get maxTokensField => "max_completion_tokens";

  @override
  List<RateLimitHeader> get rateLimits => const [
    RateLimitHeader(
      "requests",
      "Requests per minute",
      UsageUnit.requests,
      pace: true,
    ),
    RateLimitHeader(
      "tokens",
      "Tokens per minute",
      UsageUnit.tokens,
      pace: true,
    ),
    RateLimitHeader(
      "project-tokens",
      "Project tokens per minute",
      UsageUnit.tokens,
      pace: true,
    ),
  ];
}
