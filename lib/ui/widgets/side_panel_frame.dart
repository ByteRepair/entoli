import "package:flutter/material.dart";

import "nav_drawer.dart";

/// Where a [SidePanelFrame]'s panel is.
enum SidePanelMode {
  /// Beside the content, the window being wide enough and the panel shown.
  docked,

  /// Off screen by choice, in a window wide enough to dock it.
  hidden,

  /// The content's drawer, in a window too narrow to dock it.
  drawer,
}

/// A navigation panel beside [child] where the window is at least
/// [breakpoint] wide and [shown] says so, and [child]'s drawer where it is
/// narrower. [child] is at the same place in the tree in every mode, so going
/// from one to another — a resize, a toggle — keeps whatever state it holds.
///
/// [shown] is the host's to keep and [onShownChanged] its way to be asked to
/// change it, the way a field's value is; the frame keeps only its drawer. What
/// is below it reads where the panel is with [SidePanelFrame.of], and offers a
/// way back to it with [SidePanelButton].
class SidePanelFrame extends StatefulWidget {
  const SidePanelFrame({
    super.key,
    required this.panel,
    required this.child,
    this.shown = true,
    this.onShownChanged,
    this.panelWidth = navPanelWidth,
    this.breakpoint = navBreakpoint,
    this.name = "sidebar",
  });

  final Widget panel;
  final Widget child;
  final bool shown;
  final ValueChanged<bool>? onShownChanged;
  final double panelWidth;
  final double breakpoint;

  /// What the panel is called where a tooltip names it.
  final String name;

  /// The frame [context] is below, or null where there is none — content
  /// drawn on its own, which then has no panel to reveal.
  static SidePanel? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidePanel>();

  @override
  State<SidePanelFrame> createState() => _SidePanelFrameState();
}

class _SidePanelFrameState extends State<SidePanelFrame> {
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mode = constraints.maxWidth < widget.breakpoint
          ? SidePanelMode.drawer
          : widget.shown
          ? SidePanelMode.docked
          : SidePanelMode.hidden;
      return SidePanel._(
        mode: mode,
        name: widget.name,
        reveal: () => switch (mode) {
          SidePanelMode.drawer => _scaffold.currentState?.openDrawer(),
          SidePanelMode.hidden => widget.onShownChanged?.call(true),
          SidePanelMode.docked => null,
        },
        child: Scaffold(
          key: _scaffold,
          drawer: mode == SidePanelMode.drawer
              ? NavDrawer(child: widget.panel)
              : null,
          body: Row(
            children: [
              // Not there at all as a drawer: a window crossing the
              // breakpoint is not the user asking to see it go.
              if (mode != SidePanelMode.drawer)
                _DockedPanel(
                  key: const ValueKey("panel"),
                  open: mode == SidePanelMode.docked,
                  width: widget.panelWidth,
                  child: widget.panel,
                ),
              // Keyed, so the panel coming and going before it does not
              // rebuild it from nothing.
              Expanded(key: const ValueKey("content"), child: widget.child),
            ],
          ),
        ),
      );
    },
  );
}

/// The docked panel, sliding in and out at the left edge with the content
/// beside it pushed over as it does — drawn at its own width throughout and
/// clipped, so the panel is never laid out squeezed. Gone from the tree once
/// it is shut, so nothing in it holds focus or answers a search.
class _DockedPanel extends StatelessWidget {
  const _DockedPanel({
    super.key,
    required this.open,
    required this.width,
    required this.child,
  });

  final bool open;
  final double width;
  final Widget child;

  static const _duration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    // The divider's pixel is the panel's own, so it goes with it.
    final full = width + 1;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open ? 1 : 0),
      duration: _duration,
      curve: Curves.easeInOut,
      child: Row(
        children: [
          SizedBox(width: width, child: child),
          const VerticalDivider(width: 1),
        ],
      ),
      builder: (context, shown, panel) => shown == 0
          ? const SizedBox.shrink()
          : ClipRect(
              child: SizedBox(
                width: full * shown,
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: full,
                  maxWidth: full,
                  child: panel,
                ),
              ),
            ),
    );
  }
}

/// Where a [SidePanelFrame]'s panel is, for what is drawn beside it.
class SidePanel extends InheritedWidget {
  const SidePanel._({
    required this.mode,
    required this.name,
    required this.reveal,
    required super.child,
  });

  final SidePanelMode mode;
  final String name;

  /// Bring the panel on screen: open the drawer, or dock it again. Nothing
  /// where it is already docked.
  final VoidCallback reveal;

  @override
  bool updateShouldNotify(SidePanel old) =>
      mode != old.mode || name != old.name;
}

/// The way back to a [SidePanelFrame]'s panel, for a page's bar: the menu
/// button, opening the drawer where the window is narrow and docking the panel
/// again where it is hidden, and nothing where it is docked. [leadingOf] is that as an
/// `AppBar.leading`, which wants null rather than an empty widget, since an
/// empty one still takes the leading slot's width.
class SidePanelButton extends StatelessWidget {
  const SidePanelButton._(this.panel);

  final SidePanel panel;

  static Widget? leadingOf(BuildContext context) {
    final panel = SidePanelFrame.of(context);
    if (panel == null || panel.mode == SidePanelMode.docked) return null;
    return SidePanelButton._(panel);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.menu),
    tooltip: panel.mode == SidePanelMode.drawer
        ? MaterialLocalizations.of(context).openAppDrawerTooltip
        : "Show ${panel.name}",
    onPressed: panel.reveal,
  );
}
