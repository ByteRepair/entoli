import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../shell/shell_page_bar.dart";
import "../shell/snapshots.dart";
import "discard_guard.dart";
import "liquid_glass.dart";

/// A page's bar: an [AppBar], taking the same [title], [leading], [actions]
/// and [bottom], or under Liquid Glass the window's own title bar, drawn by
/// the system from those same widgets. A page says what its bar holds once
/// and in Flutter's words, and nothing of it knows which draws it: what an
/// [IconButton], a [TextButton] or a [PopupMenuButton] is natively, which SF
/// Symbol an icon is and that a tick is the system's confirm is said here,
/// and only here. See "Liquid Glass" in `lib/ui/AGENTS.md`.
///
/// What Flutter keeps under the shell is [bottom] — a page's tabs, a search
/// under its bar — drawn beneath the title bar where the [AppBar] drew it.
class PageBar extends ConsumerWidget implements PreferredSizeWidget {
  const PageBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget>? actions;
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
    if (!native) {
      return AppBar(
        leading: leading,
        title: title,
        actions: actions,
        bottom: bottom,
      );
    }
    // An action that rebuilds on its own sends the bar again when it would.
    final listenables = [
      for (final action in actions ?? const <Widget>[])
        if (action case ValueListenableBuilder(:final valueListenable))
          valueListenable,
    ];
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        final bar = _NativeBar.of(context, this);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShellPageBar(
              bar: bar.snapshot,
              onBack: bar.back,
              actions: bar.actions,
            ),
            // Under the window's title bar, which the shell reports as
            // padding.
            SizedBox(height: MediaQuery.paddingOf(context).top),
            ?bottom,
          ],
        );
      },
    );
  }
}

/// A title whose words are not one [Text]: what it says, to a title bar
/// that draws its own.
abstract interface class PageTitle {
  String get title;

  /// The line under it, if any.
  String? get subtitle;
}

/// [PageBar]'s widgets as the title bar the shell draws, and what each of
/// its buttons runs.
class _NativeBar {
  _NativeBar._(this._context);

  factory _NativeBar.of(BuildContext context, PageBar page) {
    final bar = _NativeBar._(context);
    final items = [
      for (final widget in page.actions ?? const <Widget>[]) ?bar._item(widget),
    ];
    final (title, subtitle) = _title(page.title);
    bar.snapshot = PageBarSnapshot(
      title: title,
      subtitle: subtitle ?? "",
      leading: bar._leading(page.leading),
      items: items,
    );
    return bar;
  }

  final BuildContext _context;
  late final PageBarSnapshot snapshot;
  final Map<String, VoidCallback> actions = {};

  /// What the title bar's way back runs: the leading's own, or the back key.
  late VoidCallback back = () => Navigator.of(_context).maybePop();

  int _ids = 0;
  String _id(VoidCallback? run) {
    final id = "${_ids++}";
    if (run != null) actions[id] = run;
    return id;
  }

  TitleBarLeading? _leading(Widget? leading) {
    switch (leading) {
      case null:
        final route = ModalRoute.of(_context);
        return route?.impliesAppBarDismissal ?? false
            ? TitleBarLeading.back
            : null;
      case DiscardButton() || CloseButton():
        return TitleBarLeading.close;
      case BackButton(:final onPressed):
        if (onPressed != null) back = onPressed;
        return TitleBarLeading.back;
      default:
        return TitleBarLeading.back;
    }
  }

  /// One of the actions, or null for one that draws nothing.
  ToolbarItem? _item(Widget widget) {
    switch (widget) {
      case Padding(:final child?) || Align(:final child?):
        return _item(child);
      case Builder(:final builder):
        return _item(builder(_context));
      case ValueListenableBuilder(:final valueListenable, :final child):
        // Untyped, as a menu's handler is below.
        final dynamic untyped = widget;
        return _item(untyped.builder(_context, valueListenable.value, child));
      case SizedBox(child: null):
        return null;
      case IconButton(:final icon, :final tooltip, :final onPressed):
        final data = icon is Icon ? icon.icon : null;
        final symbol = data == null ? null : _symbols[data];
        final label = tooltip ?? "";
        final tick = data == Icons.check;
        return ToolbarItem(
          id: _id(onPressed),
          label: label,
          symbol: symbol,
          // An icon with no symbol of its own says what it does instead.
          style: tick
              ? ToolbarStyle.confirm
              : symbol == null
              ? ToolbarStyle.text
              : ToolbarStyle.icon,
          enabled: onPressed != null,
        );
      case ButtonStyleButton(:final child, :final onPressed):
        return ToolbarItem(
          id: _id(onPressed),
          label: _words(child).join(" "),
          style: widget is FilledButton || widget is ElevatedButton
              ? ToolbarStyle.prominent
              : ToolbarStyle.text,
          enabled: onPressed != null,
        );
      case PopupMenuButton():
        return _menu(widget);
      default:
        return null;
    }
  }

  /// A [PopupMenuButton], its entries built now: the bar is sent again
  /// whenever the page builds, so what they say is never staler than the
  /// rest of it.
  ToolbarItem _menu(PopupMenuButton<dynamic> button) {
    final icon = button.icon;
    final data = icon is Icon ? icon.icon : null;
    // Read untyped: the button's is a function of its own entry type, which
    // a read through `dynamic` would check against and fail.
    final dynamic untyped = button;
    final dynamic picked = untyped.onSelected;
    return ToolbarItem(
      id: _id(null),
      label: button.tooltip ?? "More",
      symbol: (data == null ? null : _symbols[data]) ?? "ellipsis.circle",
      enabled: button.enabled,
      menu: [
        for (final entry in button.itemBuilder(_context))
          if (entry case PopupMenuItem(:final value, enabled: true))
            _choice(entry, () {
              if (picked != null) picked(value);
            }),
      ],
    );
  }

  /// One of a menu's entries, the first of its words its label and the rest
  /// a hint after it.
  ToolbarMenuItem _choice(PopupMenuItem<dynamic> entry, VoidCallback run) {
    final words = _words(entry.child);
    return ToolbarMenuItem(
      id: _id(run),
      label: words.firstOrNull ?? "",
      hint: words.length > 1 ? words.skip(1).join(" ") : null,
      checked: entry is CheckedPopupMenuItem && entry.checked,
    );
  }

  static (String, String?) _title(Widget? title) => switch (title) {
    PageTitle(:final title, :final subtitle) => (title, subtitle),
    _ => (_words(title).join(" "), null),
  };

  /// The words [widget] shows, from the widgets a bar's button or a menu's
  /// entry is made of.
  static List<String> _words(Widget? widget) => switch (widget) {
    Text(:final data?) => [data],
    Text(:final textSpan?) => [textSpan.toPlainText()],
    ListTile(:final title) => _words(title),
    Flex(:final children) => [for (final c in children) ..._words(c)],
    Padding(:final child) ||
    Align(:final child) ||
    SizedBox(:final child) => _words(child),
    Flexible(:final child) => _words(child),
    _ => const [],
  };

  /// The app's Material icons as the SF Symbols the system draws.
  static final Map<IconData, String> _symbols = {
    Icons.add: "plus",
    Icons.check: "checkmark",
    Icons.checklist: "checklist",
    Icons.close: "xmark",
    Icons.copy: "doc.on.doc",
    Icons.create_new_folder_outlined: "folder.badge.plus",
    Icons.delete_outline: "trash",
    Icons.edit_outlined: "pencil",
    Icons.filter_list: "line.3.horizontal.decrease",
    Icons.open_in_browser: "safari",
    Icons.open_in_new: "arrow.up.forward.square",
    Icons.restart_alt: "arrow.counterclockwise",
    Icons.save_outlined: "square.and.arrow.down",
    Icons.visibility_outlined: "eye",
  };
}
