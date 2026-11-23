import "dart:async";

import "package:flutter/material.dart";

import "../../core/platform/rich_clipboard.dart";

// Why a notice rather than a snack bar, and how it behaves, is "Notices" in
// this directory's AGENTS.md.

/// Says [message] in passing, in a notice.
void notify(BuildContext context, String message) => _show(context, message);

/// Report [error] in a notice. The one-line form several pages spell out
/// for a caught failure, hoisted so they stop duplicating it. The notice
/// can copy it, for an issue.
void say(BuildContext context, Object error) =>
    _show(context, "$error", error: true);

/// A [say] that still lands once [context] is gone, through the root overlay
/// it is under now: for a failure that can arrive after its page has closed,
/// like a mirror refusing a message.
void Function(Object error) sayLater(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  return (error) {
    if (overlay != null && overlay.mounted) {
      _showIn(overlay, "$error", error: true);
    }
  };
}

void _show(BuildContext context, String message, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay != null) _showIn(overlay, message, error: error);
}

void _showIn(OverlayState overlay, String message, {required bool error}) {
  _shown[overlay]?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Notice(
      message: message,
      error: error,
      onGone: () {
        _shown[overlay] = null;
        entry.remove();
      },
    ),
  );
  _shown[overlay] = entry;
  overlay.insert(entry);
}

// Per overlay rather than one global: each `MaterialApp` the app builds has
// its own, and removing an entry from a disposed one asserts.
final _shown = Expando<OverlayEntry>("notice");

class _Notice extends StatefulWidget {
  const _Notice({
    required this.message,
    required this.error,
    required this.onGone,
  });

  final String message;
  final bool error;
  final VoidCallback onGone;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();
  late final _curve = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeOutCubic,
  );
  late final _slide = Tween(
    begin: const Offset(0, -0.5),
    end: Offset.zero,
  ).animate(_curve);
  // Cancelled in dispose, which a test's teardown reaches: a timer left
  // pending fails the test that showed the notice.
  Timer? _timer;

  bool get _leaving => !_motion.isForwardOrCompleted;

  Duration get _stay => widget.error
      ? const Duration(seconds: 8)
      : const Duration(milliseconds: 3500);

  @override
  void initState() {
    super.initState();
    _wait();
  }

  void _wait() {
    if (_leaving) return;
    _timer?.cancel();
    _timer = Timer(_stay, _leave);
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _timer?.cancel();
    await _motion.reverse();
    if (mounted) widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fill, ink) = widget.error
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : (scheme.inverseSurface, scheme.onInverseSurface);
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: _slide,
              child: Dismissible(
                key: const ValueKey("notice"),
                direction: DismissDirection.up,
                onDismissed: (_) => widget.onGone(),
                child: MouseRegion(
                  onEnter: (_) => _timer?.cancel(),
                  onExit: (_) => _wait(),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Semantics(
                      liveRegion: true,
                      child: Material(
                        color: fill,
                        elevation: 6,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(16),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _leave,
                          child: Padding(
                            padding: widget.error
                                ? const EdgeInsets.fromLTRB(16, 10, 4, 10)
                                : const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                            child: _body(ink),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(Color ink) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(
          widget.message,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: ink),
        ),
      ),
      if (widget.error)
        IconButton(
          tooltip: "Copy",
          color: ink,
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () =>
              writeClipboard(ClipboardContent(plain: widget.message)),
        ),
    ],
  );
}
