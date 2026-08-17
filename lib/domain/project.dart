import "package:path/path.dart" as p;

/// A project is a directory holding its own chats and a workspace they share.
/// It is named by that directory, so the name is what the agent sees in a path
/// and what the user types is made safe to be one.
///
/// `null` is the default project, which is the data directory itself: every
/// chat was in it before there were any others.
const defaultProjectLabel = "Default";

String projectLabel(String? project) => project ?? defaultProjectLabel;

/// Every project there is, the default one first — the order the menus offer
/// them in, and the order a chat is looked for in.
List<String?> everyProject(List<String> named) => [null, ...named];

/// One directory under `projects/` and nothing else. Anything else is a name
/// that would reach outside it, and `projects/.hidden` is not a project either.
/// Restated in Kotlin by `WorkspaceProvider`, which cannot call this.
bool isProjectName(String name) =>
    name.isNotEmpty && !name.startsWith(".") && name == p.basename(name);

/// The directory name for what the user typed, or null if nothing usable is
/// left of it. Deliberately strict: this ends up as a `cd` target in commands
/// the model writes.
String? projectNameFrom(String typed) {
  var name = typed.trim().replaceAll(RegExp(r"[^A-Za-z0-9._ -]"), "-");
  name = name.replaceAll(RegExp(r"\s+"), "-").replaceAll(RegExp(r"-{2,}"), "-");
  name = name.replaceAll(RegExp(r"^[.-]+|[.-]+$"), "");
  if (name.length > 64) name = name.substring(0, 64);
  return name.isEmpty ? null : name;
}
