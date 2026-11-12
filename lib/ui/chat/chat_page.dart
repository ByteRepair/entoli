import "dart:async";
import "dart:math" as math;

import "package:flutter/foundation.dart" show listEquals;
import "package:flutter/material.dart";
import "package:flutter/rendering.dart"
    show RenderAbstractViewport, RenderProxyBox;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:super_sliver_list/super_sliver_list.dart";

import "../../domain/agent_backend.dart";
import "../../domain/agent_face.dart";
import "../../domain/models.dart";
import "../../domain/room/room_state.dart";
import "../../domain/project.dart";
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../fonts.dart";
import "../theme.dart";
import "../selection.dart";
import "../voice/read_aloud.dart";
import "../voice/voice_page.dart";
import "../widgets/app_mark.dart";
import "../widgets/chip_row.dart";
import "../widgets/completion_field.dart";
import "../widgets/side_panel_frame.dart";
import "../widgets/scrolling.dart";
import "chat_chrome.dart";
import "chat_settings_page.dart";
import "../../app/chat_controller.dart";
import "../../app/chat_session.dart";
import "../../app/new_chat_session.dart";
import "chat_expiry.dart";
import "../../app/composer.dart" show ComposerBinding, ComposerModel;
import "../../app/mirror_controller.dart";
import "plan_page.dart" show PlanButton;
import "../../app/transcript/transcript.dart";
import "activity/card.dart" show ActivitySource, liveMessageOf;
import "activity/format.dart" show formatRemaining;
import "widgets/chapter_rail.dart";
import "widgets/composer.dart";
import "widgets/composer_controller.dart";
import "widgets/goal_mark_row.dart";
import "widgets/composer_embed.dart";
import "widgets/paired_project_badges.dart";
import "widgets/message_bubble.dart";
import "widgets/message_text.dart";
import "widgets/omada_separator.dart" show ConversationSeparator;
import "widgets/needs_setup_bar.dart";
import "widgets/view_only_bar.dart";
import "../widgets/dialogs.dart" show notify;

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

/// The conversation's share of a wide window. Past this a reply is a line of
/// text too long to track back to the start of.
const double _readableWidth = 760;

/// The conversation and whatever answers it, centred and held to
/// [_readableWidth] — a phone gets the whole screen, a monitor gets a line it
/// can read back to the start of. The composer goes inside that width rather
/// than under it, or the conversation sits over a field twice its own width.
/// Both pages with something to type in are this. [banner] is a full-width row
/// above it, under the title bar, and stays while the conversation scrolls.
///
/// [side] goes in the margin to the right of the column, [sideWidth] wide, and
/// only where the margin has that much room: it is laid over the margin rather
/// than beside the column, so the column stays centred whether it is there or
/// not.
class _ReadableColumn extends StatelessWidget {
  const _ReadableColumn({
    required this.child,
    required this.bottom,
    this.bar,
    this.banner,
    this.side,
    this.sideWidth = 0,
  });

  final Widget child;
  final Widget bottom;

  /// What publishes the native shell's toolbar for this page, drawing nothing
  /// on screen; only inside the shell, whose toolbar is over the top of the
  /// page and whose composer is over the bottom of it. The conversation then
  /// scrolls under both, and what is at the bottom floats over it, above the
  /// composer.
  final Widget? bar;

  bool get _shell => bar != null;
  final Widget? banner;
  final Widget? side;
  final double sideWidth;

  /// Between the column's edge and [side].
  static const _sideGap = 16.0;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final page = _column(context);
    if (!_shell) return page;
    // Expanded to the page: the bar draws nothing, and a stack sized by its
    // children would size itself to that. A tooltip on this page opens above
    // what it is about: the page runs under the composer, and a tooltip only
    // knows the room the Flutter view has, so below would be behind it.
    final tooltips = TooltipTheme.of(context);
    return TooltipTheme(
      data: tooltips.copyWith(preferBelow: false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?bar,
          // A banner is not scrolled under: it sits below the toolbar.
          MediaQuery.removePadding(
            context: context,
            removeTop: banner != null,
            child: Padding(
              padding: EdgeInsets.only(top: banner != null ? insets.top : 0),
              child: page,
            ),
          ),
        ],
      ),
    );
  }

  Widget _column(BuildContext context) => Column(
    children: [
      ?banner,
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final column = Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _readableWidth),
                child: _shell
                    ? _FloatingBottom(bottom: bottom, child: child)
                    : Column(
                        children: [
                          Expanded(child: child),
                          bottom,
                        ],
                      ),
              ),
            );
            final margin = (constraints.maxWidth - _readableWidth) / 2;
            final fits = side != null && margin >= sideWidth + _sideGap * 2;
            // The column is in the stack whether or not the rail is beside
            // it: a window resized across the width the rail needs would
            // otherwise build the conversation anew, its scroll back at the
            // top.
            return Stack(
              children: [
                Positioned.fill(child: column),
                if (fits)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: constraints.maxWidth - margin + _sideGap,
                    width: sideWidth,
                    child: side!,
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );
}

/// The native shell's arrangement of the column: [child] the whole height,
/// and [bottom] — the turn surface, a question, a bar saying why there is no
/// composer — over its foot, just above the shell's composer. The
/// conversation is told both as its bottom padding, so it scrolls under them
/// and its last message still clears them.
class _FloatingBottom extends StatefulWidget {
  const _FloatingBottom({required this.bottom, required this.child});

  final Widget bottom;
  final Widget child;

  @override
  State<_FloatingBottom> createState() => _FloatingBottomState();
}

class _FloatingBottomState extends State<_FloatingBottom> {
  /// [_FloatingBottom.bottom]'s height as last laid out.
  double _height = 0;

  void _measured(Size size) {
    if (size.height == _height) return;
    // After this layout: the padding it changes is the list's, laid out in
    // the same pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _height = size.height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final composer = media.padding.bottom;
    return Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: media.copyWith(
              padding: media.padding.copyWith(bottom: composer + _height),
            ),
            child: widget.child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: composer,
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: _SizeReporter(onSize: _measured, child: widget.bottom),
          ),
        ),
      ],
    );
  }
}

/// Tells [onSize] the size [child] was laid out at, each time it changes.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReporter renderObject,
  ) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _reported) {
      _reported = size;
      onSize(size);
    }
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
  /// The screen's session: its composer, its settings, and how the first
  /// message makes a chat. Watched in the build, which keeps it.
  NewChatSession get _session => ref.read(newChatSessionProvider);
  ComposerController get _controller => _session.text as ComposerController;
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

  Future<void> _send(String text, List<Attachment> attachments) =>
      _session.send(text, attachments);

  /// The composer, or a "setup required" bar where the project needs setup
  /// and has not been set up yet. The bar replaces the composer entirely,
  /// the way `ViewOnlyBar` does for a mirrored chat.
  Widget _bottomBar() {
    final at = ref.watch(selectedProjectProvider);
    final project = at.project;
    final chrome = ref.watch(chatChromeProvider);
    if (_starting) return const SizedBox.shrink();
    Widget composer(ComposerBinding binding) => chrome.composer(
      controller: _controller,
      model: _model,
      binding: binding,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The shell's own composer says it.
        if (!chrome.overPage) const _CommandHint(),
        if (at.device != null)
          // A paired device's project: its setup and its voice are that
          // device's.
          ref.watch(projectFrozenProvider(at))
              ? const ViewOnlyBar()
              : composer(
                  ComposerBinding(
                    agentSpeaking: false,
                    onSend: _send,
                    onAbort: () {},
                    project: project,
                    device: at.device,
                  ),
                )
        else if (ref.watch(setupCompleteProvider(project)))
          composer(
            ComposerBinding(
              agentSpeaking: false,
              onSend: _send,
              onAbort: () {},
              project: project,
              onVoice: () =>
                  startVoiceChat(context, ref, meta: _session.meta.value),
            ),
          )
        else
          const NeedsSetupBar(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(newChatSessionProvider);
    final chrome = ref.watch(chatChromeProvider);
    // The frontend draws this screen itself.
    if (chrome.drawsOpenChat) return const SizedBox.expand();
    return ListenableBuilder(
      listenable: session.starting,
      builder: (context, _) => _screen(context, chrome),
    );
  }

  Widget _screen(BuildContext context, ChatChrome chrome) {
    final at = ref.watch(selectedProjectProvider);
    return Scaffold(
      appBar: chrome.overPage
          ? null
          : AppBar(
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
      body: _ReadableColumn(
        bar: chrome.newChatBar(at: at, onSettings: _openSettings),
        bottom: _bottomBar(),
        // Where the frontend draws the screen itself, spinner and all.
        child:
            chrome.newChat(
              at: at,
              controller: _controller,
              starting: _starting,
            ) ??
            (_starting
                ? const Center(child: CircularProgressIndicator())
                : _EmptyChat(
                    project: at.project,
                    device: at.device,
                    controller: _controller,
                    // The paired devices' badges are the new-chat screen's own — a
                    // chat that exists with nothing said in it yet is mid-turn at
                    // worst, and a list of other devices under its question would
                    // say nothing true about it.
                    showSyncedCards: true,
                  )),
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

/// The conversation as the chapter rail reads it: its prompts, and every row
/// by message id — null where a row is not a message — which is how going to
/// a prompt finds its row.
class _Outline {
  const _Outline(this.chapters, this.rows);

  _Outline.of(Chat chat)
    : chapters = chaptersOf(chat),
      rows = [
        for (final row in Transcript.of("", chat).rows)
          row is MessageRow ? row.message.id : null,
      ];

  static const empty = _Outline([], []);

  final List<Chapter> chapters;
  final List<String?> rows;

  // Compared so that a streamed delta, which changes neither, redraws nothing.
  @override
  bool operator ==(Object other) =>
      other is _Outline &&
      listEquals(other.chapters, chapters) &&
      listEquals(other.rows, rows);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(chapters), Object.hashAll(rows));
}

/// Measure every row of a conversation up front, a frame's budget at a time,
/// so the scrollbar is sized by real extents rather than estimates. Past a
/// few hundred rows one row's error no longer moves the thumb, and measuring
/// them all is work nobody sees.
class _MeasureAll extends ExtentPrecalculationPolicy {
  @override
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context) =>
      context.numberOfItems <= 400;
}

final _measureAll = _MeasureAll();

class _ChatBodyState extends ConsumerState<_ChatBody>
    with SingleTickerProviderStateMixin {
  /// How far off the end still counts as reading the latest: inside it a turn
  /// keeps the view pinned, outside it the jump button appears.
  static const _slack = 200.0;

  /// Inside the native shell: settled at launch, so read once.
  late final ChatChrome _chrome = ref.read(chatChromeProvider);

  /// The chat's session: its composer, and how a message is sent. Watched in
  /// the build, which keeps it while the page is up.
  ChatSession get _session => ref.read(chatSessionProvider(widget.chatId));
  ComposerController get _controller => _session.text as ComposerController;
  ComposerModel get _model => _session.composer;

  /// What a steer taken back is put back into, attachments and all.
  final GlobalKey _composer = GlobalKey();

  /// The composer on screen, whichever draws it.
  ComposerHandle? get _handle => _composer.currentState as ComposerHandle?;
  late final ScrollController _scroll = ScrollController();
  late final ScrollFollow _follow = ScrollFollow(_scroll);

  /// What the list knows of rows it has not built: an extent for each, the
  /// measured one once it has been laid out. A plain `ListView` guesses from
  /// what is on screen, so its extent — and the scrollbar with it — shifted on
  /// every row scrolled in, and a jump to an unbuilt row landed on a guess.
  final ListController _list = ListController();

  /// The one move the page makes on its own: to a chapter, or to the latest.
  /// One controller, so a second press takes over from the first rather than
  /// both pulling at the view.
  late final AnimationController _glide = AnimationController(vsync: this)
    ..addListener(_glideTick)
    ..addStatusListener(_glideStatus);
  double _glideFrom = 0;
  double _glideAt = 0;
  double Function()? _glideTarget;
  VoidCallback? _glideLanded;

  /// A notifier rather than a field: only the jump button reads it, and a
  /// `setState` mid-drag would rebuild every visible bubble to swap it.
  final ValueNotifier<bool> _atBottom = ValueNotifier(true);

  /// The conversation as the chapter rail reads it, fed from the chat's view
  /// state rather than from this page's build: once with the chat as it was
  /// loaded, then on every change to it — a turn, a deletion, a thread
  /// switched. See [_feedOutline].
  final ValueNotifier<_Outline> _outline = ValueNotifier(_Outline.empty);
  ProviderSubscription<bool>? _mirroredFeed;
  ProviderSubscription<ChatViewState>? _outlineFeed;

  /// The key on each prompt's row: what the rail reads where it is and
  /// scrolls to. Made as the list builds a prompt's row.
  final Map<String, GlobalKey> _chapterKeys = {};

  List<Chapter> get _chapters => _outline.value.chapters;

  /// The chapter being read — the last prompt at or above the top of the view.
  /// A notifier so scrolling redraws the rail and nothing else.
  final ValueNotifier<int?> _chapter = ValueNotifier(null);

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
    _watchOutline();
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
  void didUpdateWidget(_ChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId == widget.chatId) return;
    _chapterKeys.clear();
    _chapter.value = null;
    _watchOutline();
  }

  /// Feed [_outline] from whichever controller reads this chat, and switch
  /// over if the chat starts or stops being mirrored.
  void _watchOutline() {
    _mirroredFeed?.close();
    _mirroredFeed = ref.listenManual(
      isMirroredChatProvider(widget.chatId),
      (_, mirrored) => _feedOutline(
        mirrored
            ? mirrorChatControllerProvider(widget.chatId)
            : chatControllerProvider(widget.chatId),
      ),
      fireImmediately: true,
    );
  }

  void _feedOutline(ProviderListenable<ChatViewState> source) {
    _outlineFeed?.close();
    _outline.value = _Outline.empty;
    _outlineFeed = ref.listenManual(source, (_, view) {
      final chat = view.chat;
      if (chat == null) return;
      final next = _Outline.of(chat);
      if (next == _outline.value) return;
      _outline.value = next;
      // A chapter added or a thread switched moves which one the view is
      // in, with no scroll to say so.
      _afterLayout((_) {});
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _mirroredFeed?.close();
    _outlineFeed?.close();
    _outline.dispose();
    _memoryNotes?.cancel();
    _scroll.removeListener(_readPosition);
    _glide.dispose();
    _list.dispose();
    _scroll.dispose();
    _atBottom.dispose();
    _chapter.dispose();
    super.dispose();
  }

  void _readPosition() {
    if (!_scroll.hasClients) return;
    _atBottom.value = _scroll.position.nearBottom(_slack);
    // After the frame, not now: a jump reports here before the list has laid
    // out the rows it moved to, and the rows it reads are the ones it left.
    if (_chapterQueued) return;
    _chapterQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chapterQueued = false;
      if (mounted && _scroll.hasClients) _readChapter();
    });
  }

  bool _chapterQueued = false;

  /// Which chapter the view is in, from the prompts the list has built. One
  /// built below the top means the one before it is the one being read, built
  /// or not; none built at all — a reply taller than the window — leaves the
  /// answer where it was.
  void _readChapter() {
    // At the end the last prompt can be too near the bottom ever to reach the
    // top, and it is the one being read.
    if (_chapters.isNotEmpty && _scroll.position.nearBottom(0)) {
      _chapter.value = _chapters.length - 1;
      return;
    }
    final top = _scroll.offset + 24;
    int? at;
    for (final (i, chapter) in _chapters.indexed) {
      final offset = _revealOffset(chapter.id);
      if (offset == null) continue;
      if (offset <= top) {
        at = i;
      } else {
        at ??= i == 0 ? 0 : i - 1;
        break;
      }
    }
    if (at != null) _chapter.value = at;
  }

  /// The scroll offset that puts [id]'s row at the top of the view, where the
  /// list has built it.
  double? _revealOffset(String id) {
    final box = _chapterKeys[id]?.currentContext?.findRenderObject();
    if (box == null || !box.attached) return null;
    return RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
  }

  /// Bring chapter [i] to the top.
  ///
  /// A scrub along the rail jumps rather than glides: it is one move of many,
  /// and a glide per tick would trail behind the pointer.
  void _goToChapter(int i, {bool scrubbing = false}) {
    if (!_scroll.hasClients || !_list.isAttached || i >= _chapters.length) {
      return;
    }
    final chapter = _chapters[i];
    final row = _outline.value.rows.indexOf(chapter.row);
    if (row < 0 || row >= _list.numberOfItems) return;
    _follow.detach();
    // A steer is inside its reply's row: the row gets it built, and then its
    // own bubble is where to stop.
    final steer = chapter.id != chapter.row;
    double? steerAt() => steer ? _revealOffset(chapter.id) : null;
    bool reveal(ScrollPosition position) {
      final offset = steerAt();
      if (offset == null) return false;
      position.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      return true;
    }

    void land(ScrollPosition position) {
      // A built steer, which a glide's arrival always has, is gone to
      // straight: by way of its row, the reply's top showed for a frame.
      if (reveal(position)) return;
      _list.jumpToItem(index: row, scrollController: _scroll, alignment: 0);
      if (steer) _afterLayout(reveal);
    }

    if (scrubbing) {
      _stopGlide();
      land(_scroll.position);
    } else {
      _glideTo(
        () => steerAt() ?? _offsetOf(row),
        landed: () => _afterLayout(land),
      );
    }
  }

  /// Where row [index] starts: the extents above it, measured or estimated.
  /// Read again on every tick of a glide, since the rows it passes are laid
  /// out on the way and the estimate gets better as it goes.
  double _offsetOf(int index) {
    var offset = MediaQuery.paddingOf(context).top;
    for (var i = 0; i < index; i++) {
      offset += _list.extentForIndex(i).$1;
    }
    return offset;
  }

  /// Glide from where the view is to [target]. Longer trips take a little
  /// longer, never past half a second; the direction is known from the start,
  /// so the view never runs the wrong way first.
  void _glideTo(double Function() target, {VoidCallback? landed}) {
    _glide.stop();
    final position = _scroll.position;
    _glideFrom = _glideAt = position.pixels;
    _glideTarget = target;
    _glideLanded = landed;
    final screens =
        (target() - _glideFrom).abs() / math.max(position.viewportDimension, 1);
    _glide.duration = Duration(
      milliseconds: (220 + 90 * math.min(screens, 3)).round(),
    );
    _glide.forward(from: 0);
  }

  void _glideTick() {
    final target = _glideTarget;
    if (target == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    // A row laid out at a height other than the one measured for it moves the
    // view by the difference; carried, or the next tick puts the view back.
    _glideFrom += position.pixels - _glideAt;
    final to = target().clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final t = Curves.easeInOutCubic.transform(_glide.value);
    _scroll.jumpTo(_glideFrom + (to - _glideFrom) * t);
    _glideAt = position.pixels;
  }

  void _glideStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final landed = _glideLanded;
    _stopGlide();
    landed?.call();
  }

  /// A hand on the list takes over from a glide in progress.
  void _stopGlide() {
    _glideTarget = null;
    _glideLanded = null;
    _glide.stop();
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

  /// Land at the end, and keep landing until the end stops moving. A builder
  /// lays out only what shows, and the rows it has not built are measured a
  /// frame's budget at a time after it, so the extent any one frame reports
  /// is an estimate. A hand on the list ends the settle.
  ///
  /// Both ways down want this. A chat opens at its latest message; Jump to
  /// latest glides for the travel and then finishes the trip here.
  void _settleAtBottom([int tries = 60, double? lastMax]) =>
      _afterLayout((position) {
        if (position.isScrollingNotifier.value) return;
        final max = position.maxScrollExtent;
        if (position.pixels < max) position.jumpTo(max);
        if (tries > 0 && max != lastMax) _settleAtBottom(tries - 1, max);
      });

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
    ref.listen(
      chatControllerProvider(widget.chatId),
      (_, _) => _follow.jumpIfFollowing(),
    );
    final chat = view.chat;
    // The frontend draws this chat itself, and asks about its expiry.
    if (_chrome.drawsOpenChat) return const SizedBox.expand();
    if (chat == null) return _waiting();
    _opening(chat);
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
      source: chatControllerProvider(widget.chatId),
      editing: notifier,
      details: const [],
      whenEmpty: _EmptyChat(
        project: chat.state.project,
        controller: _controller,
      ),
      bottom: ref.watch(setupCompleteProvider(chat.state.project))
          ? _turnBar(
              view: view,
              driver: notifier,
              project: chat.state.project,
              onVoice: () => openVoice(context, ref, widget.chatId),
              workspace: ref
                  .watch(appConfigProvider)
                  .workspaceDir(widget.chatId, project: chat.state.project),
              workspaceHome: ref
                  .watch(appConfigProvider)
                  .projectWorkspaceDir(project: chat.state.project),
            )
          : const NeedsSetupBar(),
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
    ref.listen(
      mirrorChatControllerProvider(widget.chatId),
      (_, _) => _follow.jumpIfFollowing(),
    );
    // One pass over the Remotes list for the two things drawn from it, so the
    // page rebuilds when they change rather than whenever anything does.
    final (:online, :deviceName, :deviceId) = ref.watch(
      remoteChatsProvider.select((chats) {
        for (final entry in chats) {
          if (entry.chatId == widget.chatId) {
            return (
              online: entry.online,
              deviceName: entry.deviceName,
              deviceId: entry.deviceId,
            );
          }
        }
        return (online: false, deviceName: "the home device", deviceId: null);
      }),
    );
    final chat = view.chat;
    if (_chrome.drawsOpenChat) return const SizedBox.expand();
    if (chat == null) return _waiting();
    _opening(chat);

    return _page(
      context,
      chat: chat,
      view: view,
      source: mirrorChatControllerProvider(widget.chatId),
      // The device is the strip's to say.
      details: const [],
      editing: online ? driver : null,
      whenEmpty: const Center(child: Text("No messages yet")),
      banner: online
          ? MirrorStrip.remote(deviceName: deviceName)
          : MirrorStrip.offline(deviceName: deviceName),
      bottom: online
          ? _turnBar(
              view: view,
              driver: driver,
              project: chat.state.project,
              device: deviceId,
              workspace: null,
            )
          : const ViewOnlyBar(),
    );
  }

  Widget _waiting() => const _Waiting();

  /// Land at the end of the conversation the first time this chat is drawn.
  void _opening(Chat chat) {
    if (_opened == widget.chatId) return;
    _opened = widget.chatId;
    _settleAtBottom();
  }

  /// The chat, however it is being read. [editing] is the controller the
  /// message row acts through, and null for a mirror this device does not
  /// hold.
  /// [banner] sits above the conversation, and [bottom] is whatever answers
  /// the turn — a composer, or a bar saying why there is none.
  Widget _page(
    BuildContext context, {
    required Chat chat,
    required ChatViewState view,
    required ProviderListenable<ChatViewState> source,
    required List<Widget> details,
    required Widget whenEmpty,
    required Widget bottom,
    TurnDriver? editing,
    Widget? banner,
  }) {
    final lines = [..._details(chat.state), ...details];
    final barHeight = _barHeight(context, lines.length);
    final transcript = Transcript.of(
      widget.chatId,
      chat,
      compactFailure: view.compactFailure,
    );
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
      appBar: _chrome.overPage
          ? null
          : AppBar(
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
      body: _ReadableColumn(
        bar: _chrome.chatBar(state: chat.state, view: view),
        banner: banner,
        bottom: bottom,
        side: ValueListenableBuilder<_Outline>(
          valueListenable: _outline,
          builder: (context, outline, _) => ChapterRail(
            chapters: outline.chapters,
            current: _chapter,
            onSelect: _goToChapter,
          ),
        ),
        sideWidth: ChapterRail.width,
        child: _conversation(
          chat,
          transcript,
          view,
          source,
          editing,
          whenEmpty,
        ),
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
    String? device,
    VoidCallback? onVoice,
    String? workspace,
    String? workspaceHome,
  }) {
    Future<void> send(
      String text,
      List<Attachment> attachments, {
      bool queue = false,
    }) {
      _follow.attach();
      return _session.send(driver, text, attachments, queue: queue);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chrome.turnSurface(
          view: view,
          driver: driver,
          onWithdrawn: (said) => _handle?.restore(said),
        ),
        switch (view.roomPhase) {
          RoomPhase.waitingOnYou => _chrome.questions(
            view: view,
            driver: driver,
          ),
          _ => _chrome.composer(
            key: _composer,
            controller: _controller,
            model: _model,
            binding: ComposerBinding(
              agentSpeaking: view.roomPhase == RoomPhase.agentSpeaking,
              onSend: send,
              onQueue: (text, attachments) =>
                  send(text, attachments, queue: true),
              steers: driver.steers,
              onAbort: driver.abort,
              project: project,
              device: device,
              onVoice: onVoice,
              workspace: workspace,
              workspaceHome: workspaceHome,
            ),
          ),
        },
      ],
    );
  }

  /// A passage being answered, into the composer — or, while a question
  /// stands in its place, into what the composer will hold when it is back.
  void _reply(ComposerEmbed quote) {
    final composer = _handle;
    composer == null ? _controller.append(quote) : composer.embed(quote);
  }

  /// The one link-opening rule, both renderers of model-written markdown — a
  /// reply and a compaction summary — share it.
  void _openLink(BuildContext context, String href) {
    final uri = Uri.tryParse(href);
    if (uri != null) ref.read(linkOpenerProvider).open(context, uri);
  }

  /// The face beside a reply's author: their photo or Bot Avatar. Null for
  /// the user's own message, which names no author.
  AgentFace? _avatarOf(Chat chat, Message message) {
    final member = nameOf(message.author);
    if (member == null) return null;
    return ref
        .watch(
          agentPictureProvider((project: chat.state.project, name: member)),
        )
        .value;
  }

  Widget _conversation(
    Chat chat,
    Transcript transcript,
    ChatViewState view,
    ProviderListenable<ChatViewState> source,
    TurnDriver? editing,
    Widget whenEmpty,
  ) {
    final speechReady = ref.watch(speechReadyProvider);
    final reading = ref.watch(readAloudProvider);
    if (chat.messages.isEmpty) return whenEmpty;
    return Stack(
      children: [
        Listener(
          onPointerDown: (_) => _stopGlide(),
          onPointerSignal: (_) => _stopGlide(),
          child: NotificationListener(
            onNotification: _follow.onNotification,
            child: KeyboardDismissOnScrollBack(
              child: SuperListView.builder(
                controller: _scroll,
                listController: _list,
                extentPrecalculationPolicy: _measureAll,
                itemCount: transcript.rows.length,
                itemBuilder: (context, i) => switch (transcript.rows[i]) {
                  final ModeRow row => ConversationSeparator(text: row.text),
                  final GoalRow row => GoalMarkRow(row: row),
                  CompactionRow(:final summary) => ConversationSeparator(
                    text: CompactionRow.text,
                    body: MessageText(
                      text: summary,
                      isError: false,
                      isWaiting: false,
                      caret: false,
                      onTapLink: (href) => _openLink(context, href),
                    ),
                  ),
                  CompactionFailedRow(:final reason) => ConversationSeparator(
                    text: CompactionFailedRow.text,
                    body: MessageText(
                      text: reason,
                      isError: true,
                      isWaiting: false,
                      caret: false,
                      onTapLink: (href) => _openLink(context, href),
                    ),
                  ),
                  MessageRow(:final message, :final last, :final reactions) =>
                    KeyedSubtree(
                      key: message.role == MessageRole.user
                          ? _chapterKeys.putIfAbsent(message.id, GlobalKey.new)
                          : null,
                      child: ActivitySource(
                        live: source.select(
                          (v) => liveMessageOf(v, message.id),
                        ),
                        child: MessageBubble(
                          chatId: widget.chatId,
                          message: message,
                          avatar: _avatarOf(chat, message),
                          isWaiting: view.isRunning && last,
                          latest: last,
                          waitingNotice: view.retry,
                          waitingStatus: view.status,
                          shellOutput: view.shellOutput[message.id],
                          onTapLink: (href) => _openLink(context, href),
                          onReply: (quote) => _reply(QuoteEmbed(quote)),
                          reactions: reactions,
                          actions: MessageActions(
                            message: message,
                            driver: editing,
                            running: view.isRunning,
                            last: last,
                            threads: editing == null
                                ? null
                                : chat.branches[message.id],
                          ),
                          onSpeak: speechReady && message.hasText
                              ? () => readAloud(
                                  context,
                                  ref,
                                  message.id,
                                  message.plainText,
                                )
                              : null,
                          isSpeaking: reading == message.id,
                          steerKey: (id) =>
                              _chapterKeys.putIfAbsent(id, GlobalKey.new),
                        ),
                      ),
                    ),
                },
              ),
            ),
          ),
        ),
        // Only once the reader has left the end: up there a turn no longer
        // follows itself, and this is the way back. Above the native shell's
        // composer, which the list runs under.
        Positioned(
          right: 16,
          bottom:
              12 +
              (_chrome.overPage ? MediaQuery.paddingOf(context).bottom : 0),
          child: ValueListenableBuilder<bool>(
            valueListenable: _atBottom,
            builder: (context, atBottom, child) =>
                atBottom ? const SizedBox.shrink() : child!,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: "Jump to latest",
              onPressed: () => _glideTo(
                () => _scroll.position.maxScrollExtent,
                landed: _settleAtBottom,
              ),
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
