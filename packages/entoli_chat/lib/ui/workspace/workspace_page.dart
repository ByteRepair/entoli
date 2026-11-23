import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../core/formatting.dart";
import "../../domain/file_handoff.dart";
import "../../domain/workspace.dart";
import "../../app/handoff.dart";
import "../../app/storage.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";
import "../widgets/page_bar.dart";
import "../widgets/text_file_page.dart";

/// Opens the explorer at [root], its bar saying [title] there.
Future<void> openWorkspace(
  BuildContext context, {
  required String root,
  required String title,
  bool readOnly = false,
  WorkspaceEmpty? whenEmpty,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => WorkspacePage(
      root: root,
      title: title,
      readOnly: readOnly,
      whenEmpty: whenEmpty,
    ),
  ),
);

/// What an empty folder says, in place of the explorer's own words.
typedef WorkspaceEmpty = ({String title, String detail});

/// A workspace folder, and what can be done with what is in it. Listing,
/// creating a folder and deleting are on every platform; the routes out of
/// the app are `FileHandoff`'s, and each is drawn only where it leads
/// somewhere — see AGENTS.md, "The workspace explorer".
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({
    super.key,
    required this.root,
    required this.title,
    this.readOnly = false,
    this.whenEmpty,
  });

  /// The folder the explorer cannot go above.
  final String root;

  /// What the bar says at the root: whose workspace this is.
  final String title;

  /// Browsed and read, nothing made or deleted: a shared chat's workspace.
  final bool readOnly;

  /// What an empty folder says. Null is that the agent's files land here.
  final WorkspaceEmpty? whenEmpty;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  late String _dir = widget.root;
  List<WorkspaceEntry>? _entries;
  Object? _error;

  /// Which read is the folder's latest: one for a folder already left must
  /// not land over the one being looked at.
  int _reading = 0;

  /// Paths rather than entries: the listing is re-read under a selection, and
  /// an entry from the old one would no longer be the object in the list.
  final _selected = <String>{};
  var _selecting = false;

  /// A notifier rather than state: the bar is two logical pixels, and a
  /// `setState` for it would rebuild the bar, the FAB and every visible row
  /// twice per tap.
  final _busy = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final reading = ++_reading;
    try {
      final entries = await ref.read(workspaceProvider).list(_dir);
      if (!mounted || reading != _reading) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
    } catch (e) {
      if (!mounted || reading != _reading) return;
      setState(() => _error = e);
    }
  }

  void _retry() {
    setState(() => _error = null);
    _read();
  }

  /// A selection is one folder's, which is what lets the share sheet be
  /// handed a flat staging directory — so leaving the folder ends it.
  void _goTo(String dir) {
    setState(() {
      _dir = dir;
      _entries = null;
      _error = null;
      _clearSelection();
    });
    _read();
  }

  /// The two always move together: a selection outside selection mode is a
  /// state the page does not have. The bar is the mode; the title and the
  /// share button are what is picked.
  void _clearSelection() {
    _selecting = false;
    _selected.clear();
  }

  bool get _atRoot => _dir == widget.root;

  /// Back — the bar's arrow and the system gesture alike — ends a selection,
  /// then goes up a folder before it leaves the page, unwinding the way the
  /// taps wound it up.
  void _back() {
    if (_selecting) return setState(_clearSelection);
    if (_atRoot) return Navigator.of(context).pop();
    _goTo(p.dirname(_dir));
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  /// A text file is read here and everything else is another app's, but the
  /// name is all this can decide on: the viewer pops `true` when the bytes
  /// turn out not to be text, and the hand-off below runs after all.
  Future<void> _open(WorkspaceEntry entry) async {
    if (entry.isDirectory) return _goTo(entry.path);
    if (looksTextual(entry.name)) {
      final handOff = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => TextFilePage(
            path: entry.path,
            name: entry.name,
            readOnly: widget.readOnly,
          ),
        ),
      );
      if (handOff != true || !mounted) return;
    }
    await _guard(() => ref.read(fileHandoffProvider).open(entry.path));
  }

  Future<void> _export(List<String> paths) async {
    if (paths.isEmpty) return;
    await _guard(() => ref.read(fileHandoffProvider).export(paths));
    if (mounted) setState(_clearSelection);
  }

  Future<void> _newFolder() async {
    final name = await promptForText(
      context,
      title: "New folder",
      initial: "",
      hint: "Name",
      confirmLabel: "Create",
    );
    if (name == null || !mounted) return;
    await _guard(() async {
      await ref.read(workspaceProvider).createFolder(_dir, name);
      await _read();
    });
  }

  Future<void> _delete(List<String> paths, {bool folder = true}) async {
    if (paths.isEmpty) return;
    final agreed = await confirm(
      context,
      title: paths.length == 1
          ? "Delete \"${p.basename(paths.first)}\"?"
          : "Delete ${paths.length} items?",
      message: folder
          ? "A folder goes with everything in it. This cannot be undone."
          : "This cannot be undone.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await _guard(() async {
      await ref.read(workspaceProvider).deleteEntries(paths);
      if (mounted) setState(_clearSelection);
      await _read();
    });
  }

  @override
  Widget build(BuildContext context) {
    final handoff = ref.watch(fileHandoffProvider);
    return PopScope(
      canPop: _atRoot && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: PageBar(
          onBack: _back,
          // The folder's name over where it sits under the root: losing the
          // path is losing the only thing that says which of two folders
          // called `src` this is.
          title: _selected.isNotEmpty
              ? "${_selected.length} selected"
              : (_atRoot ? widget.title : p.basename(_dir)),
          subtitle: _atRoot ? null : p.relative(_dir, from: widget.root),
          actions: _selecting ? _selectionActions() : _browseActions(handoff),
        ),
        floatingActionButton: !handoff.canShare || _selected.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _export(_selected.toList()),
                icon: const Icon(Icons.ios_share),
                label: const Text("Share"),
              ),
        body: Column(
          children: [
            // The row is there either way: a bar that appears would push the
            // listing down under the finger that started the work.
            BusyBar(_busy),
            Expanded(child: _body(handoff)),
          ],
        ),
      ),
    );
  }

  Widget _body(FileHandoff handoff) {
    if (_error case final error?) {
      return EmptyPane(
        icon: Icons.error_outline,
        title: "That folder could not be read",
        detail: "$error",
        action: TextButton(onPressed: _retry, child: const Text("Try again")),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return EmptyPane(
        icon: Icons.folder_open,
        title: widget.whenEmpty?.title ?? "Nothing here yet",
        detail:
            widget.whenEmpty?.detail ??
            "The agent's files land here."
                "${handoff.canShare ? " Share files to Entoli to add your own." : ""}",
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return _Row(
          entry: entry,
          selecting: _selecting,
          selected: _selected.contains(entry.path),
          onTap: () => _selecting ? _toggle(entry) : _open(entry),
          onLongPress: widget.readOnly ? null : () => _select(entry),
          onShare: handoff.canShare ? () => _export([entry.path]) : null,
          onDelete: widget.readOnly
              ? null
              : () => _delete([entry.path], folder: entry.isDirectory),
        );
      },
    );
  }

  /// What can be done to what is picked. It replaces the browsing actions
  /// rather than sitting beside them.
  List<PageAction> _selectionActions() => [
    if (_selected.isNotEmpty)
      PageAction.icon(
        icon: Icons.delete_outline,
        label: "Delete",
        onPressed: () => _delete(_selected.toList()),
      ),
    PageAction.icon(
      icon: Icons.close,
      label: "Cancel selection",
      onPressed: () => setState(_clearSelection),
    ),
  ];

  List<PageAction> _browseActions(FileHandoff handoff) => [
    if (handoff.fileManager case final fileManager?)
      PageAction.icon(
        icon: Icons.open_in_new,
        label: "Show in $fileManager",
        onPressed: () => _guard(() => handoff.reveal(_dir)),
      ),
    // What it adds to is the listing, which is not there until it is read.
    if (_entries != null && _error == null && !widget.readOnly) ...[
      PageAction.icon(
        icon: Icons.create_new_folder_outlined,
        label: "New folder",
        onPressed: _newFolder,
      ),
      PageAction.icon(
        icon: Icons.checklist,
        label: "Select",
        onPressed: () => setState(() => _selecting = true),
      ),
    ],
  ];

  void _toggle(WorkspaceEntry entry) => setState(() {
    if (!_selected.remove(entry.path)) _selected.add(entry.path);
  });

  void _select(WorkspaceEntry entry) => setState(() {
    _selecting = true;
    _selected.add(entry.path);
  });
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onShare,
    required this.onDelete,
  });

  final WorkspaceEntry entry;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Null where there is no share sheet to hand it to.
  final VoidCallback? onShare;

  /// Null where nothing may be deleted.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : Icon(
              entry.isDirectory
                  ? Icons.folder
                  : Icons.insert_drive_file_outlined,
            ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory ? null : Text(formatSize(entry.size)),
      trailing: selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onShare != null || onDelete != null)
                  PopupMenuButton<VoidCallback>(
                    tooltip: "More",
                    onSelected: (run) => run(),
                    itemBuilder: (_) => [
                      if (onShare case final share?)
                        PopupMenuItem(
                          value: share,
                          child: const Text("Share…"),
                        ),
                      if (onDelete case final delete?)
                        PopupMenuItem(
                          value: delete,
                          child: const Text("Delete"),
                        ),
                    ],
                  ),
                if (entry.isDirectory) const Icon(Icons.chevron_right),
              ],
            ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
