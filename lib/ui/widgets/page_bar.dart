import "package:flutter/material.dart";

import "discard_guard.dart";

/// A pushed page's bar, said as what it holds rather than drawn: a [title],
/// the line under it, how the page is left, and its [actions]. It is an
/// [AppBar].
///
/// [bottom] is a page's tabs, or a search under its bar.
class PageBar extends StatelessWidget implements PreferredSizeWidget {
  const PageBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading = PageLeading.back,
    this.onBack,
    this.actions = const [],
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final PageLeading leading;

  /// What leaving runs, in place of the back key.
  final VoidCallback? onBack;
  final List<PageAction> actions;
  final PreferredSizeWidget? bottom;

  /// The [AppBar]'s.
  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: leading != PageLeading.none,
    leading: switch (leading) {
      PageLeading.close => const DiscardButton(),
      PageLeading.back when onBack != null => BackButton(onPressed: onBack),
      PageLeading.back || PageLeading.none => null,
    },
    title: subtitle == null
        ? Text(title, overflow: TextOverflow.ellipsis)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, overflow: TextOverflow.ellipsis),
              Text(
                subtitle!,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
    actions: [for (final action in actions) action._button(context)],
    bottom: bottom,
  );
}

/// How a page is left: back to the one under it, or closed, discarding what
/// it holds (`DiscardGuard` asking first).
enum PageLeading {
  back,
  close,

  /// Nothing: a page left only by its own actions.
  none,
}

/// One of a page's buttons, said once and drawn by whichever bar the page
/// has: a button in its [AppBar], or an item of the window's title bar.
sealed class PageAction {
  const PageAction();

  /// A button drawn as its [icon], named by [label].
  const factory PageAction.icon({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) = PageIconAction;

  /// The page's tick: what keeps what was done on it.
  const factory PageAction.confirm({
    String label,
    required VoidCallback? onPressed,
  }) = PageConfirmAction;

  /// A button that says what it does; [prominent] is the page's one
  /// action, in the accent's fill.
  const factory PageAction.text({
    required String label,
    required VoidCallback? onPressed,
    bool prominent,
  }) = PageTextAction;

  /// A button opening [items].
  const factory PageAction.menu({
    IconData? icon,
    required String label,
    required List<PageMenuItem> items,
  }) = PageMenuAction;

  /// As the [AppBar] draws it.
  Widget _button(BuildContext context);
}

/// One choice of a [PageAction.menu].
class PageMenuItem {
  const PageMenuItem({
    required this.label,
    required this.onSelected,
    this.icon,
    this.hint,
    this.checked,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onSelected;
  final IconData? icon;

  /// Drawn after the label, quieter: a key or a trigger.
  final String? hint;

  /// Ticked or not, for a choice that turns something on and off; null for
  /// one that does a thing.
  final bool? checked;
  final bool enabled;
}

class PageIconAction extends PageAction {
  const PageIconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget _button(BuildContext context) =>
      IconButton(icon: Icon(icon), tooltip: label, onPressed: onPressed);
}

class PageConfirmAction extends PageAction {
  const PageConfirmAction({this.label = "Save", required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget _button(BuildContext context) => IconButton(
    icon: const Icon(Icons.check),
    tooltip: label,
    onPressed: onPressed,
  );
}

class PageTextAction extends PageAction {
  const PageTextAction({
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget _button(BuildContext context) => prominent
      ? Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton(onPressed: onPressed, child: Text(label)),
        )
      : TextButton(onPressed: onPressed, child: Text(label));
}

class PageMenuAction extends PageAction {
  const PageMenuAction({this.icon, required this.label, required this.items});

  final IconData? icon;
  final String label;
  final List<PageMenuItem> items;

  @override
  Widget _button(BuildContext context) => PopupMenuButton<VoidCallback>(
    icon: icon == null ? null : Icon(icon),
    tooltip: label,
    onSelected: (run) => run(),
    itemBuilder: (context) => [
      for (final item in items)
        if (item.checked case final checked?)
          CheckedPopupMenuItem(
            checked: checked,
            enabled: item.enabled,
            value: item.onSelected,
            child: Text(item.label),
          )
        else
          PopupMenuItem(
            enabled: item.enabled,
            value: item.onSelected,
            child: ListTile(
              leading: item.icon == null ? null : Icon(item.icon),
              title: Text(item.label),
              trailing: item.hint == null ? null : _Hint(item.hint!),
              contentPadding: EdgeInsets.zero,
            ),
          ),
    ],
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
