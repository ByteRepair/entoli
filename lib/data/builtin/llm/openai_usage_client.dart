import "package:clock/clock.dart";

import "../../../domain/provider_usage.dart";
import "llm_client.dart";
import "openai_client.dart";

/// OpenAI's own API client, retaining documented rate-limit headers from its
/// latest response for the provider-usage view.
class OpenAiUsageClient extends OpenAiClient implements ReportsUsage {
  OpenAiUsageClient({required super.baseUrl, super.apiKey, super.httpClient});

  List<UsageWindow> _usage = const [];

  @override
  List<UsageWindow> get reportedUsage => _usage;

  @override
  void responded(Map<String, String> headers) {
    final read = usageOfHeaders(headers, clock.now());
    if (read.isNotEmpty) _usage = read;
  }

  /// The limit/remaining pairs OpenAI documents in API response headers.
  static List<UsageWindow> usageOfHeaders(
    Map<String, String> headers,
    DateTime now,
  ) {
    final normalized = {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final windows = <UsageWindow>[];
    for (final (suffix, label, unit) in const [
      ("requests", "Requests", UsageUnit.requests),
      ("tokens", "Tokens", UsageUnit.tokens),
      ("project-tokens", "Project tokens", UsageUnit.tokens),
    ]) {
      final limit = _integer(normalized["x-ratelimit-limit-$suffix"]);
      final remaining = _integer(normalized["x-ratelimit-remaining-$suffix"]);
      if (limit == null || remaining == null || limit <= 0 || remaining < 0) {
        continue;
      }
      final reset = durationOf(normalized["x-ratelimit-reset-$suffix"]);
      windows.add(
        UsageWindow(
          label: label,
          used: (limit - remaining).clamp(0, limit).toDouble(),
          max: limit.toDouble(),
          unit: unit,
          resetsAt: reset == null ? null : now.add(reset),
        ),
      );
    }
    return windows;
  }

  static int? _integer(String? value) =>
      value == null ? null : int.tryParse(value.trim());

  /// Parse OpenAI's 1s / 6m0s reset intervals; reject other formats.
  static Duration? durationOf(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(
      r"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$",
    ).firstMatch(value.trim());
    if (match == null || match.group(0)!.isEmpty) return null;
    final hours = int.tryParse(match.group(1) ?? "0") ?? 0;
    final minutes = int.tryParse(match.group(2) ?? "0") ?? 0;
    final seconds = double.tryParse(match.group(3) ?? "0") ?? 0;
    if (hours > 24 * 365 || minutes >= 60 || seconds >= 60) return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    );
  }
}
