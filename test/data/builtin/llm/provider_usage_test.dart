import "dart:convert";

import "package:clock/clock.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/builtin/llm/groq_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/openai_platform_client.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/data/builtin/llm/rate_limit_client.dart";
import "package:agent_chat/domain/provider_usage.dart";
import "package:agent_chat/app/provider_usage_words.dart";

import "sse.dart";

void main() {
  // A Wednesday, mid-month, in UTC.
  final now = DateTime.utc(2026, 11, 4, 15, 30);

  group("Rate limits off a reply", () {
    test("a Go duration, as both hosts write the time to a reset", () {
      expect(
        RateLimitClient.durationOf("2m59.56s"),
        const Duration(minutes: 2, seconds: 59, milliseconds: 560),
      );
      expect(RateLimitClient.durationOf("6m0s"), const Duration(minutes: 6));
      expect(
        RateLimitClient.durationOf("120ms"),
        const Duration(milliseconds: 120),
      );
      expect(
        RateLimitClient.durationOf("1h2m"),
        const Duration(hours: 1, minutes: 2),
      );
      expect(RateLimitClient.durationOf("soon"), isNull);
      expect(RateLimitClient.durationOf(""), isNull);
    });

    List<UsageWindow> read(RateLimitClient client, Map<String, String> h) =>
        RateLimitClient.usageOfHeaders(client.rateLimits, h, now);

    final groq = GroqClient(baseUrl: Uri.parse("https://api.groq.com/v1"));
    final openAi = OpenAiPlatformClient(
      baseUrl: Uri.parse("https://api.openai.com/v1"),
    );

    test("Groq's daily requests and tokens per minute", () {
      expect(
        read(groq, {
          "x-ratelimit-limit-requests": "14400",
          "x-ratelimit-remaining-requests": "14370",
          "x-ratelimit-reset-requests": "2m59.56s",
          "x-ratelimit-limit-tokens": "18000",
          "x-ratelimit-remaining-tokens": "17997",
          "x-ratelimit-reset-tokens": "7.66s",
        }),
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
          UsageWindow(
            label: "Tokens per minute",
            used: 3,
            max: 18000,
            unit: UsageUnit.tokens,
            resetsAt: now.add(const Duration(seconds: 7, milliseconds: 660)),
          ),
        ],
      );
    });

    test("OpenAI's requests, tokens and project tokens per minute", () {
      expect(
        read(openAi, {
          "x-ratelimit-limit-requests": "60",
          "x-ratelimit-remaining-requests": "59",
          "x-ratelimit-reset-requests": "1s",
          "x-ratelimit-limit-tokens": "150000",
          "x-ratelimit-remaining-tokens": "149984",
          "x-ratelimit-reset-tokens": "6m0s",
          "x-ratelimit-limit-project-tokens": "60000",
          "x-ratelimit-remaining-project-tokens": "57000",
          "x-ratelimit-reset-project-tokens": "3s",
        }),
        [
          UsageWindow(
            label: "Requests per minute",
            used: 1,
            max: 60,
            unit: UsageUnit.requests,
            resetsAt: now.add(const Duration(seconds: 1)),
          ),
          UsageWindow(
            label: "Tokens per minute",
            used: 16,
            max: 150000,
            unit: UsageUnit.tokens,
            resetsAt: now.add(const Duration(minutes: 6)),
          ),
          UsageWindow(
            label: "Project tokens per minute",
            used: 3000,
            max: 60000,
            unit: UsageUnit.tokens,
            resetsAt: now.add(const Duration(seconds: 3)),
          ),
        ],
      );
    });

    test(
      "a pair that cannot be read, or a pace with no reset, is left out",
      () {
        expect(
          read(openAi, {
            // A pace with nothing to say how old it is.
            "x-ratelimit-limit-requests": "60",
            "x-ratelimit-remaining-requests": "59",
            "x-ratelimit-limit-tokens": "not a number",
            "x-ratelimit-remaining-tokens": "3",
            "x-ratelimit-reset-tokens": "1s",
            "x-ratelimit-limit-project-tokens": "10",
            "x-ratelimit-remaining-project-tokens": "-1",
            "x-ratelimit-reset-project-tokens": "1s",
          }),
          isEmpty,
        );
        // A daily allowance with no reset is still an allowance.
        expect(
          read(groq, {
            "x-ratelimit-limit-requests": "1000",
            "x-ratelimit-remaining-requests": "999",
          }).single.resetsAt,
          isNull,
        );
        expect(read(groq, const {}), isEmpty);
      },
    );

    test("the client keeps its last reply's, each until its reset", () async {
      final client = OpenAiPlatformClient(
        baseUrl: Uri.parse("https://api.openai.com/v1"),
        httpClient: MockClient.streaming(
          (_, _) async => sseResponse(
            const ["[DONE]"],
            headers: {
              "x-ratelimit-limit-requests": "60",
              "x-ratelimit-remaining-requests": "59",
              "x-ratelimit-reset-requests": "1s",
              "x-ratelimit-limit-tokens": "150000",
              "x-ratelimit-remaining-tokens": "149984",
              "x-ratelimit-reset-tokens": "6m0s",
            },
          ),
        ),
      );
      List<String> shownAt(Duration later) => withClock(
        Clock.fixed(now.add(later)),
        () => [for (final window in client.reportedUsage) window.label],
      );

      expect(client.reportedUsage, isEmpty);
      await withClock(
        Clock.fixed(now),
        () => client.stream(const [], model: "gpt-test").toList(),
      );
      expect(shownAt(Duration.zero), [
        "Requests per minute",
        "Tokens per minute",
      ]);
      expect(shownAt(const Duration(seconds: 2)), ["Tokens per minute"]);
      expect(shownAt(const Duration(minutes: 7)), isEmpty);
    });
  });

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
      expect(OpenRouterPeriod.weekly.nextAfter(now), DateTime.utc(2026, 11, 9));
      expect(OpenRouterPeriod.daily.nextAfter(now), DateTime.utc(2026, 11, 5));
      // A Monday itself waits a whole week rather than none.
      expect(
        OpenRouterPeriod.weekly.nextAfter(DateTime.utc(2026, 11, 9, 1)),
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
      expect((usage.single as UsageWindow).used, 6);
    });

    test("an endpoint that answers otherwise is a failure, not nothing", () {
      expect(
        const OpenRouterProvider().usage(
          "sk-test",
          httpClient: MockClient((_) async => http.Response("nope", 500)),
        ),
        throwsA(isA<LlmException>()),
      );
    });
  });

  group("Ollama Cloud", () {
    test("the plan's credits are an allowance, bought ones a balance", () {
      expect(
        OllamaCloudProvider.usageOf({
          "included": {
            "balance_usd": 72.5,
            "allowance_usd": 100,
            "period": {
              "from": "2026-10-15T09:30:00Z",
              "until": "2026-11-15T09:30:00Z",
            },
          },
          "purchased": {"balance_usd": 25},
        }),
        [
          UsageWindow(
            label: "Monthly credits",
            used: 27.5,
            max: 100,
            unit: UsageUnit.usd,
            resetsAt: DateTime.utc(2026, 11, 15, 9, 30),
          ),
          const CreditBalance(label: "Purchased credits", usd: 25),
        ],
      );
    });

    test("no bought credits is no balance row", () {
      expect(
        OllamaCloudProvider.usageOf({
          "included": {"balance_usd": 60, "allowance_usd": 60},
          "purchased": {"balance_usd": 0},
        }),
        const [
          UsageWindow(
            label: "Monthly credits",
            used: 0,
            max: 60,
            unit: UsageUnit.usd,
          ),
        ],
      );
    });

    test("a plan from before credits gives its session and weekly limits", () {
      expect(
        OllamaCloudProvider.usageOf({
          "included": {
            "session": {
              "remaining_percent": 75,
              "resets_at": "2026-10-01T07:00:00Z",
            },
            "weekly": {
              "remaining_percent": 40,
              "resets_at": "2026-10-05T00:00:00Z",
            },
          },
          "purchased": {"balance_usd": 0},
        }),
        [
          UsageWindow(
            label: "Session",
            used: 0.25,
            max: 1,
            unit: UsageUnit.share,
            resetsAt: DateTime.utc(2026, 10, 1, 7),
          ),
          UsageWindow(
            label: "Weekly",
            used: 0.6,
            max: 1,
            unit: UsageUnit.share,
            resetsAt: DateTime.utc(2026, 10, 5),
          ),
        ],
      );
    });

    test("asks ollama.com's /api/balance, not under /v1", () async {
      final asked = <Uri>[];
      await const OllamaCloudProvider().usage(
        "key",
        httpClient: MockClient((request) async {
          asked.add(request.url);
          return http.Response("{}", 200);
        }),
      );
      expect(asked.single.toString(), "https://ollama.com/api/balance");
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
          const UsageWindow(
            label: "Tokens",
            used: 1200,
            max: 5000,
            unit: UsageUnit.tokens,
          ),
          now,
        ),
        "Tokens: 1200 of 5000 tokens",
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
      expect(
        describeUsage(
          const CreditBalance(label: "Purchased credits", usd: 25),
          now,
        ),
        r"Purchased credits: $25.00 left",
      );
    });
  });
}
