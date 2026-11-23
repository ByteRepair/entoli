# Shared UI

`packages/entoli_core/lib/view/widgets/` holds what more than one page needs
and the core draws too: the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs and `copyToClipboard` beside them, `notify` and `say`
(notices, below), `showAnchoredMenu` and `showMenuAt`, `ActionIcon`,
`AttachmentChip` / `AttachmentStrip`, `DiscardGuard`, `PageBar` and its
`PageAction`s — every pushed page's bar, said as data and drawn as an
`AppBar` — `scrolling.dart` and `text_input.dart` — the sections below. The
rest of the app's shared widgets are `lib/ui/widgets/` (see its `AGENTS.md`).

`DiscardGuard` is every editor page's way out: a pop with something to lose
asks, one with nothing leaves, and Save leaves by `Navigator.pop`, which the
guard does not stop. It asks for `edited` when the pop comes rather than at
build, since most of what a page edits sits in controllers that change with no
rebuild. Four pages had written it out, two the same way, one differently, and
two not at all — the trigger editor and the profile page, where back threw the
edits away. `DiscardButton` is the close in the bar of a page whose way out is
discarding.

`scrolling.dart` is the shared scroll rule, and it is two things. `nearBottom`
asks whether the view is close enough to the end to count as reading the
latest — the slack is the caller's, since a conversation and a five-line
transcript disagree about how close that is. `ScrollFollow` is whether a list
keeps itself at the end while new content lands on it, and the answer is the
user's, not the position's: a gesture toward the older messages detaches,
reaching the end again by any means attaches, and the caller's
`NotificationListener` is what tells it which happened. The chat page and the
voice transcript window both run one; the chat page's jump button and the
`_settleAtBottom` that lands a chat at its end are its callers' halves, not
parts of the class.

`text_input.dart` is the pair of things a field wants and Material does not
give it. `replaceIn` writes over a range and leaves the caret after it —
`CompletionField` types a completion with it and `TabIndents` an indent, and
they were the same four lines twice. `TabIndents` makes Tab type two spaces
rather than move the focus on, which every `CompletionField` of more than one
line has — the composer and a trigger's prompt — and so does any
`promptForText` of more than one line; the one-line fields are left alone,
since there Tab is how the caret reaches the buttons.

It wraps a field instead of being one, because `CompletionField`'s own
bindings are already on it: **the wrapper has to stay strictly outside them**.
Key events run from the focused node outwards, so the completion `Shortcuts`
sees Tab first and takes it while the menu has a match, and only what it
ignores reaches the indent. That is why `CompletionField` wraps the field it
has already built rather than anything nearer the `TextField`: moving the
wrapper inward kills tab-completion with nothing to say so, and a widget test
is what holds it. Merging the two into one shortcuts map is not the same thing
and does not work: `SingleActivator` has no `==`, so a second Tab entry does
not replace the first, it queues behind it. Shift+Tab is left unbound, so there
is always a key that leaves the field.

`ActionIcon` is the small icon button, and it carries the height the actions
row keeps whether or not anything is in it — the row and the buttons in it have
to agree on that, and a code block's bar now uses the same button. Its null
`onPressed` is the dead form, which is a thread arrow at either end of the
list. `copyToClipboard` is the other half of the same pairing: copying looks
identical afterwards whatever did it, so what was taken is said in a notice
from one place rather than each caller's own.

`showAnchoredMenu` is a menu under a button, as a **route**. A `MenuAnchor`
draws into an overlay instead, and an overlay is not popped by anything: the
back key passes through it to whatever is behind, which beside the chat is the
app leaving and inside the drawer is the whole sidebar closing. Neither is what
back means over a menu. `PopupMenuButton` gets this right by pushing a route,
and this is the same push without having to be the button — the project switcher
and the add-provider row keep the buttons they had. It takes the button's own
context, so both callers reach for a `Builder`: their build context is the whole
section, and a menu anchored to that hangs off the wrong edge. `showMenuAt` is
the same route at a point — where a right click or a held finger landed.

Streamed deltas are coalesced into one state update per frame: per-token updates
made the reply's text quadratic and rebuilt every visible bubble thousands of
times per turn. One buffer carries both kinds of delta, so switching between
thinking and reply flushes what it held — otherwise the two would fold into each
other's part.

`packages/entoli_core/lib/view/chat/activity/` owns the activities above a
reply and the drawer behind them; the bubble walks the parts and asks the
`ActivityCatalog` which each one is (see "Activities, on screen" in
`packages/entoli_core/lib/transcript/AGENTS.md`).

## Notices

`notify` and `say` show a notice, not a snack bar: a pill at the top of the
root overlay, under the status bar. A snack bar sits on the bottom edge, over
the composer, and swiping it away on a phone starts the system's home and
reach gestures. The notice hit-tests only itself, so the page under it stays
usable; it goes on a tap, an upward swipe or its timer, which a pointer over it
holds. One per overlay, the newest replacing the last rather than queueing
behind it. An error's waits longer and copies its text, which a snack bar did by
being selectable.
