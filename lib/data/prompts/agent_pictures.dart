// Where an agent's face lives: beside its `.md`, named after it — a picked
// photo as `<name>.png`, a Bot Avatar as `<name>.avatar.json`.
import "package:path/path.dart" as p;
import "dart:io";

import "../../core/config.dart";
import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/models.dart";
import "bundled_skill_data.dart" show bundledAgentFaces;
import "prompt_sources.dart";

/// Where an agent called [name] keeps its picture: a `.png` beside its `.md`
/// in [project]'s agents directory — the default project's where it is null.
/// The name is the file's, as the `.md` is; the writer, the remover and the
/// rename all have to agree on that, the way they do for [agentFilePath].
String agentPicturePath(AppConfig config, String name, {String? project}) =>
    p.join(
      config.promptsDir(CompletionKind.agent, project: project),
      "$name.png",
    );

/// Where an agent called [name] keeps its Bot Avatar spec, beside the `.md`
/// the way [agentPicturePath] is. The two are one face held two ways: a write
/// of either takes the other away.
String agentAvatarPath(AppConfig config, String name, {String? project}) =>
    p.join(
      config.promptsDir(CompletionKind.agent, project: project),
      "$name.avatar.json",
    );

/// Make [face] the face [project]'s own directory holds for [name], or take
/// it away where null. One face at a time: whichever is written, the other
/// file goes. The caller holds the directory's `ReadOnlyDir.write`, which
/// the agent's `.md` rides too.
Future<void> writeAgentFace(
  AppConfig config,
  String name,
  AgentFace? face, {
  String? project,
}) async {
  for (final path in [
    agentPicturePath(config, name, project: project),
    agentAvatarPath(config, name, project: project),
  ]) {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
  switch (face) {
    case AgentPhoto(:final bytes):
      await File(
        agentPicturePath(config, name, project: project),
      ).writeAsBytes(bytes);
    case AgentBot(:final spec):
      await File(
        agentAvatarPath(config, name, project: project),
      ).writeAsString(spec.encode());
    case null:
      break;
  }
}

/// The face the library's tiers show for an agent called [name]: the first
/// [tiers] rung that holds one, walked from the top — the list carries the
/// lowest precedence first, the same order the library's "later replaces
/// earlier" builds from, so a project's own answers over a default one the
/// way its `.md` does. Within a rung the Bot Avatar wins over the photo, a
/// write of one being meant to take the other away. Null where no rung has
/// either. A file that cannot be read, or a spec that no longer validates,
/// is nothing to fail a page over, so it reads as no face.
///
/// [tiers] is [promptTiers]' walk (the same one [DirectoryPrompts] loads the
/// `.md` files by), handed in rather than resolved here so the caller
/// resolves the Omada question where it already holds the config.
Future<AgentFace?> readAgentPicture(
  AppConfig config,
  String name,
  List<String> tiers,
) async {
  for (final tier in tiers.reversed) {
    final face =
        await readOwnAgentFace(config, name, project: tier) ??
        _bundledFaces[(project: tier, name: name)];
    if (face != null) return face;
  }
  return null;
}

/// The faces the app ships for its own agents, by rung and name: the
/// embedded `<name>.avatar.json` from beside each bundled `.md`, decoded
/// once — the generator has already held each to the spec. Below a face on
/// disk in the same rung, as the bundled `.md` is below the user's.
final _bundledFaces = {
  for (final file in bundledAgentFaces)
    if (BotAvatarSpec.decode(file.content) case final spec?)
      (project: file.project, name: file.name): AgentBot(spec),
};

/// The face [project]'s own directory holds for [name], and no other tier's:
/// what the editor edits, since it writes this level alone.
Future<AgentFace?> readOwnAgentFace(
  AppConfig config,
  String name, {
  String? project,
}) async {
  final avatar = File(agentAvatarPath(config, name, project: project));
  if (avatar.existsSync()) {
    try {
      final spec = BotAvatarSpec.decode(await avatar.readAsString());
      if (spec != null) return AgentBot(spec);
    } on FileSystemException {
      // Unreadable: the photo, if there is one, is the face.
    }
  }
  final photo = File(agentPicturePath(config, name, project: project));
  if (!photo.existsSync()) return null;
  try {
    return AgentPhoto(await photo.readAsBytes());
  } on FileSystemException {
    return null;
  }
}
