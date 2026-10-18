import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/sync/sync_hub.dart";
import "../../../domain/project.dart";
import "../../../providers.dart";
import "../../sidebar/sidebar.dart";
import "../../widgets/chip_row.dart";

/// The new-chat screen's cards for the projects of the devices paired with
/// this one, below the mark, the question, the badges and the chips.
///
/// The data is [RemoteChatEntry]s — chats mirrored from a paired device,
/// whose welcome named it. **That is also the limit of what is honest to
/// draw**: a project exists at this end only where one of its chats has been
/// mirrored, which is why the cards group the mirror list rather than asking
/// a paired device for a listing of its own — there is no such message. A
/// device with nothing mirrored has no card.
///
/// A badge is a [RemoteScope] with a label, which is what makes tapping it
/// [selectRemote] — the sidebar switcher's own action, so the two ways into a
/// paired device's project cannot come to disagree about what picking it
/// means. The card carries no buttons of its own; the chat list it opens is
/// the sidebar's, under it.
class SyncedDeviceCards extends ConsumerWidget {
  const SyncedDeviceCards({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = _deviceGroups(ref.watch(remoteChatsProvider));
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _DeviceCard(group: group),
          ),
      ],
    );
  }
}

/// One device's share of the new-chat screen: the header that folds the
/// device's badges away and brings them back, and, when it is open, the
/// badges under it.
class _DeviceGroup {
  _DeviceGroup({
    required this.deviceId,
    required this.deviceName,
    required this.projects,
    required this.omada,
  });

  final String deviceId;
  final String deviceName;

  /// The projects this device's mirrors sit in, label-sorted. Null is that
  /// device's default project, named the way [projectLabel] names it
  /// everywhere else a project is shown.
  final List<String?> projects;

  /// Those of [projects] with Omada on at the device, not here.
  final Set<String?> omada;
}

/// Every device that has a mirrored chat, with the projects its mirrors sit
/// in. Devices sorted by name and projects by label, so a state diff arriving
/// again does not reshuffle what is on screen.
List<_DeviceGroup> _deviceGroups(List<RemoteChatEntry> entries) {
  final names = <String, String>{};
  final projects = <String, Set<String?>>{};
  final omada = <String, Set<String?>>{};
  for (final entry in entries) {
    names[entry.deviceId] ??= entry.deviceName;
    (projects[entry.deviceId] ??= {}).add(entry.state.project);
    if (entry.omada) (omada[entry.deviceId] ??= {}).add(entry.state.project);
  }
  return [
    for (final id in names.keys)
      _DeviceGroup(
        deviceId: id,
        deviceName: names[id]!,
        projects: projects[id]!.toList()..sort((a, b) => projectLabel(a)
            .toLowerCase()
            .compareTo(projectLabel(b).toLowerCase())),
        omada: omada[id] ?? const {},
      ),
  ]..sort((a, b) =>
      a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase()));
}

/// One device's card: the header row that folds it, and, when it is open, the
/// project badges under it. Folded to start, the way [ActivityGroup] — the
/// toggle this one answers to — starts, and in-memory: a screen that exists
/// to be left has no state worth carrying out of it.
///
/// The badges are the same `ActionChip` in a `ChipRow` the empty-chat chips
/// are, so an unfold grows each of them out of nothing through the row's own
/// motion rather than a list appearing under the header. The header carries
/// the name and nothing else — no dot for the connection, no count of what is
/// folded behind it: what is there is one tap away either way.
class _DeviceCard extends ConsumerStatefulWidget {
  const _DeviceCard({required this.group});

  final _DeviceGroup group;

  @override
  ConsumerState<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<_DeviceCard> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = widget.group;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.devices_other,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      group.deviceName,
                      overflow: TextOverflow.ellipsis,
                      style: (theme.textTheme.titleSmall ?? const TextStyle())
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    _collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: ChipRow(
                entries: [
                  for (final project in group.projects)
                    ChipRowEntry(
                      key: ValueKey(project),
                      child: ActionChip(
                        label: ProjectChipLabel(project,
                            omada: group.omada.contains(project)),
                        onPressed: () => selectRemote(
                          ref,
                          (deviceId: group.deviceId, project: project),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
/// A project badge's label: its built-in icon where it has one, then its name.
/// In the label rather than the chip's avatar slot, since a `ChoiceChip`
/// paints its selected check over the avatar.
class ProjectChipLabel extends ConsumerWidget {
  const ProjectChipLabel(this.project, {this.omada, super.key});

  final String? project;

  /// Whether [project] runs Omada; null asks this device, which is wrong for
  /// a paired device's project of the same name.
  final bool? omada;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (projectIcon(project) case final icon?)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(icon, size: 18),
            ),
          Text(
            projectLabel(project),
            style: projectLabelStyle(omada ?? ref.watch(omadaOnProvider(project))),
          ),
        ],
      );
}
