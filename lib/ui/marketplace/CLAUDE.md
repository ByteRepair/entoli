# The marketplace page

`MarketplacePage` is what the sidebar's Marketplace tile opens: the site's
entries over Skills and Agents tabs. Tapping an entry opens
`MarketplaceEntryPreviewPage`, which previews and installs it.

The list is the site's `index.json` per section
(`byterepair.github.io/entoli-marketplace`, whose paths already carry
`Access-Control-Allow-Origin: *`, so a browser build can fetch it). The URL is
`marketplaceBaseUrl`, a const — promoted to a setting if it ever needs to be
one. The section path is `CompletionKind.folder`, which is `"skills"` /
`"agents"`, the site's own directory names: one fact, written once — and
anchored on the field's doc in `models.dart`, the place an edit would land.
Fetched beside it is `/ext/<folder>/index.json`, the site's record of where
every remote entry's files live, joined into the list by key.

Entry files fetch as `/{folder}/{slug}/{file}`; the skill package is the one
exception, fetched as `/{folder}/{slug}.skill` — its own function,
`fetchMarketplaceSkillPackage`, so the path shape is named rather than a
magic `.skill` file name the caller has to know — being the installable whole
of `data/skills/<slug>/`, which the build also serves file by file. The
package inside the entry's directory was the first shape, and it 404'd: the
install said "No installable package is served for this skill" for a package
that was live one path over.

An entry whose ext record joins it is **remote**: the site serves none of its
files. `MarketplaceLocation` carries what its record says — repo, the ref the
publish resolved, the entry directory's path in that repository, every blob
name under it — and the fetchers take it from there: each file from
`raw.githubusercontent.com` at the record's ref (a file the record does not
list is answered without a request), the package as its listed files fetched
and zipped here. The zip is built in the flat shape `parseSkillPackage` reads
a packaged directory out of, so a remote install walks the same intake a
local one does. A listing gone stale against its source — a listed file now
404s, the drift an unpinned ref is allowed — throws
`MarketplacePackageProblem`, rendered where the button would be: the page
itself read fine, there is just nothing to install. A site published before
remote entries had an ext index answers the ext fetch with a 404, which reads
as no locations, which is every entry local — the old behavior, unbroken.

`fetchMarketplaceEntries` is the whole read, and it throws on anything it
cannot do. What is absent in an entry's frontmatter — `version`, `tags` — is
null or empty here; nothing is invented for it. Entries are sorted by name,
the way the library below sorts its own. The meta line —
`author · v<version> · tags`, joined — is a getter on `MarketplaceEntry`,
read by the list's row and the preview's header alike, so the two renderings
cannot drift; the test asserts both.

`marketplaceEntriesProvider` is `autoDispose`, per tab: a reopen re-fetches
rather than showing what may have changed underneath it. The fetch rides
`marketplaceClientProvider` — declared in `lib/providers.dart` beside every
other must-override seam — an override in `main` and in every test, since the
package:http default is intercepted wholesale by the test binding (every
request a 400), and a bare `http.Client()` in the provider build would hide
the fake. The provider's **automatic retry is off** (`retry: (_, _) => null`):
a marketplace fetch fails on the network and the retry is the user's own
Try-again — Riverpod's automatic one schedules real timers and holds the
spinner up through ten rounds of backoff the user cannot see or stop, which
on a test's fake clock never fires at all.

The harness's `FakeNetwork` keys answers on `request.url.path`, which for a
host-with-directory URL is `/entoli-marketplace/skills/index.json` — the repo
prefix included. A test keys bodies through `indexPath(kind)` for that reason;
`/skills/index.json` alone is a path that nothing answers, and the failure it
produces reads as an unreachable marketplace rather than as a mistyped key.
`FakeNetwork({…}, missingAs404: true)` is the marketplace tests' form: a 404
is what the real site answers about a file an entry does not carry, and
`fetchMarketplaceEntryFile` turns it into a null the page reads as "none"
rather than as a failure — an agent's `profile.png` is there and then absent.

## From list to preview

`EntryPreview` is what the page fetched at open: the README, the parsed
`.skill` (or the parser's reason it refused one), the agent's prompt and its
picture. The fetches go out together — the entry's files are independent
round-trips to one host, and serially each is a round-trip on the spinner the
user is staring at.

A refused package is **shown where the button would be**, not taken as a
failure of the page: the parse runs at load — the same intake a picked
`.skill` file goes through — and its reason sits in the body. The install
button is `EntryPreview.installable(kind)`, one predicate the bar's guard and
either install's refusal both read, so a dead button is never shown for an
entry the press would refuse on, and never withheld from one it wouldn't. The
same holds for an agent whose PROMPT.md is missing or has nothing in it.

The preview loads in state like `SkillInstallPreviewPage` does rather than in
a `FutureProvider`, and for one reason beyond habit: the README is held as a
string and rendered in `_Body` at build — a load that started in `initState`
would reach `Theme.of` before the first build, the exception an inherited
widget read across the init gap throws.

The failure pane is `Unreachable`, one widget the list's tab and the preview
share, built on the shared `EmptyPane` (icon, title, the error as the detail
line, the Try-again action), so the feature has one rendering of "could not
reach" rather than two that drift, and carries the failure the page caught —
a timeout is not a 500.

## Installing

Both kinds land through the intake the app already has, and no second copy of
it was written.

**A skill is its `.skill`** — the site zips the whole directory
(`data/skills/<slug>/` including `references/` and `scripts/`) into
`_site/skills/<slug>.skill` at build time, one file per skill, served beside
the entry's directories. The page hands those bytes to `parseSkillPackage`
and `installSkillPackage` — the same call a picked `.skill` file and a
model-drafted one go through — under
`withWritableDir` over `promptsDir(skill, project)`, replace-confirm first
where the name is taken, `reloadAllPromptLibraries` after, snack last. The
parser strips the shallowest `SKILL.md`'s prefix, so the zip's top-level
folder is not load-bearing.

**An agent is the agents settings page's import shape**, aimed at the site's
files rather than a picked one (a remote one's raw files at its record, where
a listing not naming the file answers it without a request): UTF-8 decode,
`PromptDocument.parse`, refuse an empty body, `isFolderName` on the file name
— the slug for a local entry, an ext key's last segment for a remote one,
which is the remote directory's own, the name the marketplace says an agent
carries — replace-confirm, then one
`withWritableDir` block writing `agentFilePath` and, where served one,
`agentPicturePath` beside it. The picture's invalidation is the shared
`invalidateAgentPicture` (in `providers.dart`, under the provider itself):
a global write (destination null) lands in the default project's directory
that every project inherits from, so the whole `agentPictureProvider` family
is invalidated — the same answer a global agents page's write gives; a named
destination takes its own entry down.

The destination is `InstallDestination` at the body's end, `Global` default —
the same widget the skill-install preview page carries, so every install
route offers the same list.

The keep-alive mixin on `_EntryList` is worth saying why: TabBarView unmounts
the tab that has settled off-screen, and with the provider `autoDispose` that
unmounting disposed the fetch, so every flip re-ran the fetch and flashed the
spinner over a list the visit already had. `AutomaticKeepAliveClientMixin`
keeps both tabs mounted for the route's life; popping it disposes both, which
is the reopen-re-fetches rule, preserved.

Two shared widgets carry pieces of the rendering: the bottom bar is
`InstallBar` (lib/ui/widgets/install_bar.dart), the same button the
skill-install preview page shows, and the package-files list is
`PackageFileList` from the same file, which the skill view and the
skill-install preview also read — the skill view being the one that passes
`sizeOf` for its size column. Snackbar lines go through the shared `say`,
not a local messenger call.