import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// A page's work in progress, as the two logical pixels under whatever started
/// it. A bar rather than a spinner over the page: the work here is a file being
/// read or written and there is nothing to do in the meantime.
///
/// A `ValueListenable` rather than a bool, since the pages holding one keep it
/// as a notifier so that a toggle does not rebuild what is above the bar.
class BusyBar extends StatelessWidget {
  const BusyBar(this.busy, {super.key});

  final ValueListenable<bool> busy;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: busy,
        builder: (context, running, _) => SizedBox(
          height: 2,
          child: running ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
      );
}

/// Run [work] with [busy] raised, one at a time, saying what went wrong rather
/// than throwing. Both callers end at a plugin or a filesystem, where a refusal
/// is the ordinary case rather than a bug, and where the page is still on
/// screen to be told.
Future<void> whileBusy(
  BuildContext context,
  ValueNotifier<bool> busy,
  Future<void> Function() work,
) async {
  if (busy.value) return;
  busy.value = true;
  try {
    await work();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("That did not work: $e")));
    }
  } finally {
    if (context.mounted) busy.value = false;
  }
}
