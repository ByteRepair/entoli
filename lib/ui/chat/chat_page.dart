import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "../fonts.dart";
import "../theme.dart";
import "../sidebar/sidebar.dart";
import "../voice/read_aloud.dart";
import "../voice/voice_page.dart";
import "../widgets/app_mark.dart";
import "../widgets/completion_field.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/scrolling.dart";
import "chat_settings_page.dart";
import "chat_controller.dart";
import "widgets/composer.dart";
import "widgets/activity_label.dart";
import "widgets/message_bubble.dart";
import "widgets/turn_surface.dart";

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key, this.withDrawer = false});

  /// Narrow layouts have no room for the sidebar beside the chat, so it becomes
  /// this page's drawer.
  final bool withDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = ref.watch(selectedChatIdProvider);
    if (chatId == null) {
      return _Waiting(withDrawer: withDrawer, child: const _NoChat());
    }
    return _ChatBody(chatId: chatId, withDrawer: withDrawer);
  }
}

/// The conversation's share of a wide window. Past this a reply is a line of
/// text too long to track back to the start of.
const double _readableWidth = 760;

/// Nothing selected: the two ways to have a conversation, and which project
/// they happen in.
class _NoChat extends ConsumerWidget {
  const _NoChat();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Opening one is the sidebar, so this is offered only where the sidebar is
    // out of sight. The Scaffold above already answers that, and a flag threaded
    // down beside it is a second answer that can disagree.
    final scaffold = Scaffold.maybeOf(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppMark(size: 64),
            const SizedBox(height: 32),
            const _ProjectBadges(),
            FilledButton(
              onPressed: () => startChat(context, ref),
              child: const Text("New Chat"),
            ),
            // An extension of New Chat rather than a third thing: it makes one
            // and opens it in voice mode. Drawn wherever the platform can
            // listen rather than only where the models are, which is the rule
            // the composer's circle keeps — with none downloaded it leads to
            // the settings that download them.
            if (ref.watch(voiceProvider).available) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => startVoiceChat(context, ref),
                child: const Text("New Voice Chat"),
              ),
            ],
            if (scaffold?.hasDrawer ?? false) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: scaffold!.openDrawer,
                child: const Text("Open Chat"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The named projects, as badges, with the one a new chat would land in picked
/// out. The default project is nothing selected, so it has no badge — see
/// "The chat page" in CLAUDE.md.
class _ProjectBadges extends ConsumerWidget {
  const _ProjectBadges();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final named = ref.watch(projectListProvider).value ?? const [];
    // The padding would otherwise be a gap under nothing.
    if (named.isEmpty) return const SizedBox.shrink();
    final selected = ref.watch(selectedProjectProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final project in named)
            ChoiceChip(
              label: Text(project),
              selected: project == selected,
              onSelected: (on) => selectProject(ref, on ? project : null),
            ),
        ],
      ),
    );
  }
}

/// A chat with nothing said in it yet. The mark, the question, and what the
/// composer's `/` and `@` menus hold — which is the only place those are named
/// before the user has typed the character that opens them.
class _EmptyChat extends ConsumerWidget {
  const _EmptyChat({required this.onStart});

  final void Function(CompletionKind kind, String name) onStart;

  /// Enough to say what is on offer. Everything the user has written is a menu,
  /// and `/` is what opens the menu.
  static const _most = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final starters = [
      for (final kind in CompletionKind.values)
        for (final option in ref.watch(completionsProvider(kind)))
          (kind: kind, option: option),
    ].take(_most).toList();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppMark(size: 56),
            const SizedBox(height: 20),
            Text(
              "What would you like to discuss?",
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            if (starters.isEmpty)
              Text(
                "Type / for commands, @ for agents.",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final starter in starters)
                    ActionChip(
                      label: Text("${starter.kind.trigger}${starter.option.name}"),
                      labelStyle:
                          theme.textTheme.bodySmall?.copyWith(fontFamily: monoFamily),
                      // Null rather than the empty string: `Chip` builds a
                      // `Tooltip` for whatever it is given, and an empty one is
                      // a blank box on a long press.
                      tooltip: starter.option.description,
                      onPressed: () => onStart(starter.kind, starter.option.name),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AppBrand extends StatelessWidget {
  const _AppBrand();

  @override
  // Flexible because the name is not a fixed one: a debug build's is longer,
  // and the slot is a phone's toolbar.
  Widget build(BuildContext context) => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppMark(size: 24),
          SizedBox(width: 10),
          Flexible(child: Text(appTitle, overflow: TextOverflow.ellipsis)),
        ],
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
        drawer: withDrawer ? const NavDrawer(child: Sidebar()) : null,
        appBar: withDrawer ? AppBar(title: const _AppBrand()) : null,
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

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// A notifier rather than a field: only the jump button reads it, and a
  /// `setState` mid-drag would rebuild every visible bubble to swap it.
  final ValueNotifier<bool> _atBottom = ValueNotifier(true);

  /// The chat the view has already been dropped to the bottom of.
  String? _opened;

  /// Chats we have already asked about since they were opened. Keeps a rebuild
  /// from re-prompting for the same expired chat.
  String? _expiryChecked;

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
    _atBottom.dispose();
    super.dispose();
  }

  void _readPosition() {
    if (!_scroll.hasClients) return;
    _atBottom.value = _scroll.position.nearBottom(_slack);
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
        if (position.nearBottom(_slack)) _scroll.jumpTo(position.maxScrollExtent);
      });

  /// Land at the end, and keep landing until the end stops moving. A builder
  /// lays out only what shows, so the extent any one frame reports is an
  /// estimate, and a single jump lands short of the last message.
  ///
  /// Both ways down want this. A chat opens at its latest message; Jump to
  /// latest animates for the travel and then finishes the trip here, since the
  /// extent it read at the moment of the press was the estimate.
  void _settleAtBottom([int tries = 8]) => _afterLayout((position) {
        if (position.pixels >= position.maxScrollExtent) return;
        _scroll.jumpTo(position.maxScrollExtent);
        if (tries > 0) _settleAtBottom(tries - 1);
      });

  Future<void> _send(String text, List<Attachment> attachments) => ref
      .read(chatControllerProvider(widget.chatId).notifier)
      .send(text, attachments: attachments);

  Future<void> _abort() => ref.read(chatControllerProvider(widget.chatId).notifier).abort();

  /// Ask whether to keep an expired temporary chat (turning its TTL off) or
  /// delete it. The sweep handles non-open chats silently; this is the one
  /// case where the chat being deleted is the one the user is looking at.
  Future<void> _checkExpiry(BuildContext context, ChatState state) async {
    if (!state.isExpired()) return;
    if (!mounted) return;
    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Temporary chat expired"),
        content: const Text(
          "This temporary chat has passed its expiry. Turn temporary chat off "
          "to keep it, or delete it now.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("Keep"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final repo = ref.read(chatRepositoryProvider);
    if (keep == true) {
      final written = await repo.keepExpiredChat(widget.chatId, state);
      ref.read(chatControllerProvider(widget.chatId).notifier).applyState(written);
    } else {
      ref.read(selectedChatIdProvider.notifier).select(null);
      await repo.deleteChat(widget.chatId);
    }
    ref.invalidate(chatListProvider);
  }

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
      _settleAtBottom();
    }
    // Check expiry once per open: a temporary chat whose window has passed is
    // offered a choice between keeping it (turning its TTL off) and deleting it.
    if (_expiryChecked != widget.chatId) {
      _expiryChecked = widget.chatId;
      _checkExpiry(context, chat.state);
    }

    final details = _details(chat.state);
    final barHeight = _barHeight(context, details.length);
    return Scaffold(
      drawer: widget.withDrawer ? const NavDrawer(child: Sidebar()) : null,
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: barHeight,
        title: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatSettingsPage(chatId: widget.chatId)),
          ),
          // Fills the bar between leading and actions so the whole strip opens
          // the chat's settings, not just the text.
          child: SizedBox(
            height: barHeight,
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(chat.state.title.orUntitled), ...details],
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
      // A reply is full width on a phone and a centred column on a monitor:
      // the composer goes with it, or the conversation would sit under a field
      // twice its width.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _readableWidth),
          child: Column(
            children: [
              Expanded(child: _conversation(chat, view, notifier)),
              TurnSurface(view: view, notifier: notifier),
              // A question takes the composer's place rather than sitting above it:
              // the turn is waiting on this answer, and there is nothing useful to
              // type until it has it.
              if (view.questions.isEmpty)
                Composer(
                  controller: _controller,
                  isRunning: view.isRunning,
                  onSend: _send,
                  onAbort: _abort,
                  onVoice: ref.watch(voiceProvider).available
                      ? () => openVoice(context, ref, widget.chatId)
                      : null,
                )
              else
                TurnQuestions(view: view, notifier: notifier),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conversation(Chat chat, ChatViewState view, ChatController notifier) {
    final speechReady = ref.watch(speechReadyProvider);
    final reading = ref.watch(readAloudProvider);
    // `insertCompletion` rather than writing the field here: where a trigger
    // lands is the composer's rule, and a `/command` appended at the caret is
    // text nothing would ever expand. It does not ask for the focus, which is
    // the composer's other rule — see "The keyboard and the caret".
    if (chat.messages.isEmpty) {
      return _EmptyChat(
        onStart: (kind, name) => insertCompletion(_controller, kind, name),
      );
    }
    return Stack(
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
              waitingStatus: view.status,
              onTapLink: (href) {
                final uri = Uri.tryParse(href);
                if (uri != null) {
                  ref.read(linkOpenerProvider).open(context, uri);
                }
              },
              threads: chat.branches[m.id],
              onThreadStep:
                  view.isRunning ? null : (step) => notifier.stepThread(m.id, step),
              onDelete: view.isRunning ? null : () => notifier.deleteThread(m.id),
              onEdit: m.role == MessageRole.user && !view.isRunning
                  ? (text) => notifier.editAndResend(m.id, text)
                  : null,
              onRegenerate: view.isRunning ? null : () => notifier.regenerate(m.id),
              onSpeak: speechReady && m.hasText
                  ? () => readAloud(context, ref, m.id, m.plainText)
                  : null,
              isSpeaking: reading == m.id,
            );
          },
        ),
        // Only once the reader has left the end: up there a turn no longer
        // follows itself, and this is the way back.
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
              onPressed: () => _scroll
                  .animateTo(
                    _scroll.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  )
                  .then((_) => _settleAtBottom()),
              child: const Icon(Icons.arrow_downward),
            ),
          ),
        ),
      ],
    );
  }

  /// What the bar says about the chat under its title, a line each. The
  /// conditions are here and nowhere else: [_barHeight] counts what this
  /// returns, so a line added here is one the bar makes room for.
  List<Widget> _details(ChatState state) => [
        // Every chat is in a project, so naming the default one says nothing.
        if (state.project != null) _TitleLine(text: state.project!),
        if (state.pinned) _TitleLine(icon: Icons.push_pin, text: "Pinned"),
        if (state.tempTtlExpiresAt != null)
          _TtlLine(expiresAt: state.tempTtlExpiresAt!),
      ];

  /// Tall enough for the title and its detail lines. One of those fits beside
  /// the title in Material's toolbar and a second does not, so the bar buys a
  /// line for every one past the first.
  double _barHeight(BuildContext context, int details) => details > 1
      ? kToolbarHeight +
          (details - 1) * MediaQuery.textScalerOf(context).scale(_TitleLine.height)
      : kToolbarHeight;
  }

/// One line under the chat's title in the bar: the project it is in, the pin
/// on a pinned chat, or the countdown on a temporary one. A small
/// `onSurfaceVariant` icon where there is one, a 4px gap, and `bodySmall` text
/// in the same colour.
class _TitleLine extends StatelessWidget {
  const _TitleLine({this.icon, required this.text});

  /// What one of these takes, which the bar has to know before laying one out.
  /// The row is held to it rather than measured against it, so the number the
  /// bar adds per line is the number the line costs — and it is over the 16dp
  /// `bodySmall` renders at so that the text still fits once scaled.
  static const height = 18.0;

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(height),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The hourglass and time-remaining shown in the title bar of a temporary
/// chat. Ticks once a minute on its own timer so the countdown stays accurate
/// without re-rendering the rest of the app bar.
class _TtlLine extends StatefulWidget {
  const _TtlLine({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_TtlLine> createState() => _TtlLineState();
}

class _TtlLineState extends State<_TtlLine> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    return _TitleLine(icon: Icons.hourglass_empty, text: formatRemaining(remaining));
  }
}
