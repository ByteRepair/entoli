import "dart:convert";

import "../core/config.dart";
import "permission.dart";
import "temp_chat_ttl.dart";
import "tone.dart";

/// How the agents of a project's rounds run. The project's Omada section
/// names the default for its chats; a chat's own override, where Phase 2
/// adds one, wins over it.
enum OmadaOrdering {
  sequential,
  parallel,
  relay;

  static OmadaOrdering? fromNameNullable(String? name) =>
      name == null ? null : OmadaOrdering.values.asNameMap()[name];
}

/// Human-readable labels, shared by the project settings page so the
/// dropdown and the section's inherited entry name the same thing. The
/// parallel ordering is Crossfire: several members working at the same time,
/// each writing their own reply. Relay is the same start with no wave
/// barrier: what a reply names runs while its siblings are still speaking.
const omadaOrderingLabels = {
  OmadaOrdering.sequential: "Sequential",
  OmadaOrdering.parallel: "Crossfire",
  OmadaOrdering.relay: "Relay",
};

/// One line each, under the ordering dropdown: what the round does under
/// that ordering. The description shown is the effective one — the
/// project's pick, else the app default, else relay.
const omadaOrderingDescriptions = {
  OmadaOrdering.sequential: "Members run one after another, in the order "
      "the message names them.",
  OmadaOrdering.parallel: "Members run at the same time, each writes their "
      "own reply, in whatever order they finish.",
  OmadaOrdering.relay: "Members start as soon as they are named, without "
      "waiting for the room to settle.",
};

/// The default when nothing is set anywhere: relay.
const defaultOmadaOrdering = OmadaOrdering.relay;

/// Project-scoped overrides. A project can override the app-level
/// [TempChatTtl] with one of its own, keep an auto-memory store of its own,
/// and set command environment variables of its own beside the app-level
/// ones. Null means "inherit the app default". What a project says to its
/// turns is not here: that is the AGENTS.md at its workspace root, read with
/// the instructions.
class ProjectSettings {
  ProjectSettings(
      {this.tempChatTtl,
      this.environment,
      this.useProjectMemory = false,
      this.omada = false,
      this.omadaOrdering,
      this.omadaMaxGenerations,
      this.turnMaxSteps,
      this.tone,
      this.citations,
      this.permissions = const [],
      this.writableDirs = const [],
      this.sandboxReprompt,
      this.description});

  /// How long a temporary chat in this project lives. Null means inherit the
  /// app default.
  TempChatTtl? tempChatTtl;

  /// What the project's commands run under, beside the app-level variables:
  /// a name set here wins over one set there. Null means none.
  Map<String, String>? environment;

  /// Whether this project keeps an auto-memory store of its own instead of
  /// sharing the default project's. Meaningless for the default project
  /// itself, which is the one every other falls back to.
  bool useProjectMemory;

  /// Whether this project's chats can carry several agents in one round. A
  /// user project's toggle; a built-in's answer is its spec, in code, and
  /// never read from here. Absent from `project.json` loads as false, so
  /// existing files need no migration.
  bool omada;

  /// The project's default for how its rounds run. Null inherits the app
  /// default, resolved live.
  OmadaOrdering? omadaOrdering;

  /// How many handoff generations one round may run before it stops for the
  /// user. Null inherits the app default. The user's own message is
  /// generation one and uncapped; this bounds only the waves that follow it.
  int? omadaMaxGenerations;

  /// How many model calls one direct turn may make before it stops for the
  /// user. Null inherits the app default, which is the backend's own.
  /// Omada rounds are never under it: a round is several turns in flight,
  /// and one number over them all would say nothing about any member's turn.
  int? turnMaxSteps;

  /// How this project's turns are worded. Null means inherit the app
  /// default.
  Tone? tone;

  /// Whether this project's turns number the web pages they drew on. Null
  /// means inherit the app default.
  bool? citations;

  /// The text the new-chat screen asks over this project's badge, in place
  /// of the app-wide question. Empty is a deliberate answer — the screen
  /// then asks nothing — and null is the app default.
  String? description;

  /// The project's standing permission rules, in front of the app's.
  List<PermissionRule> permissions;

  /// Directories this project's commands may additionally write to, beside
  /// the workspace the sandbox grants — the machine paths a turn works in
  /// that are not the workspaces.
  List<String> writableDirs;

  /// Whether a sandbox-denied write is offered back as an approval. Null
  /// inherits the app default.
  bool? sandboxReprompt;

  static ProjectSettings load(AppConfig config, {String? project}) {
    final text = config.documents.read(config.projectSettingsFile(project: project));
    if (text == null) return ProjectSettings();
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      // A decode gives a `Map<String, dynamic>`, so the value test is what
      // keeps a number in there out of a command's environment.
      final env = json["environment"];
      final environment = env is Map<String, dynamic> && env.values.every((v) => v is String)
          ? {for (final e in env.entries) e.key: e.value as String}
          : null;
      return ProjectSettings(
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?),
        environment: environment,
        useProjectMemory: json["useProjectMemory"] as bool? ?? false,
        omada: json["omada"] as bool? ?? false,
        omadaOrdering: OmadaOrdering.fromNameNullable(
            json["omadaOrdering"] as String?),
        omadaMaxGenerations: json["omadaMaxGenerations"] as int?,
        turnMaxSteps: json["turnMaxSteps"] as int?,
        tone: Tone.fromNameNullable(json["tone"] as String?),
        citations: json["citations"] as bool?,
        permissions: permissionRulesFromJson(json["permissions"] as List<dynamic>?),
        writableDirs: [
          for (final w in (json["writableDirs"] as List<dynamic>? ?? const []))
            if (w is String) w,
        ],
        sandboxReprompt: json["sandboxReprompt"] as bool?,
        description: json["description"] as String?,
      );
    } catch (_) {
      return ProjectSettings();
    }
  }

  Future<void> save(AppConfig config, {String? project}) async {
    await config.documents.write(config.projectSettingsFile(project: project), jsonEncode({
      if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
      if (environment != null && environment!.isNotEmpty) "environment": environment,
      if (useProjectMemory) "useProjectMemory": useProjectMemory,
      if (omada) "omada": omada,
      if (omadaOrdering != null) "omadaOrdering": omadaOrdering!.name,
      if (omadaMaxGenerations != null) "omadaMaxGenerations": omadaMaxGenerations,
      if (turnMaxSteps != null) "turnMaxSteps": turnMaxSteps,
      if (tone != null) "tone": tone!.name,
      if (citations != null) "citations": citations,
      if (permissions.isNotEmpty)
        "permissions": permissionRulesToJson(permissions),
      if (writableDirs.isNotEmpty) "writableDirs": writableDirs,
      if (sandboxReprompt != null) "sandboxReprompt": sandboxReprompt,
      // Empty is written as it stands: the screen asking nothing is a value
      // here, where an absent key is the app default.
      if (description != null) "description": description,
    }));
  }

  ProjectSettings copy() => ProjectSettings(
        tempChatTtl: tempChatTtl,
        environment: environment,
        useProjectMemory: useProjectMemory,
        omada: omada,
        omadaOrdering: omadaOrdering,
        omadaMaxGenerations: omadaMaxGenerations,
        turnMaxSteps: turnMaxSteps,
        tone: tone,
        citations: citations,
        permissions: permissions,
        writableDirs: writableDirs,
        sandboxReprompt: sandboxReprompt,
        description: description,
      );
}
