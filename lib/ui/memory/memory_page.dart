import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/memories.dart";
import "../../data/builtin/memory/store.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "../chat/widgets/view_only_bar.dart" show MirrorStrip;
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";
import "../widgets/page_bar.dart";

/// Opens [project]'s memories, the bar saying [title].
Future<void> openMemories(
  BuildContext context, {
  required ProjectRef project,
  required String title,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => MemoryPage(project: project, title: title),
  ),
);

/// A project's memories: what they are, and what can be done with them — add
/// one, pin one, delete one, and a search that matches the way a turn's
/// recall does. The rules are [MemoryListController]'s.
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key, required this.project, required this.title});

  /// Whose store: a paired device's is read there, and frozen while it is
  /// away.
  final ProjectRef project;

  /// What the bar says: whose memories these are.
  final String title;

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  final _search = TextEditingController();

  MemoryListController get _list =>
      ref.read(memoryListProvider(widget.project).notifier);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// What a write said went wrong, if it said anything.
  void _said(String? refusal) {
    if (refusal != null && mounted) say(context, refusal);
  }

  Future<void> _add() async {
    final text = await promptForText(
      context,
      title: "New memory",
      initial: "",
      confirmLabel: "Save",
      hint: "A fact worth keeping: a preference, a decision, a learned detail.",
      maxLines: 4,
    );
    if (text == null || !mounted) return;
    _said(await _list.add(text));
  }

  Future<void> _delete(MemoryEntry entry) async {
    final shown = entry.text.length > 80
        ? "${entry.text.substring(0, 80)}…"
        : entry.text;
    if (!await confirm(
      context,
      title: "Delete memory?",
      message: "Delete \"$shown\"?",
      confirmLabel: "Delete",
      destructive: true,
    )) {
      return;
    }
    _said(await _list.delete(entry));
  }

  void _view(MemoryEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("Memory"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(entry.text),
            const SizedBox(height: 12),
            Text(
              memoryByline(entry),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(memoryListProvider(widget.project));
    final query = list.query;
    final entries = list.entries;
    final frozen = ref.watch(projectFrozenProvider(widget.project));
    return Scaffold(
      appBar: PageBar(
        title: widget.title,
        actions: [
          PageAction.icon(
            icon: Icons.add,
            label: "Add a memory",
            onPressed: frozen ? null : _add,
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: frozen,
        child: Column(
          children: [
            if (widget.project.device case final device?)
              if (ref.watch(syncPeersProvider)[device]?.name ?? "The device"
                  case final name)
                frozen
                    ? MirrorStrip.offline(deviceName: name)
                    : MirrorStrip.remote(deviceName: name),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: _list.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: "Search memories",
                ),
              ),
            ),
            Expanded(
              child: entries == null
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                  ? EmptyPane(
                      icon: Icons.psychology_outlined,
                      title: query.isEmpty
                          ? "No memories yet"
                          : "No memories match",
                      detail: query.isEmpty
                          ? "Facts the agent keeps, and ones you add, land here."
                          : "Nothing the store holds is about “$query”.",
                      action: query.isEmpty
                          ? FilledButton(
                              onPressed: _add,
                              child: const Text("Add a memory"),
                            )
                          : null,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 72),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _row(entries[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(MemoryEntry entry) => ListTile(
    title: Text(entry.text, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text("${memoryByline(entry)}${entry.pinned ? " · pinned" : ""}"),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(entry.pinned ? Icons.push_pin : Icons.push_pin_outlined),
          tooltip: entry.pinned ? "Unpin" : "Pin: in every turn",
          onPressed: () async => _said(await _list.togglePin(entry)),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: "Delete memory",
          onPressed: () => _delete(entry),
        ),
      ],
    ),
    onTap: () => _view(entry),
  );
}
