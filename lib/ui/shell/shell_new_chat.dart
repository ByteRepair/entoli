import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/peers.dart" show PeerStatus;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../selection.dart";
import "../sidebar/remote_projects.dart";
import "../widgets/completion_field.dart";
import "shell_outbox.dart";
import "shell_slots.dart";
import "shell_sidebar.dart" show projectSymbol;

/// The asset the new-chat screen stands its figure on.
const _athena = "assets/images/athena.png";

/// How many starters the screen offers: a row or two of chips, not a
/// catalogue.
const _starters = 6;

/// The new-chat screen's body — `_EmptyChat` on the new-chat screen — drawn
/// by the native shell: the same question, badges and starters, read the same
/// way, sent as a [NewChatSnapshot]. A badge switches project through
/// [selectProject] and a starter types into [controller] through
/// [insertCompletion], as the Flutter screen's do.
class ShellNewChat extends ConsumerStatefulWidget {
  const ShellNewChat({
    super.key,
    required this.at,
    required this.controller,
    this.starting = false,
  });

  /// The project the next chat goes to, which may be a paired device's.
  final ProjectRef at;

  /// The composer's, so a starter can type into it.
  final TextEditingController controller;
  final bool starting;

  @override
  ConsumerState<ShellNewChat> createState() => ShellNewChatState();
}

class ShellNewChatState extends ConsumerState<ShellNewChat>
    implements NewChatIntents {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  @override
  void dispose() {
    if (_slots.newChat.leave(this)) {
      _outbox.newChat(NewChatSnapshot(present: false));
    }
    super.dispose();
  }

  /// A badge. Picking the one already picked is the default project, which
  /// is nothing picked: the row is a set of toggles.
  @override
  Future<void> pick(String? device, String? project) async {
    final ProjectRef picked = (device: device, project: project);
    selectProject(
      ref,
      picked == ref.read(selectedProjectProvider) ? localProject(null) : picked,
    );
  }

  @override
  void starter(String trigger, String name) => insertCompletion(
    widget.controller,
    trigger == "@" ? CompletionKind.agent : CompletionKind.skill,
    name,
  );

  @override
  Widget build(BuildContext context) {
    _slots.newChat.claim(this);
    final at = widget.at;
    final question = ref.watch(newChatQuestionProvider(at));
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final peers = ref.watch(syncPeersProvider);
    final entries = remoteEntries(
      ref.watch(remoteChatsProvider),
      ref.watch(deviceProjectsProvider),
      peers,
    );
    final devices = {for (final e in entries) e.scope.device!};
    _outbox.newChat(
      NewChatSnapshot(
        present: true,
        question: question,
        image: _athena,
        projects: [
          for (final project in everyProject(named).whereType<String>())
            ProjectChoice(
              device: null,
              project: project,
              label: projectLabel(project),
              // Only a built-in ships an icon; a user's badge is its name.
              symbol: projectIcon(project) == null
                  ? ""
                  : projectSymbol(project),
              omada: ref.watch(omadaOnProvider(project)),
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
                      symbol: "",
                      omada: entry.omada,
                    ),
              ],
            ),
        ],
        selected: ProjectPick(device: at.device, project: at.project),
        starters: [
          for (final kind in CompletionKind.values)
            for (final option in ref.watch(
              completionsProvider((project: at, kind: kind)),
            ))
              StarterSnapshot(
                trigger: kind.trigger,
                name: option.name,
                detail: option.description,
              ),
        ].take(_starters).toList(),
        starting: widget.starting,
      ),
    );
    return const SizedBox.shrink();
  }
}
