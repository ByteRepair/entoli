import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Show [message] as a notice at the top of the screen, over whatever is
/// there. Not a snack bar: one sits on the bottom edge, where it covers the
/// composer and where swiping it away starts the system's home and reach
/// gestures. This one takes no taps but its own, goes on a tap or an upward
/// swipe, and stays while a pointer is over it. A newer notice replaces it.
///
/// An [error] is drawn in the error colours, waits longer, and carries a
/// copy button, the text being what goes into an issue.
void showNotice(BuildContext context, String message, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _shown[overlay]?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Notice(
      message: message,
      error: error,
      onGone: () {
        if (_shown[overlay] != entry) return;
        _shown[overlay] = null;
        entry.remove();
      },
    ),
  );
  _shown[overlay] = entry;
  overlay.insert(entry);
}

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
  // Cancelled in dispose, which a test's teardown reaches: a timer left
  // pending fails the test that showed the notice.
  Timer? _timer;
  bool _leaving = false;

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
    _leaving = true;
    _timer?.cancel();
    await _motion.reverse();
    if (mounted) widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fill, ink) = widget.error
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : (scheme.inverseSurface, scheme.onInverseSurface);
    final curve = CurvedAnimation(parent: _motion, curve: Curves.easeOutCubic);
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, -0.5),
                end: Offset.zero,
              ).animate(curve),
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
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _leave,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              10,
                              widget.error ? 4 : 16,
                              10,
                            ),
                            child: Row(
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
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: widget.message),
                                    ),
                                  ),
                              ],
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
      ),
    );
  }
}
