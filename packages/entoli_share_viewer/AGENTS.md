# The shared-chat viewer

A web page for a chat shared as a link (see "A shared chat" in
`lib/ui/chat/AGENTS.md`), for where the app is not installed: the conversation
read-only, as the app draws it. It is the app's own code, the core
(`entoli_core`, see "The core" in the root `AGENTS.md`), with its ports
bound to this page's few — not a second drawing of the conversation. It does
not depend on the app, so none of the app's plugins or assets are in it.

Build it in the `flutter-dev` toolbox from this directory with
`flutter build web --release`; `build/web/` is static files, which
`share-viewer.yml` deploys (see "The share viewer" in
`.github/workflows/AGENTS.md`). Open it with a share link's fragment on the URL. The renderer loads
from Flutter's CDN, so `build/web/canvaskit/` is never fetched.

## How a link becomes a page

`main.dart` does it in order:

- **`setUrlStrategy(null)`.** The chat is the fragment, and Flutter's default
  hash routing would rewrite it to `#/`. The URL stays what was opened.
- **A `MemoryFileSystem`**, since a browser has no disk. The core is handed
  its filesystem, so the app's readers, `FileChatStore` and the migration
  chain run over this one unchanged.
- **`unpackShare`** into its `/entoli`, whose `AppConfig.load` migrates a link
  from an older build and is the config the viewer runs on. A fragment that
  is not a whole zip, or not a chat, is the "incomplete" page.
- **The overrides.** The drawing's ports (`transcriptOverrides`), the
  filesystem (`fileSystemProvider`), and in place of the app's:
  - `SharedChatHost` — the chat as loaded, never running: the plan, the
    sub-agents' transcripts and the attachments read from the store; no
    agent pictures and no job logs, a job having ended where it was shared.
  - `SharedChatHandOff` — a `PageHandOff`, so a detail, the plan and an
    artifact open as in the app; a text file in `TextFilePage` read-only, any
    other file downloaded. A skill to install and the agent's browser say, in
    a notice, that they open in Entoli.
  - `WebFileHandoff` and `WebLinkOpener` (`web_hand_offs.dart`) — a file is
    downloaded as a blob; a web link opens in a new tab, and an artifact is
    its entry file in a new tab, so the files beside it that it loads do not
    come with it. The entry file is a sandboxed frame's `srcdoc` there, not a
    blob: a blob URL runs as the viewer's origin, with the viewer as its
    opener, and the page is a stranger's.

`SharedChatPage` is the bar and a `ConversationView` with nothing under it:
the chapter rail and jump to latest as in the app. The bar has the plan, the
workspace (the host's `workspaceDir`) in the explorer's `readOnly` mode, **Open in Entoli**
(`entoli://share?def=` with the same fragment, which imports it) and **Get
Entoli**, the product page.

## Tests

`test/` runs on the VM, not in a browser, over the same in-memory filesystem:
a link unpacked with nothing written to disk, an older stamp migrated, what
the host reads and what the hand-off opens, and that the disk is left alone.
The web hand-offs need a browser and are not tested.
