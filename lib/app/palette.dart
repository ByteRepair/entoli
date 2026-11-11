import "../domain/chat_search.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "remote_projects.dart";

/// Running chats first, then the rest; most recently touched first in each.
List<ChatState> chatsByRecency(
  Iterable<ChatState> chats,
  Set<String> running,
) => chats.toList()
  ..sort((a, b) {
    final byRunning =
        (running.contains(b.id) ? 1 : 0) - (running.contains(a.id) ? 1 : 0);
    return byRunning != 0 ? byRunning : b.updatedAt.compareTo(a.updatedAt);
  });

/// The default project and the built-ins sit above the rule, the user's
/// below it.
bool isUserProject(String? project) =>
    project != null && isProjectName(project);

/// What the palette lists, apart from how it is drawn — the Flutter palette
/// and the native shell's draw the same. With nothing typed ([searching]
/// false), [projects] is the default project and the built-ins, [mine] the
/// user's own below a rule, and [devices] every paired device's; with
/// something typed, [projects] and [devices] are those whose names match and
/// [mine] is empty. [chats] are those whose titles match, running first.
({
  bool searching,
  List<String?> projects,
  List<String?> mine,
  List<RemoteEntry> devices,
  List<ChatState> chats,
})
paletteListing({
  required List<String> named,
  required List<ChatState> chats,
  required List<RemoteEntry> remotes,
  required String query,
  required Set<String> running,
}) {
  final needle = searchNeedle(query);
  final every = everyProject(named);
  final found = chatsByRecency(chatsMatching(chats, query), running);
  if (needle.isEmpty) {
    return (
      searching: false,
      projects: [...every.where((p) => !isUserProject(p))],
      mine: [...every.where(isUserProject)],
      devices: remotes,
      chats: found,
    );
  }
  return (
    searching: true,
    projects: [
      for (final p in every)
        if (projectLabel(p).toLowerCase().contains(needle)) p,
    ],
    mine: const [],
    devices: [
      for (final e in remotes)
        if (e.label.toLowerCase().contains(needle)) e,
    ],
    chats: found,
  );
}
