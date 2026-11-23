import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/models.dart";

import "../../data/prompts/skill_import.dart" show isBundledPromptName;
import "../../providers.dart";
import "agent_files.dart";
import "skill_files.dart";

/// A project's own agents and skills, by name: which entries of its library
/// its directory holds, the rest inherited or bundled; and for a skill, what
/// its folder is wrong about. Asked again after every write, and each time a
/// page shows them, so a file put there behind the app's back is found.
final ownAgentsProvider = FutureProvider.autoDispose
    .family<Set<String>, String?>(
      (ref, project) =>
          AgentFiles(ref.watch(appConfigProvider), project: project).own(),
    );

final ownSkillsProvider = FutureProvider.autoDispose
    .family<Map<String, List<String>>, String?>(
      (ref, project) =>
          SkillFiles(ref.watch(appConfigProvider), project: project).own(),
    );

/// Where a skill imported on the global page goes: null is the default
/// project, the base set every project inherits.
final skillDestinationProvider = NotifierProvider<SkillDestination, String?>(
  SkillDestination.new,
);

class SkillDestination extends Notifier<String?> {
  @override
  String? build() => null;

  void pick(String? project) => state = project;
}

final promptChangesProvider = Provider(PromptChanges.new);

/// What follows a write to a project's agents or skills directory.
class PromptChanges {
  PromptChanges(this._ref);

  final Ref _ref;

  /// Re-read the library [project]'s directory is in, and what lists the
  /// project's own. The default project's is a rung of every project's
  /// library, so a change there reloads every one.
  Future<void> reload(String? project) async {
    if (project == null) {
      await reloadAllPromptLibraries(_ref.read);
    } else {
      await _ref.read(promptLibraryProvider(project).notifier).reload();
    }
    _ref.invalidate(ownAgentsProvider(project));
    _ref.invalidate(ownSkillsProvider(project));
  }
}

/// Where an entry a project's directory does not hold came from: a preset
/// the binary embeds, or a default-project entry this project inherits.
String promptOrigin(CompletionKind kind, String name, String? project) =>
    isBundledPromptName(kind, name, project: project) ? "Bundled" : "Inherited";
