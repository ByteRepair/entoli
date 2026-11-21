# The app's pages

Every page of the app's that is not a setting is an `AppPage` here: a
chat's settings and a new chat's, the context, the plan, a workspace folder
and a text file, a project's settings and its skills and agents, the
memories, the profile, the marketplace and an entry's preview, a drafted
skill's install, a Bot Avatar a link carried, a share's destination, a CLI's
sign-in, adding a model by its link, the first launch's setup and the
welcome tour, a web page and an artifact. The UI draws them and holds no
page of its own. This is "Settings as data" (see
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
leads its row: an agent in their face, or a Bot Avatar of its own, live or
still (`animate`, `botLive` on the wire). An item's `byline` is a short
line under its title, set apart from its subtitle: who made it, or how much it
holds. A collection with `UiHint.cards` is
drawn as a grid of cards instead of rows, each its face, title, byline,
subtitle (three lines at most) and its badge as a pill in the corner, a tap
running the item's `tap`: Flutter's `_Cards`
in `schema_view.dart`, up to three across, and native's `CardsRow`, an adaptive
`LazyVGrid` of glass surfaces. The marketplace's collections are the first.

A few pieces keep the look the pages had before they were data.
`PromptController` is prose the model reads — the profile's instructions —
previewed as markdown, a tap opening `PromptAppPage` over the page: the
text as a `DocumentController` being edited, Save handing it back to the
page's draft. An `ItemMeter` with `segments` is one bar of parts end to end
with a legend and a `MeterMark` across it: the context page's window. A bar
action with a glyph is drawn as its icon. The page's own action is the
first in its bar unless that one is `secondary`, and is drawn last in the
bar. An action with `adds` opens the new-item form of the
collection it names instead of running, which is how a folder's New Folder
sits in the bar; an `iconOnly` action is its glyph alone on its row (a
chat's Copy ID). Anything a tap runs is a `Pressable`. A section's `footnote` is said
under its rows, its `detail` over them.

The code editor is `re_editor`'s.

**The stack is the core's.** `AppPages` (`appPagesProvider`) holds the pages
open, the first at the bottom: `open` puts one over the others (one already
open comes to the top), `close` takes it and those over it, and `leave` is a
page closing itself, `saying` what it did — said in passing, the page that
would have said it gone. A page is handed `app`, the app as it
reads it outside a pass, and `pages`, its stack, as it opens; `opened` is
where it starts what it loads and `changed` says what it draws moved where no
watch would. A page reads its stack through `pages`, never through `app`: the
stack's own ref reading the stack is the dependency Riverpod refuses.

Every caller opens a page the same way, `openAppPage(context, page)`
(`lib/ui/app_pages.dart`), and `openFirstRun` opens the first launch's setup
and tour as the app starts.

The UI follows the stack in `AppPagesFollower`, mounted in
`AppShell`: a page opened is pushed as an `AppPageView`, one closed is taken
off, one the user backs out of is closed, its `leaving` asked first. The view
draws the sections with `SettingRow`, the bar's actions as text buttons, and a
lone document or web page as the whole body.

Tests drive a page through `PageDriver` (`test/app/pages/page_driver.dart`):
opened on a real container, its sections built inside a provider, and its changes waited on through the stack's notices.
