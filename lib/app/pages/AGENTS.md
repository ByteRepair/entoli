# The app's pages

Every page of the app's that is not a setting is an `AppPage` here: a
chat's settings and a new chat's, the context, the plan, a workspace folder
and a text file, a project's settings and its skills and agents, the
memories, the profile, the marketplace and an entry's preview, a drafted
skill's install, a Bot Avatar a link carried, a share's destination, a CLI's
sign-in, adding a model by its link, the first launch's setup and the
welcome tour, a web page and an artifact. Each frontend draws them; none
holds a page of its own. This is "Settings as data" (see
`lib/ui/settings/AGENTS.md`) taken to the rest of the app, and it is built on
the same pieces.

**A page is its sections of the settings' controllers.** `sections` returns
`PageSection`s of `SettingController`s — the toggles, choices, collections,
forms, notices, info rows and actions settings are made of — read through a
`SettingReader`, so what it watches redraws it; `toolbar` is its bar's
actions, the first its own (Save, Done, Install); `leaving` is what going
back asks, null to go. A part of a page is built with `part`, whose id is
`page:<address>/<part>` — what an intent names the controller by. Where a
row is a setting's own — Running commands on a chat's page, a project's
permissions and sandbox — `shared` builds that spec at the page's level,
under the page's id, so its rules and its words are said once; and
`settingsPage` is a whole settings page at a level, a project's skills or
agents. Two kinds were added for these pages: `DocumentController`, a
file's text as the whole of a page, edited in place with each edit said back,
and `WebController`, a web page. A `CollectionItem`'s `RowFace` says who
leads its row: an agent in their face, or a Bot Avatar of its own.

A few pieces keep the look the pages had before they were data.
`PromptController` is prose the model reads — the profile's instructions —
previewed as markdown, a tap opening `PromptAppPage` over the page: the
text as a `DocumentController` being edited, Save handing it back to the
page's draft. An `ItemMeter` with `segments` is one bar of parts end to end
with a legend and a `MeterMark` across it: the context page's window. A bar
action with a glyph is drawn as its icon, `SettingGlyph.check` as the page's
tick; a `CollectionController` with an `addGlyph` is added to from the bar
rather than a row under it (a folder's New Folder); an `iconOnly` action is
its glyph alone on its row (a chat's Copy ID).

Neither frontend has a code editor for free. Flutter's is `re_editor`'s; the
native shell's is `CodeEditor.swift`, TextKit 1 on both platforms, with a
gutter numbering the line fragments, the caret's line lit, wrap (macOS only:
`UITextView` scrolls one way) and zoom in the page's menu, and colours from
the core's grammar for the file, asked through `DocumentIntents.highlight`
once the typing pauses.

**The stack is the core's.** `AppPages` (`appPagesProvider`) holds the pages
open, the first at the bottom: `open` puts one over the others (one already
open comes to the top), `close` takes it and those over it, and `leave` is a
page closing itself, `saying` what it did — said in passing by the frontend,
the page that would have said it gone. A page is handed `app`, the app as it
reads it outside a pass, and `pages`, its stack, as it opens; `opened` is
where it starts what it loads and `changed` says what it draws moved where no
watch would. A page reads its stack through `pages`, never through `app`: the
stack's own ref reading the stack is the dependency Riverpod refuses.

Every caller opens a page the same way, `openAppPage(context, page)`
(`lib/ui/app_pages.dart`), whichever frontend is up, and `openFirstRun` opens
the first launch's setup and tour as both frontends start.

**The Flutter frontend** follows the stack in `AppPagesFollower`, mounted in
`AppShell`: a page opened is pushed as an `AppPageView`, one closed is taken
off, one the user backs out of is closed, its `leaving` asked first. The view
draws the sections with `SettingRow`, the bar's actions as text buttons, and a
lone document or web page as the whole body.

**The native shell** sends the stack over the settings contract
(`NativeSettings.appPages`, `SettingsPageKey.app` and the page's `address`),
encoded by the same `_Encoder` that sends the settings, and answers its rows'
intents by id through `SettingsBridge`; `leavePage` asks what leaving asks
and `closePage` closes. The Swift (`Settings/AppPages.swift`) draws the stack
as one sheet over the window, a navigation stack whose path is the stack —
over the settings sheet on iOS while it is up — each page with the settings'
own row views, its bar's actions in the toolbar, and a guarded page left by
its own Cancel.

Tests drive a page through `PageDriver` (`test/app/pages/page_driver.dart`):
opened on a real container, its sections built inside a provider as the shell
builds them, and its changes waited on through the stack's notices.
