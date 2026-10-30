import "package:flutter/material.dart";

/// What sits where the composer does while a paired device is away: why
/// there is nothing to type into, over a snapshot that has stopped moving.
class ViewOnlyBar extends StatelessWidget {
  const ViewOnlyBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, size: 16, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                "Offline — showing what this device last had",
                style: TextStyle(color: color, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
