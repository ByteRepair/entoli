import "package:clock/clock.dart";
import "package:http/http.dart" as http;

import "../../../../domain/llm_provider.dart";
import "../../../../domain/provider_usage.dart";
import "../http_stream.dart";
import "../llm_client.dart";
import "provider.dart";

class OpenRouterProvider extends OpenAiCompatibleProvider {
  const OpenRouterProvider([LlmProviderConfig config = preset])
    : super(config, _terms);

  static const preset = LlmProviderConfig(
    catalogId: "openrouter",
    name: "OpenRouter",
    api: LlmApi.openai,
    baseUrl: "https://openrouter.ai/api/v1",
    apiKeyEnv: "OPENROUTER_API_KEY",
    defaultModelId: "z-ai/glm-5.3-flash",
    defaultLightModelId: "nvidia/nemotron-3-nano-30b-a3b",
  );

  static const _terms = PresetTerms(
    blurb: "One key for hundreds of models from many providers.",
    prompts: PromptUse.dependsOnRoute,
    policy: "https://openrouter.ai/privacy",
    keyUrl: "https://openrouter.ai/settings/keys",
  );

  @override
  String get imageModel => "google/gemini-2.5-flash-image";

  /// `/key` describes the key it is asked with; the model list is public.
  @override
  String get keyCheckPath => "key";

  /// The key's spending cap, from the same `/key`: its documented answer
  /// says how much of the cap is left and which period it resets over. A key
  /// with no cap has no allowance to show.
  @override
  Future<List<UsageWindow>> usage(
    LlmClient client,
    String? apiKey, {
    http.Client? httpClient,
  }) async {
    final json = await LlmProvider.getJson(
      under(baseUrl, "key"),
      headers: authOf(apiKey),
      httpClient: httpClient,
    );
    return usageOfKey(json, clock.now());
  }

  /// [json], `/key`'s answer, as the cap it describes at [now].
  static List<UsageWindow> usageOfKey(Map<String, dynamic> json, DateTime now) {
    final data = json["data"];
    if (data is! Map<String, dynamic>) return const [];
    final limit = (data["limit"] as num?)?.toDouble();
    if (limit == null) return const [];
    final remaining = (data["limit_remaining"] as num?)?.toDouble() ?? limit;
    final reset = data["limit_reset"];
    return [
      UsageWindow(
        label: switch (reset) {
          "daily" => "Daily",
          "weekly" => "Weekly",
          "monthly" => "Monthly",
          _ => "Credit limit",
        },
        used: limit - remaining,
        max: limit,
        unit: UsageUnit.usd,
        resetsAt: reset is String ? nextReset(reset, now) : null,
      ),
    ];
  }

  /// When a cap that resets every [period] starts again after [now]. Its
  /// periods are UTC's: a day from midnight, a week from Monday, a month from
  /// the first.
  static DateTime? nextReset(String period, DateTime now) {
    final utc = now.toUtc();
    final midnight = DateTime.utc(utc.year, utc.month, utc.day);
    return switch (period) {
      "daily" => midnight.add(const Duration(days: 1)),
      "weekly" => midnight.add(Duration(days: 8 - utc.weekday)),
      "monthly" => DateTime.utc(utc.year, utc.month + 1),
      _ => null,
    };
  }
}
