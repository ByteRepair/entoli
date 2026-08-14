import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "../chat/chat_controller.dart";
import "../settings/settings_page.dart";
import "../widgets/dialogs.dart";

final chatListProvider = FutureProvider((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.listChats();
});

class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedChatIdProvider = NotifierProvider<SelectedChatId, String?>(SelectedChatId.new);

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  /// Selecting a chat should reveal it. On narrow layouts the sidebar is a
  /// drawer sitting over the chat, so it has to get out of the way.
  void _open(BuildContext context, WidgetRef ref, String chatId) {
    ref.read(selectedChatIdProvider.notifier).select(chatId);
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) scaffold!.closeDrawer();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatListProvider);
    // Material, not Scaffold: the shell's Scaffold owns the drawer, and an
    // inner one would shadow it.
    return Material(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text("Chats", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: "New chat",
                  onPressed: () async {
                    final repo = ref.read(chatRepositoryProvider);
                    final chat = await repo.createChat();
                    ref.invalidate(chatListProvider);
                    if (context.mounted) _open(context, ref, chat.state.id);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              data: (chats) => ListView.builder(
                itemCount: chats.length,
                itemBuilder: (context, i) {
                  final c = chats[i];
                  final selected = ref.watch(selectedChatIdProvider) == c.id;
                  return ListTile(
                    selected: selected,
                    title: Text(c.title.isEmpty ? "(untitled)" : c.title),
                    subtitle: Text(_formatTimestamp(c.updatedAt)),
                    onTap: () => _open(context, ref, c.id),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) async {
                        switch (value) {
                          case "rename":
                            final title = await promptForText(
                              context,
                              title: "Rename chat",
                              initial: c.title,
                              hint: "Chat title",
                              confirmLabel: "Rename",
                            );
                            if (title == null) return;
                            await ref.read(chatRepositoryProvider).renameChat(c.id, title);
                            ref.read(chatControllerProvider(c.id).notifier).applyTitle(title);
                            ref.invalidate(chatListProvider);
                          case "delete":
                            final confirmed = await confirm(
                              context,
                              title: "Delete chat?",
                              message:
                                  "Delete \"${c.title.isEmpty ? "(untitled)" : c.title}\"? This cannot be undone.",
                              confirmLabel: "Delete",
                              destructive: true,
                            );
                            if (!confirmed) return;
                            if (selected) ref.read(selectedChatIdProvider.notifier).select(null);
                            await ref.read(chatRepositoryProvider).deleteChat(c.id);
                            ref.invalidate(chatListProvider);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: "rename", child: Text("Rename")),
                        PopupMenuItem(value: "delete", child: Text("Delete")),
                      ],
                    ),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text("Error: $e")),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text("Settings"),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatTimestamp(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_months[l.month - 1]} ${l.day}, ${two(l.hour)}:${two(l.minute)}';
  }
}
