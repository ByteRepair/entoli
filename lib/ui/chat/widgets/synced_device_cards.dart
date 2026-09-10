import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/sync/sync_hub.dart";
import "../../../domain/models.dart";
import "../../../domain/project.dart";
import "../../../providers.dart";
import "../../sidebar/sidebar.dart";

/// The new-chat screen's cards for the projects of the devices paired with
/// this one, below the mark, the question, the badges and the chips.
///
/// The data is [RemoteChatEntry]s — chats mirrored from a paired device,
/// whose welcome named it. **That is also the limit of what is honest to
/// draw**: a project exists at this end only where one of its chats has been
/// mirrored, which is why the cards group the mirror list rather than asking
/// a paired device for a listing of its own — there is no such message. A
/// device with nothing mirrored has no card, and a card's counts are of what
/// this device holds, which is what a mirror reads anyway.
///
/// A card is a [RemoteScope] with a label, which is what makes tapping it
/// [selectRemote] — the sidebar switcher's own action, so the two ways into a
/// paired device's project cannot come to disagree about what picking it
/// means. The card carries no buttons of its own; the chat list it opens is
/// the sidebar's, under it.
class SyncedDeviceCards extends ConsumerWidget {
  const SyncedDeviceCards();

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
/// device's project rows away and brings them back, and, when it is open,
/// the rows under it.
class _DeviceGroup {
  _DeviceGroup({
    required this.deviceId,
    required this.deviceName,
    required this.online,
    required this.projects,
  });

  final String deviceId;
  final String deviceName;

  /// Whether the connection to them is up, as any entry this device
  /// contributed said. The header shows it; the list behind a tap is readable
  /// either way, a snapshot being what a mirror holds.
  final bool online;

  final List<_ProjectGroup> projects;
}

/// One project's share of a device's card: its name and the chats of it this
/// device mirrors, newest first.
class _ProjectGroup {
  _ProjectGroup({required this.project, required this.chats});

  /// Null is that device's default project, named the way [projectLabel]
  /// names it everywhere else a project is shown.
  final String? project;

  final List<ChatState> chats;

  String get label => projectLabel(project);
}

/// Every device that has a mirrored chat, each with the projects its mirrors
/// sit in. Devices sorted by name and projects by label, so a state diff
/// arriving again does not reshuffle what is on screen.
List<_DeviceGroup> _deviceGroups(List<RemoteChatEntry> entries) {
  final devices = <String, ({String name, bool online})>{};
  final projects = <String, Map<String?, List<ChatState>>>{};
  for (final entry in entries) {
    final device = devices[entry.deviceId] ??= (
      name: entry.deviceName,
      online: entry.online,
    );
    devices[entry.deviceId] = (
      name: device.name,
      online: device.online || entry.online,
    );
    projects
        .putIfAbsent(entry.deviceId, () => {})[entry.state.project] ??= [];
    projects[entry.deviceId]![entry.state.project]!.add(entry.state);
  }
  return [
    for (final MapEntry(key: id, value: device) in devices.entries)
      _DeviceGroup(
        deviceId: id,
        deviceName: device.name,
        online: device.online,
        projects: [
          for (final MapEntry(key: project, value: chats)
              in projects[id]!.entries)
            _ProjectGroup(
              project: project,
              chats: chats
                ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
            ),
        ]..sort((a, b) =>
              a.label.toLowerCase().compareTo(b.label.toLowerCase())),
      ),
  ]..sort((a, b) =>
      a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase()));
}

/// One device's card: the header row that folds it, and, when it is open, the
/// project rows under it. Folded to start, the way [ActivityGroup] — the
/// toggle this one answers to — starts, and in-memory: a screen that exists
/// to be left has no state worth carrying out of it.
class _DeviceCard extends StatefulWidget {
  const _DeviceCard({required this.group, required this.onOpen});

  final _DeviceGroup group;

  /// The device's project being read, named the way [RemoteScope] names one.
  final void Function(String? project) onOpen;

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
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
                  _OnlineDot(online: group.online),
                  const SizedBox(width: 8),
                  Text(
                    "${group.projects.length} "
                    "${group.projects.length == 1 ? "project" : "projects"}",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final project in group.projects)
                    _ProjectRow(
                      project: project,
                      onOpen: () => widget.onOpen(project.project),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One project row of a device's card: the whole row is the tap, which reads
/// that device's project through the sidebar's switcher.
class _ProjectRow extends ConsumerWidget {
  const _ProjectRow({required this.project, required this.onOpen});

  final _ProjectGroup project;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = project.project;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            // A built-in project's icon sits in the slot a user project
            // reserves, the way the empty-chat badges and the sidebar's menu
            // keep the labels aligned.
            if (projectIcon(name) case final icon?)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(icon, size: 18),
              )
            else
              const SizedBox(width: 28),
            Expanded(
              child: Text(
                project.label,
                overflow: TextOverflow.ellipsis,
                style: projectLabelStyle(
                  name != null && ref.watch(omadaOnProvider(name)),
                ),
              ),
            ),
            Text(
              "${project.chats.length} "
              "${project.chats.length == 1 ? "chat" : "chats"}",
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnlineDot extends StatelessWidget {
  const _OnlineDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Icon(
      online ? Icons.circle : Icons.circle_outlined,
      size: 10,
      color: online ? Colors.green : theme.colorScheme.onSurfaceVariant,
    );
  }
}