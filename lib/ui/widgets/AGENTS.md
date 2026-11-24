# Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` (one field
over every configured model, whose entry storing null means what [nullLabel]
says — None where nothing exists, Off where a feature is optional — and
sharing the loading and failure states every page would otherwise spell out),
the `Default`-plus-reset pairing,
`LabelledField` (a field under its caption) and
`InheritableDropdown` over both (whose first entry stores null and names what
null resolves to), `Choice` (a swatch, corner or icon to pick, with the one
selected ring), `NavDrawer` and `navBreakpoint`, `SidePanelFrame` (below),
`Nothing`, `CompletionField`, `PromptField` (below), `SearchField`,
`ListHeading` and `catalog.dart`. What the conversation draws with as well is
the core's, in `packages/entoli_core/lib/view/widgets/` (see its `AGENTS.md`).

`PromptField` is prose the model reads — a trigger's prompt, an agent's system
prompt, the profile's and a project's instructions — shown as markdown the way
the chat sets it, over an Edit button that opens `PromptPage`: a box that is
the whole page, Save and Discard, discarding asking first. It is one widget
because the three pages had grown three answers to one question — a field a
few lines tall that scrolled, for text that is written once, read many times,
and often long. The page is `CompletionField` where `/skills` and `@agents`
mean something (a prompt, which is dispatched through the library) and a plain
field where they do not (instructions, where `@` pulls in a file). A message
edited in the chat opens the same page, its Save called Send.

`SearchField` is the rounded search box over a list — the sidebar's, the
marketplace's and the project palette's — and `ListHeading` the caption a list's
groups sit under. Two were copies of the sidebar's, one had drifted.

`LogPanel` is a task's output folded under a Log row, hidden while empty: Byte
Repair's setup and delete, and Data's export. The task writes to the
`LiveLog` (`lib/app/live_log.dart`, a `StringSink`) its notifier owns, so the
log outlives the page and a writer needs no widget to write.

`SidePanelFrame` is a navigation panel beside a page where the window is wide
enough and the panel shown, and, where it is narrow, what its `narrow` says:
the page's drawer (`SidePanelNarrow.drawer`, the shell's sidebar) or a page of
its own with the content opened in front of it while the host's
`contentShown` says so (`SidePanelNarrow.page`, settings' categories), back
returning to it through `onHideContent`. A `bar` builder gives the frame's
Scaffold a bar for the mode it is in, which is how settings titles a category
in front of the list. The page is at the same place in the tree in every
mode, so a toggle or a resize keeps whatever it holds; that is the frame's
whole reason over a `Row` here and a drawer there, which rebuilt the page
each time the window crossed the breakpoint. Whether the panel is shown is
the host's to keep — `shown`, and `onShow` for the frame's own button — so a
menu command and the button drive the same state. A page below reads where
the panel is with `SidePanelFrame.of` and puts `SidePanelButton.leadingOf`
in its bar: the menu button, opening the drawer narrow and docking the panel
again where it is hidden, and nothing where it is docked or a page — a page's
way back is its bar's back button. The panel slides in
and out, pushing the page over. One Scaffold holds the drawer — the
frame's — so a page under it carries none of its own.

As pages, the content is pushed over the panel and popped off it by the
theme's own page transition — `pageTransitionsTheme.buildTransitions`, handed
the route the frame is on and run for that route's durations — so it moves as
any page pushed on this platform does, Cupertino's slide on the Apples and the
fade forwards or zoom elsewhere. Where that slide is Cupertino's, the content
is left by iOS's swipe from the leading edge too, the slide following the
finger and deciding at the end as a route's swipe does (past halfway, or a
fling back). The route's own swipe cannot be it: the content's `PopScope`
turns it off while the content is in front, and on it would pop settings
whole rather than the category. Not a nested Navigator: a category pushes its
editors with `Navigator.of`, and they belong over the whole window, not inside
the frame. Docked, a pick switches the content at once, and a resize across
the breakpoint jumps to where the pages are rather than sliding there.

`CompletionField` is the field a prompt is written in: the menu of `/skills` and
`@agents` that matches what has been typed, the arrows and tab and return that
take one, and escape. It was the composer's, and it is here because the trigger
editor writes a prompt too — one that is dispatched through the same library, so
being offered them in a chat and not there was the tell. Where the menu goes is
the caller's, through `layout`: the composer's spans the whole composer rather
than the field, since the `+` and Send are either side of it, and the trigger's
prompt page puts it under a box that is the whole page. Where a trigger is typed
from a menu is the core's (`triggerOpened` in `lib/app/composer.dart`), and
`reopen` shows the menu for it. What a caller must not do is write its own
trigger handling: `activeCompletionToken` has to keep agreeing with
`prompt_library.dart`, and one copy of it can.

`ThinkingSlider` is a choice of how hard something thinks: a bar of points, the
least thought on the left and the most on the right, the labels under them the
caller's (`stops`, in order). The bar is a halftone of contour lines through a
noise field warped by itself — `ValueNoise` in `noise.dart` — with more
layers of noise and more lines the further right a dot is, so the left is a few
slow curves and the right a dense web; it is lit up to the point picked. It
moves for as long as it is on screen — it was once only while hovered and for a
moment after a pick, which on a phone, with no hover, left it still nearly
always — and not at all where the platform asks for no animation. Its ticker is
muted with its route's `TickerMode`, so a page covered by another costs nothing;
a page showing one never settles, so a test of it pumps rather than
`pumpAndSettle`s, as a page with a spinner does. A tap or a drag anywhere over
the bar or the labels picks the nearest point, the arrow keys step through them,
and it is a slider to assistive technology.

`Nothing` is one muted line where a strip of a page would otherwise be
blank: a project with no chats in it, a search nothing answered,
a paired device's list with nothing picked out of it. It is here rather than in
the sidebar it started in because two of them are on screen at once — the
sidebar's list beside the chat pane — and they had already drifted a text style
apart.

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

It never asks for the field's focus, and that is the whole rule. On Android
focus is the keyboard, so a composer that reaches for it is a keyboard rising
over a conversation nobody was typing in — which is what attaching a file did,
and what the `+` menu's own entries did. Neither has anything to type at: the
file is already on the strip, and the menu the trigger character opens is
tapped. The field has no `FocusNode` of its own any more, since nothing was left
to point one at.

Giving focus away is the composer's rule; taking it back when the keyboard goes
is the app's, and is the next section.

## A catalog of things to download

There are two of them: the on-device models, text and voice, and the Linux the
agent runs commands in. They are different enough to be two catalogs — one is
models that are picked, the other is per-architecture and decides where a
command runs — and identical in everything about *downloading*. So that half
is one implementation, at both ends: `DownloadRun` fetches and `Downloads<T>`
reports, and what differs between them is hooks.

The models are one catalog because every one is an `Installable`: a text model
and a voice model each say what their row shows and how they are fetched and
deleted, so `ModelDownloads` queues either and `ModelDownloadTile` draws
either, on the On-device page (`OnDeviceCatalog`), a section per kind.

`Downloads<T>` in `ui/settings/downloads.dart` is the notifier both catalogs
are: the running subscriptions, the bar's state, the Cancel in the
notification, the release on dispose, and the order a delete happens in. A
catalog answers six things — its ids, how to `begin` a download, what one and
several are called, how to look again, what to unpick, and how to erase. Held
above the settings page rather than in it, because a download outlives the page
and, on Android, outlives the app being on screen.

**Unpick, erase, then look again — in that order, and in the base class.** A
setting left naming something deleted fails later and somewhere else: voice
mode staying off with no word of why for a voice model, and the middle of a
turn for a rootfs. It was written twice, and the second copy is the one that
would have drifted.

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

`CatalogTile`, `CatalogAction` and `InstalledPicker` in
`ui/widgets/catalog.dart` are the same again for what is drawn: a row with its
optional note, failure and bar; the one button that is download *or* cancel *or*
delete and never two; and the field over what is installed. `CatalogAction` owns
the confirmation as well as the button: *that* deleting asks is the same for
both, while what is being agreed to is not, so each catalog passes the two
strings and nothing else. `InstalledPicker` is deliberately **not**
`InheritableDropdown`, which looks identical and means something else — there
null is "inherit what the level above says" and comes with a reset button, here
it is either an answer of its own (Android) or nothing picked yet. It also owns
the one trap both pickers had spelled out separately: a value no item carries is
what `DropdownButton` asserts on, so a setting naming something since deleted
has to fall back to null.

`DownloadProgress` in `model/download.dart` is what a store reports, and it is
one type because it was the same three fields twice — a bar reading one of them
cannot tell which store filled it in.

## The model catalog

Every model picker is a field that opens `ModelCatalogPage`: a search over every
model the configured providers offer, with what each costs and can do, under the
entries that store less than a model — the null entry and each provider's
Default. What a picker is offered is its `ModelRole`'s: the chat LLM only models
that talk (text in, text out) and call tools, since the agent works through
tools; title, classifier and memory any model that talks, being plain
completions; the image model only models that make images; the transcription and
speech models only what models.dev says transcribes or speaks, beside the
installed on-device voice models under `localProviderId` — see "A provider's
models" in `packages/entoli_voice/lib/AGENTS.md`. An endpoint's own listing is
offered to the chat roles alone, since nothing says one of its models is
anything else.

`ModelInfo` holds only the models.dev fields something reads, and the cache and
the built-in snapshot are trimmed to those. Structured output went for that
reason: nothing sends a schema, the background roles parse their JSON from text.

The models come from `ModelCatalog` (`model/model_registry.dart`), which is
models.dev's own shape: a provider is matched to its models.dev entry by its
Provider ID (`LlmProviderConfig.catalogId`), then by base URL, and the model by
its exact id inside it. Never by its name. The id (`LlmProviderConfig.id`) is a
UUID given when it is added, what the settings, the secret store and every chat
point at, so a rename moves nothing; the name is what the user calls it, unique
among the providers, so a second account at one service is a second entry under
a name of its own; the Provider ID is its models.dev key. An entry in
`settings.json` with no `name` reads its id as all three.
`data/model_catalog.dart` loads it at startup — the presets' default models
built in (`lib/data/builtin_models.dart`, written by
`tool/gen_builtin_models.dart` and committed, since it fetches), then the cached
copy in `<dataDir>/models.json`, then a fetch when that is a day old — asked
at launch, every half hour while the app runs, and when the first provider is
added. So with no network and no cache the Defaults are still pickable. Run
the generator when a preset's defaults change. A preset's Defaults are the
preset's, not the entry's: an entry carries the ids it was added with, and
the settings notifier's load puts the current preset's over them
(`withPresetDefaults`), so a release that changes one reaches providers
connected before it.

A card's star puts its model in `AppSettings.favouriteModels`, one app-level
list of (provider, model) pairs, and the Favourites section under Quick picks
lists the starred ones the picker's role can use, in the order they were
starred — so one list serves every picker, and an image model starred there
does not turn up among the chat models. A starred model whose provider has gone
is simply not listed; the pair stays until it is unstarred, should the provider
come back.

A model the catalog does not list is added through `ModelForm`, the core's form,
onto the provider it is reached through (`LlmProviderConfig.customModels`, in
the same shape), where it comes before the catalog's own entry of the same id.

A provider's own list is asked only where the user names one: the dialog's
Models endpoint (`LlmProviderConfig.modelsEndpoint`), empty by default. The
hosted providers' `/models` add nothing to models.dev's entry — ids alone, plus
retired and non-chat ones — so an empty field lists the catalog's entry, a
filled one lists the endpoint's instead, and a provider models.dev does not know
offers nothing until one is named. Listing is the provider's
(`LlmProvider.listModels`), not the chat client's: a local server asks its own
`/models` unless another is named, and the on-device providers list what is
installed. What such a list has and the catalog does not know is offered as a
chat model with nothing known of it; one the catalog does know is offered by
what the catalog says.
