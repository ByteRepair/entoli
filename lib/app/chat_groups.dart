import "../domain/models.dart";

/// How long ago a group's chats last changed, or that they are pinned:
/// what the sidebar heads each group with, worded by each frontend.
enum ChatPeriod { pinned, today, yesterday, previousWeek, previousMonth, month }

/// The chats under one of the sidebar's headings.
class ChatGroup {
  const ChatGroup(this.period, this.chats, {this.month});

  final ChatPeriod period;

  /// For [ChatPeriod.month], the month: its first day, local.
  final DateTime? month;
  final List<ChatState> chats;
}

/// [chats] newest first, under the period their last change puts them in.
///
/// [now] is a parameter rather than read here so a test can say where the
/// boundaries fall; the sidebar passes the real clock.
///
/// Pinned chats come first, newest first among themselves — a category of
/// one is still drawn, the pin being what the user asked to see, not a date
/// — and the rest follow under their periods, in the order the chats come
/// in. The order the periods come out in is what saves ranking them: sorted
/// newest first, each chat lands in the group it is already in or one
/// further down, and never one further up.
List<ChatGroup> groupChatsByDate(
  Iterable<ChatState> chats, {
  required DateTime now,
}) {
  final sorted = chats.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final pinned = sorted.where((c) => c.pinned).toList();
  final rest = sorted.where((c) => !c.pinned).toList();
  final groups = <(ChatPeriod, DateTime?), List<ChatState>>{};
  for (final chat in rest) {
    final key = _period(chat.updatedAt.toLocal(), now.toLocal());
    groups.putIfAbsent(key, () => []).add(chat);
  }
  return [
    if (pinned.isNotEmpty) ChatGroup(ChatPeriod.pinned, pinned),
    for (final MapEntry(key: (period, month), value: chats) in groups.entries)
      ChatGroup(period, chats, month: month),
  ];
}

(ChatPeriod, DateTime?) _period(DateTime at, DateTime now) {
  final days = _daysBetween(at, now);
  // A chat dated in the future is a clock that has gone back, and today is the
  // least surprising place for it.
  if (days <= 0) return (ChatPeriod.today, null);
  if (days == 1) return (ChatPeriod.yesterday, null);
  if (days < 7) return (ChatPeriod.previousWeek, null);
  if (days < 30) return (ChatPeriod.previousMonth, null);
  return (ChatPeriod.month, DateTime(at.year, at.month));
}

/// Whole days from one local date to another, counted on a UTC calendar: a
/// local day either side of a clock change is 23 or 25 hours long, and
/// yesterday would round to today.
int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
