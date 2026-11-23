import "dart:async";
import "dart:math" as math;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:entoli_core/model/agent_backend.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/room/room_state.dart";
import "package:entoli_core/model/project.dart";
import "../../providers.dart";
import "package:entoli_core/view/fonts.dart";
import "package:entoli_core/view/theme.dart";
import "../selection.dart";
import "../voice/read_aloud.dart";
import "../widgets/app_mark.dart";
import "../widgets/chip_row.dart";
import "../widgets/completion_field.dart";
import "../widgets/side_panel_frame.dart";
import "package:entoli_core/view/widgets/scrolling.dart";
import "chat_settings_page.dart";
import "../../app/chat_controller.dart";
import "../../app/chat_session.dart";
import "package:entoli_core/transcript/reader.dart" show WidgetReader;
import "../../app/new_chat_session.dart";
import "chat_expiry.dart";
import "../../app/composer.dart"
    show
        ComposerAnswering,
        ComposerImported,
        ComposerModel,
        ComposerNeedsSetup,
        ComposerReady,
        ComposerStarting,
        ComposerViewOnly;
import "../../app/mirror_controller.dart";
import "package:entoli_core/view/chat/plan_page.dart" show PlanButton;
import "package:entoli_core/transcript/transcript.dart";
import "package:entoli_core/model/formatting.dart" show formatRemaining;
import "widgets/composer.dart";
import "widgets/turn_surface.dart";
import "widgets/composer_controller.dart";
import "widgets/composer_embed.dart";
import "widgets/paired_project_badges.dart";
import "package:entoli_core/view/chat/widgets/message_bubble.dart";
import "package:entoli_core/view/chat/widgets/conversation_view.dart";
import "widgets/imported_bar.dart";
import "widgets/needs_setup_bar.dart";
import "widgets/view_only_bar.dart";
import "../voice/voice_page.dart" show openVoice, startVoiceChat;
import "package:entoli_core/view/widgets/dialogs.dart" show notify, sayLater;

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatId = ref.watch(selectedChatIdProvider);
    if (chatId != null) {
      return _ChatBody(chatId: chatId);
    }
    return const _NewChat();
  }
}

/// Nothing selected: the chat that has not been made yet. Nothing here is keyed
/// on a chat, because there is none — the project is `selectedProjectProvider`'s
/// and the settings are this screen's own, until the first message makes one
/// out of both. See "Nothing selected is a new chat".
class _NewChat extends ConsumerStatefulWidget {
  const _NewChat();

  @override
  ConsumerState<_NewChat> createState() => _NewChatState();
}

class _NewChatState extends ConsumerState<_NewChat> {
  /// Found once, not on every build: the root overlay does not move.
  late final _say = sayLater(context);

  /// The screen's session: its composer, its settings, and how the first
  /// message makes a chat. Watched in the build, which keeps it.
  NewChatSession get _session => ref.read(newChatSessionProvider);
  ComposerController get _controller => _session.text.controller;
  ComposerModel get _model => _session.composer;
  bool get _starting => _session.starting.value;

  void _openSettings() {
    final session = _session;
    openNewChatSettings(
      context,
      initial: session.meta.value,
      project: ref.read(selectedProjectProvider).project,
      onSave: (meta) => session.meta.value = meta,
    );
  }

  /// The composer, or what the session's slot puts in its place.
  Widget _bottomBar() {
    final slot = _session.slot(
      WidgetReader(ref),
      ref.watch(selectedProjectProvider),
      say: _say,
      startVoice: (meta) {
        if (mounted) startVoiceChat(context, ref, meta: meta);
      },
    );
    if (slot is ComposerStarting) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _CommandHint(),
        switch (slot) {
          ComposerReady(:final binding) => Composer(
            model: _model,
            binding: binding,
          ),
          ComposerViewOnly() => const ViewOnlyBar(),
          _ => const NeedsSetupBar(),
        },
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(newChatSessionProvider);
    return ListenableBuilder(
      listenable: session.starting,
      builder: (context, _) => _screen(context),
    );
  }

  Widget _screen(BuildContext context) {
    final at = ref.watch(selectedProjectProvider);
    return Scaffold(
      appBar: AppBar(
        leading: SidePanelButton.leadingOf(context),
        title: const _AppBrand(),
        actions: [
          // A paired device's chat takes its settings once it is there:
          // these name this device's models.
          if (at.device == null)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: "Chat settings",
              onPressed: _openSettings,
            ),
        ],
      ),
      body: ReadableColumn(
        bottom: _bottomBar(),
        child: _starting
            ? const Center(child: CircularProgressIndicator())
            : KeyboardDismissOnTouch(
                child: _EmptyChat(
                  project: at.project,
                  device: at.device,
                  controller: _controller,
                  // The paired devices' badges are the new-chat screen's own
                  // — a chat that exists with nothing said in it yet is
                  // mid-turn at worst, and a list of other devices under its
                  // question would say nothing true about it.
                  showSyncedCards: true,
                ),
              ),
      ),
    );
  }
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

  final ProjectRef selected;
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
                  label: ProjectChipLabel(project),
                  selected: localProject(project) == selected,
                  onSelected: (on) =>
                      selectProject(ref, localProject(on ? project : null)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A chat with nothing said in it yet, which is also the page the app opens
/// on. Athena, the question, the project it would happen in, and — while the
/// user has asked for them — the start page's chips, which are the only place
/// the composer's `/` and `@` menus are named before their trigger is typed.
/// See [_StarterChips] for what "asked for" means.
///
/// Its rows are `settled`, so what the user arrives on is static and every
/// change from their first interaction on animates.
class _EmptyChat extends ConsumerWidget {
  const _EmptyChat({
    required this.project,
    required this.controller,
    this.device,
    this.showSyncedCards = false,
  });

  /// The paired device [project] is on, or null for this one. Its question
  /// and starters are that device's.
  final String? device;

  /// The project this chat is in, or on the new-chat screen the one the next
  /// chat goes to. Either way it is the badge picked out.
  final String? project;

  /// The composer's, so a chip can type into it. See [insertCompletion] for
  /// where a trigger lands and why it does not ask for the focus.
  final TextEditingController controller;

  /// The paired devices' badges, which only the new-chat screen asks for —
  /// see its own call for why.
  final bool showSyncedCards;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remote = device != null;
    final question = ref.watch(
      newChatQuestionProvider((device: device, project: project)),
    );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Athena(),
            const SizedBox(height: 16),
            // A project whose description is the empty string asks nothing:
            // the sweep is handed the empty string and eats its own tail
            // away, rather than the widget leaving the tree and the next
            // question's arrival being a mount instead of a change.
            _QuestionSweep(text: question, style: theme.textTheme.titleMedium),
            // On the new-chat screen this device's badges stay whichever
            // device is picked, so there is always a way back to them.
            if (!remote || showSyncedCards)
              _ProjectBadges(
                selected: (device: device, project: project),
                settled: true,
              ),
            if (showSyncedCards) const PairedProjectBadges(),
            _StarterChips(
              at: (device: device, project: project),
              controller: controller,
            ),
          ],
        ),
      ),
    );
  }
}

/// The start page's chips: a `/skill` or `@agent` per thing the library holds.
/// Discovery is a choice, so the row is drawn only while
/// `showCommandChipsProvider` says the user asked for it — see "The chat page"
/// in AGENTS.md.
///
/// A widget of its own rather than a block of `_EmptyChat` so the library is
/// watched only while the row is on screen: a library reload walks every
/// project's prompts and comes back through here, and there is no reason for
/// that to rebuild a screen drawing nothing about it.
class _StarterChips extends ConsumerWidget {
  const _StarterChips({required this.at, required this.controller});

  /// The project whose library is read, and whose paired device it is on — the
  /// same reference the badges above are given.
  final ProjectRef at;

  /// The composer's, so a chip can type into it.
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showCommandChipsProvider)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    // Hoisted out of the loop: one style for every chip, built once a build.
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: monoFamily,
    );
    final starters = [
      for (final kind in CompletionKind.values)
        for (final option in ref.watch(
          completionsProvider((project: at, kind: kind)),
        ))
          (kind: kind, option: option),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ChipRow(
        settled: true,
        entries: [
          for (final starter in starters)
            ChipRowEntry(
              key: ValueKey("${starter.kind.trigger}${starter.option.name}"),
              child: ActionChip(
                label: Text("${starter.kind.trigger}${starter.option.name}"),
                labelStyle: labelStyle,
                // Null rather than the empty string: `Chip` builds a
                // `Tooltip` for whatever it is given, and an empty one is a
                // blank box on a long press.
                tooltip: starter.option.description,
                onPressed: () => insertCompletion(
                  controller,
                  starter.kind,
                  starter.option.name,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CommandHint extends StatelessWidget {
  const _CommandHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Text(
        "Type / for commands, @ for agents.",
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// The empty chat's figure. Full length rather than cropped to a square, so
/// it is sized by the screen's height and capped where a phone held sideways
/// would otherwise lose the question below the fold. The feet fade into the
/// page, so the figure stands on the question rather than ending above it.
class _Athena extends StatelessWidget {
  const _Athena();

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.3).clamp(
      120.0,
      280.0,
    );
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 0.82, 1],
      ).createShader(bounds),
      child: Image.asset(
        "assets/images/athena.png",
        height: height,
        filterQuality: FilterQuality.medium,
        semanticLabel: "Athena",
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
  const _QuestionSweep({required this.text, required this.style})
    : super(duration: const Duration(milliseconds: 400), curve: Curves.linear);

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
    _tween =
        visitor(
              _tween,
              widget.text,
              (value) => _SweepTween(begin: value as String),
            )
            as _SweepTween;
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

/// The page with no conversation on it yet — one still being read off disk,
/// or still on its way from a paired device. Carries the way back to the
/// sidebar the real page would, where there is one.
class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) {
    final leading = SidePanelButton.leadingOf(context);
    return Scaffold(
      appBar: leading == null
          ? null
          : AppBar(leading: leading, title: const _AppBrand()),
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody({required this.chatId});
  final String chatId;

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  /// Found once, not on every streamed token's build: the root overlay does
  /// not move.
  late final _say = sayLater(context);

  /// The chat's session: its composer, and how a message is sent. Watched in
  /// the build, which keeps it while the page is up.
  ChatSession get _session => ref.read(chatSessionProvider(widget.chatId));
  ComposerController get _controller => _session.text.controller;
  ComposerModel get _model => _session.composer;

  /// The composer on screen, which a reply's quote focuses.
  final GlobalKey<ComposerState> _composer = GlobalKey();

  /// The conversation on screen, which a message sent follows.
  final GlobalKey<ConversationViewState> _conversation = GlobalKey();

  /// Chats we have already asked about since they were opened. Keeps a rebuild
  /// from re-prompting for the same expired chat.
  String? _expiryChecked;

  /// The page's half of the memory notes: the ones this chat is about land as
  /// a line, since the turn they came from is over by then.
  StreamSubscription<MemoryNote>? _memoryNotes;

  @override
  void initState() {
    super.initState();
    _memoryNotes = ref
        .read(agentBackendProvider)
        .memoryNotes
        .where((note) => note.chatId == widget.chatId)
        .listen((note) {
          if (!mounted) return;
          notify(context, note.text);
        });
  }

  @override
  void dispose() {
    _memoryNotes?.cancel();
    super.dispose();
  }

  /// Ask whether to keep an expired temporary chat (turning its TTL off) or
  /// delete it. The sweep handles non-open chats silently; this is the one
  /// case where the chat being deleted is the one the user is looking at.
  Future<void> _checkExpiry(BuildContext context, ChatState state) =>
      checkChatExpiry(context, widget.chatId, state);

  @override
  Widget build(BuildContext context) {
    ref.watch(chatSessionProvider(widget.chatId));
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
    final chat = view.chat;
    if (chat == null) return _waiting();
    // Check expiry once per open: a temporary chat whose window has passed is
    // offered a choice between keeping it (turning its TTL off) and deleting it.
    if (_expiryChecked != widget.chatId) {
      _expiryChecked = widget.chatId;
      _checkExpiry(context, chat.state);
    }

    return _page(
      context,
      chat: chat,
      view: view,
      // An edit, a regenerate or a reaction is a turn, which an imported
      // chat refuses until it is enabled.
      editing: chat.state.imported ? null : notifier,
      details: const [],
      whenEmpty: _EmptyChat(
        project: chat.state.project,
        controller: _controller,
      ),
      bottom: _turnBar(view: view, driver: notifier),
    );
  }

  /// A mirrored chat's page. Every byte came over the wire and stays in RAM,
  /// and every write goes back to the home device — the repository routes the
  /// settings there, and the controller the turns and edits. Offline, it is a
  /// snapshot: read, and nothing to type into.
  Widget _mirrored(BuildContext context) {
    final view = ref.watch(mirrorChatControllerProvider(widget.chatId));
    final driver = ref.read(
      mirrorChatControllerProvider(widget.chatId).notifier,
    );
    final (:online, name: deviceName, :deviceId) =
        ref.watch(mirrorHomeProvider(widget.chatId)) ?? unknownMirrorHome;
    final chat = view.chat;
    if (chat == null) return _waiting();

    return _page(
      context,
      chat: chat,
      view: view,
      // The device is the strip's to say.
      details: const [],
      editing: online && !chat.state.imported ? driver : null,
      whenEmpty: const Center(child: Text("No messages yet")),
      banner: online
          ? MirrorStrip.remote(deviceName: deviceName)
          : MirrorStrip.offline(deviceName: deviceName),
      bottom: _turnBar(
        view: view,
        driver: online ? driver : null,
        device: deviceId,
      ),
    );
  }

  Widget _waiting() => const _Waiting();

  /// The chat, however it is being read. [editing] is the controller the
  /// message row acts through, and null for a mirror this device does not
  /// hold.
  /// [banner] sits above the conversation, and [bottom] is whatever answers
  /// the turn — a composer, or a bar saying why there is none.
  Widget _page(
    BuildContext context, {
    required Chat chat,
    required ChatViewState view,
    required List<Widget> details,
    required Widget whenEmpty,
    required Widget bottom,
    TurnDriver? editing,
    Widget? banner,
  }) {
    final lines = [..._details(chat.state), ...details];
    final barHeight = _barHeight(context, lines.length);
    final speechReady = ref.watch(speechReadyProvider);
    final reading = ref.watch(readAloudProvider);
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
      appBar: AppBar(
        leading: SidePanelButton.leadingOf(context),
        titleSpacing: 0,
        toolbarHeight: barHeight,
        title: InkWell(
          onTap: () => openChatSettings(context, widget.chatId),
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
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          PlanButton(chatId: widget.chatId),
        ],
      ),
      body: ConversationView(
        key: _conversation,
        chatId: widget.chatId,
        banner: banner,
        bottom: bottom,
        whenEmpty: whenEmpty,
        message: (row, steerKey) => _message(
          row,
          view,
          editing,
          steerKey,
          speechReady: speechReady,
          reading: reading,
        ),
      ),
    );
  }

  /// What a running turn puts on screen, and what answers it. A question takes
  /// the composer's place rather than sitting above it: the turn is waiting on
  /// this answer, and there is nothing useful to type until it has it.
  Widget _turnBar({
    required ChatViewState view,
    required TurnDriver? driver,
    String? device,
  }) {
    final slot = _session.slot(
      WidgetReader(ref),
      view,
      driver,
      say: _say,
      openVoice: () {
        if (mounted) openVoice(context, ref, widget.chatId);
      },
      device: device,
      sent: () => _conversation.currentState?.follow(),
    );
    Widget over(Widget below) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TurnSurface(view: view, notifier: driver!, onWithdrawn: _model.restore),
        below,
      ],
    );
    return switch (slot) {
      ComposerReady(:final binding) => over(
        Composer(key: _composer, model: _model, binding: binding),
      ),
      ComposerAnswering() => over(TurnQuestions(view: view, notifier: driver!)),
      ComposerNeedsSetup() => const NeedsSetupBar(),
      ComposerImported() => ImportedBar(chat: view.chat!.state),
      ComposerViewOnly() || ComposerStarting() => const ViewOnlyBar(),
    };
  }

  /// A passage being answered, into the composer — or, while a question
  /// stands in its place, into what the composer will hold when it is back.
  void _reply(ComposerEmbed quote) {
    final composer = _composer.currentState;
    composer == null ? _controller.append(quote) : composer.embed(quote);
  }

  Widget _message(
    MessageRow row,
    ChatViewState view,
    TurnDriver? editing,
    GlobalKey Function(String id) steerKey, {
    required bool speechReady,
    required String? reading,
  }) {
    final MessageRow(:message, :last, :reactions) = row;
    return MessageBubble(
      chatId: widget.chatId,
      message: message,
      avatar: row.face(WidgetReader(ref), project: view.chat?.state.project),
      moment: row.moment(view, editing),
      latest: last,
      onReply: (quote) => _reply(QuoteEmbed(quote)),
      reactions: reactions,
      actions: MessageActions.of(row, view, editing),
      onSpeak: speechReady && message.hasText
          ? () => readAloud(context, ref, message.id, message.plainText)
          : null,
      isSpeaking: reading == message.id,
      steerKey: steerKey,
    );
  }

  /// What the bar says about the chat under its title, a line each. The
  /// conditions are here and nowhere else: [_barHeight] counts what this
  /// returns, so a line added here is one the bar makes room for.
  List<Widget> _details(ChatState state) {
    // Every chat is in a project, so naming the default one says nothing.
    // A built-in's directory name is read as its label, not its path.
    final project = state.project != null
        ? _TitleLine(text: projectLabel(state.project))
        : null;
    final expiresAt = state.tempTtlExpiresAt;
    return [
      // The countdown shares the project's line, held to the bar's right edge.
      if (expiresAt != null)
        Row(
          children: [
            ?project,
            const Spacer(),
            _TtlLine(expiresAt: expiresAt),
          ],
        )
      else
        ?project,
      if (state.pinned) _TitleLine(icon: Icons.push_pin, text: "Pinned"),
    ];
  }

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
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
    return _TitleLine(
      icon: Icons.hourglass_empty,
      text: formatRemaining(remaining),
    );
  }
}
