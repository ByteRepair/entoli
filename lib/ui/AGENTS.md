# The look of the app, and the keyboard

## Opening a link

`PlatformLinkOpener` is here rather than under `core/platform/` because it is a
page, not a port. What it dispatches on is the platform, which is what filed it
there to begin with, but two of its three answers are a `Navigator.push` of a
webview it also defines — it takes a `BuildContext`, builds `Scaffold`s and
`AppBar`s, and reaches the shared `copyToClipboard` the rest of the UI uses.
Under `core/` that last one was the only import in the tree pointing from
`core/` back into `ui/`, which is the direction that says a file is on the wrong
side of a line.

What stayed behind is what genuinely is a port: the artifact server under
`core/platform/`, the loopback the phones' artifact webview is served from.
Desktop needs no server at all: the base stylesheet is injected into the artifact's entry file at publish time (see
"Artifacts" in the root notes), so the desktop opener opens the file on disk
over `file://` and nothing about the page needs building at open time. That is
also why the injection had to move: opening a temp copy of the entry file, as
this used to, would break every relative reference to the files sitting beside
it. The `LinkOpener` interface stays in `domain/`,
which is what lets `main` inject it and the tests fake it.

The one thing the opener asks beyond the store is the `SyncHub`, handed in
`main` beside it and null in tests: a chat being mirrored has no artifact
directory here, so its artifacts come down as one zip (see "Artifacts" in the
root notes) and open out of a temp directory by the same platform paths. The
staging itself is the `RemoteArtifacts` port, not opener code — the opener
asks it where the artifact landed and says the device-away line where the
answer is null. The null is also the shape of "no sync running", which is
what keeps every sync-unaware caller on the local paths unchanged.

## Links into Entoli

Entoli registers the `entoli://` scheme on every platform — Android's
`VIEW` filter on `MainActivity`, `CFBundleURLTypes` in both Apple `Info.plist`s,
`x-scheme-handler/entoli` in the Linux desktop entry, and
`HKLM\Software\Classes\entoli` in the MSI. `app_links` delivers them, the
launching one and every one after, on one stream that `IncomingLinks` (wrapped
in `main` beside `IncomingShares`) reads. What a link means is
`AppLink.parse` (`lib/domain/app_link.dart`), and nothing else reads one:

- `entoli://new?prompt=…` — the new-chat screen with the prompt in its
  composer, **unsent**: a web page wrote it, so the user sends it. This is the
  form the agent harnesses take (`t3code://new?prompt=…`), so Open Bot
  Avatar's "Open in" menu can name Entoli with one entry. The prompt waits in
  `newChatPromptProvider` (`openNewChat(prompt:)`) only until the new-chat
  screen takes it, so unlike the screen's own settings it never outlives one.
- `entoli://install/marketplace/entoli/<skill|agent>/<slug>` — the
  marketplace's own preview page for that entry, its Install the same. The
  `entoli` segment names the marketplace, so another can be added without a
  new form.
- `entoli://install/<skill|agent>?def=…` — the entry carried whole, base64url:
  a skill's `.skill` zip, or an agent's PROMPT.md gzipped with `name=` beside
  it, since an agent's name is its file's and not in it. A skills or agents
  settings row's **Copy install link** makes one (`AppLink.share`, over the
  bytes Export would save), and refuses one past `appLinkMaxLength` —
  Windows' command line, about 32K characters, is the tightest hand-over —
  so a skill too big to share says so to the sharer instead. The same preview
  page opens with nothing fetched (`sharedEntry`), the SKILL.md or prompt
  body in the README's place, since a link from anyone is untrusted text and
  the user installs only what they have seen. **A link cut short is caught
  where it is read**, because a chat app that truncates a long link hands
  over something that still looks like one: a gzip ends in its CRC and
  length and a zip in its end record, and `AppLink.parse` checks both, so a
  cut link opens the page saying it is incomplete with no Install. That is
  why an agent is always gzipped — plain text cannot say it all arrived.
- `entoli://install/avatar?def=…` — a Bot Avatar definition, raw or base64url
  JSON (Open Bot Avatar's own `def`), on `BotAvatarInstallPage`: the bot and
  Install, landing in the editor's library.

The desktops are single-instance for it: Linux's runner lets GLib emit
`command-line` (`G_APPLICATION_HANDLES_COMMAND_LINE`), here or in the running
copy, which is where `app_links` reads the link; Windows' `wWinMain` hands a
link to a running window (`SendAppLinkToInstance`) and exits.

## The theme

One palette, seeded by default from the iOS / macOS theme (Apple's systemBlue
as both seeds, on grey surfaces; see below) and built in each brightness by `entoliTheme`. `MaterialApp` gets both as `theme` and
`darkTheme` whichever is in use, so a system that turns dark at sunset turns the
app with it without anything being told. `AppTheme` — `system`, `light`, `dark`
— says which, and is app-level with no per-chat override: a palette is the
app's, not a conversation's.

**The faces are the artifact stylesheet's.** Source Serif 4 on every tier of
the text theme, and Playfair Display on the display and headline tiers plus
`titleLarge` and `titleMedium` — the same two faces the stylesheet names, and
the reason the artifacts are the best-looking thing in the app. The cut sits
below `titleMedium`: at 14pt a serif reads as prose, and putting the buttons
and timestamps of a UI in a display face is a poster rather than a screen.
Both are bundled in `ui/fonts.dart` beside Roboto Mono, as static instances of
the Google Fonts variable fonts — the engine reads no `opsz` axis, and a
variable `wght` makes every weight request synthetise or clamp. They reach the
theme through `entoliTheme`'s `fontFamily: bodyFamily` plus a partial
`textTheme:` of the display tiers: `ThemeData` applies the `fontFamily` to the
default theme it builds and merges the passed tiers over it. The family has to
sit on the theme's side of that merge — `Theme.of` re-merges the englishLike
geometry *under* whatever the theme carries, so a family on the geometry side
(`englishLike`) would lose to the default's own `Roboto`.

## What the settings page can change about it

Three things, all app-level like the theme itself: a primary colour, a secondary
one and a corner radius. The colours are a `ThemeColour`, eight of Tailwind's
600 tones — which is what `entoliIndigo` already was, so the row looks like one
set rather than one colour per family from wherever it happened to sit. Both
default to `apple`, the iOS / macOS theme. `indigo` was the default before the
themes; `settings.json` always writes both fields, so an install that saved
its settings keeps it. Each of the two has one spelling, `entoliIndigoArgb`
and `appleBlueArgb` beside the enum: a const `Color` cannot be built from an
enum's field, so the layer with no `Color` in it holds the number.

Those eight are the *pastel* row, and they keep their unprefixed enum names
because `settings.json` stores them. Above them is a *bold* row (Material's 500
tones, `bold*`). Both rows are drawn once, under a Primary | Secondary switch
that says which field a tap writes and wears each one's current colour; two
copies of every row was a wall of swatches. Above all of it sits one row of
`ColourTheme`s — well-known schemes such as Adwaita or Dracula, each a pair of
`ThemeColour`s from the `theme` group that one tap writes into both fields.
A theme with one accent is that accent twice and draws as a solid swatch; a
pair draws split diagonally. Nothing new is stored: a theme is selected while
the two fields hold its pair.

What separates the rows is the scheme variant, not only the hex. The pastels
are strong colours that `fromSeed`'s default `tonalSpot` softens, and that
softening is what makes them pastel; bold and theme seeds go through
`fidelity`, which keeps the seed's chroma so the app looks like the swatch.
That is also why there is no pastel brown or slate: `tonalSpot` lands
them next to amber and a blue. The variant travels with the seed (`Seed` in
`ui/theme.dart`), since a bold primary can sit beside a pastel secondary.

`fidelity` also tints every surface with the seed, which the operating systems'
own themes do not: iOS/macOS, Windows, Adwaita, Breeze and Ubuntu paint their
windows grey. Their primaries carry `greySurfaces`, and `_scheme` takes the
neutral roles from a `monochrome` scheme for them. The editor themes and
Material You keep the tint, since their own backgrounds are tinted.

Text on a filled surface takes the scheme's paired foreground, not the page's.
With `fidelity` a container *is* the seed, so `onSurface` on a bold yellow in
dark mode is light grey on yellow. `onFill` looks the fill up among the
scheme's roles and returns its `on*` partner, which Material builds to contrast
with it; `onFillTheme` hands that to a subtree's text and to `primary`, so
links and the caret follow. The message bubble wraps what was said in it. Code
names `onSurface` on a surface of its own, so it is left alone.

The primary is the seed. The secondary is grafted from a *second* scheme seeded
with it: `fromSeed`'s `secondary:` names one role, which would leave
`secondaryContainer` a tone of the primary seed beside a colour that is not.
The same colour twice is the ungrafted scheme, so the default is byte-identical
to what one seed gives.

`CornerRadius` is named after Material's shape scale, which is where its eight
numbers come from, and it reaches the shapes `entoliTheme` sets and no others:
fields, cards, dialogs, menus, sheets and buttons. The `BorderRadius.circular` literals
scattered through the widgets are deliberately not it — a bubble, a code block
inside that bubble and a search box were each tuned against the ones around
them, and collapsing them onto one number would flatten a hierarchy rather than
follow a setting.

**Material 3 Expressive** replaces both colours with the one the system is
themed to. `ThemeChannel.kt` answers with `system_accent1_500`, the tone Android
derives its own palette from, and Dart seeds a scheme with it rather than
reading the system's whole palette out — Material generates the other roles from
one colour, which is what Android did to arrive at that one in the first place.
Below Android 12, and on every other platform, `systemAccent()` is null, and
that null is the whole of what takes the switch off the settings page: nothing
else has to ask which version of which platform this is. It is read once at
startup, so a wallpaper changed under the app reaches it at the next launch. The
two colours are left where they were while it is on, so turning it off returns
to what was picked.

Three providers, and the split is what each answers: `systemAccentProvider` is
what the platform has, `paletteAccentProvider` is what the palette is using —
the first, but only where the switch is on — and `appLookProvider` resolves the
settings against it into the seeds and the radius `entoliTheme` takes. `main`
watches the last of them and the theme mode beside it, so the rule that an
accent replaces both colours is written once and the settings page draws its
colour rows from the same answer.

Android's splash has followed the system since `minSdk` went to 26 and the
pre-Lollipop `launch_background.xml` could go. Until this landed the app did not
agree with it: a dark phone showed a dark splash and then a white app.

The exceptions are the two voice colours beside `entoliIndigo`, and why they
are not seeded is in "The screen".

`AppTheme` mirrors material's `ThemeMode` rather than holding one. Nothing in
`domain/` imports material — `core/config.dart` does reach `foundation`, so this
is about the framework's UI half rather than about Flutter at all — and the name
in `settings.json` should not be pinned to a framework enum's, which would make
the file unreadable if that enum were ever renamed. `ui/theme.dart` is the one
place that maps between them, and the label the settings page draws is on the
enum, the arrangement `ApproveMode` already has.

The one other thing in it is `inputDecorationTheme`, and it is there because
every field and every dropdown in the app is outlined. Spelled at each of them
instead it was the same literal twenty-odd times, and three of them were left
wearing Material's underline — the catalog pickers under Terminal, On-device and
Voice, which then looked nothing like the model pickers beside them. A field
that wants its own border still passes one and wins: the sidebar's rounded
search box and the composer dressed as a shell command are both that.

`entoliTheme` is a function rather than two `ThemeData` literals in `main`:
light and dark differ by a `Brightness` and nothing else, and a second literal
is a second thing to keep in step.

`main` watches the one field rather than the settings object. Without the
`select`, adding a provider or editing an environment variable would rebuild the
whole app under the user.

## The keyboard and the caret

Android closes the keyboard on a back gesture and says nothing about it but that
the view insets fell — and on touch the framework deliberately never unfocuses a
field for a tap outside it — so a field tapped once goes on holding the caret
over a conversation nobody is typing in. `FocusFollowsKeyboard` wraps the app in
`main` and is the whole of the answer: it remembers what held focus while the
insets were up and drops it when they fall to nothing. It is app-level because
both halves already are, `MediaQuery` and the `FocusManager`, so every field
gets it and the composer keeps no focus code at all.

It reads `MediaQuery.viewInsetsOf`, so it has to be above every `Scaffold`, which
is what takes the bottom inset out of what it lays out. Being at the root is also
what makes it survive: this was in `_ComposerState` first, whose state goes every
time the `QuestionPanel` takes the composer's place, so its "the keyboard is up"
flag could be false with the keyboard up. Then it was deleted outright, read as a
mechanism that existed only to undo the focus requests going away. It was not:
the insets are the only report of the keyboard closing there is, and the caret
came back with them.

What it remembers is a node, rather than asking what holds focus once the insets
have fallen, because by then focus may have moved — to a pushed route's scope
when the `+` menu opens, or to a reply's `SelectableText`, which is a read-only
`EditableText` and closes the keyboard by taking the focus away from the field.
Unfocusing either of those breaks something that was working, and `hasFocus` on
the node the keyboard was up for is the whole of the test. The gap it leaves is
focus moving straight from one field to another, where the insets never fall and
the second field keeps its caret; closing that means watching every focus change,
which is how a reply's selection would get dropped.

## The app's commands

Everything the app can be told to do by name — a new chat, Settings, pin the
open chat, hide the sidebar — is an `AppItem` (`lib/app/app_items.dart`), and
there are two kinds, sorted by one rule: what changes what happens is the
core's, what changes what is on screen or where is the UI's. An
`AppAction` (new chat, pin, rename, move, delete, stop) is run by the core,
the UI asking first for what it needs — a name, a project, a yes. A
`Destination` (Settings, Profile, a chat's settings, the sidebar, voice mode)
is where the UI takes the app, through `flutterNavigate` in `commands.dart`,
an exhaustive switch with no default, so a new destination does not compile
until it is reached. Each
item's title and keys are plain data (`AppKey`), and its availability and
title (`availabilityOf`, `titleOf`) are pure functions of a few facts, so the
core decides them with no widget in sight. The enum's name is the item's id,
which is why one is never renamed: a key, a menu item and Shortcuts all say
which item by it. Settings > Shortcuts lists the ones with keys, so the page
cannot disagree with what answers them; `app_command.dart` is how Flutter
hears and prints those keys.

What an item does is `Commands` (`commands.dart`): an action's switch, and
`Navigate` for a destination.
`Commands.watch` is a snapshot of what the app has open taken in a build — so a
menu greys and labels its items afresh as the app changes. It watches only the
facts a menu draws — the open chat's id, whether it is pinned and whether a
turn runs — since every rebuild sends the whole menu to the platform, and a
chat's state changes with each message that lands. `Commands.read` is
the same taken at a key or a click, which `run` acts on.
`availability` is the one answer to whether a command can run now, and why
not — the keys, the menus and Shortcuts all ask it, the menus reading only
whether. A command is not `anywhere` unless it opens one of the
app's own pages, and the rest only run with the chat pane in front: they act
on what it shows, and a page pushed over it is hiding that. Settings over
Settings replaces it rather than stacking a second.

The commands that act on one chat — pin, rename, move, delete — are
`chatCommands`, run on a given chat by `runOnChat` (`chat_actions.dart`): the
sidebar row's menu runs them on its own chat and `Commands` on the open one.
Each is a dialog over a write in `ChatEdits`, and the write works out for
itself whether its chat is the one on screen and whether it is a mirror, so no
caller passes either. The writes are apart from the dialogs because Shortcuts
makes the same edits with no dialog to show — see "Shortcuts" in
`macos/AGENTS.md`. The project's pages beside its chats are
`project_actions.dart`, which says which of them a project has for the
switcher's buttons and the Project menu alike. A mirrored chat runs none of
them from the menu: its state is its home device's.

Two things are deliberately not commands. Next and previous chapter and jump
to latest are the chat page's private scroll state, and offering them would
have the page register itself with the menu while mounted — a second way for
a command to exist, with a lifetime. The new-chat screen's own settings are
held by that screen until there is a chat, for the same reason.

### The menu bar

**The menu bar is a module of its own.** On Apple's platforms it belongs to
the app rather than to a window. `appMenus` (`lib/app/app_items.dart`) is its layout as data: menus of
groups of items, and the platform's own after them (Hide, Quit, Full Screen —
macOS's alone). `packages/entoli_menu` draws it, one Swift source for macOS and
iPadOS over its own Pigeon contract (`pigeons/menu.dart`): Dart sends the
whole bar, titled and greyed, whenever that changed, and Swift sends back the
id of the item picked. The bar is SwiftUI's — `AppCommands`, in each Runner's
`.commands` — so the platform puts in what it always does (Hide, Quit, Full
Screen, the Window menu) and the layout says only each menu's role: the app
menu, File, View and Help take the app's items into the platform's own, and
an `own` menu is one of the app's. It is a port, `AppMenus`
(`lib/app/app_menus.dart`), bound in `main` as `NativeAppMenus`
(`core/platform/app_menus.dart`) on the two Apples and absent everywhere
else. Before the app is up nothing is sent, so the welcome tour has no app
items to reach past it by.

`AppMenuSync` (`app_menu.dart`), mounted in `AppShell` below the Navigator,
shows the layout as the app stands and runs a pick through `Navigate`. **The
menu holds the keys of every item in it**, as its own key equivalents, and
`runKey` — the app's one key handler — stands down for those wherever there
is a menu bar, so no key runs twice. Elsewhere Flutter's handler has every
key. `menuBarAlwaysShown` says where the bar is always on screen,
which is what takes the sidebar's Profile, Marketplace and Settings off it.

The sidebar can be hidden (`sidebarShownProvider`, the View menu, Ctrl+Alt+S).
`AppShell` lays it out in a `SidePanelFrame` (see `lib/ui/widgets/AGENTS.md`),
which the setting is the `shown` of: hidden, the chat pane takes the window and
its bar has a button that brings the sidebar back, so it is in reach on a
platform with no menus too. A narrow window has the sidebar as a drawer
whatever the setting says.

## The composer and the page bars

**The composer's rules are the core's.** `ComposerModel`
(`lib/app/composer.dart`) is what a composer decides apart from how it is
drawn — what is attached, which mode the text puts it in and which callback
it holds, whether Send would do anything, whether Queue is on offer, where a
`!` command runs before the shell has said — and runs every
`ComposerAction` in one exhaustive switch, so a new action does not compile
until it does something. It reads the field through `ComposerText`, which
`ComposerController` implements, so it imports no widget. What it says — the
hint, the send label, how far the field grows — is `composer_words.dart`'s,
and where each action sits is the `Composer`'s `_place`, a switch over the
same list with no default. The chat page owns one model per chat and one
`ComposerBinding` (the turn it sends into, where it is). `ComposerHandle` is
what the page asks of it: Reply, and a steer taken back put back.

`PageBar` (`widgets/page_bar.dart`) is the bar of every pushed page, said as
data — a `title` and a `subtitle`, how it is left, and its `PageAction`s — and
drawn as an `AppBar`.
