// Where an agent's profile picture lives: beside its `.md`, named after it.
import "package:path/path.dart" as p;
import "dart:io";
import "dart:typed_data";

import "../../core/config.dart";
import "../../domain/models.dart";
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

/// The bytes of the picture the library's tiers show for an agent called
/// [name]: the first [tiers] rung that holds one, walked from the top —
/// the list carries the lowest precedence first, the same order the
/// library's "later replaces earlier" builds from, so a project's own
/// answers over a default one the way its `.md` does. Null where no rung has
/// one. A file that cannot be read is nothing to fail a page over, so that
/// reads as no picture.
///
/// [tiers] is [promptTiers]' walk (the same one [DirectoryPrompts] loads the
/// `.md` files by), handed in rather than resolved here so the caller
/// resolves the Omada question where it already holds the config.
Future<Uint8List?> readAgentPicture(
  AppConfig config,
  String name,
  List<String> tiers,
) async {
  for (final tier in tiers.reversed) {
    final file = File(agentPicturePath(config, name, project: tier));
    if (!file.existsSync()) continue;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }
  return null;
}
