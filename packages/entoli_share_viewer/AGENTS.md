# The shared-chat viewer

A web page for a chat shared as a link (see "A shared chat" in
`lib/ui/chat/AGENTS.md`), for where the app is not installed: the conversation
read-only, as the app draws it. It is the app's own code, the chat package
(`entoli_chat`, see "The chat package" in the root `AGENTS.md`), with its ports
bound to this page's few — not a second drawing of the conversation. It does
not depend on the app, so none of the app's plugins or assets are in it.

Build it in the `flutter-dev` toolbox from this directory with
`flutter build web --release`; `build/web/` is static files. Nothing deploys
it yet. Open it with a share link's fragment on the URL. The renderer loads
from Flutter's CDN, so `build/web/canvaskit/` is never fetched.

## How a link becomes a page

`main.dart` does it in order:

- **`setUrlStrategy(null)`.** The chat is the fragment, and Flutter's default
  hash routing would rewrite it to `#/`. The URL stays what was opened.
- **`useMemoryFileSystem`** (`memory_io.dart`). A browser has no disk, and
  `lib/` reads its files through `dart:io` with no port over it, so the whole
  process gets `IOOverrides` over `package:file`'s `MemoryFileSystem`. The
  app's readers, `FileChatStore` and the migration chain run unchanged over it.
- **`unpackShare`** into `/entoli`, then `AppConfig.load`, which migrates a
  link from an older build. A fragment that is not a whole zip, or not a chat,
  is the "incomplete" page.
- **The overrides.** The drawing's ports (`transcriptOverrides`), and in place
  of the app's:
  - `SharedChatHost` — the chat as loaded, never running: the plan, the
    sub-agents' transcripts and the attachments read from the store; no
    agent pictures and no job logs, a job having ended where it was shared.
  - `SharedChatHandOff` — a detail opens as in the app; a text file in
    `TextFilePage` read-only, any other file downloaded; the plan on
    `PlanPage`. A skill to install and the agent's browser say they open in
    Entoli.
  - `WebFileHandoff` and `WebLinkOpener` (`web_hand_offs.dart`) — a file is
    downloaded as a blob; a web link opens in a new tab, and an artifact is
    its entry file in a new tab, so the files beside it that it loads do not
    come with it.

`SharedChatPage` is the bar and a `ConversationView` with nothing under it:
the chapter rail and jump to latest as in the app. The bar has the plan, the
workspace in the explorer's `readOnly` mode, **Open in Entoli**
(`entoli://share?def=` with the same fragment, which imports it) and **Get
Entoli**, the product page.

## Tests

`test/` runs on the VM, not in a browser, over the same in-memory filesystem:
a link unpacked with nothing written to disk, an older stamp migrated, what
the host reads and what the hand-off opens. `IOOverrides` reach only the
isolate that set them, which is why the app reads a share's files before
handing the compressing to `compute`. The web hand-offs need a browser and are
not tested.
