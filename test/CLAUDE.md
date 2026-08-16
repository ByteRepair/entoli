# Tests

What the suite is built on, and the two or three things about it that are not
obvious from reading a test. Everything about the app itself is in the root
`CLAUDE.md`.

## What is shared

`test/harness.dart` holds `TestApp` — the app over a throwaway data directory
with the backend faked — plus `tempConfig`, `makeState`, the dropdown finders,
and the pumping helpers below. `test/fakes.dart` holds `FakeBackend`, whose
`scriptedEvents` and `hold` drive a turn and whose `scriptedTitle` names a chat,
beside `FakeAttachmentPicker`, `FakeLauncherIcons` and `testLibrary`.

`seedChat` is a chat that is actually in the sidebar: creating one no longer
puts it there, so it creates and then writes its `state.json`. `writeChatTo`
(and `TestApp.writeChat`) is for one that has a conversation in it: there is no
whole-log write on `ChatStore` to reach for, since a log is only ever appended
to, so it writes the state and then appends `recordsOf` the messages — which is
what a turn would have done. It closes each reply with a `turnEnd` as well:
without one the chat reads as a turn the process was killed in the middle of and
is offered to be carried on, which is the point of `finished: false` and a
surprise everywhere else.

## The filesystem a test runs on

`tempConfig` is a real temp directory over `fileSystemIo`, torn down when the
test ends. That is what `TestApp` uses by default, and what the store and
repository tests assert against with `dart:io` — the layout on a disk is the
thing under test, so `File(config.stateFile(id)).existsSync()` is the honest way
to check it.

`FakeChatStore` is for the other kind: a test whose subject is *what* was
written rather than where it landed. `TestApp.create(store: …)` takes one, and
its `records(id)` hands back the chat's log directly. The log tests use it
because reading records back off a disk meant polling for them, and a poll
under a parallel test run is a test that flakes — twice, before they moved.
Reach for it when a filesystem is incidental to what is being checked, not to
avoid the pumping below.

`web_filesystem_test.dart` is the other half. `newFileSystemMemory()` is the
same `FileSystemIdb` the web build runs on, over an in-memory IndexedDB rather
than the browser's, so the browser's chat store, its settings and its
attachments are exercised here on the VM. Two `AppConfig`s over one filesystem
is a reload, which is the property the web build exists for and the only way to
check it without loading a tab.

## Widget tests and the fake clock

A `testWidgets` body runs on a fake clock, and real file I/O only advances
inside `runAsync`. Since the store became asynchronous, awaiting it directly in
a widget test waits forever rather than failing — so anything that reads or
writes through the store or the settings goes through `io(tester, …)`.

`settleIo` is `pumpAndSettle` with real rounds interleaved. Two reasons it
exists rather than the plain call: anything reading the store draws a spinner
until it answers and a spinner is a running animation, so settling on one times
out; and a write started by a tap shows no spinner at all while it runs, so an
idle frame is not evidence that it landed. Hence `least` — a floor of real
rounds that happen whatever the tree looks like. Raise it at a call site where a
UI action kicks off store work the assertion depends on, rather than raising the
default.

`pumpUntil` is the same idea aimed at a finder, for waiting on something to
appear.

Do not reach for the memory filesystem to avoid all this. It was tried: sembast
resolves through timers, not microtasks, so a widget test hangs on it exactly as
it hangs on a disk. `runAsync` is the only answer.

## The live test

`test/live/miniswe_live.dart` drives a real provider through the production
path. It deliberately does **not** call
`TestWidgetsFlutterBinding.ensureInitialized()`: that installs an `HttpOverrides`
answering every request with a 400, which is the whole of what a live test is
for. That rules out `rootBundle`, so it copies `assets/prompts/` off disk
instead of using `BundledPrompts`. Not a `_test.dart` file, so `flutter test`
skips it.

## Odds and ends

`ProviderModelSelector` is tested directly in `provider_model_selector_test.dart`
rather than through both settings pages, since it owns every rule about the
provider/model pair and they only say where the values come from.

A test that writes `settings.json` has to go through `config.documents.write`,
not the file: the app reads settings from the synchronous copy `Documents`
holds, and a file written behind it is not seen.

The composer's keyboard is asserted as `tester.testTextInput.isVisible` rather
than as which node holds focus. The rule the composer keeps is about the
keyboard, and the field has no `FocusNode` to reach for anyway.
