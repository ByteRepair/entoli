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

/// A chat for secure coding: the agent writes test harnesses alongside the
/// code it writes and formally verifies C with ESBMC. Full capabilities —
/// profile, memory and a shared workspace are all there, since verification
/// work benefits from continuity — and the note stands in for the instruction
/// files, the way the anonymous one does.
class ByteRepairProject extends BuiltinProject {
  const ByteRepairProject()
      : super(
          dir: "byte-repair",
          label: byteRepairProjectLabel,
          icon: Icons.verified_user,
          rootfsIsolation: true,
          requiresSetup: true,
        );

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
      "Methodology:\n"
      "1. Write small, atomic functions. Each should have a single "
      "responsibility and single-digit cyclomatic complexity — ESBMC roughly "
      "doubles the state space per branch, so high complexity blows the "
      "verification budget and the 20s-per-harness limit below.\n"
      "2. Secure by design: before implementing a function, write its contract "
      "(__ESBMC_requires / __ESBMC_ensures on the signature) and its harness. "
      "Then write the body. A function whose contract you cannot state is too "
      "big — split it.\n"
      "3. After the task, run `make verify` and fix every failure — in the code "
      "or the harness — until the whole run is green. A verification failure "
      "is a bug to fix, not a warning to note.\n"
      "\n"
      "Layout (under the project root):\n"
      "- src/ — the implementation files.\n"
      "- harness/<harness-name>/main.c — one harness per verified function.\n"
      "- Makefile — builds the harnesses and runs ESBMC on each. Express the "
      "source files through variables and substitute them rather than inlining "
      "paths everywhere; a harness's rule should differ only in its name.\n"
      "\n"
      "Each harness: nondet the inputs, assume the preconditions the contract "
      "requires, call the function, assert the postconditions. ESBMC checks "
      "memory safety (null-deref, out-of-bounds, use-after-free, leaks) "
      "automatically — spend asserts on functional properties, not on "
      "re-stating safety.\n"
      "\n"
      "ESBMC constructs (no header needed; they are injected):\n"
      "- nondet_int(), nondet_uint(), nondet_char(), nondet_short(), "
      "nondet_long(), nondet_float(), nondet_bool() — fresh arbitrary values.\n"
      "- __ESBMC_assume(cond) — discard executions where cond is false. A "
      "false-on-every-path assumption makes verification vacuous (everything "
      "'passes' untested), so pair a strong assume with an assert that actually "
      "exercises the code.\n"
      "- __ESBMC_assert(cond, \"msg\") — report a violation when cond is false.\n"
      "- Contracts: __ESBMC_requires(cond), __ESBMC_ensures(cond), "
      "__ESBMC_assigns(targets), __ESBMC_old(expr) for the entry value, "
      "__ESBMC_return_value in ensures, __ESBMC_is_fresh(p, n) for a pointer "
      "parameter's extent and separation. State is_fresh on any pointer the "
      "function dereferences, or ESBMC flags the deref out-of-bounds.\n"
      "- __ESBMC_forall(&i, body) / __ESBMC_exists(&i, body) for properties "
      "over arrays (requires --z3).\n"
      "- #pragma unroll N immediately before a loop bounds it to N iterations "
      "in source, stable across edits — prefer it over the global --unwind.\n"
      "\n"
      "Each harness must finish in under 20 seconds. Keep it under budget by "
      "lowering cyclomatic complexity, by `#pragma unroll N` on bounded loops, "
      "or by replacing deep callees with their contracts "
      "(`--replace-call-with-contract <callee>`) so their bodies are not "
      "unrolled. `--force-malloc-success` drops the malloc-returns-NULL path "
      "and halves the state space for allocating functions.\n"
      "\n"
      "If a function has unbounded loops or irreducible complexity, do not "
      "write a harness for it — instead add a Makefile entry that prints "
      "`Skipping <function>` and exits 0, so `make verify` stays green.\n"
      "\n"
      "Makefile invocation pattern (per harness):\n"
      "\tesbmc harness/<name>/main.c \$(SRC) \\\n"
      "\t    --function main \\\n"
      "\t    --enforce-contract <verified-function> \\\n"
      "\t    --timeout 20 \\\n"
      "\t    [--z3] [--force-malloc-success] [--replace-call-with-contract <callee>]\n"
      "`--enforce-contract <f>` must be paired with `--function main` (the "
      "harness entry) so the contract is checked against arbitrary inputs the "
      "harness supplies, not against whatever main happens to call. "
      "`make verify` runs each harness in order and fails the build on any "
      "ESBMC failure.\n"
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
