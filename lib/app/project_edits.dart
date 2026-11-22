import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/project.dart";
import "../domain/work_folders.dart";
import "../providers.dart";
import "selection.dart";

/// What a project's settings page does beyond its settings: count and
/// delete the project, here or on a paired device, and grant it work
/// folders.
class ProjectEdits {
  ProjectEdits(this._ref);

  final Ref _ref;

  /// How many chats [at] holds, counted once the list is read rather than
  /// from what was last drawn.
  Future<int> chatCount(ProjectRef at) async {
    if (at.device case final device?) {
      return _ref
          .read(remoteChatsProvider)
          .where((c) => c.deviceId == device && c.state.project == at.project)
          .length;
    }
    final chats = await _ref.read(chatListProvider.future);
    return chats.where((c) => c.project == at.project).length;
  }

  /// Deletes [project], its chats and its shared workspace, and lets go of
  /// every reference to it: the selection, the assistant's project and the
  /// linked instruction files.
  Future<void> delete(String project) async {
    await _ref.read(chatRepositoryProvider).deleteProject(project);
    _ref.read(selectedProjectProvider.notifier).switchTo(localProject(null));
    // Left written down, the next save would write it back, and a project
    // made again under the name would pick it up.
    if (_ref.read(appSettingsProvider).assistantProject == project) {
      await _ref.read(appSettingsProvider.notifier).setAssistantProject(null);
    }
    await _ref
        .read(linkedInstructionsStoreProvider)
        .update((l) => l.withoutProject(project));
    _ref.invalidate(projectListProvider);
    _ref.invalidate(chatListProvider);
  }

  /// Deletes [project] on [device], and waits for it to say so; false where
  /// it did not. Gone, the device's default project is selected.
  Future<bool> deleteRemote(String device, String project) async {
    if (!await _ref
        .read(syncHubProvider)
        .deleteRemoteProject(device, project)) {
      return false;
    }
    _ref.read(selectedProjectProvider.notifier).switchTo((
      device: device,
      project: null,
    ));
    return true;
  }

  /// Why [dir] grants nothing to [project]'s turns, or null where it
  /// grants. The chat workspaces are inside the project's, so that one
  /// stands for them all.
  FolderRefusal? refusal(String? project, String dir) {
    final config = _ref.read(appConfigProvider);
    return refuseFolder(
      dir,
      dataDir: config.dataDir,
      home: _ref.read(shellProvider).machineHome,
      workspaces: [config.projectWorkspaceDir(project: project)],
    );
  }

  /// A folder from the platform's picker, never typed, added to
  /// [project]'s work folders: what refused it, or null where it was added
  /// or nothing was picked.
  Future<FolderRefusal?> addFolder(String? project) async {
    final picked = await _ref
        .read(folderPickerProvider)
        .pick(confirmLabel: "Add");
    if (picked == null) return null;
    if (refusal(project, picked) case final refused?) return refused;
    final settings = projectSettingsProvider(project);
    final dirs = _ref.read(settings).writableDirs;
    if (!dirs.contains(picked)) {
      await _ref.read(settings.notifier).setWritableDirs([...dirs, picked]);
    }
    return null;
  }

  Future<void> removeFolder(String? project, String dir) {
    final settings = projectSettingsProvider(project);
    return _ref
        .read(settings.notifier)
        .setWritableDirs([..._ref.read(settings).writableDirs]..remove(dir));
  }
}

final projectEditsProvider = Provider(ProjectEdits.new);

/// What deleting [project] with its [count] chats asks.
String deleteProjectMessage(String project, int count) =>
    "Delete \"$project\", its $count ${count == 1 ? "chat" : "chats"} "
    "and its shared workspace? This cannot be undone.";
