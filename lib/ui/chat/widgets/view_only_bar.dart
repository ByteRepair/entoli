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

/// The strip over a chat this device is driving from afar. It is the one
/// thing on the page that says the commands are running somewhere else, which
/// is the whole difference between this and a chat of one's own.
class InControlBar extends StatelessWidget {
  const InControlBar({
    super.key,
    required this.deviceName,
    required this.onRelease,
  });

  final String deviceName;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline,
                  size: 16, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Running on $deviceName",
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onRelease,
                child: const Text("Hand back"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The banner over a mirrored chat whose home device has gone away. Floating
/// over the conversation rather than displacing it: the point of keeping the
/// snapshot is that it stays readable.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.deviceName});

  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.wifi_off_outlined,
                  size: 16, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "$deviceName is offline",
                  style: TextStyle(
                      color: theme.colorScheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
