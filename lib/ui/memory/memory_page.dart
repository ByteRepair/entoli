import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/memory/store.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";

/// The row that opens the memories, on the project settings pages. The default
/// project has no settings page, so its store is a button in the sidebar
/// rather than a row.
class MemoryTile extends StatelessWidget {
  const MemoryTile({super.key, required this.dir, required this.title});

  final String dir;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.psychology_outlined),
      title: const Text("Memories"),
      subtitle: const Text("Browse, add, pin, delete"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MemoryPage(dir: dir, title: title)),
      ),
    );
  }
}

const _months = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// A memory's age in words: the year goes with it once it is no longer this
/// one, because a memory outlives the week reminders are planned for.
String _when(DateTime at) => at.year == DateTime.now().year
    ? "${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}"
    : "${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]} ${at.year}";

/// A project's memories: what they are, and what can be done with them — add
/// one, delete one, and a search that matches the way a turn's recall does.
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key, required this.dir, required this.title});

  final String dir;

  /// What the app bar says: whose memories these are.
  final String title;

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  final _search = TextEditingController();
  List<MemoryEntry>? _entries;
  int _generation = 0;

  MemoryStore get _store =>
      MemoryStore(ref.read(appConfigProvider).fs, widget.dir);

  @override
  void initState() {
    super.initState();
    _search.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// A search types faster than the store answers, and an old answer must not
  /// land under a newer query.
  Future<void> _reload() async {
    final generation = ++_generation;
    final entries = await _query(_search.text.trim());
    if (!mounted || generation != _generation) return;
    setState(() => _entries = entries);
  }

  /// Newest first, the way the store holds them read back; a search is best
  /// first, which is the order the recall would have offered them in.
  Future<List<MemoryEntry>> _query(String query) async {
    final entries = await _store.entries();
    if (query.isEmpty) return [...entries].reversed.toList();
    return _store.search(query);
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
    try {
      await _store.add(text);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("The memory could not be saved.")),
      );
      return;
    }
    _reload();
  }

  Future<void> _togglePin(MemoryEntry entry) async {
    final store = _store;
    try {
      if (entry.pinned) {
        await store.unpin(entry.id);
      } else {
        // Counted over the whole store: a search is a window, and a pin made
        // inside it must not slip past the limit the full list would show.
        final pinned =
            (await store.entries()).where((e) => e.pinned).length;
        if (pinned >= pinnedLimit) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Four is the most that can be pinned.")),
          );
          return;
        }
        await store.pin(entry.id);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("The pin could not be changed.")),
      );
      return;
    }
    _reload();
  }

  Future<void> _delete(MemoryEntry entry) async {
    final shown = entry.text.length > 80 ? "${entry.text.substring(0, 80)}…" : entry.text;
    if (!await confirm(
      context,
      title: "Delete memory?",
      message: "Delete \"$shown\"?",
      confirmLabel: "Delete",
      destructive: true,
    )) {
      return;
    }
    try {
      await _store.delete(entry.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("The memory could not be deleted.")),
      );
      return;
    }
    _reload();
  }

  void _view(MemoryEntry entry) {
    showDialog<void>(
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
                "${_when(entry.at)} · ${entry.chat == null ? "added by you" : "kept by the agent"}",
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
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim();
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: "Add a memory",
            onPressed: _add,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
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
                        title: query.isEmpty ? "No memories yet" : "No memories match",
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
                        itemBuilder: (context, i) {
                          final entry = entries[i];
                          return ListTile(
                            title: Text(
                              entry.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              "${_when(entry.at)} · "
                              "${entry.chat == null ? "added by you" : "kept by the agent"}"
                              "${entry.pinned ? " · pinned" : ""}",
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    entry.pinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                  ),
                                  tooltip:
                                      entry.pinned ? "Unpin" : "Pin: in every turn",
                                  onPressed: () => _togglePin(entry),
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
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
