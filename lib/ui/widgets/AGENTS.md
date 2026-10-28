# Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` (one field
over every configured model, whose entry storing null means what [nullLabel]
says — None where nothing exists, Off where a feature is optional — and
sharing the loading and failure states every page would otherwise spell out),
the `Default`-plus-reset pairing,
`LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), the `promptForText` / `promptForPair` / `confirm` /
`pickProject` dialogs and `copyToClipboard` beside them, `showAnchoredMenu`,
`NavDrawer` and `navBreakpoint`, `ActionIcon`, `AttachmentChip` /
`AttachmentStrip`, `EmptyPane`, `Nothing`, `TempChatTtlField`, `TristateToggle`,
`CompletionField`,
`text_input.dart` — the sections below — and `catalog.dart`.

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

`CompletionField` is the field a prompt is written in: the menu of `/skills`
and `@agents` that matches what has been typed, the arrows and tab and return
that take one, and escape. It was the composer's, and it is here because the
trigger editor writes a prompt too — one that is dispatched through the same
library, so being offered them in a chat and not there was the tell. Where the
menu goes is the caller's, through `layout`: the composer's spans the whole
composer rather than the field, since the `+` and Send are either side of it,
and the trigger's prompt page puts it under a box that is the whole page.
`completionInsertItems` is the `+` button's two entries, for a menu that offers
other things too — the composer's also attaches files. What a caller must not
do is write its own trigger handling: `activeCompletionToken` has to keep
agreeing with `prompt_library.dart`, and one copy of it can.

`TempChatTtlField` is how long a chat lives, as the chat settings page asks it —
`Default` naming the project's or the app's answer, and the value written
straight onto `meta.json`. The trigger editor asks with the same field: the
new chat a trigger makes is a chat, and a bool could only ever have named one of
the five TTLs.

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

`EmptyPane` is the middle of a page with nothing on it. The workspace has two —
a folder with no files in it, and a file the viewer could not read — and a
placeholder differing between them by a few pixels of padding reads as a bug
rather than as two states.

`Nothing` is the one-line version of the same thing, for a strip of a page
rather than a page: a project with no chats in it, a search nothing answered,
a paired device's list with nothing picked out of it. It is here rather than in
the sidebar it started in because two of them are on screen at once — the
sidebar's list beside the chat pane — and they had already drifted a text style
apart.

`ActionIcon` is the small icon button, and it carries the height the actions
row keeps whether or not anything is in it — the row and the buttons in it have
to agree on that, and a code block's bar now uses the same button. Its null
`onPressed` is the dead form, which is a thread arrow at either end of the
list. `copyToClipboard` is the other half of the same pairing: copying looks
identical afterwards whatever did it, so what was taken is said in a snack bar
from one place rather than each caller's own.

`settings_card.dart` is the settings row that is a card: icon and title at the
top, the subtitle under, the right-angle arrow at the top right where a tap
does something. What the tap does stays the caller's — the `.copy` constructor
is the whole-card-is-the-button form (the copy icon rides in the arrow's slot
and the tap itself copies, through the same `copyToClipboard`), a navigation
card takes an `onTap` that pushes, and null `trailing`/`onTap` is a card that
only states a fact — the Chats card. `SettingsCardRow` is the Wrap that holds
a screen's worth of them at one fixed width — the only place a row card's
width is decided, every child boxed with it, so callers place children bare;
two per phone line and capped where the window is wide. A card placed alone
keeps its `ListTile` width by growing to its parent instead, which is what
`WorkspaceTile` does where the chat settings page uses it.

`floating_position.dart` and `chip_row.dart` are the empty-chat screen's two
animation mechanisms, and anything else that wants the same motion reaches for
them rather than re-deriving it. `FloatingPosition` is a child of a `Wrap`
whose painted position glides to wherever the wrap next puts it, because the
wrap moves children by rewriting `WrapParentData.offset` after `layout()` and
asks nothing of a child whose constraints did not change — so the render
object asks for its own paint on every layout, where the new slot is already
written, and paints at the offset it is catching up to. One fixed deadline per
run, each frame closing the same eased share of what remains: a target that
keeps moving (a neighbour's slot growing frame by frame) is chased smoothly
and landed on exactly, not crawled after, and one pushed onto the next line
travels there instead of teleporting. Hit-testing and paint transforms follow
the painted offset, so a tap lands where the chip is shown.

`ChipRow` is the row over it: a centred `Wrap` that animates a change of set
per entry rather than swapping the row whole. It diffs the desired entries
against what is on screen, holds a removed entry for the 180 ms its shrink
runs (by identity, so a key back mid-exit revives it in place rather than
being vanished by a removal scheduled for the instance it replaced), and
grows every kept or arriving entry's slot through `_EnterExit` — the slot's
width and the child's scale and opacity are the one tween, so painted size
always equals slot size and what appears from nothing is the chip itself.
A row is grown into on first build, not shown settled; the empty-state line
of the empty chat is an entry of it like any other. `settled` is the caller's
say-so otherwise: it is snapshot at the row's own first build, so the entries
the row is created with are shown at full size and everything arriving after
animates — how a screen the user arrives on opens without motion while every
change after it keeps the one rule. The row's own height is part of the same
motion: an `AnimatedSize` over the `Wrap` glides a change of line count — a
badge pushed onto a new line, or a line collapsing — where the column below
used to snap with it.

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

`lib/ui/chat/activity/` owns the activities above a reply and the drawer
behind them; the bubble walks the parts and asks `activityFor` which each one
is (see "Activities, on screen" in `lib/ui/chat/AGENTS.md`).

`Composer` opens a menu above the field when the caret sits in a `/` or `@`
token, over a library that is already loaded — so it takes no chat id, has no
loading state, and starts nothing. Enter, Tab and the arrows are bound only
while the menu has a match — the rest of the time they have to keep doing what
they do in a text box, which for Tab is `TabIndents`. The `+` button left of the
field is a second way in: for a command or an agent it types the trigger
character rather than opening its own list, so both routes share one code path;
for a file it opens the chooser.

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

## The model catalog

Every model picker is a field that opens `ModelCatalogPage`: a search over
every model the configured providers offer, with what each costs and can do,
under the entries that store less than a model — the null entry and each
provider's Default. What a picker is offered is its `ModelRole`'s: the chat
LLM only models that talk (text in, text out) and call tools, since the agent
works through tools; title, classifier and memory any model that talks, being
plain completions; the image model only models that make images; the transcription and speech
models only what models.dev says transcribes or speaks, beside the installed
on-device voice models under `localProviderId` — see "A provider's models" in
`lib/data/voice/AGENTS.md`. An endpoint's own listing is offered to the chat
roles alone, since nothing says one of its models is anything else.

`ModelInfo` holds only the models.dev fields something reads, and the cache and
the built-in snapshot are trimmed to those. Structured output went for that
reason: nothing sends a schema, the background roles parse their JSON from text.

The models come from `ModelCatalog` (`domain/model_registry.dart`), which is
models.dev's own shape: a provider
is matched to its models.dev entry by id, then by base URL, and the model by
its exact id inside it. `data/model_catalog.dart` loads it at startup — the
presets' default models built in (`lib/data/builtin_models.dart`, written by
`tool/gen_builtin_models.dart` and committed, since it fetches), then the
cached copy in `<dataDir>/models.json`, then a fetch when that is a day old,
or when the first provider is added. So with no network and no cache the
Defaults are still pickable. Run the generator when a preset's defaults change.

A model the catalog does not list is added on the "Add model" page, onto the
provider it is reached through (`LlmProviderConfig.customModels`, in the same
shape), where it comes before the catalog's own entry of the same id.

A provider's own list is asked only where the user names one: the dialog's
Models endpoint (`LlmProviderConfig.modelsEndpoint`), empty by default. The
hosted providers' `/models` add nothing to models.dev's entry — ids alone, plus
retired and non-chat ones — so an empty field means the catalog alone, and a
provider models.dev does not know offers nothing until one is named. Listing is
the provider's (`LlmProvider.listModels`), not the chat client's: a local
server asks its own `/models` unless another is named, and the on-device
providers list what is installed. What such a list has and the catalog does not know is
offered as a chat model with nothing known of it; one the catalog does know is
offered by what the catalog says.
