import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../domain/file_handoff.dart";
import "../../domain/project.dart";
import "../../domain/workspace.dart";
import "../../providers.dart";

/// Where the files another app shared should go. Every workspace Entoli has is
/// a row — each project's shared one, the default included, then each chat's
/// own — and picking one writes the files there and closes the page. Nothing
/// else is on offer, because a share arrives with nowhere to put it and asking
/// is the whole of what this page is for.
class ShareTargetPage extends ConsumerWidget {
  const ShareTargetPage({super.key, required this.files});

  final List<IncomingFile> files;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    final projects = everyProject(ref.watch(projectListProvider).value ?? const []);
    final chats = ref.watch(chatListProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(files.length == 1 ? "Share 1 file to" : "Share ${files.length} files to"),
      ),
      body: ListView(
        children: [
          const _Heading("Projects"),
          for (final project in projects)
            _Target(
              icon: Icons.workspaces_outline,
              title: projectLabel(project),
              subtitle: "Shared workspace",
              onTap: () => _save(
                context,
                config.fs,
                config.projectWorkspaceDir(project: project),
                projectLabel(project),
              ),
            ),
          if (chats.isNotEmpty) const _Heading("Chats"),
          for (final chat in chats)
            _Target(
              icon: Icons.chat_bubble_outline,
              title: chat.title,
              subtitle: projectLabel(chat.project),
              onTap: () => _save(
                context,
                config.fs,
                config.workspaceDir(chat.id, project: chat.project),
                chat.title,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, FileSystem fs, String dir, String title) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await writeIncoming(fs, dir, files);
    } catch (e) {
      // Left open on purpose: the files are still in hand, and another
      // workspace is one tap away.
      messenger.showSnackBar(SnackBar(content: Text("Could not save: $e")));
      return;
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(
      content: Text(files.length == 1
          ? "Saved ${files.single.path} to $title"
          : "Saved ${files.length} files to $title"),
    ));
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _Target extends StatelessWidget {
  const _Target({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}
