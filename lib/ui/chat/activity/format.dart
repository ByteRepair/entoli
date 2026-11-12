import "../../../core/formatting.dart" show plural;

export "../../../core/formatting.dart"
    show plural, formatAge, formatRemaining, formatUntil;

/// "12 seconds", "2 minutes 5 seconds" — what a label reads after "Thought for".
String formatThinkingTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 1) return "a moment";
  if (seconds < 60) return plural(seconds, "second");
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final head = plural(minutes, "minute");
  return rest == 0 ? head : "$head ${plural(rest, "second")}";
}
