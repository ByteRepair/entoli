# The workspace explorer

A workspace is where the agent's work lands, and until now the only way to see
it was to leave the app. `WorkspaceTile` on the chat and project settings pages
opens `WorkspacePage` over one folder — the chat's own `workspace/` or the
project's shared one, resolved by the page that knows which it is.

The default project's is reached from the sidebar instead, from the slot beside
the project switcher that a named project fills with its settings gear. The
default project has no settings page — it is the data directory, so a settings
page for it would be the app's own said twice — and the workspace is the only
thing such a page would have held, so the button goes straight there. It was
under app settings before, which put one project's workspace somewhere none of
the others were.

Listing, making a folder and deleting go through the config's `FileSystem`
(`listWorkspace`, `createFolder`, `deleteEntries`), so they are the same code on
a disk and over IndexedDB and are offered wherever the explorer is. A typed
folder name is sanitised by `safeRelativePath` like anything else joined onto a
workspace — `../` is a name a folder can be asked for. Deleting looks each path
up rather than trusting what the listing said it was, since a selection is held
as paths and the listing under it is re-read.

Everything else the page can do is `FileHandoff`'s, and every route is gated the
way `Shell.canRunCommands` gates the agent's commands. The three platforms do
not differ in degree here, they differ in kind — and so there are three
implementations, not two. The conditional import splits `dart:io` from
`dart:js_interop`, which it has to: `Process` will not compile in a browser and a
`Blob` will not compile on the VM. Desktop and Android are then chosen at
runtime in `platformFileHandoff`, because they share `dart:io` and agree on
nothing else here. Choosing rather than branching is the point: a class that
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
- **A browser** opens a file as a blob in a new tab, which is what lets the
  browser preview it, downloads a selection, and takes files in through the
  chooser `<input type="file">` already is — `webkitdirectory` for a folder,
  whose `webkitRelativePath` is what keeps the folder's shape.

`exportKind` is the one thing the port says about presentation, and it says the
*kind* rather than the words: a share sheet and a download are not the same
promise to the user, but which word and which glyph say so is `WorkspacePage`'s
to decide. Null is a platform with nowhere to hand a selection, which is what
takes the export button off the desktop toolbar — selecting itself stays, since
deleting is the filesystem's rather than a route out of the app.

A selection replaces the browsing actions rather than sitting beside them: the
app bar is the filesystem's verbs on what is picked, and the FAB stays the route
out of the app, which is the one thing a platform can be without.

Neither a share sheet nor a download takes a folder, so a selection with one in
it goes as a single zip (`zipEntries`, in `lib/data/` rather than `local/` or
`web/` because it is written against the `FileSystem` and both sides use it).
Several plain files stay several, which is what `ACTION_SEND_MULTIPLE` is for. A
selection is one folder's — leaving the folder clears it — which is what lets
Android's staging directory stay flat, and why nothing checks for two files of
the same name in it.

Coming the other way, an `IncomingFile` is deliberately **not** its bytes. A
batch arrives with as many files as its source chose to send and then waits on
screen while the user picks a workspace, so held as buffers it is a video's
worth of heap for as long as that takes — and on a phone, long enough to be
killed for it. What each one holds instead is whatever its own source already
had: `IncomingBlob` in a browser, where a `File` is a handle to bytes that have
not been loaded yet, and `IncomingStaged` on Android, which is the copy
`FilesChannel` already made. `IncomingBytes` is the trivial third, for bytes
genuinely in hand.

`writeIncoming` makes room and hands over a target; `writeTo` decides what
putting it there means. That split is where the traversal boundary lives —
`safeRelativePath` runs once, before dispatch, so no variant can open a hole in
it — and it is why the writes stay sequential: doing them at once would put
every file's bytes in memory together, which is the whole thing being avoided.
Only the folders are batched, because `create` on the web opens a read-write
transaction before it looks, and a folder upload names one directory hundreds of
times.

`IncomingBlob` lives beside `WebFileHandoff` rather than with its siblings in
`lib/domain/`, since it holds a `package:web` type. That is also why
`IncomingFile` is `abstract` and not `sealed` — the variants are deliberately
not all in one library, and nothing switches on them.

That staging directory is the other thing worth knowing about the Android half.
Everything handed to an intent is a **copy under the app's cache**, never the
workspace file itself, because a `FileProvider` only mints URIs under the paths
in `res/xml/file_paths.xml` and one `<cache-path>` is the whole of that file.
The alternative was a `<root-path>` exposing the data directory by path for the
sake of not copying, which is a worse trade on a directory holding `settings.json`
and every chat. It costs a copy per open; workspace files are the agent's output,
and the ones big enough to notice are rare.
