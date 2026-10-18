import "package:flutter/material.dart";

/// What sits where the composer does on a mirrored chat nobody here is
/// driving: why there is nothing to type into, and the way to change that.
///
/// Taking control is a request. The button says what this device asked for,
/// never what it decided — the home device is the only thing that knows
/// whether somebody else got there first.
class ViewOnlyBar extends StatelessWidget {
  const ViewOnlyBar({
    super.key,
    required this.online,
    this.onTakeControl,
    this.asking = false,
    this.takenByAnother = false,
  });

  /// Whether the connection to the chat's home device is up. False means
  /// everything above is a stale snapshot.
  final bool online;

  /// Null where there is nothing to ask — offline, or somebody else has it.
  final VoidCallback? onTakeControl;

  /// Asked for, waiting on the home device.
  final bool asking;

  /// Another device holds it. There is nothing to press: the lock is theirs
  /// until they let it go or their connection does.
  final bool takenByAnother;

  String get _said {
    if (!online) return "Offline — showing what this device last had";
    if (takenByAnother) return "Another device is driving this chat";
    if (asking) return "Asking to take control…";
    return "View only";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = online ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error;
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
            Icon(online ? Icons.visibility_outlined : Icons.cloud_off_outlined,
                size: 16, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _said,
                style: TextStyle(color: color, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (online && !takenByAnother) ...[
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: asking ? null : onTakeControl,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text("Take control"),
              ),
            ],
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
  /// This device is driving. The commands are still the home device's.
  const MirrorStrip.inControl({
    super.key,
    required this.deviceName,
    required this.onRelease,
  })  : offline = false;

  /// Read and written there, nothing to hand back: a settings page's.
  const MirrorStrip.remote({super.key, required this.deviceName})
      : offline = false,
        onRelease = null;

  /// The home device has gone. Nothing here is moving any more.
  const MirrorStrip.offline({super.key, required this.deviceName})
      : offline = true,
        onRelease = null;

  final String deviceName;
  final bool offline;
  final VoidCallback? onRelease;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = offline ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    return Material(
      color: offline ? scheme.errorContainer : scheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, offline ? 8 : 4, offline ? 16 : 8,
              offline ? 8 : 4),
          child: Row(
            children: [
              Icon(
                  offline
                      ? Icons.wifi_off_outlined
                      : onRelease != null
                          ? Icons.play_circle_outline
                          : Icons.devices_other,
                  size: 16,
                  color: on),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  offline
                      ? "$deviceName is offline"
                      : onRelease != null
                          ? "Running on $deviceName"
                          : "On $deviceName",
                  style: TextStyle(color: on, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onRelease != null)
                TextButton(onPressed: onRelease, child: const Text("Hand back")),
            ],
          ),
        ),
      ),
    );
  }
}
