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
`VIEW` filter (on `MainActivity` and the `PromptIcon` alias, for the reason
the share filter is on both), `CFBundleURLTypes` in both Apple `Info.plist`s,
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
— says which, and is app-level with no per-chat override for the same reason the
icon is.

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
enum, the arrangement `AppIcon` and `ApproveMode` already have.

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
open chat, hide the sidebar — is an `AppCommand` (`app_command.dart`): its
label and its keys, nothing else. The enum's name is the command's id, which
is why one is never renamed: a key, a menu item and whatever names one next (a
Windows jump list, a Linux `.desktop` action, an argument the app is launched
with) all say which command by it. Settings > Shortcuts lists the ones with
keys, so the page cannot disagree with what answers them.

What a command does is `Commands` (`commands.dart`), and it is one switch.
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

`appMenus` (`app_menu_bar.dart`) is the menu bar as data: menus of groups of
commands, and the platform's own items after them (Hide, Quit, Full Screen —
macOS's alone, dropped where `PlatformProvidedMenuItem.hasMenu` says no).
`AppMenuBar` draws it as Flutter's `PlatformMenuBar` inside `AppShell` — or
`ShellBridge`, under the native shell (see "Liquid Glass") — below the
Navigator the commands open their pages on. A command's keys and its menu
item both run it, and whichever hears the keys first does: Flutter's key
handler where it gets them, the platform's menu where it does.

Flutter's engine has a menu bar on macOS alone. iPadOS gets the same menus
over `agent_chat/menu`, which `installMenuChannel` points Flutter's own
`DefaultPlatformMenuDelegate` at — the engine's protocol, so the Dart is the
same on both and only the Swift answering it differs; see "The menu bar" in
`ios/AGENTS.md`. Every other platform draws none. `platformHasMenus` says
where there are menus, `menuBarAlwaysShown` where they are always on screen,
which is what takes the sidebar's Profile, Marketplace and Settings off it.

The sidebar can be hidden (`sidebarShownProvider`, the View menu, Ctrl+Alt+S).
`AppShell` lays it out in a `SidePanelFrame` (see `lib/ui/widgets/AGENTS.md`),
which the setting is the `shown` of: hidden, the chat pane takes the window and
its bar has a button that brings the sidebar back, so it is in reach on a
platform with no menus too. A narrow window has the sidebar as a drawer
whatever the setting says.

## Liquid Glass

On iOS and macOS the app's chrome can be Apple's own: a SwiftUI window, its
sidebar, toolbar, composer, turn surface, new-chat screen, voice mode, project
palette and popovers drawn by the system in the glass this version of the OS
draws its own apps in — Liquid Glass on 26, its materials before that, since
every glass call names what the OS provides rather than drawing a look of its
own (`Glass.swift`). The conversation itself, and every page pushed over it,
stay Flutter: one Flutter view, embedded in the SwiftUI window. So a feature
in a reply or on a settings page is still built once, and only the chrome is
built twice — a native copy of what the Flutter app draws, with the rules
shared.

**It is the switch in Settings > General > Appearance**, `liquidGlass` in
`settings.json`, on by default and written only when off, the way `autoUpdate`
is. It sits where Material 3 Expressive sits on Android, and like it takes the
colours' place: while it is on the theme colours and the corners are not on
the page, and `appLookProvider` hands `entoliTheme` the defaults — the iOS /
macOS theme — whatever was picked, leaving what was picked where it was for
the switch going off. Light, Dark and System stay, being the one appearance
choice the native chrome follows too. **It is read once, at launch, by the
Swift**: before Dart runs, `LaunchSettings.swift` reads `liquidGlass` out of
`settings.json` and the shell takes the window before it is shown, so the
Flutter view is never on screen outside it. Dart asks `hosting` and draws for
the answer (`_glassAtLaunch` in `main`) rather than deciding again, so the two
cannot disagree. That reader is a second copy of `dataDir()` — `$ENTOLI_CONFIG`,
else `~/.config/<leaf>` on macOS, the debug leaf from the Runner's xcconfigs
as `EntoliDataLeaf`, and `Documents/entoli` on iOS — and of the setting's
default, and moving either means moving it too; it reads before the
migrations run, so a migration that moves `settings.json` breaks it. Switching
the setting away from what the launch started with asks, in a dialog, for the
app to be quit and reopened rather than appearing to do nothing. The in-app restart a restore makes is not one: it is this process
still running, its window already the shell's or not. `LiquidGlass` (`widgets/liquid_glass.dart`) is the
launch's answer — `available` on the two Apples, and `on` as it started, the
window then being the shell's.

### The bridge

`lib/ui/shell/` is the only Dart that knows the shell exists, and Swift is its
one client: the Flutter app on every other platform, and on these with the
switch off, reads its providers as it always has. With the shell, `main` puts
`ShellBridge` where `AppShell` would be. It sends
it what to draw, runs what it sends back, and draws `ChatPage`, with no bar
and no composer of its own.

**The wire is one definition, `pigeons/shell.dart`**, which Pigeon turns
into the Dart in `packages/entoli_glass/lib/src/`, the Swift in the plugin's
`Contract/` (one file for both Runners), and a fake of the Swift end for the
tests. `tool/prepare.sh` runs it, and its output is not committed. A field or
an intent the two sides read differently does not compile. It is a protocol a
client could implement anywhere: the app holds every rule and all the state,
and the client holds only the last snapshot of each concern. `NativeShell` is
what the app says — `hosting`, a snapshot per concern, the one-offs
`voiceLevel` and `focusComposer`, and `strip`, answered later (below); each
`*Intents` API is what a surface's client says the user did, a method per
intent, the few the client waits on (a project's error, a paste's yes or no)
marked `@async`.

**A snapshot is a concern's whole state, sent when it changed.** The
contract's classes compare by value, and `ShellOutbox` sends one only when it
differs from the last of its concern, since most are rebuilt on every frame
a turn streams: `window`, `sidebar`, `chatBar` and `pageBar` (one
`TitleBarSnapshot`), `composer` and `composerValue`, `turn`, `newChat`,
`voice`, `palette`. The microphone's level goes raw, many times a second, and
the glow reads it per frame rather than redrawing the shell for it.
`ShellModel` is the Swift's `NativeShell`, holding what the last snapshot
said and nothing of its own.

**Adding to it** is an edit to `pigeons/shell.dart` and `tool/prepare.sh`;
the compiler then names every place that has to follow. A default is a
constructor default there, and Swift's starting value before Dart has said
anything is a `static let initial` beside its view, since Pigeon gives a
Swift struct none. A field may not be called `description`, which is Swift's.

**What no surface owns is a provider; what a surface owns, its widget.**
The window's, the sidebar's and the palette's snapshots are providers —
`windowSnapshotProvider`, `sidebarSnapshotProvider`,
`paletteSnapshotProvider`, each in its concern's own file beside the runner
for its intents — and `ShellPublisher`, which `ShellBridge` holds, sends each
from a listener on the container. Not from a build: a build waits for a
frame, and an iPhone shows its sidebar exactly when the Flutter view is out
of the window and the engine paused, so a rename, a pin or a delete made from
the list never reached it until the user left it. A widget's own
subscription would not do either, being paused under a page that covers the
conversation. The surfaces' snapshots — the bars, the composer, the turn,
the new-chat screen, voice mode — stay with the widget on top of their
`ShellSlot`, are on screen only while the Flutter view is, and read what they
send in their own build, since a provider watched from a builder beneath one
can be missed. The running chats are a listenable, so the snapshots watch
`busyChatIdsProvider`, its set as a value.

**An intent goes to whoever is on screen.** The window's, the sidebar's and
the palette's go to `ShellBridge`'s own runners. The composer's, the turn
surface's, the new-chat screen's, voice mode's and the two title bars' (one
API on the channels `chatBar` and `pageBar`) go to the widget on top of that
surface's `ShellSlot`, which implements the `*Intents` itself: each claims the
top when it mounts — or, where the last built is the one on screen, when it
is built — and leaves when it goes, taking its snapshot back if it was on
top, and the slot points the channel at whoever is on top now. Turn surfaces
stack — voice mode's over the chat page's — and the one beneath sends again
when the top one goes, nothing it watches having changed to rebuild it. A row's rename and a delete's confirmation are
native dialogs that send the edit itself, which `ChatEdits` makes as it does
for the Flutter sidebar's dialogs.

**The composer's rules are one copy.** `ComposerLogic` is what a composer
decides apart from how it is drawn — what is attached, which mode the text
puts it in, whether Send would do anything, whether Queue is on offer,
sending — and the words and limits that follow from it: each mode's hint and
send label, how far the field grows, where a `!` command runs before the
shell has said. The Flutter `Composer` and `ShellComposer` both draw it, the
shell's configured by a `Composer` it never mounts, the chat page choosing
between them in one place. Both
answer `ComposerHandle`, so Reply and a steer taken back reach either. The
text is Dart's `ComposerController`: what the native field types arrives as
`edited` and is not sent back to it, which mid-composition would undo the
input method's marked text, and what Dart changes — a completion taken, a
message put back, the field cleared on send — goes as `composerValue`. A quote
card is an attachment character in the native field carrying its embed's code
unit, so offsets mean the same on both sides.

### The layout

**The Flutter view runs under the toolbar and the composer, never under the
sidebar**, and how far those reach goes to Dart as top and bottom padding.
`ShellInsets` applies it above the Navigator, from `MaterialApp.builder`, so a
page pushed over the conversation clears the toolbar as the conversation
does. On the chat page `_FloatingBottom` lets the conversation run the whole
height and pads it by the composer and by whatever Flutter still draws above
it — the browser's prompts, a setup or offline bar — measured, so the last
message clears both; and tooltips there open above what they are about,
since a tooltip knows only the Flutter view's room and below is behind the
composer. On iOS the keyboard is left out of the insets: Flutter hears of it
itself, and counted twice the conversation went up under the toolbar.

`FlutterCanvas` is the Flutter view and every layer drawn in its coordinates,
in one container: the edges are said once, and a layer gets exactly the
view's frame, so a point Dart names is the same point there. What floats over
everything is the system's own presentation instead. The reaction strip is a
`strip` request — the anchor's rect in Flutter's coordinates and the choices
— which the Swift answers when one is picked or the popover dismissed: a
popover, in the system's glass and a window of its own, so it is clipped by
nothing and placed, dismissed and read out as a popover is.

**A Flutter page over the conversation covers the chrome.** `AppRoutes`
(`app_routes.dart`), on the Navigator from `main`, says whether a page is
pushed over the first route; the shell steps its composer and new-chat screen
aside while one is, and its title bar becomes the page's. A dialog covers
nothing, and neither does a sheet — which is why an activity's drawer is a
page here and a sheet only without the shell (see "Thinking and tool runs"
in `lib/ui/chat/AGENTS.md`). **A pick closes the pages
first**, in either shell: opening a chat, a new one or another project from
the sidebar or the palette goes through `toConversation`, which closes each
page the way the back key would. A page that asks before it goes is asked,
and waited for — a discard goes on to the next page and the pick, a keep
stops there with nothing changed under it. Asking again instead, the first
version, closed the question and asked again for ever.

**A page's bar is the window's title bar.** A page says what its bar holds
with `PageBar` (`widgets/page_bar.dart`) as data rather than widgets: a
`title` and a `subtitle`, how it is left (`PageLeading`: back, or a close
that discards), what leaving runs if not the back key, and its `actions`.
Each action is a `PageAction` — `.icon`, `.confirm` (the tick), `.text`
(`prominent` for a page's one filled button), `.menu` of `PageMenuItem`s —
and draws itself both ways: as a button in an `AppBar`, which is what the
bar is with the shell off or in a route that is not a page, and as an item
of the window's title bar under it, the tick as the system's confirm and
its Material icon looked up as an SF Symbol. That is the whole of the
design: a page knows nothing of the shell, and neither bar is read back
out of the other, so a new kind of action is a new `PageAction`, said once
and drawn by both. An action that comes and goes is the page's `if`, the
page rebuilding as it would for anything else it shows. What Flutter keeps
under the shell is `bottom` — tabs, a search under the bar — drawn under
the title bar, where the `AppBar` drew it. The bars stack as their pages
do, `ShellPageBar` claiming the top as it mounts and giving it up as its
page starts to leave, so the bar beneath is back for the whole of the way
back; the back the title bar draws is the page's back key, so a page that
asks before it goes is asked. The Swift is `TitleBar.swift`, one view for
every bar the window has: the chat's is drawn by it too, its buttons sent
under `toolbar` and a page's under `pageBar`. On an iPhone it hides the
split view's own back while a page leads, the page's being the one that
pops it.

The appearance is the app's, not the window's: popovers, menus and sheets are
windows of their own, so `NSApp.appearance` on macOS and the window's
`overrideUserInterfaceStyle` on iOS follow Light, Dark and System.

### Voice mode, and the glow

`VoicePage` stays a Flutter route, so leaving it is still popping it and the
session still lives exactly as long as the page; under the shell it draws
nothing, and the Swift draws voice mode over the whole window from its
snapshots. The orb is new here: a mesh gradient of the two voices' colours
(`Glow.swift`, macOS 15 and iOS 18; a blurred canvas of the same blobs
before), faded to a soft disc behind the system's clear glass. It drifts
while starting, swells with the microphone while listening, orbits while a
turn runs, beats in the reply's colour while speaking, and sits grey and still
— not redrawing — while the microphone is shut.

### Where the platforms differ

The menu bar is still Flutter's `PlatformMenuBar` on macOS, `AppMenuBar`
inside `ShellBridge`, so `appMenus` stays the one definition. It has no Edit
menu, so the native field takes its own editing keys — cut, copy, paste,
select all, undo, and Return's send and queue — in `performKeyEquivalent`,
which the window offers a view before the menu bar; an Edit menu would have
sent the same keys to Flutter's own text fields too. On an iPhone the split
view is a stack, and it opens on the detail column — nothing selected is the
new-chat screen, as it is in the Flutter app, not the list. The chat's bar
leads with a sidebar button in place of the split view's chevron, the Flutter
app's menu button drawn the system's way, and picking a chat, a new one, a
page or a project from the list goes back to the detail as the Flutter drawer
closes on each; `ShellModel.compactColumn` is the one state for all of it.
Only the behaviour follows Flutter's: the layout stays the native split
view. The app's pages are a menu on the list's bar, there being no menu bar
to hold them. The hosting is each Runner's own story — see "The native shell" in
`macos/AGENTS.md` and `ios/AGENTS.md`.

What is tested is the Dart half, `test/ui/shell/`: every snapshot as the
Swift receives it, over the real channels to `FakeNativeShell`, every intent
against the app's fakes, the stacking, the page closing. The Swift is checked
by building both Runners and looking.
