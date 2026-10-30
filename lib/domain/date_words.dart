/// How a moment is worded where a user reads it — the settings row, the
/// editor's buttons, the tools' answers. One home, because a wording change
/// is one edit and the three readers cannot drift; [describeFire] takes
/// [now] rather than reading the clock, so a test's own idea of today
/// steers it the way everything else date-shaped here is steered.
const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const _months = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

/// A moment relative to [now]: today and tomorrow by name, then the date.
String describeFire(DateTime at, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  // Whole days, round()ed: both are local midnights and the hours between
  // them sit a whole day off by one hour per DST boundary crossed, which
  // truncation would word as today (a 23-hour day before spring-forward).
  final difference = (day.difference(today).inHours / 24).round();
  final when = timeOfDay(at);
  return switch (difference) {
    0 => "Today $when",
    1 => "Tomorrow $when",
    _ => "${shortDate(at)} $when",
  };
}

/// The date alone, weekday first: "Mon 3 Jan".
String shortDate(DateTime at) =>
    "${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}";

/// The time alone, twelve-hour: "9:00 AM".
String timeOfDay(DateTime at) {
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, "0");
  return "$hour:$minute ${at.hour < 12 ? "AM" : "PM"}";
}
