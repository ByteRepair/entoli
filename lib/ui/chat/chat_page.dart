import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../widgets/app_mark.dart";
import "chat_settings_page.dart";
import "chat_controller.dart";
import "widgets/composer.dart";
import "widgets/message_bubble.dart";
import "widgets/question_panel.dart";
import "widgets/resume_bar.dart";
import "widgets/sub_agent_strip.dart";

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key, this.withDrawer = false});

  /// Narrow layouts have no room for the sidebar beside the chat, so it becomes
  /// this page's drawer.
  final bool withDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = ref.watch(selectedChatIdProvider);
    if (chatId == null) {
      return _Waiting(
        withDrawer: withDrawer,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppMark(size: 64),
            SizedBox(height: 16),
            Text("Select or create a chat"),
          ],
        ),
      );
    }
    return _ChatBody(chatId: chatId, withDrawer: withDrawer);
  }
}

class AppBrand extends StatelessWidget {
  const AppBrand({super.key});

  @override
  Widget build(BuildContext context) => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [AppMark(size: 24), SizedBox(width: 10), Text("Entoli")],
      );
}

/// The page with no conversation in it yet — nothing selected, or one still
/// being read off disk. Carries the drawer and bar the real page would.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.withDrawer, required this.child});

  final bool withDrawer;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        drawer: withDrawer ? const Drawer(child: Sidebar()) : null,
        appBar: withDrawer ? AppBar(title: const AppBrand()) : null,
        body: Center(child: child),
      );
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody({required this.chatId, required this.withDrawer});
  final String chatId;
  final bool withDrawer;

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  /// How far off the end still counts as reading the latest: inside it a turn
  /// keeps the view pinned, outside it the jump button appears.
  static const _slack = 200.0;
  static const _topSlack = 8.0;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Notifiers rather than fields: only the bar's title and the jump button
  /// read these, and a `setState` mid-drag would rebuild every visible bubble
  /// to swap one of them.
  final ValueNotifier<bool> _atTop = ValueNotifier(true);
  final ValueNotifier<bool> _atBottom = ValueNotifier(true);

  /// The chat the view has already been dropped to the bottom of.
  String? _opened;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_readPosition);
  }

  @override
  void dispose() {
    _scroll.removeListener(_readPosition);
    _controller.dispose();
    _scroll.dispose();
    _atTop.dispose();
    _atBottom.dispose();
    super.dispose();
  }

  void _readPosition() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _atTop.value = position.pixels <= _topSlack;
    _atBottom.value = position.maxScrollExtent - position.pixels <= _slack;
  }

  /// Once the list has been laid out, which is the first moment its extent is
  /// worth reading.
  void _afterLayout(void Function(ScrollPosition) act) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      act(_scroll.position);
      _readPosition();
    });
  }

  /// Streaming fires this every frame, so it jumps rather than starting a new
  /// 100ms animation each time.
  void _scrollToBottom() => _afterLayout((position) {
        if (position.maxScrollExtent - position.pixels <= _slack) {
          _scroll.jumpTo(position.maxScrollExtent);
        }
      });

  /// A chat opens at its latest message. A builder lays out only what shows, so
  /// the extent the first frame reports is an estimate — jump again until it
  /// stops moving, rather than landing short of the end.
  void _openAtBottom([int tries = 8]) => _afterLayout((position) {
        if (position.pixels >= position.maxScrollExtent) return;
        _scroll.jumpTo(position.maxScrollExtent);
        if (tries > 0) _openAtBottom(tries - 1);
      });

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
      return _Waiting(
        withDrawer: widget.withDrawer,
        child: const CircularProgressIndicator(),
      );
    }
    if (_opened != widget.chatId) {
      _opened = widget.chatId;
      _openAtBottom();
    }

    return Scaffold(
      drawer: widget.withDrawer ? const Drawer(child: Sidebar()) : null,
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
                child: ValueListenableBuilder<bool>(
                  valueListenable: _atTop,
                  builder: (context, atTop, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: atTop ? const AppBrand() : _title(context, chat.state),
                  ),
                ),
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
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        itemCount: chat.messages.length,
                        itemBuilder: (context, i) {
                          final m = chat.messages[i];
                          return MessageBubble(
                            chatId: widget.chatId,
                            message: m,
                            isWaiting: view.isRunning && i == chat.messages.length - 1,
                            waitingNotice: view.retry,
                            onTapLink: (href) {
                              final uri = Uri.tryParse(href);
                              if (uri != null) {
                                ref.read(linkOpenerProvider).open(context, uri);
                              }
                            },
                            onEdit: m.role == MessageRole.user && !view.isRunning
                                ? (text) => notifier.editAndResend(m.id, text)
                                : null,
                            onRegenerate: view.isRunning ? null : () => notifier.regenerate(m.id),
                          );
                        },
                      ),
                      // Only once the reader has left the end: up there a turn
                      // no longer follows itself, and this is the way back.
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _atBottom,
                          builder: (context, atBottom, child) =>
                              atBottom ? const SizedBox.shrink() : child!,
                          child: FloatingActionButton.small(
                            heroTag: null,
                            tooltip: "Jump to latest",
                            onPressed: () => _scroll.animateTo(
                              _scroll.position.maxScrollExtent,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                            ),
                            child: const Icon(Icons.arrow_downward),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          // Only while nothing is running: the turn being carried on is the one
          // at the end, so the offer and the work are never both on screen.
          if (chat.unfinished && !view.isRunning)
            ResumeBar(
              startedAt: chat.messages.last.createdAt,
              onContinue: notifier.resume,
            ),
          SubAgentStrip(agents: view.runningSubAgents),
          for (final a in view.approvals)
            ApprovalBanner(
              approval: a,
              onAllow: () => notifier.respondApproval(a.id, ApprovalResponse.allow),
              onDeny: () => notifier.respondApproval(a.id, ApprovalResponse.deny),
            ),
          // A question takes the composer's place rather than sitting above it:
          // the turn is waiting on this answer, and there is nothing useful to
          // type until it has it.
          if (view.questions.isEmpty)
            Composer(
              controller: _controller,
              isRunning: view.isRunning,
              onSend: _send,
              onAbort: _abort,
            )
          else
            QuestionPanel(
              key: ValueKey(view.questions.first.id),
              request: view.questions.first,
              onAnswered: (answers) =>
                  notifier.answerQuestions(view.questions.first.id, answers),
            ),
        ],
      ),
    );
  }

  Widget _title(BuildContext context, ChatState state) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(state.title.orUntitled),
          // Only where there is something to say: every chat is in a project,
          // and naming the default one on every chat is noise.
          if (state.project != null)
            Text(
              state.project!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      );
}
