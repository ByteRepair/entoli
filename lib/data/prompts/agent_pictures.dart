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

/// Both of an agent's face files, the order a write, a move or a delete walks.
List<String> agentFacePaths(AppConfig config, String name, {String? project}) =>
    [
      agentPicturePath(config, name, project: project),
      agentAvatarPath(config, name, project: project),
    ];

/// The face [project]'s own directory holds for [name], and no other tier's:
/// what the editor edits, since it writes this level alone.
Future<AgentFace?> readOwnAgentFace(
  AppConfig config,
  String name, {
  String? project,
}) => _faceIn(config, name, project);

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
        await _faceIn(config, name, tier) ?? bundledAgentFace(name, tier);
    if (face != null) return face;
  }
  return null;
}

/// The face the app ships for its own agent called [name] in [tier]: the
/// embedded `<name>.avatar.json` from beside the bundled `.md`. Below a face
/// on disk in the same rung, as the bundled `.md` is below the user's.
AgentFace? bundledAgentFace(String name, String tier) {
  for (final file in bundledAgentFaces) {
    if (file.name != name || file.project != tier) {
      continue;
    }
    final spec = BotAvatarSpec.decode(file.content);
    return spec == null ? null : AgentBot(spec);
  }
  return null;
}

Future<AgentFace?> _faceIn(
  AppConfig config,
  String name,
  String? project,
) async {
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
