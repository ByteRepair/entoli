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

What stayed behind is what genuinely is a port: the artifact server and the web
artifact opener under `core/platform/io/` and `core/platform/web/`, still
reached through the conditional import that keeps `dart:io` off the web and
`package:web` off a native build. Desktop is no longer one of them: the base
stylesheet is injected into the artifact's entry file at publish time (see
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

## The theme

One palette, seeded from `entoliIndigo` by default — the colour the icon sits
on, which the seed used to miss by being `Colors.indigo` instead — and built in
each brightness by `entoliTheme`. `MaterialApp` gets both as `theme` and
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
set rather than one colour per family from wherever it happened to sit — and
both default to `indigo`, which is the scheme the app had before any of this
existed. That colour has one spelling, `entoliIndigoArgb` beside the enum:
`entoliIndigo` is it as a `Color`, and a const `Color` cannot be built from an
enum's field, so the layer with no `Color` in it holds the number.

The primary is the seed. The secondary is grafted from a *second* scheme seeded
with it: `fromSeed`'s `secondary:` names one role, which would leave
`secondaryContainer` a tone of the primary seed beside a colour that is not.
Both indigo is the ungrafted scheme, so the default is byte-identical to what
one seed gives.

`CornerRadius` is named after Material's shape scale, which is where its eight
numbers come from, and it reaches the shapes `entoliTheme` sets and no others:
fields, dialogs, menus, sheets and buttons. The `BorderRadius.circular` literals
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
