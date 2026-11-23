import "dart:math" as math;

import "package:flutter/foundation.dart" show listEquals;
import "package:flutter/material.dart";
import "package:flutter/rendering.dart" show RenderAbstractViewport;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:super_sliver_list/super_sliver_list.dart";

import "../../../transcript/host.dart";
import "../../../transcript/transcript.dart";
import "../../../model/models.dart";
import "../../../model/room/room_state.dart";
import "../../widgets/scrolling.dart";
import "../activity/card.dart" show ActivitySource, liveMessageOf;
import "chapter_rail.dart";
import "transcript_row.dart";

/// The conversation and whatever answers it, centred and held to
/// [readableWidth] — a phone gets the whole screen, a monitor gets a line it
/// can read back to the start of. The composer goes inside that width rather
/// than under it, or the conversation sits over a field twice its own width.
/// Both pages with something to type in are this. [banner] is a full-width row
/// above it, under the title bar, and stays while the conversation scrolls.
///
/// [side] goes in the margin to the right of the column, [sideWidth] wide, and
/// only where the margin has that much room: it is laid over the margin rather
/// than beside the column, so the column stays centred whether it is there or
/// not.
class ReadableColumn extends StatelessWidget {
  const ReadableColumn({
    super.key,
    required this.child,
    required this.bottom,
    this.banner,
    this.side,
    this.sideWidth = 0,
  });

  final Widget child;
  final Widget bottom;
  final Widget? banner;
  final Widget? side;
  final double sideWidth;

  /// Between the column's edge and [side].
  static const _sideGap = 16.0;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ?banner,
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final column = Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: readableWidth),
                child: Column(
                  children: [
                    Expanded(child: child),
                    bottom,
                  ],
                ),
              ),
            );
            final margin = (constraints.maxWidth - readableWidth) / 2;
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

/// A conversation as it is read: its rows in a list that opens at the latest
/// and follows a turn while the reader is there, the chapter rail beside it,
/// and the way back to the end once the reader has left it. Fed by the
/// host's view of the chat (`TranscriptHost.view`) — the app's controller or
/// mirror, the share viewer's unpacked chat.
///
/// A message's row is the host's to draw ([message]), given the key for a
/// steer read into it ([steerKey]) which the rail finds it by; the rest is
/// the same wherever the conversation is shown.
class ConversationView extends ConsumerStatefulWidget {
  const ConversationView({
    super.key,
    required this.chatId,
    required this.message,
    required this.bottom,
    this.whenEmpty = const SizedBox.shrink(),
    this.banner,
  });

  final String chatId;
  final Widget Function(MessageRow row, GlobalKey Function(String id) steerKey)
  message;

  /// Under the conversation: whatever answers the turn.
  final Widget bottom;

  /// In place of the list while the chat has nothing said in it.
  final Widget whenEmpty;

  /// Above the conversation, full width; see [ReadableColumn.banner].
  final Widget? banner;

  @override
  ConsumerState<ConversationView> createState() => ConversationViewState();
}

class ConversationViewState extends ConsumerState<ConversationView>
    with SingleTickerProviderStateMixin {
  /// How far off the end still counts as reading the latest: inside it a turn
  /// keeps the view pinned, outside it the jump button appears.
  static const _slack = 200.0;

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

  /// Keep to the end from here, as a message just sent wants to.
  void follow() => _follow.attach();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_readPosition);
    _feedOutline();
  }

  @override
  void didUpdateWidget(ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) {
      _chapterKeys.clear();
      _chapter.value = null;
    }
    if (oldWidget.chatId != widget.chatId) _feedOutline();
  }

  ProviderListenable<ChatViewState> get _source =>
      ref.read(transcriptHostProvider).view(widget.chatId);

  /// Feed [_outline] from the chat's view, keep to the end of a turn
  /// being followed, and land at the end the first time the chat is there.
  void _feedOutline() {
    _outlineFeed?.close();
    _outline.value = _Outline.empty;
    _outlineFeed = ref.listenManual(_source, (_, view) {
      final chat = view.chat;
      if (chat == null) return;
      _follow.jumpIfFollowing();
      if (_opened != widget.chatId) {
        _opened = widget.chatId;
        _settleAtBottom();
      }
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
    _outlineFeed?.close();
    _outline.dispose();
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

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(_source);
    final chat = view.chat;
    return ReadableColumn(
      banner: widget.banner,
      bottom: widget.bottom,
      side: ValueListenableBuilder<_Outline>(
        valueListenable: _outline,
        builder: (context, outline, _) => ChapterRail(
          chapters: outline.chapters,
          current: _chapter,
          onSelect: _goToChapter,
        ),
      ),
      sideWidth: ChapterRail.width,
      child: chat == null || chat.messages.isEmpty
          ? widget.whenEmpty
          : _conversation(
              Transcript.of(
                widget.chatId,
                chat,
                compactFailure: view.compactFailure,
              ),
            ),
    );
  }

  GlobalKey _keyOf(String id) => _chapterKeys.putIfAbsent(id, GlobalKey.new);

  Widget _conversation(Transcript transcript) => Stack(
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
              itemBuilder: (context, i) => TranscriptRowView(
                transcript.rows[i],
                message: (row) {
                  final message = row.message;
                  return KeyedSubtree(
                    key: message.role == MessageRole.user
                        ? _keyOf(message.id)
                        : null,
                    child: ActivitySource(
                      live: _source.select((v) => liveMessageOf(v, message.id)),
                      child: widget.message(row, _keyOf),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
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
