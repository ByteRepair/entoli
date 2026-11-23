import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:entoli_chat/core/config.dart";
import "../../data/prompts/prompt_export.dart";
import "package:entoli_chat/domain/app_link.dart" show appLinkMaxLength;
import "package:entoli_chat/domain/models.dart";
import "../../providers.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart";

/// The end of a skills or agents row: Copy install link, then Export, each
/// run through [guard]. Where not [linkable] the link's place is kept, so
/// Export stands where it does on every other row.
class PromptRowActions extends ConsumerWidget {
  const PromptRowActions({
    super.key,
    required this.kind,
    required this.name,
    required this.project,
    required this.guard,
    this.linkable = true,
  });

  final CompletionKind kind;
  final String name;
  final String? project;
  final Future<void> Function(Future<void> Function() work) guard;
  final bool linkable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (linkable)
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: "Copy install link for $name",
            onPressed: () => guard(
              () => _copyInstallLink(
                context,
                ref.read(appConfigProvider),
                kind,
                name,
                project: project,
              ),
            ),
          )
        else
          const SizedBox(width: 48),
        IconButton(
          icon: const Icon(Icons.download),
          tooltip: "Export $name",
          onPressed: () => guard(
            () => exportAndSave(
              ref.read(appConfigProvider),
              ref.read(backupHandoffProvider),
              kind,
              name,
              project: project,
            ),
          ),
        ),
      ],
    );
  }
}

/// The entry as an `entoli://` link on the clipboard. One too long for every
/// platform to hand over is refused here, where the user can still export
/// the file instead, rather than arriving cut short at the other end.
Future<void> _copyInstallLink(
  BuildContext context,
  AppConfig config,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  final link = await installLinkOf(config, kind, name, project: project);
  if (!context.mounted) return;
  if (link.length > appLinkMaxLength) {
    say(context, "$name is too big for a link. Export it as a file instead.");
    return;
  }
  await copyToClipboard(
    context,
    link,
    said: "Copied an install link for $name.",
  );
}
