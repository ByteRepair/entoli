# Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` and
`OptionalModelPicker` (one field over every configured model, differing only in
what the entry storing null means, and sharing the loading and failure states
every page would otherwise spell out), the `Default`-plus-reset pairing,
`LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs and `copyToClipboard` beside them, `showAnchoredMenu`,
`NavDrawer` and `navBreakpoint`, `ActionIcon`, `AttachmentChip` /
`AttachmentStrip`, `EmptyPane`, `TempChatTtlField`, `CompletionField` — the
section below — and `catalog.dart`.

`CompletionField` is the field a prompt is written in: the menu of `/commands`
and `@agents` that matches what has been typed, the arrows and tab and return
that take one, and escape. It was the composer's, and it is here because the
reminder editor writes a prompt too — one that is dispatched through the same
library, so being offered them in a chat and not there was the tell. Where the
menu goes is the caller's, through `layout`: the composer's spans the whole
composer rather than the field, since the `+` and Send are either side of it,
and the reminder's prompt page puts it under a box that is the whole page.
`completionInsertItems` is the `+` button's two entries, for a menu that offers
other things too — the composer's also attaches files. What a caller must not
do is write its own trigger handling: `activeCompletionToken` has to keep
agreeing with `prompt_library.dart`, and one copy of it can.

`TempChatTtlField` is how long a chat lives, as the chat settings page asks it —
`Default` naming the project's or the app's answer, and the value written
straight onto `meta.json`. The reminder editor asks with the same field: a
reminder's chat is a chat, and a bool there could only ever have named one of
the five TTLs.

`EmptyPane` is the middle of a page with nothing on it. The workspace has two —
a folder with no files in it, and a file the viewer could not read — and a
placeholder differing between them by a few pixels of padding reads as a bug
rather than as two states.

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

## A catalog of things to download

There are two of them: the voice models, and the Linux the agent runs commands
in. They are different enough to be two catalogs — one is picked in two halves
and has system sentinels in it, the other is per-architecture and decides where
a command runs — and identical in everything about *downloading*. So that half
is one implementation, at both ends: `DownloadRun` fetches and `Downloads<T>`
reports, and what differs between them is hooks.

`Downloads<T>` in `ui/settings/downloads.dart` is the notifier both catalogs
are: the running subscriptions, the bar's state, the Cancel in the
notification, the release on dispose, and the order a delete happens in. A
catalog answers six things — its ids, how to `begin` a download, what one and
several are called, how to look again, what to unpick, and how to erase. Held
above the settings page rather than in it, because a download outlives the page
and, on Android, outlives the app being on screen.

**Unpick, erase, then look again — in that order, and in the base class.** Both
catalogs resolve a pick against the catalog rather than the disk, so a setting
left naming something deleted fails later and somewhere else: at the microphone
for a voice model, and in the middle of a turn for a rootfs. It was written
twice, and the second copy is the one that would have drifted.

`begin` returning null is the other rule worth naming: a distribution with no
image for this device has nothing to fetch, so the press does nothing rather
than starting a download that fails. The button that raised it is already dead,
which makes this the belt to that pair of braces.

**The bar is redrawn on every event and the notification is not.** Progress
arrives once a megabyte, and telling Android each time is a channel call, a map
encoded and a notification rebuilt through five binder calls — some fourteen
hundred of them for a rootfs, to move a bar a hundred pixels wide. So the
platform is told when what it would *say* changes: a different set of downloads,
or another whole percent. `state` still moves on every event, because that is
what the row is drawn from.

`DownloadRun` in `data/download.dart` is the other half, and the half that was
harder to have two of: the HTTP client, the throttle on how often a fetch
reports, and — the part that matters — what a **cancelled** download does. A
listener that goes away has to take the half-written directory with it, and
there is nobody left to tell about it. Each store keeps only what is its own:
the voice one loops over a model's files and puts a `.tar.bz2` through an
isolate, the rootfs one hashes the tarball on the way past and hands it to
`tar`. The hash rides on `fetch`'s `watch` sink so that checking a download
costs no second read of the file.

`CatalogTile`, `CatalogAction` and `InstalledPicker` in `ui/widgets/catalog.dart`
are the same again for what is drawn: a row with its optional note, failure and
bar; the one button that is download *or* cancel *or* delete and never two; and
the field over what is installed. `CatalogAction` owns the confirmation as well
as the button: *that* deleting asks is the same for both, while what is being
agreed to is not, so each catalog passes the two strings and nothing else.
`InstalledPicker` is deliberately **not**
`InheritableDropdown`, which looks identical and means something else — there
null is "inherit what the level above says" and comes with a reset button, here
it is either an answer of its own (Android) or nothing picked yet. It also owns
the one trap both pickers had spelled out separately: a value no item carries is
what `DropdownButton` asserts on, so a setting naming something since deleted
has to fall back to null.

`DownloadProgress` in `domain/download.dart` is what a store reports, and it is
one type because it was the same three fields twice — a bar reading one of them
cannot tell which store filled it in.
