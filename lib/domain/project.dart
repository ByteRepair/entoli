import "package:path/path.dart" as p;

/// A project is a directory holding its own chats and a workspace they share.
/// It is named by that directory, so the name is what the agent sees in a path
/// and what the user types is made safe to be one.
///
/// `null` is the default project. It is a directory under `projects/` like any
/// other, and [defaultProjectDir] is its name; `null` rather than that string
/// everywhere above the filesystem, because which project is the default is not
/// a thing the UI or a stored setting should be able to disagree about.
const defaultProjectLabel = "Default";

/// The default project's directory, and so a name no other project may have.
const defaultProjectDir = "default";

String projectLabel(String? project) => project ?? defaultProjectLabel;

/// Every project there is, the default one first — the order the menus offer
/// them in, and the order a chat is looked for in.
List<String?> everyProject(List<String> named) => [null, ...named];

/// A stored project name read against the projects there are: one that has
/// since been deleted is the default project. A setting holds a name rather
/// than a reference, so both ends of one have to resolve it the same way, or a
/// field says `Default` while what it drives lands somewhere else.
String? projectOrDefault(String? named, List<String> existing) =>
    named != null && existing.contains(named) ? named : null;

/// One directory under `projects/` and nothing else, bar the default project's:
/// that one is `null` above the filesystem, so a second way to name it would be
/// a second entry for it in every list. Anything else is a name that would
/// reach outside `projects/`, and `projects/.hidden` is not a project either.
/// Restated in Kotlin by `WorkspaceProvider`, which cannot call this.
bool isProjectName(String name) =>
    name.isNotEmpty &&
    !name.startsWith(".") &&
    name == p.basename(name) &&
    name.toLowerCase() != defaultProjectDir;

/// The directory name for what the user typed, or null if nothing usable is
/// left of it. Deliberately strict: this ends up as a `cd` target in commands
/// the model writes.
String? projectNameFrom(String typed) {
  var name = typed.trim().replaceAll(RegExp(r"[^A-Za-z0-9._ -]"), "-");
  name = name.replaceAll(RegExp(r"\s+"), "-").replaceAll(RegExp(r"-{2,}"), "-");
  name = name.replaceAll(RegExp(r"^[.-]+|[.-]+$"), "");
  if (name.length > 64) name = name.substring(0, 64);
  return isProjectName(name) ? name : null;
}
