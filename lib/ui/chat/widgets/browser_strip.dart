import "dart:async";

import "package:flutter/foundation.dart" show defaultTargetPlatform, TargetPlatform;
import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/log.dart";
import "../../../domain/agent_browser.dart";
import "../../../providers.dart";
import "browser_input.dart";

/// The chat's browser tab, while one is open: a chip beside the running
/// sub-agents, and a live view of the page behind it. The view is the
/// browser's own screencast, so it shows the page when the browser runs
/// hidden too. Not on a mirrored chat, whose browser is the other device's.
class BrowserStrip extends ConsumerWidget {
  const BrowserStrip({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browser = ref.watch(agentBrowserProvider);
    if (!browser.available ||
        !browser.configured ||
        ref.watch(isMirroredChatProvider(chatId))) {
      return const SizedBox.shrink();
    }
    final tab = browser.tab(chatId);
    return ValueListenableBuilder<BrowserPage?>(
      valueListenable: tab.page,
      builder: (context, page, _) {
        if (page == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ActionChip(
            avatar: Icon(Icons.travel_explore,
                size: 16, color: theme.colorScheme.onPrimaryContainer),
            label: Text(
              "Browser · ${_where(page)}",
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
            backgroundColor: theme.colorScheme.primaryContainer,
            side: BorderSide.none,
            shape: const StadiumBorder(),
            visualDensity: VisualDensity.compact,
            tooltip: "Watch the agent's browser",
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => BrowserCard(tab: tab, onQuit: browser.close),
            ),
          ),
        );
      },
    );
  }
}

/// A page's host, or its title where it has none to show.
String _where(BrowserPage page) {
  final host = Uri.tryParse(page.url)?.host ?? "";
  if (host.isNotEmpty) return host;
  return page.title.isNotEmpty ? page.title : "blank page";
}

/// The live view: the page's title and address over its frames, for as long
/// as the card is open, with the browser's own back, forward and reload, and
/// the page itself under the user's mouse and keyboard. Listens again when the
/// tab is reopened under it.
class BrowserCard extends StatefulWidget {
  const BrowserCard({super.key, required this.tab, required this.onQuit});

  final BrowserTab tab;

  /// Quit the whole browser, every chat's tab with it.
  final Future<void> Function() onQuit;

  @override
  State<BrowserCard> createState() => _BrowserCardState();
}

class _BrowserCardState extends State<BrowserCard> {
  StreamSubscription<BrowserFrame>? _sub;
  BrowserFrame? _frame;
  bool _ended = false;
  int? _opened;
  final _focus = FocusNode(debugLabel: "browser viewport");

  /// The presses still held, by physical key, so a release names the key the
  /// press did: a key's character is not reported on its way up.
  final _held = <PhysicalKeyboardKey, BrowserKey>{};

  /// The button a press went down with, which the release reports though the
  /// event no longer holds it.
  String _pressed = "none";

  /// Clicks in a row, for a double click: the protocol counts them, not the
  /// page.
  var _clicks = 0;
  DateTime _lastDown = DateTime(0);
  Offset _lastAt = Offset.zero;

  /// One move in flight at a time; the newest waiting behind it replaces
  /// any older, so a fast mouse does not queue a trail of stale positions.
  bool _moving = false;
  BrowserPointer? _nextMove;

  @override
  void initState() {
    super.initState();
    widget.tab.page.addListener(_follow);
    _follow();
  }

  /// A new tab under the same chat is a new stream to listen to.
  void _follow() {
    final opened = widget.tab.page.value?.opened;
    if (opened == _opened && _sub != null) return;
    _opened = opened;
    unawaited(_sub?.cancel());
    _sub = null;
    if (opened == null) {
      if (mounted) setState(() => _ended = true);
      return;
    }
    _ended = false;
    _sub = widget.tab.frames().listen(
      (frame) => setState(() => _frame = frame),
      onDone: () {
        if (mounted) setState(() => _ended = true);
      },
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tab.page.removeListener(_follow);
    unawaited(_sub?.cancel());
    _focus.dispose();
    super.dispose();
  }

  /// Fire [send], saying in the log rather than on screen when it fails: the
  /// next frame shows whether it landed.
  void _send(Future<void> Function() send) {
    unawaited(send().catchError((Object e) {
      logFailure("browser", "input to the page failed", e);
    }));
  }

  int get _modifiers {
    final keys = HardwareKeyboard.instance;
    return browserModifiers(
      alt: keys.isAltPressed,
      control: keys.isControlPressed,
      meta: keys.isMetaPressed,
      shift: keys.isShiftPressed,
    );
  }

  bool get _shortcut {
    final keys = HardwareKeyboard.instance;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return mac ? keys.isMetaPressed : keys.isControlPressed;
  }

  /// A point on the drawn frame, in the page's CSS pixels.
  Offset _toPage(Offset local, Size drawn) {
    final frame = _frame;
    if (frame == null || drawn.width == 0 || drawn.height == 0) return local;
    return Offset(local.dx * frame.width / drawn.width,
        local.dy * frame.height / drawn.height);
  }

  void _move(BrowserPointer event) {
    if (_moving) {
      _nextMove = event;
      return;
    }
    _moving = true;
    unawaited(widget.tab.pointer(event).catchError((Object _) {}).whenComplete(() {
      _moving = false;
      final next = _nextMove;
      _nextMove = null;
      if (next != null) _move(next);
    }));
  }

  static String _buttonOf(int buttons) => buttons & kPrimaryMouseButton != 0
      ? "left"
      : buttons & kSecondaryMouseButton != 0
          ? "right"
          : buttons & kMiddleMouseButton != 0
              ? "middle"
              : "none";

  void _down(PointerDownEvent event, Size drawn) {
    _focus.requestFocus();
    final at = _toPage(event.localPosition, drawn);
    final now = DateTime.now();
    _clicks = now.difference(_lastDown) < const Duration(milliseconds: 500) &&
            (at - _lastAt).distance < 5
        ? _clicks + 1
        : 1;
    _lastDown = now;
    _lastAt = at;
    _pressed = _buttonOf(event.buttons);
    _send(() => widget.tab.pointer(BrowserPointer(
          BrowserPointerKind.down,
          x: at.dx,
          y: at.dy,
          button: _pressed,
          buttons: event.buttons,
          clickCount: _clicks,
          modifiers: _modifiers,
        )));
  }

  void _up(PointerUpEvent event, Size drawn) {
    final at = _toPage(event.localPosition, drawn);
    _send(() => widget.tab.pointer(BrowserPointer(
          BrowserPointerKind.up,
          x: at.dx,
          y: at.dy,
          button: _pressed,
          buttons: event.buttons,
          clickCount: _clicks,
          modifiers: _modifiers,
        )));
    _pressed = "none";
  }

  void _hover(PointerEvent event, Size drawn) {
    final at = _toPage(event.localPosition, drawn);
    _move(BrowserPointer(
      BrowserPointerKind.move,
      x: at.dx,
      y: at.dy,
      button: _buttonOf(event.buttons),
      buttons: event.buttons,
      modifiers: _modifiers,
    ));
  }

  void _scroll(PointerSignalEvent event, Size drawn) {
    if (event is! PointerScrollEvent) return;
    final at = _toPage(event.localPosition, drawn);
    _send(() => widget.tab.pointer(BrowserPointer(
          BrowserPointerKind.wheel,
          x: at.dx,
          y: at.dy,
          deltaX: event.scrollDelta.dx,
          deltaY: event.scrollDelta.dy,
          modifiers: _modifiers,
        )));
  }

  /// Every key goes to the page while the viewport has focus — Tab and Escape
  /// included, which would otherwise move focus or close the card.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      final down = _held.remove(event.physicalKey);
      if (down != null) {
        _send(() => widget.tab.key(browserKeyUp(down, modifiers: _modifiers)));
      }
      return KeyEventResult.handled;
    }
    final shortcut = _shortcut;
    // Paste is the user's clipboard, not the page's.
    if (shortcut && event.logicalKey == LogicalKeyboardKey.keyV) {
      if (event is KeyDownEvent) {
        _send(() async {
          final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
          if (text != null && text.isNotEmpty) await widget.tab.insertText(text);
        });
      }
      return KeyEventResult.handled;
    }
    final key = browserKeyDown(event, modifiers: _modifiers, shortcut: shortcut);
    if (key == null) return KeyEventResult.handled;
    _held[event.physicalKey] = key;
    _send(() => widget.tab.key(key));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _frame;
    final open = !_ended;
    final aspect = frame != null && frame.width > 0 && frame.height > 0
        ? frame.width / frame.height
        : 16 / 10;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: "Back",
                    icon: const Icon(Icons.arrow_back),
                    onPressed: open ? () => _send(widget.tab.back) : null,
                  ),
                  IconButton(
                    tooltip: "Forward",
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: open ? () => _send(widget.tab.forward) : null,
                  ),
                  IconButton(
                    tooltip: "Reload",
                    icon: const Icon(Icons.refresh),
                    onPressed: open ? () => _send(widget.tab.reload) : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ValueListenableBuilder<BrowserPage?>(
                      valueListenable: widget.tab.page,
                      builder: (context, page, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            page == null || page.title.isEmpty
                                ? "Browser"
                                : page.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            page?.url ?? "Closed",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: "Quit the browser",
                    icon: const Icon(Icons.power_settings_new),
                    color: theme.colorScheme.error,
                    onPressed: open ? () => unawaited(widget.onQuit()) : null,
                  ),
                  IconButton(
                    tooltip: "Close",
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: AspectRatio(
                aspectRatio: aspect,
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: frame == null
                      ? Center(
                          child: _ended
                              ? Text("The browser has closed.",
                                  style: theme.textTheme.bodyMedium)
                              : const CircularProgressIndicator(),
                        )
                      : LayoutBuilder(
                          builder: (context, box) {
                            final drawn = box.biggest;
                            return Focus(
                              focusNode: _focus,
                              onKeyEvent: _key,
                              child: MouseRegion(
                                cursor: open
                                    ? SystemMouseCursors.basic
                                    : MouseCursor.defer,
                                child: Listener(
                                  onPointerDown:
                                      open ? (e) => _down(e, drawn) : null,
                                  onPointerUp: open ? (e) => _up(e, drawn) : null,
                                  onPointerMove:
                                      open ? (e) => _hover(e, drawn) : null,
                                  onPointerHover:
                                      open ? (e) => _hover(e, drawn) : null,
                                  onPointerSignal:
                                      open ? (e) => _scroll(e, drawn) : null,
                                  child: Image.memory(
                                    frame.jpeg,
                                    gaplessPlayback: true,
                                    fit: BoxFit.fill,
                                    width: drawn.width,
                                    height: drawn.height,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
