import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/groq_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/provider_usage.dart";
import "package:agent_chat/ui/settings/provider_usage_view.dart";

import "sse.dart";

void main() {
  // A Wednesday, mid-month, in UTC.
  final now = DateTime.utc(2026, 11, 4, 15, 30);

  group("OpenRouter", () {
    Map<String, dynamic> key({num? limit, num? remaining, String? reset}) => {
      "data": {
        "label": "sk-or-v1-abc",
        "limit": limit,
        "limit_remaining": remaining,
        "limit_reset": reset,
        "usage": 40.0,
      },
    };

    test("a capped key is what is spent of its cap, resetting by period", () {
      expect(
        OpenRouterProvider.usageOfKey(
          key(limit: 300, remaining: 212.5, reset: "monthly"),
          now,
        ),
        [
          UsageWindow(
            label: "Monthly",
            used: 87.5,
            max: 300,
            unit: UsageUnit.usd,
            resetsAt: DateTime.utc(2026, 12),
          ),
        ],
      );
    });

    test("a weekly cap resets on the next Monday, a daily one at midnight", () {
      expect(
        OpenRouterProvider.nextReset("weekly", now),
        DateTime.utc(2026, 11, 9),
      );
      expect(
        OpenRouterProvider.nextReset("daily", now),
        DateTime.utc(2026, 11, 5),
      );
      // A Monday itself waits a whole week rather than none.
      expect(
        OpenRouterProvider.nextReset("weekly", DateTime.utc(2026, 11, 9, 1)),
        DateTime.utc(2026, 11, 16),
      );
    });

    test("a cap that never resets says so, and no cap is nothing to show", () {
      expect(
        OpenRouterProvider.usageOfKey(
          key(limit: 50, remaining: 10),
          now,
        ).single,
        const UsageWindow(
          label: "Credit limit",
          used: 40,
          max: 50,
          unit: UsageUnit.usd,
        ),
      );
      expect(OpenRouterProvider.usageOfKey(key(), now), isEmpty);
    });

    test("asks /key with the key", () async {
      final asked = <http.Request>[];
      final usage = await const OpenRouterProvider().usage(
        const OpenRouterProvider().client(null),
        "sk-test",
        httpClient: MockClient((request) async {
          asked.add(request);
          return http.Response(
            jsonEncode(key(limit: 10, remaining: 4, reset: "daily")),
            200,
          );
        }),
      );
      expect(asked.single.url.toString(), "https://openrouter.ai/api/v1/key");
      expect(asked.single.headers["authorization"], "Bearer sk-test");
      expect(usage.single.used, 6);
    });

    test("an endpoint that answers otherwise is a failure, not nothing", () {
      expect(
        const OpenRouterProvider().usage(
          const OpenRouterProvider().client(null),
          "sk-test",
          httpClient: MockClient((_) async => http.Response("nope", 500)),
        ),
        throwsA(isA<LlmException>()),
      );
    });
  });

  group("Ollama Cloud", () {
    test("the session and weekly allowances are shares", () {
      expect(
        OllamaCloudProvider.usageOf({
          "limits": {
            "session": {"usage": 0.37},
            "weekly": {"usage": 0.12},
          },
        }),
        const [
          UsageWindow(
            label: "Session",
            used: 0.37,
            max: 1,
            unit: UsageUnit.share,
          ),
          UsageWindow(
            label: "Weekly",
            used: 0.12,
            max: 1,
            unit: UsageUnit.share,
          ),
        ],
      );
    });

    test("an answer with no limits in it is nothing to show", () {
      expect(
        OllamaCloudProvider.usageOf({
          "requests": [
            {"model": "glm-5.3-flash", "request_count": 12},
          ],
        }),
        isEmpty,
      );
    });

    test("asks ollama.com's /api/usage, not under /v1", () async {
      final asked = <Uri>[];
      await const OllamaCloudProvider().usage(
        const OllamaCloudProvider().client(null),
        "key",
        httpClient: MockClient((request) async {
          asked.add(request.url);
          return http.Response("{}", 200);
        }),
      );
      expect(asked.single.toString(), "https://ollama.com/api/usage");
    });
  });

  group("Groq", () {
    test("a Go duration, as Groq writes the time to a reset", () {
      expect(
        GroqClient.durationOf("2m59.56s"),
        const Duration(minutes: 2, seconds: 59, milliseconds: 560),
      );
      expect(GroqClient.durationOf("120ms"), const Duration(milliseconds: 120));
      expect(
        GroqClient.durationOf("1h2m"),
        const Duration(hours: 1, minutes: 2),
      );
      expect(GroqClient.durationOf("soon"), isNull);
      expect(GroqClient.durationOf(""), isNull);
    });

    test("the daily requests are read off a reply's headers", () {
      expect(
        GroqClient.usageOfHeaders({
          "x-ratelimit-limit-requests": "14400",
          "x-ratelimit-remaining-requests": "14370",
          "x-ratelimit-reset-requests": "2m59.56s",
          "x-ratelimit-limit-tokens": "18000",
        }, now),
        [
          UsageWindow(
            label: "Daily requests",
            used: 30,
            max: 14400,
            unit: UsageUnit.requests,
            resetsAt: now.add(
              const Duration(minutes: 2, seconds: 59, milliseconds: 560),
            ),
          ),
        ],
      );
      expect(GroqClient.usageOfHeaders(const {}, now), isEmpty);
    });

    test("the provider reports what its client's last reply said", () async {
      final client = GroqClient(
        baseUrl: Uri.parse("https://api.groq.com/openai/v1"),
        httpClient: MockClient.streaming(
          (_, _) async => sseResponse(
            const ["[DONE]"],
            headers: {
              "x-ratelimit-limit-requests": "1000",
              "x-ratelimit-remaining-requests": "999",
            },
          ),
        ),
      );
      const groq = GroqProvider();
      expect(await groq.usage(client, null), isEmpty);
      await client.stream(const [], model: "openai/gpt-oss-20b").toList();
      expect((await groq.usage(client, null)).single.used, 1);
    });
  });

  group("describeUsage", () {
    test("says what is spent of what, and when it starts again", () {
      expect(
        describeUsage(
          UsageWindow(
            label: "Monthly",
            used: 87.5,
            max: 300,
            unit: UsageUnit.usd,
            resetsAt: now.add(const Duration(days: 26, hours: 8)),
          ),
          now,
        ),
        r"Monthly: $87.50 of $300.00 · resets in 26 days",
      );
      expect(
        describeUsage(
          const UsageWindow(
            label: "Weekly",
            used: 0.123,
            max: 1,
            unit: UsageUnit.share,
          ),
          now,
        ),
        "Weekly: 12% used",
      );
      expect(
        describeUsage(
          UsageWindow(
            label: "Daily requests",
            used: 30,
            max: 14400,
            unit: UsageUnit.requests,
            resetsAt: now.add(const Duration(hours: 1, minutes: 5)),
          ),
          now,
        ),
        "Daily requests: 30 of 14400 requests · resets in 1 hour",
      );
    });
  });
}
