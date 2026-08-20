# Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (each a field over the model list, sharing the loading and
failure states every page would otherwise spell out) over
`ProviderModelSelector` (which owns every rule about the pair), the
`Default`-plus-reset pairing, `LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs and `copyToClipboard` beside them, `showAnchoredMenu`,
`NavDrawer` and `navBreakpoint`, `ActionIcon`, and `AttachmentChip` /
`AttachmentStrip`.

`ActionIcon` is the small icon button, and it carries the height the actions
row keeps whether or not anything is in it — the row and the buttons in it have
to agree on that, and a code block's bar now uses the same button. Its null
`onPressed` is the dead form, which is a thread arrow at either end of the
list. `copyToClipboard` is the other half of the same pairing: copying looks
identical afterwards whatever did it, so what was taken is said in a snack bar
from one place rather than each caller's own.

`showAnchoredMenu` is a menu under a button, as a **route**. A `MenuAnchor`
draws into an overlay instead, and an overlay is not popped by anything: the
back key passes through it to whatever is behind, which beside the chat is the
app leaving and inside the drawer is the whole sidebar closing. Neither is what
back means over a menu. `PopupMenuButton` gets this right by pushing a route, and
this is the same push without having to be the button — the project switcher and
the add-provider row keep the buttons they had. It takes the button's own
context, so both callers reach for a `Builder`: their build context is the whole
section, and a menu anchored to that hangs off the wrong edge.

Streamed deltas are coalesced into one state update per frame: per-token updates
made the reply's text quadratic and rebuilt every visible bubble thousands of
times per turn. One buffer carries both kinds of delta, so switching between
thinking and reply flushes what it held — otherwise the two would fold into each
other's part.

`activity_label.dart` owns the labels and the drawer behind them; the bubble
walks the parts and decides which of the two each one is.

`Composer` opens a menu above the field when the caret sits in a `/` or `@`
token, over a library that is already loaded — so it takes no chat id, has no
loading state, and starts nothing. Enter, Tab and the arrows are bound only
while the menu has a match — the rest of the time they have to keep doing what
they do in a text box. The `+` button left of the field is a second way in: for
a command or an agent it types the trigger character rather than opening its own
list, so both routes share one code path; for a file it opens the chooser.

Send is dead while there is nothing to send, which `_worthSending` decides —
whitespace is nothing, a file on its own is something. `_submit` asks it again
rather than trusting the button, because Ctrl/Cmd+Enter reaches `_submit`
without passing the button at all.

Which way the button is driven is worth the two lines it takes to say. A
`setState` would rebuild the composer, and the composer's build resolves the
completion menu and its matches — no business re-running because a letter was
typed. Watching the `TextEditingController` directly fixes that but fires on
every `TextEditingValue`, so a bare caret move rebuilt the button and the
thirty-odd widgets Material puts under it for an answer that cannot have
changed. So it is a `ValueNotifier<bool>`, set from the listener the field
already has for the completion token, and the button redraws when the answer
flips rather than when the field is touched.

It never asks for the field's focus, and that is the whole rule. On Android focus
is the keyboard, so a composer that reaches for it is a keyboard rising over a
conversation nobody was typing in — which is what attaching a file did, and what
the `+` menu's own entries did. Neither has anything to type at: the file is
already on the strip, and the menu the trigger character opens is tapped. The
field has no `FocusNode` of its own any more, since nothing was left to point one
at.

Giving focus away is the composer's rule; taking it back when the keyboard goes
is the app's, and is the next section.

The sidebar's new-chat button is a `FloatingActionButton` over the profile and
settings tiles, which is the one part of the sidebar that is not a list of
chats and has room to its right. Not `Scaffold.floatingActionButton`: the
sidebar is deliberately a `Material`, since an inner `Scaffold` would shadow
the one holding the drawer.
