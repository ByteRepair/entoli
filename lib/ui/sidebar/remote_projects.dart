import "../../data/sync/peers.dart" show PeerState;
import "../../data/sync/sync_hub.dart" show RemoteChatEntry;
import "../../domain/project.dart";

/// How a project on a paired device is read out. Its default project is the
/// device's name alone — the local default has no name either, and inventing
/// one here would be the only place in the app that gives it one.
String remoteLabel(String deviceName, String? project) =>
    project == null ? deviceName : "$deviceName · ${projectLabel(project)}";

/// A project on a paired device, as the switcher lists it.
typedef RemoteEntry = ({ProjectRef scope, String label, bool omada, int count});

/// Every project of every paired device, one entry each, device first: what
/// the device last listed, whether or not anything of it is mirrored here.
List<RemoteEntry> remoteEntries(
  List<RemoteChatEntry> remotes,
  Map<String, List<String>> projects,
  Map<String, PeerState> peers,
) {
  final counts = <ProjectRef, int>{};
  final omada = <ProjectRef>{};
  for (final entry in remotes) {
    final ProjectRef scope = (
      device: entry.deviceId,
      project: entry.state.project,
    );
    counts[scope] = (counts[scope] ?? 0) + 1;
    if (entry.omada) omada.add(scope);
  }
  final entries = [
    for (final MapEntry(key: device, value: named) in projects.entries)
      for (final project in everyProject(named))
        if ((device: device, project: project) case final ProjectRef scope)
          (
            scope: scope,
            label: remoteLabel(peers[device]?.name ?? device, project),
            omada: omada.contains(scope),
            count: counts[scope] ?? 0,
          ),
  ];
  entries.sort(
    (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );
  return entries;
}
