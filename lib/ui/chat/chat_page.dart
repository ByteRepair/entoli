import "dart:async";
import "dart:math" as math;
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_backend.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../fonts.dart";
import "../theme.dart";
import "../sidebar/sidebar.dart";
import "../voice/read_aloud.dart";
import "../voice/voice_page.dart";
import "../widgets/app_mark.dart";
import "../widgets/chip_row.dart";
import "../widgets/completion_field.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/nothing.dart";
import "../widgets/scrolling.dart";
import "chat_settings_page.dart";
import "chat_controller.dart";
import "mirror_controller.dart";
import "widgets/activity_label.dart" show formatRemaining;
import "widgets/composer.dart";
import "widgets/synced_device_cards.dart";
import "widgets/message_bubble.dart";
import "widgets/omada_separator.dart" show ConversationSeparator;
import "widgets/needs_setup_bar.dart";
import "widgets/turn_surface.dart";
import "widgets/view_only_bar.dart";

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key, this.withDrawer = false});

  /// Narrow layouts have no room for the sidebar beside the chat, so it becomes
  /// this page's drawer.
  final bool withDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = ref.watch(selectedChatIdProvider);
    if (chatId != null) return _ChatBody(chatId: chatId, withDrawer: withDrawer);
    // Reading a paired device's list is the one place nothing selected does not
    // mean a new chat: making one is this device's, and would take the sidebar
    // home from whatever it was showing.
    if (ref.watch(selectedRemoteProvider) != null) {
      return _Waiting(
        withDrawer: withDrawer,
        child: const Nothing("Pick a chat to follow."),
      );
    }
    return _NewChat(withDrawer: withDrawer);
  }
}

/// The conversation's share of a wide window. Past this a reply is a line of
/// text too long to track back to the start of.
const double _readableWidth = 760;

/// The conversation and whatever answers it, centred and held to
/// [_readableWidth] — a phone gets the whole screen, a monitor gets a line it
/// can read back to the start of. The composer goes inside that width rather
/// than under it, or the conversation sits over a field twice its own width.
/// Both pages with something to type in are this. [banner] floats over the top
/// of it.
class _ReadableColumn extends StatelessWidget {
  const _ReadableColumn({required this.child, required this.bottom, this.banner});

  final Widget child;
  final Widget bottom;
  final Widget? banner;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _readableWidth),
          child: Stack(
            children: [
              Column(children: [Expanded(child: child), bottom]),
              if (banner != null)
                Positioned(left: 0, right: 0, top: 0, child: banner!),
            ],
          ),
        ),
      );
}

/// Nothing selected: the chat that has not been made yet. Nothing here is keyed
/// on a chat, because there is none — the project is `selectedProjectProvider`'s
/// and the settings are this screen's own, until the first message makes one
/// out of both. See "Nothing selected is a new chat".
class _NewChat extends ConsumerStatefulWidget {
  const _NewChat({required this.withDrawer});

  final bool withDrawer;

  @override
  ConsumerState<_NewChat> createState() => _NewChatState();
}

class _NewChatState extends ConsumerState<_NewChat> {
  final TextEditingController _controller = TextEditingController();

  /// What the chat this screen makes will run its first turn under. Held here
  /// rather than in a provider so that it dies with the screen: armed
  /// app-wide it would land on whatever chat happened to be created next,
  /// including one started from somewhere else entirely.
  ChatMeta _meta = ChatMeta();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final picked = await Navigator.of(context).push<ChatMeta>(
      MaterialPageRoute(
        builder: (_) => NewChatSettingsPage(
          initial: _meta,
          project: ref.read(selectedProjectProvider),
        ),
      ),
    );
    // Null is a page backed out of rather than saved.
    if (picked != null && mounted) setState(() => _meta = picked);
  }

  /// The composer has already cleared itself, so a chat that could not be made
  /// would take the message with it silently. Put it back instead — the reason
  /// is logged, and this is the only thing left on screen to say so.
  Future<void> _send(String text, List<Attachment> attachments) async {
    if (await startChatWith(ref, text, attachments: attachments, meta: _meta)) {
      return;
    }
    if (!mounted) return;
    _controller.text = text;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Could not start a chat.")),
    );
  }

  /// The composer, or a "setup required" bar where the project needs setup
  /// and has not been set up yet. The bar replaces the composer entirely,
  /// the way `ViewOnlyBar` does for a mirrored chat.
  Widget _bottomBar() {
    final project = ref.watch(selectedProjectProvider);
    if (ref.watch(setupCompleteProvider(project))) {
      return Composer(
        controller: _controller,
        agentSpeaking: false,
        onSend: _send,
        onAbort: () {},
        project: project,
        onVoice: ref.watch(voiceProvider).available
            ? () => startVoiceChat(context, ref, meta: _meta)
            : null,
        workspace: null,
      );
    }
    return NeedsSetupBar(
      onOpenSettings: () => openSetupSettings(context),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        drawer: widget.withDrawer ? const NavDrawer(child: Sidebar()) : null,
        appBar: AppBar(
          title: const _AppBrand(),
          actions: [
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: "Chat settings",
              onPressed: _openSettings,
            ),
          ],
        ),
        body: _ReadableColumn(
          bottom: _bottomBar(),
          child: _EmptyChat(
            project: ref.watch(selectedProjectProvider),
            controller: _controller,
            // The paired devices' cards are the new-chat screen's own — a
            // chat that exists with nothing said in it yet is mid-turn at
            // worst, and a list of other devices under its question would
            // say nothing true about it.
            showSyncedCards: true,
          ),
        ),
      );
}

/// The projects a new chat could happen in, as badges, with the one picked out.
/// The named projects the user has made, and the built-in ones the app ships —
/// a built-in is always on offer, so the row is never empty. The default
/// project is nothing selected, so it has no badge — see "The chat page" in
/// AGENTS.md.
///
/// The row is a [ChipRow], so it animates both ways a badge moves: picking
/// one grows the check, and the `AnimatedSize` inside each entry turns that
/// into a width change whose re-flow every other badge glides along with —
/// one pushed onto a new line travels there rather than teleports — and a
/// project made or deleted elsewhere grows in or shrinks out.
class _ProjectBadges extends ConsumerWidget {
  const _ProjectBadges({required this.selected, required this.settled});

  final String? selected;
  final bool settled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final named = ref.watch(projectListProvider).value ?? const [];
    // `everyProject` leads with the default, which is the null that has no
    // badge; the rest are the built-in and the named.
    final projects = everyProject(named).whereType<String>().toList();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ChipRow(
        settled: settled,
        entries: [
          for (final project in projects)
            ChipRowEntry(
              key: ValueKey(project),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: ChoiceChip(
                  // The icon rides in the label rather than the avatar slot:
                  // Material's ChoiceChip paints the selected check over the
                  // avatar, so an icon there disappears under the tick when
                  // picked. In the label it sits beside the text, and the check
                  // keeps the leading slot to itself the way it had before the
                  // icon was added.
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (projectIcon(project) case final icon?)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(icon, size: 18),
                        ),
                       Text(
                         projectLabel(project),
                         style: projectLabelStyle(
                           ref.watch(omadaOnProvider(project)),
                         ),
                       ),
                    ],
                  ),
                  selected: project == selected,
                  onSelected: (on) => selectProject(ref, on ? project : null),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A chat with nothing said in it yet, which is also the page the app opens
/// on. The mark, the question, the project it would happen in, and what the
/// composer's `/` and `@` menus hold — which is the only place those are named
/// before the user has typed the character that opens them.
///
/// Its rows are `settled`, so what the user arrives on is static and every
/// change from their first interaction on animates.
class _EmptyChat extends ConsumerWidget {
  const _EmptyChat({
    required this.project,
    required this.controller,
    this.showSyncedCards = false,
  });

  /// The project this chat is in, or on the new-chat screen the one the next
  /// chat goes to. Either way it is the badge picked out.
  final String? project;

  /// The composer's, so a chip can type into it. See [insertCompletion] for
  /// where a trigger lands and why it does not ask for the focus.
  final TextEditingController controller;

  /// The paired devices' cards, which only the new-chat screen asks for —
  /// see its own call for why.
  final bool showSyncedCards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final starters = [
      for (final kind in CompletionKind.values)
        for (final option in ref.watch(completionsProvider((project: project, kind: kind))))
          (kind: kind, option: option),
    ];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppMark(size: 56),
            const SizedBox(height: 20),
            // A project whose description is the empty string asks nothing:
            // the sweep is handed the empty string and eats its own tail
            // away, rather than the widget leaving the tree and the next
            // question's arrival being a mount instead of a change.
            _QuestionSweep(
              text: ref.watch(emptyChatQuestionProvider(project)),
              style: theme.textTheme.titleMedium,
            ),
            _ProjectBadges(selected: project, settled: true),
            const SizedBox(height: 20),
            ChipRow(
              settled: true,
              entries: starters.isEmpty
                  ? [
                      // Nothing to offer is said as an entry of the same row,
                      // so a library emptying or filling animates it the way
                      // any chip arrives and leaves.
                      ChipRowEntry(
                        key: const ValueKey("empty"),
                        child: Text(
                          "Type / for commands, @ for agents.",
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ]
                  : [
                      for (final starter in starters)
                        ChipRowEntry(
                          key: ValueKey(
                              "${starter.kind.trigger}${starter.option.name}"),
                          child: ActionChip(
                            label: Text(
                                "${starter.kind.trigger}${starter.option.name}"),
                            labelStyle: theme.textTheme.bodySmall
                                ?.copyWith(fontFamily: monoFamily),
                            // Null rather than the empty string: `Chip` builds
                            // a `Tooltip` for whatever it is given, and an
                            // empty one is a blank box on a long press.
                            tooltip: starter.option.description,
                            onPressed: () => insertCompletion(
                                controller, starter.kind, starter.option.name),
                          ),
                        ),
                    ],
            ),
            if (showSyncedCards) ...[
              const SizedBox(height: 20),
              const SyncedDeviceCards(),
            ],
          ],
        ),
      ),
    );
  }
}

/// The empty-chat screen's question, which changes with the project by
/// sweeping rather than by snapping or fading: the new text takes over from
/// the first character and the change front moves progressively towards the
/// end, so the left of the line already reads the new question while the
/// tail is still the old one. The front runs the longer string's length, so
/// a shorter new question sees the old one's tail eaten past its own end
/// rather than left standing behind the front.
///
/// The tween carries the strings, so a change mid-sweep retargets from the
/// hybrid on screen — the framework's own interruptible path — rather than
/// restarting. Constant speed: a fade would rush the left end and hide the
/// sweep the motion is.
class _QuestionSweep extends ImplicitlyAnimatedWidget {
  const _QuestionSweep({
    required this.text,
    required this.style,
  }) : super(
          duration: const Duration(milliseconds: 400),
          curve: Curves.linear,
        );

  final String text;
  final TextStyle? style;

  @override
  ImplicitlyAnimatedWidgetState<_QuestionSweep> createState() =>
      _QuestionSweepState();
}

/// The sweep as a tween: at [t] the front sits [t] of the way along the
/// longer of the two strings, left of it the new question, right of it the
/// old one. Larping the strings rather than animating a bare scalar is what
/// lets the framework retarget from the hybrid mid-sweep — the alternative
/// was bookkeeping in the builder to recover what the tween never carried.
class _SweepTween extends Tween<String> {
  _SweepTween({super.begin, super.end});

  @override
  String lerp(double t) {
    final target = end ?? "";
    final from = begin ?? "";
    final n = math.max(target.length, from.length);
    final k = (t * n).round().clamp(0, n);
    return target.substring(0, math.min(k, target.length)) +
        from.substring(math.min(k, from.length));
  }
}

class _QuestionSweepState extends AnimatedWidgetBaseState<_QuestionSweep> {
  late _SweepTween _tween;

  @override
  void initState() {
    _tween = _SweepTween(begin: widget.text, end: widget.text);
    super.initState();
  }

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _tween = visitor(_tween, widget.text,
        (value) => _SweepTween(begin: value as String)) as _SweepTween;
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _tween.evaluate(animation),
      textAlign: TextAlign.center,
      style: widget.style,
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

/// The page with no conversation on it yet — one still being read off disk, or
/// a paired device's list with nothing picked out of it. Carries the drawer and
/// bar the real page would. The default child is the spinner, which is what
/// reading one off disk wants.
class _Waiting extends StatelessWidget {
  const _Waiting({
    required this.withDrawer,
    this.child = const CircularProgressIndicator(),
  });

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

/// One row of the conversation: a message, or a line saying the room's mode
/// changed before it. Each row owns its own alignment — the bubble aligns
/// itself, the separator is full width — so the list renders entries and
/// nothing wraps anything.
sealed class ConversationEntry {
  const ConversationEntry();
}

class MessageEntry extends ConversationEntry {
  const MessageEntry(this.message,
      {required this.inOmadaSection, required this.last});

  final Message message;

  /// The reply sits in a section of the conversation where Omada is on: an
  /// unnamed reply is the main agent's, and names itself "Entoli".
  final bool inOmadaSection;

  /// The newest message of the thread, which is the one a running turn
  /// appends to — the spinner and the caret live on it.
  final bool last;
}

class SectionEntry extends ConversationEntry {
  const SectionEntry(this.omada);

  /// The mode the room entered at this boundary.
  final bool omada;
}

/// The divider after the message a compaction's boundary names. [summary] is
/// what the drawer behind it shows.
class CompactionEntry extends ConversationEntry {
  const CompactionEntry(this.summary);

  /// What the model reads in place of the messages above this line.
  final String summary;
}

/// The conversation as rows, walked off the thread in order. A turn opener
/// carrying a mode that differs from the running one emits a [SectionEntry]
/// first — both flips are rows, the off-flip bounding an on-section — and
/// every message carries whether it sits in an on-section, which is what
/// names the main agent "Entoli" there. A compaction boundary is said after
/// the message it covers: the divider is where the summary took over.
List<ConversationEntry> entriesOf(Chat chat) {
  final entries = <ConversationEntry>[];
  var on = false;
  final byBoundary = {for (final c in chat.compactions) c.upToMessageId: c};
  for (final (index, m) in chat.messages.indexed) {
    final opener = m.omadaOn;
    if (opener != null && opener != on) {
      on = opener;
      entries.add(SectionEntry(on));
    }
    entries.add(MessageEntry(m,
        inOmadaSection: on, last: index == chat.messages.length - 1));
    final marker = byBoundary[m.id];
    if (marker != null) entries.add(CompactionEntry(marker.summary));
  }
  return entries;
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  /// How far off the end still counts as reading the latest: inside it a turn
  /// keeps the view pinned, outside it the jump button appears.
  static const _slack = 200.0;

  final TextEditingController _controller = TextEditingController();
  late final ScrollController _scroll = ScrollController();
  late final ScrollFollow _follow = ScrollFollow(_scroll);

  /// A notifier rather than a field: only the jump button reads it, and a
  /// `setState` mid-drag would rebuild every visible bubble to swap it.
  final ValueNotifier<bool> _atBottom = ValueNotifier(true);

  /// The chat the view has already been dropped to the bottom of.
  String? _opened;

  /// Chats we have already asked about since they were opened. Keeps a rebuild
  /// from re-prompting for the same expired chat.
  String? _expiryChecked;

  /// The page's half of the memory notes: the ones this chat is about land as
  /// a line, since the turn they came from is over by then.
  StreamSubscription<MemoryNote>? _memoryNotes;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_readPosition);
    _memoryNotes = ref
        .read(agentBackendProvider)
        .memoryNotes
        .where((note) => note.chatId == widget.chatId)
        .listen((note) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(note.text)),
      );
    });
  }

  @override
  void dispose() {
    _memoryNotes?.cancel();
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
  void _scrollToBottom() => _follow.jumpIfFollowing();

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

  /// What the list does on the way past, and what [ScrollFollow] answers for:
  /// a gesture away from the end stops the turn following the reader down, and
  /// arriving at the end starts it again.
  bool _onScroll(ScrollNotification n) => _follow.onNotification(n);

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
    // A mirrored chat is read through the hub's mirror rather than the local
    // store, so it is a different controller and a different bottom of the
    // page. Everything between those two is the same page — see [_page].
    return ref.watch(isMirroredChatProvider(widget.chatId))
        ? _mirrored(context)
        : _local(context);
  }

  Widget _local(BuildContext context) {
    final view = ref.watch(chatControllerProvider(widget.chatId));
    final notifier = ref.read(chatControllerProvider(widget.chatId).notifier);
    ref.listen(chatControllerProvider(widget.chatId), (_, _) => _scrollToBottom());
    final chat = view.chat;
    if (chat == null) return _waiting();
    _opening(chat);
    // Check expiry once per open: a temporary chat whose window has passed is
    // offered a choice between keeping it (turning its TTL off) and deleting it.
    if (_expiryChecked != widget.chatId) {
      _expiryChecked = widget.chatId;
      _checkExpiry(context, chat.state);
    }

    // A chat being typed into from a paired device says so: the prompts
    // arriving are somebody else's, and nothing else on the page would tell.
    final drivenBy = ref.watch(drivenChatsProvider)[widget.chatId];
    return _page(
      context,
      chat: chat,
      view: view,
      editing: notifier,
      details: [
        if (drivenBy != null)
          _TitleLine(icon: Icons.edit_outlined, text: "Driven from $drivenBy"),
      ],
      onOpenSettings: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatSettingsPage(chatId: widget.chatId)),
      ),
      whenEmpty: _EmptyChat(project: chat.state.project, controller: _controller),
      bottom: ref.watch(setupCompleteProvider(chat.state.project))
          ? _turnBar(
              view: view,
              driver: notifier,
              project: chat.state.project,
              onVoice: ref.watch(voiceProvider).available
                  ? () => openVoice(context, ref, widget.chatId)
                  : null,
              workspace: ref
                  .watch(appConfigProvider)
                  .workspaceDir(widget.chatId, project: chat.state.project),
              workspaceHome: ref
                  .watch(appConfigProvider)
                  .projectWorkspaceDir(project: chat.state.project),
            )
          : NeedsSetupBar(
              onOpenSettings: () => openSetupSettings(context),
            ),
    );
  }

  /// A mirrored chat's page. Nothing here touches the repository or the store
  /// — every byte came over the wire and stays in RAM, so expiry, settings and
  /// the whole message-editing row are out whether or not this device is
  /// driving. What control changes is only whether there is a composer: the
  /// turn itself runs on the home device either way.
  Widget _mirrored(BuildContext context) {
    final view = ref.watch(mirrorChatControllerProvider(widget.chatId));
    final driver = ref.read(mirrorChatControllerProvider(widget.chatId).notifier);
    final control = ref.watch(mirrorControlProvider(widget.chatId));
    ref.listen(mirrorChatControllerProvider(widget.chatId), (_, _) => _scrollToBottom());
    // One pass over the Remotes list for the two things drawn from it, so the
    // page rebuilds when they change rather than whenever anything does.
    final (:online, :deviceName) = ref.watch(remoteChatsProvider.select((chats) {
      for (final entry in chats) {
        if (entry.chatId == widget.chatId) {
          return (online: entry.online, deviceName: entry.deviceName);
        }
      }
      return (online: false, deviceName: "the home device");
    }));
    final chat = view.chat;
    if (chat == null) return _waiting();
    _opening(chat);

    final held = control.held && online;
    final controls = ref.read(mirrorControlProvider(widget.chatId).notifier);
    return _page(
      context,
      chat: chat,
      view: view,
      details: [_TitleLine(icon: Icons.devices_other, text: deviceName)],
      whenEmpty: const Center(child: Text("No messages yet")),
      banner: !online
          ? MirrorStrip.offline(deviceName: deviceName)
          : held
              ? MirrorStrip.inControl(
                  deviceName: deviceName, onRelease: controls.release)
              : null,
      bottom: held
          ? _turnBar(
              view: view,
              driver: driver,
              project: chat.state.project,
              workspace: null)
          : ViewOnlyBar(
              online: online,
              asking: control.asking,
              takenByAnother: control.takenByAnother,
              onTakeControl: controls.take,
            ),
    );
  }

  Widget _waiting() => _Waiting(withDrawer: widget.withDrawer);

  /// Land at the end of the conversation the first time this chat is drawn.
  void _opening(Chat chat) {
    if (_opened == widget.chatId) return;
    _opened = widget.chatId;
    _settleAtBottom();
  }

  /// The chat, however it is being read. [editing] is the controller the
  /// message row acts through and is null for a mirror, whose messages are
  /// the home device's to edit; [onOpenSettings] is null for the same reason.
  /// [banner] floats over the conversation, and [bottom] is whatever answers
  /// the turn — a composer, or a bar saying why there is none.
  Widget _page(
    BuildContext context, {
    required Chat chat,
    required ChatViewState view,
    required List<Widget> details,
    required Widget whenEmpty,
    required Widget bottom,
    ChatController? editing,
    VoidCallback? onOpenSettings,
    Widget? banner,
  }) {
    final lines = [..._details(chat.state), ...details];
    final barHeight = _barHeight(context, lines.length);
    final title = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Held to the height the bar counted for it, the way a detail line
          // is.
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(_titleHeight),
            child: Text(chat.state.title.orUntitled),
          ),
          ...lines,
        ],
      ),
    );
    return Scaffold(
      drawer: widget.withDrawer ? const NavDrawer(child: Sidebar()) : null,
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: barHeight,
        title: onOpenSettings == null
            ? title
            : InkWell(
                onTap: onOpenSettings,
                // Fills the bar between leading and actions so the whole strip
                // opens the chat's settings, not just the text.
                child: SizedBox(
                  height: barHeight,
                  width: double.infinity,
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
              ),
        actions: [
          if (view.isRunning)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
        ],
      ),
      body: _ReadableColumn(
        banner: banner,
        bottom: bottom,
        child: _conversation(chat, view, editing, whenEmpty),
      ),
    );
  }

  /// What a running turn puts on screen, and what answers it. A question takes
  /// the composer's place rather than sitting above it: the turn is waiting on
  /// this answer, and there is nothing useful to type until it has it.
  ///
  /// [workspace] is where this chat's shell stands, for the composer's bar —
  /// null on a mirrored chat, whose commands run on the device they are
  /// driven to rather than this one. [workspaceHome] is the project workspace
  /// beside it, what the bar's fallback words in the guest's vocabulary.
  Widget _turnBar({
    required ChatViewState view,
    required TurnDriver driver,
    required String? project,
    VoidCallback? onVoice,
    String? workspace,
    String? workspaceHome,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TurnSurface(view: view, notifier: driver),
          switch (view.roomPhase) {
            RoomPhase.waitingOnYou => TurnQuestions(view: view, notifier: driver),
            _ => Composer(
                controller: _controller,
                agentSpeaking: view.roomPhase == RoomPhase.agentSpeaking,
                onSend: (text, attachments) =>
                    driver.send(text, attachments: attachments),
                onAbort: driver.abort,
                project: project,
                onVoice: onVoice,
                workspace: workspace,
                workspaceHome: workspaceHome,
              ),
          },
        ],
      );

  /// The one link-opening rule, both renderers of model-written markdown — a
  /// reply and a compaction summary — share it.
  void _openLink(BuildContext context, String href) {
    final uri = Uri.tryParse(href);
    if (uri != null) ref.read(linkOpenerProvider).open(context, uri);
  }

  /// The bytes of the picture beside an addressed member's name: the named
  /// member's, where the message names one — the same condition the label
  /// answers, so the two never disagree. Null where it names none, so the
  /// main agent's reply draws its label alone, whatever a file in the agents
  /// directory might hold.
  Uint8List? _avatarOf(Chat chat, Message message) {
    final member = nameOf(message.author);
    if (member == null) return null;
    return ref
        .watch(agentPictureProvider(
            (project: chat.state.project, name: member)))
        .value;
  }

  Widget _conversation(
      Chat chat, ChatViewState view, ChatController? editing, Widget whenEmpty) {
    final speechReady = ref.watch(speechReadyProvider);
    final reading = ref.watch(readAloudProvider);
    if (chat.messages.isEmpty) return whenEmpty;
    final entries = entriesOf(chat);
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView.builder(
              controller: _scroll,
              itemCount: entries.length,
              itemBuilder: (context, i) => switch (entries[i]) {
                SectionEntry(:final omada) => ConversationSeparator(
                    text: omada ? "Omada is turned on" : "Omada is turned off"),
                CompactionEntry(:final summary) => ConversationSeparator(
                    text: "Compact Conversation",
                    body: MessageText(
                      text: summary,
                      isError: false,
                      isWaiting: false,
                      caret: false,
                      onTapLink: (href) => _openLink(context, href),
                    )),
                MessageEntry(:final message, :final inOmadaSection, :final last) =>
                  Builder(builder: (context) {
                    // A mirror has no editing controller: the log belongs to
                    // the home device, so the whole row of things to do to a
                    // message is out — and while a turn runs, the controller
                    // refuses them all.
                    final mutable = editing != null && !view.isRunning;
                    return MessageBubble(
                      chatId: widget.chatId,
                      message: message,
                      author: message.author,
                      // The member's picture, only where a member speaks —
                      // the label's own condition. Read per message: one
                      // provider entry per addressed member.
                      avatar: _avatarOf(chat, message),
                      entoli: inOmadaSection,
                      isWaiting: view.isRunning && last,
                      waitingNotice: view.retry,
                      waitingStatus: view.status,
                      shellOutput: view.shellOutput,
                      onTapLink: (href) => _openLink(context, href),
                      threads: editing == null ? null : chat.branches[message.id],
                      onThreadStep:
                          mutable ? (step) => editing.stepThread(message.id, step) : null,
                      onDelete: mutable ? () => editing.deleteThread(message.id) : null,
                      onEdit: mutable && message.role == MessageRole.user
                          ? (text) => editing.editAndResend(message.id, text)
                          : null,
                      onRegenerate: mutable ? () => editing.regenerate(message.id) : null,
                      onSpeak: speechReady && message.hasText
                          ? () => readAloud(context, ref, message.id, message.plainText)
                          : null,
                      isSpeaking: reading == message.id,
                    );
                  }),
              }),
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
        // A built-in's directory name is read as its label, not its path.
        if (state.project != null) _TitleLine(text: projectLabel(state.project)),
        if (state.pinned) _TitleLine(icon: Icons.push_pin, text: "Pinned"),
        if (state.tempTtlExpiresAt != null)
          _TtlLine(expiresAt: state.tempTtlExpiresAt!),
      ];

  /// What the title takes, and what the row drawing it is held to.
  static const _titleHeight = 28.0;

  /// Tall enough for the title and its detail lines, with Material's toolbar
  /// as the floor rather than as the first line's allowance.
  double _barHeight(BuildContext context, int details) {
    final scaler = MediaQuery.textScalerOf(context);
    final lines =
        scaler.scale(_titleHeight) + details * scaler.scale(_TitleLine.height);
    return math.max(kToolbarHeight, lines);
  }
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
