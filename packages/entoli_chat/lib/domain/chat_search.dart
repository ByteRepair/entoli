import "models.dart";

/// The chats whose title holds [query], which is the whole of what searching
/// looks at. Searching what was *said* means reading every `conv.jsonl` off
/// disk on every keystroke; the titles are already in memory, since they are
/// what the list draws.
/// An empty query needs no arm of its own: every string holds the empty one.
List<ChatState> chatsMatching(Iterable<ChatState> chats, String query) {
  final needle = searchNeedle(query);
  return chats.where((c) => titleMatches(c, needle)).toList();
}

/// What a typed query compares as. Hoisted out of the loop it is used in:
/// lowercasing the needle once per chat allocates a string per row per
/// keystroke.
String searchNeedle(String query) => query.trim().toLowerCase();

/// The one rule either list searches by, so the local one and a paired
/// device's cannot come to disagree about what a trailing space means.
/// [needle] is already through [searchNeedle].
bool titleMatches(ChatState chat, String needle) =>
    chat.title.orUntitled.toLowerCase().contains(needle);
