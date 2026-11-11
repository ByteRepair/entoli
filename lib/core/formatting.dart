/// A size as the workspace explorer shows it, and as the backup section says
/// how big one came out. Rounded hard on purpose: it is there to tell an empty
/// file from a big one, not to be added up.
///
/// Not what a saved result's notice says: that is Claude Code's wording,
/// `_charSize` in `data/builtin/templates.dart`.
String formatSize(int bytes) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = unit == 0 || size >= 10
      ? size.round().toString()
      : size.toStringAsFixed(1);
  return "$rounded ${units[unit]}";
}

/// "200K", "1M": a window as providers write it.
String tokenCount(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return "${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M";
  }
  return n >= 1000 ? "${(n / 1000).round()}K" : "$n";
}

/// The first [end] UTF-16 code units of [text], one fewer where [end] would
/// split a surrogate pair: a cut that never leaves half a character.
String safeCut(String text, int end) {
  final at = end.clamp(0, text.length);
  if (at == 0 || at == text.length) return text.substring(0, at);
  final last = text.codeUnitAt(at - 1);
  return text.substring(0, last >= 0xD800 && last <= 0xDBFF ? at - 1 : at);
}

/// "1 chat", "3 chats".
String plural(int count, String unit) => "$count $unit${count == 1 ? "" : "s"}";

/// "a moment ago", "5 minutes ago", "2 days ago" — how long ago something
/// happened. Coarse on purpose: it is read to decide whether carrying on still
/// makes sense, not to know exactly when.
String formatAge(Duration age) {
  if (age.inMinutes < 1) return "a moment ago";
  if (age.inHours < 1) return "${plural(age.inMinutes, "minute")} ago";
  if (age.inDays < 1) return "${plural(age.inHours, "hour")} ago";
  return "${plural(age.inDays, "day")} ago";
}

/// "23m left", "5h left", "3d left" — how long before a temporary chat expires.
/// Coarse like [formatAge]: the shortest TTL is 24 hours, so minute precision
/// is enough. "expiring" is the brief edge state before the sweep hides it.
String formatRemaining(Duration remaining) {
  if (remaining.inMinutes <= 0) return "expiring";
  if (remaining.inHours < 1) {
    return "${plural(remaining.inMinutes, "minute")} left";
  }
  if (remaining.inDays < 1) return "${plural(remaining.inHours, "hour")} left";
  return "${plural(remaining.inDays, "day")} left";
}

/// "in 23 minutes", "in 5 hours", "in 3 days" — how long before something
/// starts again. Coarse like [formatAge]; "now" under a minute.
String formatUntil(Duration left) {
  if (left.inMinutes < 1) return "now";
  if (left.inHours < 1) return "in ${plural(left.inMinutes, "minute")}";
  if (left.inDays < 1) return "in ${plural(left.inHours, "hour")}";
  return "in ${plural(left.inDays, "day")}";
}
