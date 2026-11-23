import "package:flutter/material.dart";

import "stand_in_bar.dart";

/// What sits where the composer does while a paired device is away: why
/// there is nothing to type into, over a snapshot that has stopped moving.
class ViewOnlyBar extends StatelessWidget {
  const ViewOnlyBar({super.key});

  @override
  Widget build(BuildContext context) => const StandInBar(
    icon: Icons.cloud_off_outlined,
    text: "Offline — showing what this device last had",
    alarming: true,
  );
}

/// The strip under the title bar of a page whose data is a paired device's —
/// a mirrored chat, its settings, a project there — and the one thing on it
/// that says so. A row of its own rather than over the content, so nothing
/// under it is hidden. Its states are the same shape, so they are one widget.
class MirrorStrip extends StatelessWidget {
  /// Read, written and run there.
  const MirrorStrip.remote({super.key, required this.deviceName})
    : offline = false;

  /// The home device has gone. Nothing here is moving any more.
  const MirrorStrip.offline({super.key, required this.deviceName})
    : offline = true;

  final String deviceName;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = offline ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    return Material(
      color: offline ? scheme.errorContainer : scheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                offline ? Icons.wifi_off_outlined : Icons.devices_other,
                size: 16,
                color: on,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  offline ? "$deviceName is offline" : "On $deviceName",
                  style: TextStyle(color: on, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A settings page's line saying whose values it shows: [deviceName]'s, and
/// while it is away, that nothing changes until it is back.
class DeviceNotice extends StatelessWidget {
  const DeviceNotice({
    super.key,
    required this.what,
    required this.deviceName,
    required this.online,
  });

  /// What lives there: "chat", "project".
  final String what;
  final String deviceName;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        online
            ? "This $what lives on $deviceName."
            : "$deviceName is offline. These settings can be changed once it "
                  "is back.",
        style: theme.textTheme.bodySmall?.copyWith(
          color: online
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.error,
        ),
      ),
    );
  }
}
