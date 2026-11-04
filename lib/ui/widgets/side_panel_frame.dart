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

  /// The whole window, in a window too narrow to dock it, with the content
  /// behind it until something in the panel opens it.
  panelPage,

  /// The content as the whole window, in front of the panel, which it is
  /// left for by the back key or [SidePanelFrame.onHideContent].
  contentPage,
}

/// What a [SidePanelFrame]'s panel becomes in a window too narrow to dock it.
enum SidePanelNarrow {
  /// A drawer over the content, which is what is on screen: the chat's
  /// sidebar, over the conversation the user came for.
  drawer,

  /// A page of its own, with the content pushed over it and back returning
  /// to it: settings' categories, which are the structure of the page and
  /// should not sit behind a menu button.
  page,
}

/// A navigation panel beside [child] where the window is at least
/// [breakpoint] wide and [shown] says so, and, where it is narrower, what
/// [narrow] says: [child]'s drawer, or a page of its own that [child] is
/// opened over while [contentShown]. [child] is at the same place in the tree
/// in every mode, so going from one to another — a resize, a toggle — keeps
/// whatever state it holds.
///
/// [shown] is the host's to keep, and [onShow] the way the frame's own button
/// asks it to dock the panel again; the frame keeps only its drawer. What is
/// below it reads where the panel is with [SidePanelFrame.of], and offers a way
/// back to it with [SidePanelButton].
class SidePanelFrame extends StatefulWidget {
  const SidePanelFrame({
    super.key,
    required this.panel,
    required this.child,
    this.shown = true,
    this.onShow,
    this.panelWidth = navPanelWidth,
    this.breakpoint = navBreakpoint,
    this.narrow = SidePanelNarrow.drawer,
    this.contentShown = false,
    this.onHideContent,
    this.bar,
  });

  final Widget panel;
  final Widget child;
  final bool shown;
  final VoidCallback? onShow;
  final double panelWidth;
  final double breakpoint;
  final SidePanelNarrow narrow;

  /// With [SidePanelNarrow.page], whether [child] is in front of the panel
  /// in a narrow window. Like [shown], the host's to keep; it means nothing
  /// where the panel is docked.
  final bool contentShown;

  /// What the back key runs while [child] is in front of the panel — the
  /// host putting [contentShown] back to false.
  final VoidCallback? onHideContent;

  /// The frame's own bar, over the panel and [child] alike, built for the
  /// mode the frame is in: a page whose title says what is in front.
  final PreferredSizeWidget Function(SidePanelMode mode)? bar;

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
      final wide = constraints.maxWidth >= widget.breakpoint;
      final mode = wide
          ? (widget.shown ? SidePanelMode.docked : SidePanelMode.hidden)
          : switch (widget.narrow) {
              SidePanelNarrow.drawer => SidePanelMode.drawer,
              SidePanelNarrow.page when widget.contentShown =>
                SidePanelMode.contentPage,
              SidePanelNarrow.page => SidePanelMode.panelPage,
            };
      final panelPage = mode == SidePanelMode.panelPage;
      return SidePanel._(
        mode: mode,
        reveal: () => switch (mode) {
          SidePanelMode.drawer => _scaffold.currentState?.openDrawer(),
          SidePanelMode.hidden => widget.onShow?.call(),
          SidePanelMode.contentPage => widget.onHideContent?.call(),
          SidePanelMode.docked || SidePanelMode.panelPage => null,
        },
        child: Scaffold(
          key: _scaffold,
          appBar: widget.bar?.call(mode),
          drawer: mode == SidePanelMode.drawer
              ? NavDrawer(child: widget.panel)
              : null,
          body: Row(
            children: [
              // Not there at all narrow: a window crossing the breakpoint is
              // not the user asking to see it go.
              if (wide)
                _DockedPanel(
                  open: mode == SidePanelMode.docked,
                  width: widget.panelWidth,
                  child: widget.panel,
                ),
              // Keyed, so the panel coming and going before it does not
              // rebuild it from nothing. The content stays under the panel
              // as a page, offstage, for the same reason.
              Expanded(
                key: const ValueKey("content"),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage: panelPage,
                      child: TickerMode(
                        enabled: !panelPage,
                        // Back from the content is to the panel rather than
                        // out of the route.
                        child: PopScope(
                          canPop: mode != SidePanelMode.contentPage,
                          onPopInvokedWithResult: (didPop, _) {
                            if (!didPop) widget.onHideContent?.call();
                          },
                          child: widget.child,
                        ),
                      ),
                    ),
                    if (panelPage) widget.panel,
                  ],
                ),
              ),
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
    required this.open,
    required this.width,
    required this.child,
  });

  final bool open;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The divider's pixel is the panel's own, so it goes with it.
    final full = width + 1;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open ? 1 : 0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      // Its own layer: only the clip moves while it slides, so the panel is
      // not repainted every frame.
      child: RepaintBoundary(
        child: Row(
          children: [
            SizedBox(width: width, child: child),
            const VerticalDivider(width: 1),
          ],
        ),
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
    required this.reveal,
    required super.child,
  });

  final SidePanelMode mode;

  /// Bring the panel on screen: open the drawer, dock it again, or put the
  /// content back behind it. Nothing where it is already on screen.
  final VoidCallback reveal;

  @override
  bool updateShouldNotify(SidePanel old) => mode != old.mode;
}

/// The way back to a [SidePanelFrame]'s panel, for a page's bar: the menu
/// button, opening the drawer where the window is narrow and docking the panel
/// again where it is hidden, and nothing where it is docked. [leadingOf] is
/// that as an `AppBar.leading`, which wants null rather than an empty widget,
/// since an empty one still takes the leading slot's width.
class SidePanelButton extends StatelessWidget {
  const SidePanelButton._(this.panel);

  final SidePanel panel;

  static Widget? leadingOf(BuildContext context) {
    final panel = SidePanelFrame.of(context);
    // A page's way back is the bar's back button, which the host draws.
    if (panel == null ||
        !(panel.mode == SidePanelMode.drawer ||
            panel.mode == SidePanelMode.hidden)) {
      return null;
    }
    return SidePanelButton._(panel);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.menu),
    tooltip: panel.mode == SidePanelMode.drawer
        ? MaterialLocalizations.of(context).openAppDrawerTooltip
        : "Show sidebar",
    onPressed: panel.reveal,
  );
}
