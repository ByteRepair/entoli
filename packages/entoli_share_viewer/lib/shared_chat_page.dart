import "package:entoli_chat/app/handoff.dart";
import "package:entoli_chat/app/reader.dart" show WidgetReader;
import "package:entoli_chat/app/transcript/host.dart";
import "package:entoli_chat/domain/app_link.dart" show appLinkScheme;
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/ui/chat/plan_page.dart" show PlanButton;
import "package:entoli_chat/ui/chat/widgets/conversation_view.dart";
import "package:entoli_chat/ui/chat/widgets/message_bubble.dart";
import "package:entoli_chat/ui/workspace/workspace_page.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:url_launcher/url_launcher.dart";

/// A shared chat, read-only: the conversation as the app draws it, its
/// workspace and plan as the app opens them, and the two ways to carry on
/// with it — the app, where it is installed, or the page to get it.
class SharedChatPage extends ConsumerWidget {
  const SharedChatPage({
    super.key,
    required this.chat,
    required this.payload,
    required this.workspace,
  });

  final Chat chat;

  /// The link's fragment, handed to the app whole.
  final String payload;

  /// Where the chat's workspace was unpacked.
  final String workspace;

  static final _download = Uri.parse("https://byterepair.io/products/entoli/");

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = chat.state.id;
    final source = ref.read(transcriptHostProvider).view(chatId);
    final view = ref.watch(source);
    void openLink(String href) {
      final uri = Uri.tryParse(href);
      if (uri != null) ref.read(linkOpenerProvider).open(context, uri);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(chat.state.title.orUntitled),
        actions: [
          PlanButton(chatId: chatId),
          IconButton(
            tooltip: "Files",
            icon: const Icon(Icons.folder_outlined),
            onPressed: () => openWorkspace(
              context,
              root: workspace,
              title: "Files",
              readOnly: true,
            ),
          ),
          TextButton(
            onPressed: () =>
                launchUrl(Uri.parse("$appLinkScheme://share?def=$payload")),
            child: const Text("Open in Entoli"),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () => launchUrl(_download),
              child: const Text("Get Entoli"),
            ),
          ),
        ],
      ),
      body: ConversationView(
        chatId: chatId,
        source: source,
        bottom: const SizedBox.shrink(),
        onTapLink: openLink,
        message: (row, steerKey) => MessageBubble(
          chatId: chatId,
          message: row.message,
          avatar: row.face(WidgetReader(ref), project: chat.state.project),
          moment: row.moment(view, null),
          latest: row.last,
          onTapLink: openLink,
          reactions: row.reactions,
          steerKey: steerKey,
        ),
      ),
    );
  }
}
