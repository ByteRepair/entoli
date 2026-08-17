import "package:flutter/material.dart";

/// Where a panel beside the content stops fitting and becomes a drawer. The
/// chat's sidebar and the settings page's categories both turn here.
const double navBreakpoint = 900.0;

/// A docked panel's width, the same for both of them.
const double navPanelWidth = 280.0;

/// Material's compact breakpoint — a phone, either way up.
const double _compact = 600.0;

/// Picking something in a nav panel should reveal it, and as a drawer the panel
/// is sitting over the thing it is revealing. Takes the tapped tile's own
/// context, which is the one below the Scaffold; docked, and with nothing open,
/// `closeDrawer` is already a no-op.
void closeNavDrawer(BuildContext context) => Scaffold.maybeOf(context)?.closeDrawer();

/// A navigation panel as a page's drawer, taking the whole screen where a panel
/// of the usual width would leave a sliver of the page behind, and closed by
/// the back key rather than leaving the app.
class NavDrawer extends StatelessWidget {
  const NavDrawer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Drawer(
      width: width < _compact ? width : null,
      // Claims the back key from Android, which the drawer's own
      // `LocalHistoryEntry` does not — see CLAUDE.md. Deleting this as dead
      // code is how it shipped broken once.
      child: PopScope(
        canPop: false,
        // True when the route popped anyway, and then there is nothing to close.
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Scaffold.of(context).closeDrawer();
        },
        child: child,
      ),
    );
  }
}
