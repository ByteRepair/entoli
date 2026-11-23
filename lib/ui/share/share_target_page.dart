import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_chat/core/log.dart";
import "package:entoli_chat/domain/file_handoff.dart";
import "package:entoli_chat/domain/models.dart" show ChatTitle;
import "package:entoli_chat/domain/project.dart";
import "package:entoli_chat/app/storage.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";

import "../../providers.dart";
import "../widgets/section_header.dart";

/// Offers [files] a workspace over whatever is on screen; done once the page
/// is gone, saved or not.
Future<void> openShareTarget(BuildContext context, List<IncomingFile> files) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ShareTargetPage(files: files)),
    );

/// Where the files another app shared should go: each project's shared
/// workspace, the default included, then each chat's own. Picking one
/// writes the files there and closes the page.
class ShareTargetPage extends ConsumerWidget {
  const ShareTargetPage({super.key, required this.files});

  final List<IncomingFile> files;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    final projects = everyProject(
      ref.watch(projectListProvider).value ?? const [],
    );
    final chats = ref.watch(chatListProvider).value ?? const [];
    return Scaffold(
      appBar: PageBar(
        title: files.length == 1
            ? "Share 1 File To"
            : "Share ${files.length} Files To",
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeader("Projects"),
          for (final project in projects)
            _Target(
              icon: Icons.folder_outlined,
              title: projectLabel(project),
              subtitle: "Shared workspace",
              onTap: () => _save(
                ref,
                context,
                config.projectWorkspaceDir(project: project),
                projectLabel(project),
              ),
            ),
          if (chats.isNotEmpty) ...[
            const Divider(),
            const SectionHeader("Chats"),
            for (final chat in chats)
              _Target(
                icon: Icons.chat_bubble_outline,
                title: chat.title.orUntitled,
                subtitle: projectLabel(chat.project),
                onTap: () => _save(
                  ref,
                  context,
                  config.workspaceDir(chat.id, project: chat.project),
                  chat.title.orUntitled,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _save(
    WidgetRef ref,
    BuildContext context,
    String dir,
    String title,
  ) async {
    try {
      await ref.read(workspaceProvider).writeIncoming(dir, files);
    } catch (e) {
      // Left open so the failure is on screen, not to be tried again: what
      // landed before it has landed, and a second pick would only move the
      // rest.
      logFailure("share", "could not save the share to $title", e);
      if (context.mounted) say(context, "Could not save: $e");
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    notify(
      context,
      files.length == 1
          ? "Saved ${files.single.path} to $title"
          : "Saved ${files.length} files to $title",
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
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: onTap,
  );
}
