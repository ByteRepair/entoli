import "../../domain/models.dart";

/// The chats under one of the sidebar's headings.
class ChatGroup {
  const ChatGroup(this.heading, this.chats);

  final String heading;
  final List<ChatState> chats;
}

/// The heading pinned chats sit under, ahead of every date group. A category
/// of one is still drawn — the pin is what the user asked to see, not a date.
const pinnedHeading = "Pinned";

/// [chats] newest first, under the heading their last change puts them in.
///
/// [now] is a parameter rather than read here so a test can say where the
/// boundaries fall; the sidebar passes the real clock.
///
/// Pinned chats come first under [pinnedHeading], newest first among
/// themselves; the rest follow under the date headings, in the order the chats
/// come in. The order the headings come out in is what saves ranking them:
/// sorted newest first, each chat lands in the group it is already in or one
/// further down, and never one further up — and the pinned group is always
/// above the date groups because it is drawn before them.
List<ChatGroup> groupChatsByDate(Iterable<ChatState> chats, {required DateTime now}) {
  final sorted = chats.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final pinned = sorted.where((c) => c.pinned).toList();
  final rest = sorted.where((c) => !c.pinned).toList();
  final groups = <String, List<ChatState>>{};
  for (final chat in rest) {
    final heading = _heading(chat.updatedAt.toLocal(), now.toLocal());
    groups.putIfAbsent(heading, () => []).add(chat);
  }
  return [
    if (pinned.isNotEmpty) ChatGroup(pinnedHeading, pinned),
    for (final group in groups.entries) ChatGroup(group.key, group.value),
  ];
}

/// The chats whose title holds [query], which is the whole of what searching
/// looks at. Searching what was *said* means reading every `conv.jsonl` off
/// disk on every keystroke; the titles are already in memory, since they are
/// what the list draws.
/// An empty query needs no arm of its own: every string holds the empty one.
List<ChatState> chatsMatching(Iterable<ChatState> chats, String query) {
  final needle = query.trim().toLowerCase();
  return chats.where((c) => c.title.orUntitled.toLowerCase().contains(needle)).toList();
}

const _months = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

String _heading(DateTime at, DateTime now) {
  final days = _daysBetween(at, now);
  // A chat dated in the future is a clock that has gone back, and today is the
  // least surprising place for it.
  if (days <= 0) return "Today";
  if (days == 1) return "Yesterday";
  if (days < 7) return "Previous 7 days";
  if (days < 30) return "Previous 30 days";
  final month = _months[at.month - 1];
  return at.year == now.year ? month : "$month ${at.year}";
}

/// Whole days from one local date to another, counted on a UTC calendar: a
/// local day either side of a clock change is 23 or 25 hours long, and
/// yesterday would round to today.
int _daysBetween(DateTime from, DateTime to) => DateTime.utc(to.year, to.month, to.day)
    .difference(DateTime.utc(from.year, from.month, from.day))
    .inDays;
