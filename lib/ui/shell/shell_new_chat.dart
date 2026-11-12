import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/peers.dart" show PeerStatus;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../app/settings/spec.dart" show SettingReader;
import "../../providers.dart";
import "../selection.dart";
import "../../app/remote_projects.dart";
import "../widgets/completion_field.dart";
import "shell_composer.dart" show completionOf, triggerOf;
import "glyphs.dart";

/// The asset the new-chat screen stands its figure on.
const _athena = "assets/images/athena.png";

/// The new-chat screen as the native shell draws it, apart from any widget:
/// the question, the project badges, the paired devices' projects and the
/// starters, read as the Flutter screen reads them and sent as a
/// [NewChatSnapshot]; a badge switches project and a starter types into
/// [controller]. `ShellChat` holds one while nothing is selected.
class NewChatRunner implements NewChatIntents {
  NewChatRunner(this._container, {required this.controller});

  final ProviderContainer _container;

  /// The composer's, so a starter can type into it.
  final TextEditingController controller;

  /// A badge. Picking the one already picked is the default project, which
  /// is nothing picked: the row is a set of toggles.
  @override
  Future<void> pick(String? device, String? project) async {
    final ProjectRef picked = (device: device, project: project);
    _container
        .read(selectedProjectProvider.notifier)
        .switchTo(
          picked == _container.read(selectedProjectProvider)
              ? localProject(null)
              : picked,
        );
  }

  @override
  void starter(ComposerTrigger trigger, String name) =>
      insertCompletion(controller, completionOf(trigger), name);

  /// The screen at [at], what it reads watched through [reader].
  NewChatSnapshot snapshot(
    SettingReader reader,
    ProjectRef at, {
    required bool starting,
  }) {
    final question = reader.watch(newChatQuestionProvider(at));
    final showStarters = reader.watch(showCommandChipsProvider);
    final named = reader.watch(projectListProvider).value ?? const <String>[];
    final peers = reader.watch(syncPeersProvider);
    final entries = remoteEntries(
      reader.watch(remoteChatsProvider),
      reader.watch(deviceProjectsProvider),
      peers,
    );
    final devices = {for (final e in entries) e.scope.device!};
    return NewChatSnapshot(
      present: true,
      question: question,
      image: _athena,
      projects: [
        for (final project in everyProject(named).whereType<String>())
          ProjectChoice(
            project: project,
            label: projectLabel(project),
            // Only a built-in ships an icon; a user's badge is its name.
            glyph: projectIcon(project) == null
                ? null
                : projectShellGlyph(project),
            omada: reader.watch(omadaOnProvider(project)),
          ),
      ],
      devices: [
        for (final device in devices)
          DeviceSnapshot(
            name: peers[device]?.name ?? device,
            offline: peers[device]?.status != PeerStatus.online,
            projects: [
              for (final entry in entries)
                if (entry.scope.device == device)
                  ProjectChoice(
                    device: device,
                    project: entry.scope.project,
                    label: projectLabel(entry.scope.project),
                    omada: entry.omada,
                  ),
            ],
          ),
      ],
      selected: ProjectPick(device: at.device, project: at.project),
      // Only while the row is drawn: a hidden row's list is work the Swift
      // throws away, and watching the library for it keeps this screen
      // subscribed to every reload for nothing.
      starters: showStarters ? _starterChips(reader, at) : const [],
      showStarters: showStarters,
      starting: starting,
    );
  }

  /// The things the composer's menus would offer here, as the chips that name
  /// them. Build only, since it watches the library.
  ///
  /// No cap: everything the library holds is on offer, as on the Flutter row,
  /// since the screen scrolls and everything the user has written is a menu
  /// that `/` opens anyway.
  List<StarterSnapshot> _starterChips(SettingReader reader, ProjectRef at) {
    return [
      for (final kind in CompletionKind.values)
        for (final option in reader.watch(
          completionsProvider((project: at, kind: kind)),
        ))
          StarterSnapshot(
            trigger: triggerOf(kind),
            name: option.name,
            detail: option.description,
          ),
    ];
  }
}
