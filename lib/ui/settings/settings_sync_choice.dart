import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/sync/settings_merge.dart";
import "package:entoli_core/view/widgets/dialogs.dart";

import "../../app/settings_sync.dart";
import "../../data/sync/sync_hub.dart";
import "../../providers.dart";

/// Which side of a pair a choice names.
enum _Side { here, none, there }

/// Who wins where both of a pair changed the same profile field or provider:
/// this device, neither (the two do not sync them), or the peer. Three
/// segments, this device's name first, the way the theme's are.
class SettingsSyncChoice extends ConsumerWidget {
  const SettingsSyncChoice({
    super.key,
    required this.deviceId,
    required this.peerName,
  });

  final String deviceId;
  final String peerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hub = ref.watch(syncHubProvider);
    final sync = hub.settingsSync;
    return ValueListenableBuilder<Map<String, SyncPrecedence?>>(
      valueListenable: sync.precedences,
      builder: (context, precedences, _) {
        final side = switch (precedences[deviceId]) {
          null => null,
          SyncPrecedence(:final winner) when winner == null => _Side.none,
          SyncPrecedence(:final winner) when winner == deviceId => _Side.there,
          _ => _Side.here,
        };
        return SegmentedButton<_Side>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: _Side.here, label: Text(hub.deviceName)),
            const ButtonSegment(value: _Side.none, label: Text("No Sync")),
            ButtonSegment(value: _Side.there, label: Text(peerName)),
          ],
          selected: {?side},
          emptySelectionAllowed: side == null,
          onSelectionChanged: (picked) => unawaited(
            sync
                .choose(deviceId, switch (picked.first) {
                  _Side.here => sync.selfId,
                  _Side.none => null,
                  _Side.there => deviceId,
                })
                .catchError((Object e) {
                  if (context.mounted) say(context, e);
                }),
          ),
        );
      },
    );
  }
}

/// What the choice means, said under it wherever it is drawn.
const settingsSyncExplained =
    "Your profile and providers, keys included, are kept the same on both "
    "devices. The latest edit wins; where both changed the same thing, the "
    "device chosen here does.";

/// Asks, over [child], which device wins for each paired device that has
/// connected with nothing chosen: the first time two devices meet. Once per
/// device per launch, a dialog dismissed being asked again next time.
class SettingsSyncPrompt extends ConsumerStatefulWidget {
  const SettingsSyncPrompt({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SettingsSyncPrompt> createState() => _SettingsSyncPromptState();
}

class _SettingsSyncPromptState extends ConsumerState<SettingsSyncPrompt> {
  late final SettingsSync? _sync = ref.read(settingsSyncProvider);
  final _asked = <String>{};

  @override
  void initState() {
    super.initState();
    _sync?.undecided.addListener(_ask);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  @override
  void dispose() {
    _sync?.undecided.removeListener(_ask);
    super.dispose();
  }

  void _ask() {
    final sync = _sync;
    if (!mounted || sync == null) return;
    for (final peerId in sync.undecided.value) {
      if (!_asked.add(peerId)) continue;
      final name =
          ref.read(syncPeersProvider)[peerId]?.name ?? "the other device";
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => _ChoiceDialog(peerId: peerId, peerName: name),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ChoiceDialog extends ConsumerWidget {
  const _ChoiceDialog({required this.peerId, required this.peerName});

  final String peerId;
  final String peerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncHubProvider).settingsSync;
    // Chosen here or on the other device: either closes it.
    return ValueListenableBuilder<Set<String>>(
      valueListenable: sync.undecided,
      builder: (context, undecided, _) {
        if (!undecided.contains(peerId)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
        }
        return AlertDialog(
          title: Text("Sync with $peerName?"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Choose whose profile and providers to keep. "
                "$settingsSyncExplained",
              ),
              const SizedBox(height: 16),
              SettingsSyncChoice(deviceId: peerId, peerName: peerName),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Later"),
            ),
          ],
        );
      },
    );
  }
}
