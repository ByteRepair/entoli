import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../sidebar/sidebar.dart";
import "chat_settings_page.dart";
import "chat_controller.dart";
import "widgets/composer.dart";
import "widgets/message_bubble.dart";

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = ref.watch(selectedChatIdProvider);
    if (chatId == null) {
      return const Scaffold(body: Center(child: Text("Select or create a chat")));
    }
    return _ChatBody(chatId: chatId);
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody({required this.chatId});
  final String chatId;

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Streaming fires this every frame, so it jumps rather than starting a new
  /// 100ms animation each time — and only while the reader is already at the
  /// bottom, so scrolling back through a turn is not fought.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.maxScrollExtent - position.pixels > 200) return;
      _scroll.jumpTo(position.maxScrollExtent);
    });
  }

  Future<void> _send(String text, List<Attachment> attachments) => ref
      .read(chatControllerProvider(widget.chatId).notifier)
      .send(text, attachments: attachments);

  Future<void> _abort() => ref.read(chatControllerProvider(widget.chatId).notifier).abort();

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(chatControllerProvider(widget.chatId));
    final notifier = ref.read(chatControllerProvider(widget.chatId).notifier);
    ref.listen(chatControllerProvider(widget.chatId), (_, _) => _scrollToBottom());
    final chat = view.chat;
    if (chat == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatSettingsPage(chatId: widget.chatId)),
          ),
          // Fills the bar between leading and actions so the whole strip opens
          // the chat's settings, not just the text.
          child: SizedBox(
            height: kToolbarHeight,
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(chat.state.title.orUntitled),
              ),
            ),
          ),
        ),
        actions: [
          if (view.isRunning)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? const Center(child: Text("What would you like to discuss?"))
                : ListView.builder(
                    controller: _scroll,
                    itemCount: chat.messages.length,
                    itemBuilder: (context, i) {
                      final m = chat.messages[i];
                      return MessageBubble(
                        chatId: widget.chatId,
                        message: m,
                        isWaiting: view.isRunning && i == chat.messages.length - 1,
                        waitingNotice: view.retry,
                        onEdit: m.role == MessageRole.user && !view.isRunning
                            ? (text) => notifier.editAndResend(m.id, text)
                            : null,
                        onRegenerate: view.isRunning ? null : () => notifier.regenerate(m.id),
                      );
                    },
                  ),
          ),
          for (final a in view.approvals)
            ApprovalBanner(
              approval: a,
              onAllow: () => notifier.respondApproval(a.id, ApprovalResponse.allow),
              onDeny: () => notifier.respondApproval(a.id, ApprovalResponse.deny),
            ),
          Composer(
            controller: _controller,
            isRunning: view.isRunning,
            onSend: _send,
            onAbort: _abort,
          ),
        ],
      ),
    );
  }
}
