# The workspace explorer

A workspace is where the agent's work lands, and until now the only way to see
it was to leave the app. `WorkspaceTile` on the chat and project settings pages
opens `WorkspacePage` over one folder — the chat's own `workspace/` or the
project's shared one, resolved by the page that knows which it is.

The default project's is reached from the sidebar instead, from the slot beside
the project switcher that a named project fills with its settings gear. The
default project has no settings page — it cannot be renamed or deleted, which is
most of what a named project's holds — and the workspace is the only other thing
such a page would have held, so the button goes straight there. It was under app
settings before, which put one project's workspace somewhere none of the others
were.

A project's workspace holds a `chats/` folder, since a chat's own workspace is a
folder inside it. That is the layout rather than something the explorer draws:
the same folder is what the chat settings page opens directly, and what the
agent's `HOME` points at from a command.

Listing, making a folder and deleting (`listWorkspace`, `createFolder`,
`deleteEntries`) are the same code on every platform and are offered wherever the explorer is. A typed
folder name is sanitised by `safeRelativePath` like anything else joined onto a
workspace — `../` is a name a folder can be asked for. Deleting looks each path
up rather than trusting what the listing said it was, since a selection is held
as paths and the listing under it is re-read.

A text file is the one thing a tap does not leave the app for. `TextFilePage`
(`lib/ui/widgets/`, since the profile page opens linked instruction files in
it too) reads it off the disk the listing came from, so it is one page on
every platform. It opens as a preview: markdown rendered
with the reply's style sheet, anything else in `re_editor`'s `CodeEditor`,
read-only and highlighted by the grammar `grammarOfFile` picks from the name —
the same thirty-one `CodeBlockBuilder` registers, found by a grammar's alias the
way a fence names one. Edit turns the editor writable (markdown switches to its
source), and the save is a plain write rather than `writeThroughRename`, since a
rename makes a new file and drops the mode an agent gave its script, and would
replace a linked CLAUDE.md that is a symlink with a file of its own. Wrapping
and text size belong to the reader rather than the file, so they are held for
the session rather than per page.

Not Monaco, which was asked for: its Flutter wrapper is a webview, and
`webview_flutter` has no Linux backend, so the one desktop this is developed on
would have had none — besides shipping several MB of Monaco's JS.
`re_editor` is pure Flutter from the authors of `re_highlight`, lays out only
the lines on screen, and highlights in an isolate.

The boundary between it and the hand-off is drawn twice, because a name is not
evidence. `looksTextual` goes by the extension alone — a known one, or none at
all, which is what `README`, `Makefile` and every dotfile have — and it is the
half the explorer can answer without a read. Not `package:mime` for that half:
its table has no entry for `py`, `go`, `yaml`, `ts`, `kt`, `rb` or most of what
a coding agent writes, and it calls `rs` an XML dialect. The bytes settle the
rest: `readTextHead` returns null for a NUL byte or a decode that fails, and the
viewer pops `true` to send the file back out to the explorer's hand-off, so a
`.log` the agent wrote as a gzip ends up where it would have gone anyway. The
hand-off stays the explorer's rather than the viewer's because the explorer is
what will still be on screen to say so if it fails. The app bar keeps that route
out for the files that *are* text, since a `.md` is often wanted in a real
editor.

`textViewLimit` (256 KB) is where the page stops showing a file. A workspace
holds logs with no upper bound on them, so only the head is read — enough to
tell text from binary — and a file past it gets a pane with two buttons: open it
in another app, or copy the whole of it, which is the one read of the full file
and happens only on that tap. The head is never shown on its own: it is not the
file, and an editor over it would cut the rest off on a save.
The cap falls on a byte rather than a
character, which is the one thing `readTextHead` has to undo before it decodes:
a rune cut in half is otherwise a file that reads as binary.

Everything else the page can do is `FileHandoff`'s, and every route is gated the
way `Shell.canRunCommands` gates the agent's commands. Desktop and Android do
not differ in degree here, they differ in kind — and so there are two
implementations, chosen at runtime in `createFileHandoff`, because they share
`dart:io` and agree on nothing else here. Choosing rather than branching is the point: a class that
answered both would carry an `if (Platform.isAndroid)` in every member, and
every future member too.

- **Desktop** has a file manager and a registry of viewers, and `url_launcher`
  reaches both: `reveal` opens the current folder (the app bar's button) and
  `open` opens a file, which is the same call on a different path. It needs no
  chooser of its own — the file manager is already pointed at the workspace —
  and it has no share sheet, so a selection there is only ever deleted.
- **Android** has the share sheet, both ways. `export` sends a selection through
  `Intent.createChooser`, so every app on the device is on offer rather than a
  default winning silently; `open` is an `ACTION_VIEW`. Files come back in the
  same way, and only that way: another app shares to Entoli. It is not the only
  route out any more — a `DocumentsProvider` puts the workspaces in the Files
  app, for the other app to browse rather than be handed something. Both are
  below.

`canShare` is false on a platform with no share sheet to hand a selection to,
which is what takes the Share button off the desktop toolbar — selecting itself
stays, since deleting is the filesystem's rather than a route out of the app.

A selection replaces the browsing actions rather than sitting beside them: the
app bar is the filesystem's verbs on what is picked, and the FAB stays the route
out of the app, which is the one thing a platform can be without.

A share sheet does not take a folder, so a selection with one in it goes as a
single zip, written straight to the staging directory by `zipTo`
(`lib/data/zip.dart`, the walker a backup streams through too).
Several plain files stay several, which is what `ACTION_SEND_MULTIPLE` is for. A
selection is one folder's — leaving the folder clears it — which is what lets
Android's staging directory stay flat, and why nothing checks for two files of
the same name in it.

Coming the other way, an `IncomingFile` is deliberately **not** its bytes. A
batch arrives with as many files as its source chose to send and then waits on
screen while the user picks a workspace, so held as buffers it is a video's
worth of heap for as long as that takes — and on a phone, long enough to be
killed for it. What each one holds instead is whatever its own source already
had: `IncomingStaged` on Android is the copy `FilesChannel` already made.
A restore's `_RestoredFile` (`lib/data/backup.dart`) is the other, a zip member
read once as it is written.

`writeIncoming` makes room and hands over a target; `writeTo` decides what
putting it there means. That split is where the traversal boundary lives —
`safeRelativePath` runs once, before dispatch, so no variant can open a hole in
it — and it is why the writes stay sequential: doing them at once would put
every file's bytes in memory together, which is the whole thing being avoided.

That staging directory is the other thing worth knowing about the Android half.
Everything handed to an intent is a **copy under the app's cache**, never the
workspace file itself, because a `FileProvider` only mints URIs under the paths
in `res/xml/file_paths.xml` and one `<cache-path>` is the whole of that file.
The alternative was a `<root-path>` exposing the data directory by path for the
sake of not copying, which is a worse trade on a directory holding `settings.json`
and every chat. It costs a copy per open; workspace files are the agent's output,
and the ones big enough to notice are rare.
