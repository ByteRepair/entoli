import "package:clock/clock.dart";

import "../../../domain/provider_usage.dart";
import "openai_client.dart";

/// Groq through its OpenAI surface, keeping what its replies say of the
/// account's allowance. Groq has no endpoint that says it; every reply
/// carries it in documented `x-ratelimit-*` headers instead, so the last
/// reply's are what there is to show.
class GroqClient extends OpenAiClient {
  GroqClient({required super.baseUrl, super.apiKey, super.httpClient});

  /// The daily request allowance as of the last reply. Empty before one.
  List<UsageWindow> get usage => _usage;
  List<UsageWindow> _usage = const [];

  @override
  void responded(Map<String, String> headers) {
    final read = usageOfHeaders(headers, clock.now());
    if (read.isNotEmpty) _usage = read;
  }

  /// The requests-per-day pair from [headers], received at [now]. The
  /// tokens pair is per minute, a pace rather than an allowance, and is left
  /// out.
  static List<UsageWindow> usageOfHeaders(
    Map<String, String> headers,
    DateTime now,
  ) {
    final limit = double.tryParse(headers["x-ratelimit-limit-requests"] ?? "");
    final remaining = double.tryParse(
      headers["x-ratelimit-remaining-requests"] ?? "",
    );
    if (limit == null || remaining == null) return const [];
    final reset = durationOf(headers["x-ratelimit-reset-requests"] ?? "");
    return [
      UsageWindow(
        label: "Daily requests",
        used: limit - remaining,
        max: limit,
        unit: UsageUnit.requests,
        resetsAt: reset == null ? null : now.add(reset),
      ),
    ];
  }

  static final _part = RegExp(r"(\d+(?:\.\d+)?)(ms|h|m|s)");

  /// A Go duration as Groq writes the time until a reset — `2m59.56s`,
  /// `120ms`. Null for anything else.
  static Duration? durationOf(String text) {
    if (text.isEmpty || text.replaceAll(_part, "").isNotEmpty) return null;
    var micros = 0.0;
    for (final m in _part.allMatches(text)) {
      final value = double.parse(m[1]!);
      micros +=
          value *
          switch (m[2]!) {
            "h" => Duration.microsecondsPerHour,
            "m" => Duration.microsecondsPerMinute,
            "s" => Duration.microsecondsPerSecond,
            _ => Duration.microsecondsPerMillisecond,
          };
    }
    return Duration(microseconds: micros.round());
  }
}
