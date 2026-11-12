import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/chat_session.dart";
import "../app/composer.dart" show ComposerText;
import "chat/widgets/composer_controller.dart";
import "voice/voice_page.dart" as voice;

/// The chat sessions' host for either frontend: the Flutter field's text,
/// and what is said or opened, over the context of the window's root page —
/// `AppShell`, or the native shell's bridge — which attaches as it mounts.
class RootChatSessionHost implements ChatSessionHost {
  ({BuildContext context, WidgetRef ref})? _root;

  void attach(BuildContext context, WidgetRef ref) =>
      _root = (context: context, ref: ref);

  void detach(BuildContext context) {
    if (identical(_root?.context, context)) _root = null;
  }

  @override
  ComposerText newText() => ComposerController();

  @override
  void say(String message) {
    final context = _root?.context;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void openVoice(String chatId) {
    final root = _root;
    if (root == null || !root.context.mounted) return;
    voice.openVoice(root.context, root.ref, chatId);
  }
}
