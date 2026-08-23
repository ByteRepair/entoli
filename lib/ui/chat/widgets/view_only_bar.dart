import "package:flutter/material.dart";

/// What sits where the composer does on a mirrored chat. A mirror sends
/// nothing itself in this phase — prompts travel with Take Control, which
/// lands later — so there is nothing to type into and the bar says so.
/// Offline it says why the content is not moving either.
class ViewOnlyBar extends StatelessWidget {
  const ViewOnlyBar({super.key, required this.online});

  /// Whether the connection to the chat's home device is up. False means
  /// everything above is a stale snapshot.
  final bool online;

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
            Text(
              online ? "View only" : "Offline — showing what this device last had",
              style: TextStyle(color: color, fontSize: 13),
            ),
          ],
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
