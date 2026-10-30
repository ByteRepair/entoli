import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "share_target_page.dart";

/// Wraps the app so a share from another app can be offered a workspace over
/// whatever is on screen. Android's, and only Android's: everywhere else
/// `FileHandoff.takeShare` answers with nothing and this is a pass-through.
///
/// Both routes in are needed and neither is enough. The read at startup catches
/// the share that launched the app, where Kotlin had staged the files before
/// Dart was listening; [FileHandoff.shareArrived] catches the one that arrives
/// while the app is already up, including into an activity whose engine was
/// cached and whose `main` therefore does not run again.
class IncomingShares extends ConsumerStatefulWidget {
  const IncomingShares({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingShares> createState() => _IncomingSharesState();
}

class _IncomingSharesState extends ConsumerState<IncomingShares> {
  StreamSubscription<void>? _arrivals;

  /// One page at a time: a second share while the first is still being placed
  /// would otherwise stack two identical pages, and the second read would find
  /// nothing anyway.
  var _asking = false;

  @override
  void initState() {
    super.initState();
    _arrivals = ref
        .read(fileHandoffProvider)
        .shareArrived
        .listen((_) => _claim());
    WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
  }

  @override
  void dispose() {
    _arrivals?.cancel();
    super.dispose();
  }

  Future<void> _claim() async {
    if (_asking) return;
    _asking = true;
    try {
      final files = await ref.read(fileHandoffProvider).takeShare();
      if (files.isEmpty || !mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => ShareTargetPage(files: files)));
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
