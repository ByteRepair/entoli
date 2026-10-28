import "package:flutter/foundation.dart";
import "package:flutter/material.dart";

/// A path is only something to link where the picker hands back the file
/// itself: a phone's picker gives a copy, and a browser no path at all.
bool get linksInstructionFiles =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      _ => false,
    };

/// The profile page's linked files, in the order a turn reads them. Held
/// down to drag, since a handle on every row would be a second control beside
/// the remove button for something done rarely.
class LinkedFileList extends StatelessWidget {
  const LinkedFileList({
    super.key,
    required this.files,
    required this.missing,
    required this.nameOf,
    required this.onOpen,
    required this.onRemove,
    required this.onReorder,
    required this.onAdd,
  });

  final List<String> files;
  final Set<String> missing;
  final String Function(String path) nameOf;
  final void Function(String path) onOpen;
  final void Function(String path) onRemove;
  final void Function(int from, int to) onReorder;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: files.length,
            onReorderItem: onReorder,
            itemBuilder: (context, i) {
              final path = files[i];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(path),
                index: i,
                child: _FileTile(
                  path: path,
                  name: nameOf(path),
                  missing: missing.contains(path),
                  onTap: () => onOpen(path),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Remove",
                    onPressed: () => onRemove(path),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text("Add instructions file"),
            ),
          ),
        ],
      );
}

/// A project's switch for each of the user's instruction files, all on until
/// the project turns one off.
class InstructionFileSwitches extends StatelessWidget {
  const InstructionFileSwitches({
    super.key,
    required this.rows,
    required this.off,
    required this.missing,
    required this.onOpen,
    required this.onChanged,
  });

  /// Path and what the row is called.
  final List<(String, String)> rows;
  final Set<String> off;
  final Set<String> missing;
  final void Function(String path) onOpen;
  final void Function(String path, bool on) onChanged;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final (path, name) in rows)
            _FileTile(
              path: path,
              name: name,
              missing: missing.contains(path),
              onTap: () => onOpen(path),
              trailing: Switch(
                value: !off.contains(path),
                onChanged: (on) => onChanged(path, on),
              ),
            ),
        ],
      );
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.path,
    required this.name,
    required this.missing,
    required this.onTap,
    required this.trailing,
  });

  final String path;
  final String name;
  final bool missing;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        missing ? "Not found: $path" : path,
        overflow: TextOverflow.ellipsis,
        style: missing ? TextStyle(color: scheme.error) : null,
      ),
      onTap: missing ? null : onTap,
      trailing: trailing,
    );
  }
}
