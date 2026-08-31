import "package:flutter/material.dart" show Icons, IconData;

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
    this.icon,
    this.profilePolicy = ProfilePolicy.inherit,
    this.memory = MemoryPolicy.app,
    this.sharedWorkspace = true,
    this.disabled = const {},
    this.rootfsIsolation = false,
    this.requiresSetup = false,
  });

  /// The directory name under `projects/`, in the case it is created in.
  final String dir;

  /// What the menus and the title bar say.
  final String label;

  /// The icon shown beside the label where the project is picked as a badge
  /// (the empty-chat row) or a menu row (the sidebar switcher). Null for a
  /// built-in that ships no icon, and for every user project — only a built-in
  /// gets the slot, since a user's project is a name alone.
  final IconData? icon;

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

  /// Whether the project gets its own rootfs instance under its data directory,
  /// so packages installed inside the guest do not appear in another project's
  /// chats. The base download in cache is the template; the project's copy is
  /// its living filesystem, backed up and surviving a cache clear. False on
  /// user projects, which share the base rootfs in cache the way they always
  /// have.
  final bool rootfsIsolation;

  /// Whether the project needs a setup step before turns can be sent. The
  /// chat page hides the composer and shows a "setup required" bar until a
  /// `.setup-complete` marker appears in the project's directory. The store
  /// that runs setup writes the marker; a delete removes it.
  final bool requiresSetup;

  /// The instruction text the app ships for a turn in it. Where non-null it is
  /// the turn's instructions in full: no AGENTS.md file is read, and none is
  /// offered to write, so there is no file to delete or edit away from under
  /// the turn.
  String? get bundledInstructions => null;

  /// Where a built-in ships a note ([bundledInstructions] non-null), whether
  /// the user's instruction files are also read on top of it. False (the
  /// default) keeps the note as the whole instructions, the way anonymous does;
  /// true reads the global and project AGENTS.md after it, so a user's rules
  /// reach the turn and win on conflict — rendered after the bundled entry,
  /// which is the precedence this codebase already gives a project file over a
  /// global one. Has no effect where there is no note: a user's project reads
  /// its files regardless.
  bool get includesUserInstructions => false;

  /// Whether a turn in this project is configured from a project settings
  /// page. A user project always has one; a built-in overrides this where the
  /// page would show more than its name and path. Default false (anonymous),
  /// since its turns run on the note alone and there is nothing on the page
  /// to edit. `ByteRepairProject` turns it on, so the sidebar offers the
  /// settings gear for it the way it does for a user's project.
  bool get hasSettingsPage => false;

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
enum AgentCapability { ask, task, artifact, createSkill, webSearch }

/// What the menus and the title bar call the anonymous built-in. A const so
/// the label and the tests that assert it name one string, the way
/// `defaultProjectLabel` does for the default project. The incognito glyph is
/// the project's [BuiltinProject.icon], not the emoji it once carried.
const anonProjectLabel = "Anon";

/// What the menus and the title bar call the Byte Repair built-in. A const for
/// the same reason `anonProjectLabel` is one; the shield is its
/// [BuiltinProject.icon].
const byteRepairProjectLabel = "Byte-Repair";

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
          icon: Icons.visibility_off,
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

/// A chat for secure coding: the agent writes C with ESBMC contracts and
/// delegates formal verification to the @esbmc-verifier sub-agent. Full
/// capabilities — profile, memory and a shared workspace are all there, since
/// verification work benefits from continuity — and the note stands in for the
/// instruction files, the way the anonymous one does.
class ByteRepairProject extends BuiltinProject {
  const ByteRepairProject()
      : super(
          dir: "byte-repair",
          label: byteRepairProjectLabel,
          icon: Icons.verified_user,
          rootfsIsolation: true,
          requiresSetup: true,
        );

  /// The note is the base, not the whole: the user's instruction files are
  /// read after it, so a rule the user sets for Byte Repair reaches the turn
  /// and wins where the two disagree — see `includesUserInstructions`.
  @override
  bool get includesUserInstructions => true;

  /// The page is worth opening: it carries the Instructions row that edits the
  /// project AGENTS.md read on top of the bundled note, beside Environment and
  /// Temporary chats.
  @override
  bool get hasSettingsPage => true;

  @override
  String get bundledInstructions =>
      "This is a Byte Repair project: you are a coding agent with ESBMC, a "
      "formal verifier for C and C++ that proves memory safety and functional "
      "properties by bounded model checking. The goal is not just code that "
      "runs, but code you can prove correct.\n"
      "\n"
      "Prefer C; use C++ only where the task demands it, and avoid templates "
      "and exceptions in verified code — ESBMC's C++ support is limited there.\n"
      "\n"
      "Follow the user's instructions above all. Verification is the default, "
      "not a compulsion — if the user asks to stop verifying and show results, "
      "do that.\n"
      "\n"
      "Design functions small and atomic: a single responsibility and "
      "single-digit cyclomatic complexity each. ESBMC roughly doubles the "
      "state space per branch, so high complexity blows the verification "
      "budget. Not all code can or should be verified — design the core "
      "verifiable parts with low complexity, and accept that functions with "
      "nested loops or irreducible complexity will be skipped at "
      "verification time. A function whose contract you cannot state is too "
      "big — split it.\n"
      "\n"
      "Workflow:\n"
      "1. Write the code. Do not compile-check after each file — nothing "
      "runs until verification.\n"
      "2. Delegate verification to the @esbmc-verifier agent via the task "
      "tool. It writes the harnesses and Makefile, runs `make verify`, and "
      "reports which functions pass, fail, or are skipped.\n"
      "3. Read the report, fix failures in the implementation, and "
      "re-delegate if needed.\n"
      "4. Summarize the results for the user.\n"
      "\n"
      "Layout: create a task-named subdirectory (kebab-case, e.g. "
      "`ini-parser/`) in the workspace root first, and put everything inside "
      "it:\n"
      "- src/ — the implementation files.\n"
      "- harness/ — the @esbmc-verifier agent writes harnesses here.\n"
      "- Makefile — the @esbmc-verifier agent writes this.\n"
      "\n"
      "Write contracts inside the function body as statements (not on the "
      "signature) so the verifier can check them. The @esbmc-verifier agent "
      "has the ESBMC contract syntax, harness patterns, and invocation forms "
      "— delegate to it when it is time to verify rather than running ESBMC "
      "yourself.\n"
      "\n"
      "The environment has ESBMC and `make`; `gcc` may be absent (ESBMC has "
      "its own front end). You may probe for environment setup (`which gcc "
      "make`, `esbmc --version`) but do not probe or web-search for ESBMC "
      "contract syntax — that is the verifier agent's job.\n"
      "\n"
      "Files containing __ESBMC_* constructs are written with the write tool, "
      "not heredocs in bash — the contract text trips the command safety "
      "classifier.\n"
      "\n"
      "This note stands in for the instruction files the other projects read.";

  @override
  String? get emptyChatQuestion => "What would you like to verify?";
}

/// The built-in projects, in the order the menus offer them.
const builtinProjects = <BuiltinProject>[
  AnonymousProject(),
  ByteRepairProject(),
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
