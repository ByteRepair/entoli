import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../shell/shell_page_bar.dart";
import "discard_guard.dart";
import "liquid_glass.dart";

/// A pushed page's bar, said as what it holds rather than drawn: a [title],
/// the line under it, how the page is left, and its [actions]. Without the
/// native shell it is an [AppBar]; under Liquid Glass it is the window's own
/// title bar, which the system draws. A page knows nothing of which, and each
/// [PageAction] draws itself either way. See "Liquid Glass" in
/// `lib/ui/AGENTS.md`.
///
/// [bottom] — a page's tabs, a search under its bar — is Flutter's either
/// way, drawn beneath whichever bar is above it.
class PageBar extends ConsumerWidget implements PreferredSizeWidget {
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

  /// The [AppBar]'s: a [Scaffold] gives the bar up to this much and takes
  /// what it draws, which under the shell is no more than [bottom].
  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A page, not a dialog's: a dialog covers nothing, the window's bar
    // staying the conversation's.
    final native =
        ref.watch(liquidGlassProvider).on &&
        ModalRoute.of(context) is PageRoute;
    return native ? _native(context) : _flutter(context);
  }

  Widget _flutter(BuildContext context) => AppBar(
    leading: switch (leading) {
      PageLeading.close => const DiscardButton(),
      PageLeading.back when onBack != null => BackButton(onPressed: onBack),
      PageLeading.back => null,
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

  Widget _native(BuildContext context) {
    final presses = _Presses();
    final dismisses = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShellPageBar(
          bar: TitleBarSnapshot(
            title: title,
            subtitle: subtitle ?? "",
            leading: switch (leading) {
              PageLeading.close => TitleBarLeading.close,
              PageLeading.back when onBack != null || dismisses =>
                TitleBarLeading.back,
              PageLeading.back => null,
            },
            items: [for (final action in actions) action._item(presses)],
          ),
          onBack: onBack ?? () => Navigator.of(context).maybePop(),
          actions: presses.runs,
        ),
        // Under the window's title bar, which the shell reports as padding.
        SizedBox(height: MediaQuery.paddingOf(context).top),
        ?bottom,
      ],
    );
  }
}

/// How a page is left: back to the one under it, or closed, discarding what
/// it holds (`DiscardGuard` asking first).
enum PageLeading { back, close }

/// One of a page's buttons, said once and drawn by whichever bar the page
/// has: a button in its [AppBar], or an item of the window's title bar.
sealed class PageAction {
  const PageAction();

  /// A button drawn as its [icon], named by [label].
  const factory PageAction.icon({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) = _IconAction;

  /// The page's tick: what keeps what was done on it.
  const factory PageAction.confirm({
    String label,
    required VoidCallback? onPressed,
  }) = _ConfirmAction;

  /// A button that says what it does; [prominent] is the page's one
  /// action, in the accent's fill.
  const factory PageAction.text({
    required String label,
    required VoidCallback? onPressed,
    bool prominent,
  }) = _TextAction;

  /// A button opening [items].
  const factory PageAction.menu({
    IconData? icon,
    required String label,
    required List<PageMenuItem> items,
  }) = _MenuAction;

  /// As the [AppBar] draws it.
  Widget _button(BuildContext context);

  /// As the window's title bar draws it, what a press runs kept in
  /// [presses] under the id the item is sent with.
  TitleBarItem _item(_Presses presses);
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

class _IconAction extends PageAction {
  const _IconAction({
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

  @override
  TitleBarItem _item(_Presses presses) {
    final symbol = _symbolOf(icon);
    return TitleBarItem(
      id: presses.add(onPressed),
      label: label,
      symbol: symbol,
      // An icon the system has no symbol for says what it does instead.
      style: symbol == null ? TitleBarItemStyle.text : TitleBarItemStyle.icon,
      enabled: onPressed != null,
    );
  }
}

class _ConfirmAction extends PageAction {
  const _ConfirmAction({this.label = "Save", required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget _button(BuildContext context) => IconButton(
    icon: const Icon(Icons.check),
    tooltip: label,
    onPressed: onPressed,
  );

  @override
  TitleBarItem _item(_Presses presses) => TitleBarItem(
    id: presses.add(onPressed),
    label: label,
    symbol: "checkmark",
    style: TitleBarItemStyle.confirm,
    enabled: onPressed != null,
  );
}

class _TextAction extends PageAction {
  const _TextAction({
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

  @override
  TitleBarItem _item(_Presses presses) => TitleBarItem(
    id: presses.add(onPressed),
    label: label,
    style: prominent ? TitleBarItemStyle.prominent : TitleBarItemStyle.text,
    enabled: onPressed != null,
  );
}

class _MenuAction extends PageAction {
  const _MenuAction({this.icon, required this.label, required this.items});

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

  @override
  TitleBarItem _item(_Presses presses) => TitleBarItem(
    id: presses.add(null),
    label: label,
    symbol: (icon == null ? null : _symbolOf(icon!)) ?? "ellipsis.circle",
    menu: [
      for (final item in items)
        if (item.enabled)
          TitleBarMenuItem(
            id: presses.add(item.onSelected),
            label: item.label,
            hint: item.hint,
            symbol: item.icon == null ? null : _symbolOf(item.icon!),
            checked: item.checked ?? false,
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

/// What each item of a title bar runs when pressed, by the id it was sent
/// under.
class _Presses {
  final Map<String, VoidCallback> runs = {};
  int _next = 0;

  String add(VoidCallback? run) {
    final id = "${_next++}";
    if (run != null) runs[id] = run;
    return id;
  }
}

/// The SF Symbol the system draws for one of the app's Material icons, or
/// null where it has none named here.
String? _symbolOf(IconData icon) => _symbols[icon];

final Map<IconData, String> _symbols = {
  Icons.add: "plus",
  Icons.check: "checkmark",
  Icons.checklist: "checklist",
  Icons.close: "xmark",
  Icons.copy: "doc.on.doc",
  Icons.copy_all_outlined: "doc.on.doc",
  Icons.create_new_folder_outlined: "folder.badge.plus",
  Icons.delete_outline: "trash",
  Icons.edit_outlined: "pencil",
  Icons.filter_list: "line.3.horizontal.decrease",
  Icons.format_size: "textformat.size",
  Icons.open_in_browser: "safari",
  Icons.open_in_new: "arrow.up.forward.square",
  Icons.restart_alt: "arrow.counterclockwise",
  Icons.save_outlined: "square.and.arrow.down",
  Icons.visibility_outlined: "eye",
};
