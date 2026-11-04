import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../core/config.dart";
import "../../data/prompts/prompt_export.dart";
import "../../domain/app_link.dart" show appLinkMaxLength;
import "../../domain/models.dart";
import "../widgets/dialogs.dart";

/// A skills or agents row's Copy install link: the entry as an `entoli://`
/// link on the clipboard. One too long for every platform to hand over is
/// refused here, where the user can still export the file instead, rather
/// than arriving cut short at the friend's end.
Future<void> copyInstallLink(
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
  await Clipboard.setData(ClipboardData(text: link));
  if (context.mounted) say(context, "Copied an install link for $name.");
}
