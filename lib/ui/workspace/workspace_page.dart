import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/file_handoff.dart";
import "../../domain/workspace.dart";
import "../../providers.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";
import "../widgets/formatting.dart";
import "text_viewer_page.dart";

/// The row that opens the explorer, on the chat, project and app settings pages
/// alike. All three hold a workspace and none has anything else to say about it.
class WorkspaceTile extends StatelessWidget {
  const WorkspaceTile({super.key, required this.root, required this.title});

  final String root;

  /// What the explorer's app bar says at the root. The row says only
  /// "Workspace": the page it sits in has already named the owner.
  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: const Text("Workspace"),
      subtitle: const Text("Browse files"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => WorkspacePage(root: root, title: title)),
      ),
    );
  }
}

/// A workspace folder, and what can be done with what is in it. Listing,
/// creating a folder and deleting go through the `FileSystem` and are on every
/// platform; the routes out of the app are `FileHandoff`'s, and each is drawn
/// only where it leads somewhere — see CLAUDE.md, "The workspace explorer".
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key, required this.root, required this.title});

  /// The folder the explorer cannot go above.
  final String root;

  /// What the app bar says at the root: whose workspace this is.
  final String title;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  late String _dir = widget.root;
  Future<List<WorkspaceEntry>>? _entries;

  /// Paths rather than entries: the listing is re-read under a selection, and
  /// an entry from the old one would no longer be the object in the list.
  final _selected = <String>{};
  var _selecting = false;

  /// A notifier rather than state: the bar is two logical pixels, and a
  /// `setState` for it would rebuild the app bar, the FAB and every visible row
  /// twice per tap.
  final _busy = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _entries = _read();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
        _entries = _read();
      });

  Future<List<WorkspaceEntry>> _read() =>
      listWorkspace(ref.read(appConfigProvider).fs, _dir);

  /// A selection is one folder's, which is what lets the share sheet be handed
  /// a flat staging directory — so leaving the folder ends it.
  void _goTo(String dir) {
    setState(() {
      _dir = dir;
      _clearSelection();
      _entries = _read();
    });
  }

  /// The two always move together, so nothing sets one of them: a selection
  /// outside selection mode is a state the page does not have. Which of them to
  /// read is then the question being asked — the toolbar is the mode, the title
  /// and the export button are what is picked.
  void _clearSelection() {
    _selecting = false;
    _selected.clear();
  }

  bool get _atRoot => _dir == widget.root;

  /// Back goes up a folder before it leaves the page, so a system back gesture
  /// unwinds the way the taps that got here wound it up.
  void _back() {
    if (_atRoot) return Navigator.of(context).pop();
    _goTo(ref.read(appConfigProvider).fs.path.dirname(_dir));
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  /// A text file is read here and everything else is another app's, but the
  /// name is all this can decide on: the viewer pops `true` when the bytes turn
  /// out not to be text, and the hand-off below runs after all.
  Future<void> _open(WorkspaceEntry entry) async {
    if (entry.isDirectory) return _goTo(entry.path);
    if (looksTextual(ref.read(appConfigProvider).fs, entry.name)) {
      final handOff = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => TextViewerPage(path: entry.path, name: entry.name),
      ));
      if (handOff != true || !mounted) return;
    }
    await _guard(() => ref.read(fileHandoffProvider).open(entry.path));
  }

  Future<void> _export() async {
    final paths = _selected.toList();
    if (paths.isEmpty) return;
    await _guard(() => ref.read(fileHandoffProvider).export(paths));
    if (mounted) setState(_clearSelection);
  }

  Future<void> _import({required bool folders}) => _guard(() async {
        final files = await ref.read(fileHandoffProvider).import(folders: folders);
        if (files.isEmpty) return;
        await writeIncoming(ref.read(appConfigProvider).fs, _dir, files);
        _reload();
      });

  Future<void> _newFolder() async {
    final name = await promptForText(
      context,
      title: "New folder",
      initial: "",
      hint: "Name",
      confirmLabel: "Create",
    );
    if (name == null) return;
    await _guard(() async {
      await createFolder(ref.read(appConfigProvider).fs, _dir, name);
      _reload();
    });
  }

  Future<void> _delete() async {
    final paths = _selected.toList();
    if (paths.isEmpty) return;
    final fs = ref.read(appConfigProvider).fs;
    final agreed = await confirm(
      context,
      title: paths.length == 1
          ? "Delete \"${fs.path.basename(paths.first)}\"?"
          : "Delete ${paths.length} items?",
      message: "A folder goes with everything in it. This cannot be undone.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!agreed) return;
    await _guard(() async {
      await deleteEntries(fs, paths);
      setState(() {
        _clearSelection();
        _entries = _read();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final handoff = ref.watch(fileHandoffProvider);
    final fs = ref.watch(appConfigProvider).fs;
    final export = handoff.exportKind;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _back),
        title: _Title(
          text: _selected.isNotEmpty
              ? "${_selected.length} selected"
              : (_atRoot ? widget.title : fs.path.basename(_dir)),
          under: _atRoot ? null : fs.path.relative(_dir, from: widget.root),
        ),
        actions: _selecting ? _selectionActions() : _browseActions(handoff),
      ),
      floatingActionButton: export == null || _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _export,
              icon: Icon(_exportIcons[export]),
              label: Text(_exportLabels[export]!),
            ),
      body: Column(
        children: [
          // The row is there either way: a bar that appears would push the
          // listing down under the finger that started the work.
          BusyBar(_busy),
          Expanded(
            child: FutureBuilder<List<WorkspaceEntry>>(
              future: _entries,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = snapshot.data!;
                if (entries.isEmpty) {
                  final route = _inboundRoute(handoff);
                  return EmptyPane(
                    icon: Icons.folder_open,
                    title: "Nothing here yet",
                    detail: "The agent's files land here."
                        "${route == null ? "" : " $route"}",
                  );
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _Row(
                    entry: entries[i],
                    selecting: _selecting,
                    selected: _selected.contains(entries[i].path),
                    onTap: () {
                      if (_selecting) {
                        _toggle(entries[i]);
                      } else {
                        _open(entries[i]);
                      }
                    },
                    onLongPress: () => _select(entries[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// What can be done to what is picked. It replaces the browsing actions
  /// rather than sitting beside them.
  List<Widget> _selectionActions() => [
        if (_selected.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "Delete",
            onPressed: _delete,
          ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: "Cancel selection",
          onPressed: () => setState(_clearSelection),
        ),
      ];

  List<Widget> _browseActions(FileHandoff handoff) => [
        if (handoff.canReveal)
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: "Show in file manager",
            onPressed: () => _guard(() => handoff.reveal(_dir)),
          ),
        IconButton(
          icon: const Icon(Icons.create_new_folder_outlined),
          tooltip: "New folder",
          onPressed: _newFolder,
        ),
        if (handoff.canImport)
          PopupMenuButton<bool>(
            icon: const Icon(Icons.upload_file),
            tooltip: "Upload",
            onSelected: (folders) => _import(folders: folders),
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text("Upload files")),
              PopupMenuItem(value: true, child: Text("Upload folder")),
            ],
          ),
        IconButton(
          icon: const Icon(Icons.checklist),
          tooltip: "Select",
          onPressed: () => setState(() => _selecting = true),
        ),
      ];

  void _toggle(WorkspaceEntry entry) => setState(() {
        if (!_selected.remove(entry.path)) _selected.add(entry.path);
      });

  void _select(WorkspaceEntry entry) => setState(() {
        _selecting = true;
        _selected.add(entry.path);
      });

  /// What the empty state offers, which is whichever route in the toolbar
  /// actually drew. The upload button wins where a platform has both: it is one
  /// tap away, where a share is another app away.
  String? _inboundRoute(FileHandoff handoff) {
    if (handoff.canImport) return "Upload your own from the toolbar.";
    if (handoff.exportKind == ExportKind.share) {
      return "Share files to Entoli to add your own.";
    }
    return null;
  }
}

const _exportLabels = {ExportKind.share: "Share", ExportKind.download: "Download"};

const _exportIcons = {
  ExportKind.share: Icons.ios_share,
  ExportKind.download: Icons.download,
};

/// The folder's name over where it sits under the root. `AppBar` has one line
/// to give, and losing the path is losing the only thing that says which of two
/// folders called `src` this is.
class _Title extends StatelessWidget {
  const _Title({required this.text, required this.under});

  final String text;
  final String? under;

  @override
  Widget build(BuildContext context) {
    if (under == null) return Text(text, overflow: TextOverflow.ellipsis);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, overflow: TextOverflow.ellipsis),
        Text(
          under!,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final WorkspaceEntry entry;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : Icon(entry.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory ? null : Text(formatSize(entry.size)),
      trailing: entry.isDirectory && !selecting ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
