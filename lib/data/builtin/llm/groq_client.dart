import "../../../domain/provider_usage.dart";
import "rate_limit_client.dart";

/// Groq through its OpenAI surface. Groq has no endpoint that says what is
/// spent; every reply carries it in documented `x-ratelimit-*` headers
/// instead: the requests a day and the tokens a minute.
class GroqClient extends RateLimitClient {
  GroqClient({required super.baseUrl, super.apiKey, super.httpClient});

  @override
  List<RateLimitHeader> get rateLimits => const [
    RateLimitHeader("requests", "Daily requests", UsageUnit.requests),
    RateLimitHeader(
      "tokens",
      "Tokens per minute",
      UsageUnit.tokens,
      pace: true,
    ),
  ];
}
