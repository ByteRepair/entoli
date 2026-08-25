import "profile.dart";

/// A project the app ships rather than the user creates.
///
/// It is a directory under `projects/` like any other — its chats use the same
/// layout, the same store, the same rules of movement — plus a spec of what a
/// turn in it may not have. Its name is refused by [isProjectName]
/// (`project.dart`), so one cannot be created, renamed or deleted, and
/// [everyProject] is where it is offered. A turn never meets a built-in
/// project itself: `ChatRepository` resolves it into a profile, a memory, a
/// workspace and a set of capabilities, and the backend sees only those.
class BuiltinProject {
  const BuiltinProject({
    required this.dir,
    required this.label,
    this.profilePolicy = ProfilePolicy.inherit,
    this.profile,
    this.memory = MemoryPolicy.app,
    this.sharedWorkspace = true,
    this.disabled = const {},
  });

  /// The directory name under `projects/`, in the case it is created in.
  final String dir;

  /// What the menus and the title bar say.
  final String label;

  /// What the turn's "About the user" is.
  final ProfilePolicy profilePolicy;

  /// The profile, when [profilePolicy] is [ProfilePolicy.fixed].
  final Profile? profile;

  /// Whether project memory runs for a turn in it.
  final MemoryPolicy memory;

  /// Whether the project's workspace is shared between its chats. When false,
  /// a chat's own workspace is also the `HOME` of its commands, a `project:`
  /// path resolves inside it, and the prompt says nothing of a shared one.
  final bool sharedWorkspace;

  /// What the project takes away from a turn. A project only ever weakens one:
  /// the platform's facts and a headless turn's restrictions apply on top,
  /// never under.
  final Set<AgentCapability> disabled;
}

/// What a turn's "About the user" is.
enum ProfilePolicy {
  /// The usual resolution: the project's own profile, then the app's.
  inherit,

  /// Nothing: neither the project's nor the app's profile is read.
  none,

  /// The project's own [BuiltinProject.profile] alone; nothing else is read.
  fixed,
}

/// Whether project memory runs for the turn.
enum MemoryPolicy {
  /// The app's gates answer, the way a user's project's does.
  app,

  /// Nothing: no instructions, no recall, no extraction, no memory tools.
  off,
}

/// A tool a [BuiltinProject] may take away from a turn. The file tools are the
/// floor — every project can read, write and edit in its own workspace — and
/// are not here. What a turn can run at all is the platform's fact, which a
/// project does not widen or narrow either: `bash` and the prompt around it
/// change with the shell, not with the project.
enum AgentCapability { ask, task, artifact, webSearch }

/// The built-in projects, in the order the menus offer them.
const builtinProjects = <BuiltinProject>[
  /// A chat with no profile, no project memory, and no workspace it shares
  /// with another chat: the tools and the context that would reach them are
  /// simply not there.
  BuiltinProject(
    dir: "anonymous",
    label: "Anonymous",
    profilePolicy: ProfilePolicy.none,
    memory: MemoryPolicy.off,
    sharedWorkspace: false,
  ),
];

/// The built-in project [dir] is one, or null for a user's. [dir] is read the
/// way a typed name is, so a stored name and a menu entry are one thing.
BuiltinProject? builtinProjectOf(String? dir) {
  if (dir == null) return null;
  final name = dir.toLowerCase();
  for (final project in builtinProjects) {
    if (project.dir == name) return project;
  }
  return null;
}

/// Whether [dir] names a built-in project, whatever its case.
bool isBuiltinProject(String? dir) => builtinProjectOf(dir) != null;

/// What [spec]'s policy makes of the profiles there are: [projectProfile] is
/// the project's own (from its `project.json`) and [appProfile] the app's.
/// Null is no spec — a user's project, or the default one — and the policy is
/// [ProfilePolicy.inherit].
Profile? profileUnder(
  BuiltinProject? spec, {
  required Profile? projectProfile,
  required Profile? appProfile,
}) {
  switch (spec?.profilePolicy ?? ProfilePolicy.inherit) {
    case ProfilePolicy.inherit:
      return projectProfile ?? appProfile;
    case ProfilePolicy.none:
      return null;
    case ProfilePolicy.fixed:
      return spec?.profile;
  }
}
