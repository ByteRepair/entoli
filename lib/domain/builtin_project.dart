import "profile.dart";
import "temp_chat_ttl.dart";

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

  /// The instruction text the app ships for a turn in it. Where non-null it is
  /// the turn's instructions in full: no AGENTS.md file is read, and none is
  /// offered to write, so there is no file to delete or edit away from under
  /// the turn.
  String? get bundledInstructions => null;

  /// The temporary-chat TTL a built-in ships as its own default, in place of
  /// the app-level one. Null falls through to the app default the way a user's
  /// project does. A chat's own override still wins, the way it does for any
  /// project.
  TempChatTtl? get tempChatTtl => null;

  /// The question the empty-chat screen asks when this is the project the next
  /// chat goes to. Null is the default question, shared with every project
  /// that is not a built-in.
  String? get emptyChatQuestion => null;
}

/// What a turn's "About the user" is.
enum ProfilePolicy {
  /// The usual resolution: the project's own profile, then the app's.
  inherit,

  /// Nothing: neither the project's nor the app's profile is read.
  none,
}

/// Whether project memory runs for the turn.
enum MemoryPolicy {
  /// The app's gates answer, the way a user's project's does.
  app,

  /// Nothing: no store, no recall, no extraction, no memory tools.
  off,
}

/// A tool a [BuiltinProject] may take away from a turn. The file tools are the
/// floor — every project can read, write and edit in its own workspace — and
/// are not here. What a turn can run at all is the platform's fact, which a
/// project does not widen or narrow either: `bash` and the prompt around it
/// change with the shell, not with the project.
enum AgentCapability { ask, task, artifact, webSearch }

/// What the menus and the title bar call the anonymous built-in. A const so
/// the emoji variation selector cannot drift between the label and the tests
/// that assert it, the way `defaultProjectLabel` does for the default project.
const anonProjectLabel = "\u{1F576}\uFE0F Anon";

/// A chat with no profile, no project memory, and no workspace it shares
/// with another chat: the tools and the context that would reach them are
/// simply not there. Its instructions are the app's own note about what it is,
/// in code rather than in a file — the only AGENTS.md it has is one nobody
/// could delete or edit away from under a turn.
class AnonymousProject extends BuiltinProject {
  const AnonymousProject()
      : super(
          dir: "anonymous",
          label: anonProjectLabel,
          profilePolicy: ProfilePolicy.none,
          memory: MemoryPolicy.off,
          sharedWorkspace: false,
        );

  @override
  String get bundledInstructions =>
      "This is an anonymous chat. Its workspace is scratch for this chat "
      "alone: nothing in it is shared with any other conversation, and "
      "nothing about it is remembered. There is no profile of the user and no "
      "memory of earlier chats, and this note stands in for the instruction "
      "files the other projects read.";

  /// Anonymous chats are scratch: they live a day by default, not forever.
  @override
  TempChatTtl? get tempChatTtl => TempChatTtl.hours24;

  @override
  String? get emptyChatQuestion => "What would you like to discuss anonymously?";
}

/// The built-in projects, in the order the menus offer them.
const builtinProjects = <BuiltinProject>[
  AnonymousProject(),
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

/// What [spec]'s policy makes of the app's profile. Null is no spec — a
/// user's project, or the default one — and the policy is
/// [ProfilePolicy.inherit].
Profile? profileUnder(BuiltinProject? spec, {required Profile? appProfile}) =>
    spec?.profilePolicy == ProfilePolicy.none ? null : appProfile;
