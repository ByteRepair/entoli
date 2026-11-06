import "package:clock/clock.dart";

import "../../../domain/provider_usage.dart";
import "llm_client.dart";
import "openai_client.dart";

/// One `x-ratelimit-limit-*` / `x-ratelimit-remaining-*` pair a provider
/// documents on its replies, with the `x-ratelimit-reset-*` beside it.
class RateLimitHeader {
  const RateLimitHeader(
    this.suffix,
    this.label,
    this.unit, {
    this.pace = false,
  });

  /// What follows `x-ratelimit-limit-`: `requests`, `tokens`.
  final String suffix;

  /// Says the period, since the headers' names do not: "Daily requests",
  /// "Tokens per minute".
  final String label;
  final UsageUnit unit;

  /// A limit counted per minute: a pace rather than an allowance, which is
  /// true only until it resets. A reading of one with no reset time could be
  /// any age, so it is not kept.
  final bool pace;
}

/// An OpenAI-shaped host that says what is spent of its limits on every reply
/// rather than at an endpoint, in `x-ratelimit-*` headers. What the last reply
/// said is kept, and dropped once the time it said the limit resets has
/// passed: past it the limit is whole again, and a number still on screen
/// would be one that stopped being true.
abstract class RateLimitClient extends OpenAiClient implements ReportsUsage {
  RateLimitClient({required super.baseUrl, super.apiKey, super.httpClient});

  /// The pairs this host documents, in the order they are shown.
  List<RateLimitHeader> get rateLimits;

  List<UsageWindow> _read = const [];

  @override
  List<UsageWindow> get reportedUsage {
    final now = clock.now();
    return [
      for (final window in _read)
        if (window.resetsAt?.isAfter(now) ?? true) window,
    ];
  }

  @override
  void responded(Map<String, String> headers) {
    final read = usageOfHeaders(rateLimits, headers, clock.now());
    if (read.isNotEmpty) _read = read;
  }

  /// The windows [limits] name in [headers], received at [now]. A pair that
  /// is missing, unreadable or says less than nothing is left out, and so is
  /// a pace with no reset.
  static List<UsageWindow> usageOfHeaders(
    List<RateLimitHeader> limits,
    Map<String, String> headers,
    DateTime now,
  ) => [for (final header in limits) ?_windowOf(header, headers, now)];

  static UsageWindow? _windowOf(
    RateLimitHeader header,
    Map<String, String> headers,
    DateTime now,
  ) {
    String? named(String part) => headers["x-ratelimit-$part-${header.suffix}"];
    final limit = double.tryParse(named("limit") ?? "");
    final remaining = double.tryParse(named("remaining") ?? "");
    if (limit == null || remaining == null || limit <= 0 || remaining < 0) {
      return null;
    }
    final reset = durationOf(named("reset") ?? "");
    if (header.pace && reset == null) return null;
    return UsageWindow(
      label: header.label,
      used: (limit - remaining).clamp(0, limit),
      max: limit,
      unit: header.unit,
      resetsAt: reset == null ? null : now.add(reset),
    );
  }

  static final _part = RegExp(r"(\d+(?:\.\d+)?)(ms|h|m|s)");

  /// A Go duration, the way both hosts write the time until a reset —
  /// `6m0s`, `2m59.56s`, `120ms`. Null for anything else.
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
