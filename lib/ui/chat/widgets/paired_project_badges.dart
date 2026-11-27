import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/project.dart";
import "package:entoli_core/view/chat/widgets/omada_separator.dart";

import "../../../data/sync/peers.dart" show PeerStatus;
import "../../../providers.dart";
import "../../selection.dart";
import "../../../app/remote_projects.dart";
import "../../widgets/chip_row.dart";
import "../../widgets/toggle_chip.dart";

/// The new-chat screen's badges for the projects of the devices paired with
/// this one: under a line naming each device, every project it last listed —
/// its default included, which here is a project like any other rather than
/// nothing selected — as a [ChoiceChip] the way this device's badges are.
/// Ticking one is [selectProject], the sidebar switcher's own action;
/// unticking it is back to this device's default.
class PairedProjectBadges extends ConsumerWidget {
  const PairedProjectBadges({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(syncPeersProvider);
    final selected = ref.watch(selectedProjectProvider);
    final entries = remoteEntries(
      ref.watch(remoteChatsProvider),
      ref.watch(deviceProjectsProvider),
      peers,
    );
    final devices = {for (final e in entries) e.scope.device!};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final device in devices) ...[
          ConversationSeparator(
            text: peers[device]?.status == PeerStatus.online
                ? peers[device]?.name ?? device
                : "${peers[device]?.name ?? device} · offline",
          ),
          ChipRow(
            entries: [
              for (final entry in entries)
                if (entry.scope.device == device)
                  ChipRowEntry(
                    key: ValueKey(entry.scope),
                    child: ProjectBadge(
                      entry.scope.project,
                      omada: entry.omada,
                      selected: entry.scope == selected,
                      onSelected: (on) => selectProject(
                        ref,
                        on ? entry.scope : localProject(null),
                      ),
                    ),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A project's badge: its built-in icon where it has one, then its name in
/// the style that says whether it runs Omada.
class ProjectBadge extends ConsumerWidget {
  const ProjectBadge(
    this.project, {
    required this.selected,
    required this.onSelected,
    this.omada,
    super.key,
  });

  final String? project;
  final bool selected;
  final ValueChanged<bool> onSelected;

  /// Whether [project] runs Omada; null asks this device, which is wrong for
  /// a paired device's project of the same name.
  final bool? omada;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = projectIcon(project);
    return ToggleChip(
      leading: icon == null ? null : Icon(icon, size: 18),
      label: Text(
        projectLabel(project),
        style: projectLabelStyle(omada ?? ref.watch(omadaOnProvider(project))),
      ),
      selected: selected,
      onSelected: onSelected,
    );
  }
}
