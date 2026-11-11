import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/agent_pictures.dart";
import "../../data/prompts/skill_import.dart" show agentFilePath, isFolderName;
import "../../domain/agent_face.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";

/// A project's own agents on disk: which are there, and every write a page
/// makes to them, each through the directory's read-only lock. One copy for
/// every frontend's agents page.
class AgentFiles {
  const AgentFiles(this.config, {this.project});

  final AppConfig config;

  /// Null is the default project.
  final String? project;

  String get _dir => config.promptsDir(CompletionKind.agent, project: project);

  /// The agents in this project's own directory; every other name a library
  /// lists is inherited or bundled.
  Future<Set<String>> own() async {
    final names = <String>{};
    final dir = Directory(_dir);
    if (dir.existsSync()) {
      await for (final entity in dir.list()) {
        if (entity is File && p.extension(entity.path) == ".md") {
          names.add(p.basenameWithoutExtension(entity.path));
        }
      }
    }
    return names;
  }

  bool has(String name) =>
      File(agentFilePath(config, name, project: project)).existsSync();

  /// Writes [name] as [source]. [removes] names the file a rename takes
  /// away, written over first so a failure halfway leaves the agent where it
  /// was. [face] is what the agent looks like now: an agent written over
  /// another does not keep the face of the one it replaced. The create is
  /// load-bearing: `writeAsString` does not make parents.
  Future<void> write(
    String name,
    String source, {
    String? removes,
    AgentFace? face,
  }) {
    final renames = removes != null && removes != name;
    return platform.readOnlyDirs.of(_dir).write(() async {
      final file = File(agentFilePath(config, name, project: project));
      await file.create(recursive: true);
      await file.writeAsString(source);
      if (renames) {
        await File(agentFilePath(config, removes, project: project)).delete();
        await writeAgentFace(config, removes, null, project: project);
      }
      await writeAgentFace(config, name, face, project: project);
    });
  }

  Future<void> delete(String name) =>
      platform.readOnlyDirs.of(_dir).write(() async {
        await File(agentFilePath(config, name, project: project)).delete();
        await writeAgentFace(config, name, null, project: project);
      });

  /// An imported `.md` read as the agent it would be: under its file's own
  /// name, the way an editor save names one. A body with nothing in it is
  /// refused, being a mention that does nothing.
  static ({String name, String source})? import(
    String fileName,
    List<int> bytes, {
    required void Function(String why) refuse,
  }) {
    final source = utf8.decode(bytes, allowMalformed: true);
    final document = PromptDocument.parse(CompletionKind.agent, "", source);
    if (document.body.isEmpty) {
      refuse("That file cannot be imported: there is no prompt in it.");
      return null;
    }
    final name = p.basenameWithoutExtension(fileName);
    if (!isFolderName(name)) {
      refuse("That file cannot be imported: its name cannot be a file name.");
      return null;
    }
    return (name: name, source: source);
  }
}
