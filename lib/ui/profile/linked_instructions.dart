import "package:flutter/material.dart";

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
            child: InstructionFileTile(
              path: path,
              name: nameOf(path),
              missing: missing.contains(path),
              onTap: () => onOpen(path),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: "Unlink",
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
          label: const Text("Link files…"),
        ),
      ),
    ],
  );
}

/// One instruction file: its name over its path, opened by a tap unless it
/// is not on disk.
class InstructionFileTile extends StatelessWidget {
  const InstructionFileTile({
    super.key,
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
