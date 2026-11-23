import "package:flutter/material.dart";

import "dialogs.dart" show confirm;

/// An editor page's way out that loses what was typed: every pop of the route
/// under it — the back key, the bar's back arrow, [DiscardButton], a swipe —
/// asks first where [edited] says there is something to lose, and leaves at
/// once where there is not. The answer is asked for when the pop comes rather
/// than held, since most of what a page edits is in controllers that change
/// without a rebuild.
///
/// Save leaves by `Navigator.pop`, which a `PopScope` does not stop, so a page
/// needs nothing else to tell saving from discarding.
class DiscardGuard extends StatelessWidget {
  const DiscardGuard({
    super.key,
    required this.edited,
    required this.child,
    this.title = "Discard changes",
    this.message = "Throw away these edits?",
  });

  final bool Function() edited;
  final Widget child;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final leave =
          !edited() ||
          await confirm(
            context,
            title: title,
            message: message,
            confirmLabel: "Discard",
            destructive: true,
          );
      if (leave && context.mounted) Navigator.of(context).pop();
    },
    child: child,
  );
}

/// The app bar's leading for a page under [DiscardGuard] whose way out is
/// discarding rather than going back: a close, through the guard.
class DiscardButton extends StatelessWidget {
  const DiscardButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.close),
    tooltip: "Discard",
    onPressed: () => Navigator.of(context).maybePop(),
  );
}
