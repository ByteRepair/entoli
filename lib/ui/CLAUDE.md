# The look of the app, and the keyboard

## The theme

One palette, seeded from `entoliIndigo` — the colour the icon sits on, which the
seed used to miss by being `Colors.indigo` instead — and built in each
brightness by `entoliTheme`. `MaterialApp` gets both as `theme` and `darkTheme`
whichever is in use, so a system that turns dark at sunset turns the app with it
without anything being told. `AppTheme` — `system`, `light`, `dark` — says
which, and is app-level with no per-chat override for the same reason the icon
is.

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
