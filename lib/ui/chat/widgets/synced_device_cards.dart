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
            child: _DeviceCard(
              group: group,
              onOpen: (project) => selectRemote(
                ref,
                (deviceId: group.deviceId, project: project),
              ),
            ),
          ),
      ],
    );
  }
}

/// One device's share of the new-chat screen: the header that folds the
/// device's badges away and brings them back, and, when it is open, the
/// badges under it.
class _DeviceGroup {
  _DeviceGroup({required this.deviceId, required this.deviceName, required this.projects});

  final String deviceId;
  final String deviceName;

  /// The projects this device's mirrors sit in, label-sorted.
  final List<_ProjectGroup> projects;
}

/// One project's share of a device's card.
class _ProjectGroup {
  _ProjectGroup({required this.project});

  /// Null is that device's default project, named the way [projectLabel]
  /// names it everywhere else a project is shown.
  final String? project;

  String get label => projectLabel(project);
}

/// Every device that has a mirrored chat, with the projects its mirrors sit
/// in. Devices sorted by name and projects by label, so a state diff arriving
/// again does not reshuffle what is on screen.
List<_DeviceGroup> _deviceGroups(List<RemoteChatEntry> entries) {
  final devices = <String>{};
  final projects = <String, Map<String?, void>>{};
  for (final entry in entries) {
    devices.add(entry.deviceId);
    (projects[entry.deviceId] ??= {})[entry.state.project] = null;
  }
  return [
    for (final id in devices)
      _DeviceGroup(
        deviceId: id,
        deviceName:
            entries.firstWhere((entry) => entry.deviceId == id).deviceName,
        projects: [
          for (final project in projects[id]!.keys)
            _ProjectGroup(project: project),
        ]..sort((a, b) =>
              a.label.toLowerCase().compareTo(b.label.toLowerCase())),
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
  const _DeviceCard({required this.group, required this.onOpen});

  final _DeviceGroup group;

  /// The device's project being read, named the way [RemoteScope] names one.
  final void Function(String? project) onOpen;

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
                      key: ValueKey(project.project),
                      child: ActionChip(
                        // The icon rides in the label rather than the avatar
                        // slot, the way the empty-chat badges keep the label
                        // and any mark beside it one piece.
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (projectIcon(project.project) case final icon?)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(icon, size: 18),
                              ),
                            Text(
                              project.label,
                              style: projectLabelStyle(
                                project.project != null &&
                                    ref.watch(omadaOnProvider(project.project)),
                              ),
                            ),
                          ],
                        ),
                        onPressed: () => widget.onOpen(project.project),
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