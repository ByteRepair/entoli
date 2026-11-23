# Picking files and handing them off

`entoli_files` is the adapter for what a page does with a file outside
Entoli: the platform's choosers, and the routes a file takes to another app.
`entoli_files.dart` is the whole of what the app reaches —
`platformFilePicker`, `platformFileHandoff` and
`platformBackupHandoff`, bound in `main` and `lib/core/platform/host.dart` —
plus `zipTo`, which the backup streams through too.

## The choosers

`file_selector` is the one plugin under every chooser, on every platform the
app runs on, answering the core's `FilePicker` (`FileSelectorFilePicker`):
a folder, one file or several, each filtered by a `FileTypes` the page names.
A page holds a `PickedFile`, never the plugin's `XFile`, so no page imports
the plugin and a test answers with a file on its own disk. Android's chooser
hands back a content URI, which the plugin copies under the cache by its
display name, so `path` is a real file there too. The composer's Image and
File are the core's `pickAttachments` over it, which reads the files into
`Attachment`s.

A filter names extensions, MIME types and uniform type identifiers together,
since each platform reads only its own field: the desktops the extension,
Android the MIME type, Apple's the UTI.

## The hand-offs

`FileHandoff` is what the workspace explorer does past showing a file, and
every route is gated the way `Shell.canRunCommands` gates the agent's
commands (see "The workspace explorer" in
`packages/entoli_core/lib/view/workspace/AGENTS.md`). Desktop and Android do
not differ in degree here, they differ in kind — and so each platform has its
own implementation, chosen at runtime in `platformFileHandoff`, because they
share `dart:io` and agree on nothing else here. Choosing rather than branching
is the point: a class that answered both would carry an
`if (Platform.isAndroid)` in every member, and every future member too.

- **Desktop** has a file manager and a registry of viewers, and `url_launcher`
  reaches both: `reveal` opens the current folder (the bar's button) and
  `open` opens a file, which is the same call on a different path. It needs no
  chooser of its own — the file manager is already pointed at the workspace —
  and it has no share sheet, so an entry there is only ever deleted.
- **iOS** opens a file as a desktop does, and its file manager is the Files app:
  `IosFileHandoff` sends `reveal` to the Runner, which opens Files at the folder
  through a File Provider. `fileManager` names it on the button, and is null on
  Android, which has no file manager to show a folder in. See "The workspaces in
  the Files app" in `ios/AGENTS.md`.
- **Android** has the share sheet, both ways. `export` sends an entry through
  `Intent.createChooser`, so every app on the device is on offer rather than a
  default winning silently; `open` is an `ACTION_VIEW`. Files come back in the
  same way, and only that way: another app shares to Entoli. It is not the only
  route out: a `DocumentsProvider` puts the workspaces in the Files app, for
  the other app to browse rather than be handed something (see "The workspaces
  in the Files app" in `android/AGENTS.md`). The other end of the channel,
  `agent_chat/files`, is `FilesChannel.kt` in the app's Android project.

A share sheet does not take a folder, so a folder goes as a single zip,
written straight to the staging directory by `zipTo` (`zip.dart`, the walker a
backup streams through too), which is what lets Android's staging directory
stay flat.

That staging directory is the other thing worth knowing about the Android half.
Everything handed to an intent is a **copy under the app's cache**, never the
workspace file itself, because a `FileProvider` only mints URIs under the paths
in `android/app/src/main/res/xml/file_paths.xml` and one `<cache-path>` is the
whole of that file. The alternative was a `<root-path>` exposing the data
directory by path for the sake of not copying, which is a worse trade on a
directory holding `settings.json` and every chat. It costs a copy per open;
workspace files are the agent's output, and the ones big enough to notice are
rare.

## A backup's way out

`BackupHandoff` is a save dialog and a chooser (see "Backing it all up" in
`lib/ui/settings/AGENTS.md`). `FileSelectorBackup` is the whole of it on the
desktops, `getSaveLocation` being a dialog there. Android is the exception and
`SharedBackup` is why: `file_selector` implements no save dialog there, so a
backup leaves through the share sheet, which is `FileHandoff`'s. An intent
carries a file rather than bytes, so the zip is written to the cache and
`FileHandoff` then stages a copy of its own under the one path a
`FileProvider` will mint URIs from — the archive is written twice, which is
what reusing that route out costs rather than opening a second one.
