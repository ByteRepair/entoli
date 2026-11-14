# The marketplace page

`MarketplaceAppPage` (`lib/app/pages/marketplace.dart`, an `AppPage` both
frontends draw) is what the sidebar's Marketplace tile opens: the site's
entries, Skills or Agents picked above them. Tapping an entry opens
`MarketplaceEntryAppPage`, which previews and installs it.

The list is organized, and the organizing is `groups.dart`, pure
and tested on its own. **Collections** come first: `/<folder>/collections.json`
(`{slug: {name, summary, members}}`, the marketplace build's) names each one
and its members by index key — an ext manifest's sub-entries, or a group the
marketplace declares in `collections/<folder>.toml` — and a listed entry is
that collection's rather than a front-page row. Membership is the list and
nothing else, so a site from before the file (a 404, read as no records)
leaves every entry on the front page as it was, and a key the index no
longer has drops out. A collection row opens `MarketplaceCollectionAppPage`,
the members already fetched, with a search and tags of its own, its address
scoped by slug, since `open` raises a page already open at an address. With
a query the front page also shows the matching collections and, under each
collection's name, its matching members, so a search finds a skill wherever
it is filed. **The front page's tags filter its own entries only**, so their
row heads the entries' section, under the collections rather than over them,
and stays there while a tick is set even if a search empties it. A tag every
entry of a list carries narrows nothing and is not offered (`tagsOf`), which
is what keeps `external` off a collection of remote entries; a list no tag
narrows has no Tags row. A search row searches — name and description alike, over the entries the fetch already
holds, nothing re-read off disk; the needle is the sidebar's
`searchNeedle` (`domain/chat_search.dart`), the one shared rule for what a typed query compares as, and
the lowercased name and description the match reads are `late final` on the
entry, once per entry rather than once per keystroke — and the Tags row
opens the section's tag picker. Both filter the list in the order it is drawn
rather than re-ordering it — a description-only match keeps the alphabetical
row it belongs in. The ticks are a **per-section** set the page owns — the
picker page (`MarketplaceTagsAppPage`) ticks into it, so going back is
already filtered — and passing means carrying **every** tag ticked: the
intersection, where an empty set filters nothing. Search and tags hold
together, and a no-match result says "Nothing matches here.", distinct from
the empty-index line. The picker lists the section's tags with each one's
entry count under a search of its own, and Clear when anything is ticked.

**Every row wears a Bot Avatar picked from its key** (`face.dart`): the
preset at `hashString(key) % presets.length`, coloured `ownColour(key)`, so a
row looks the same on every device with nothing fetched. It follows the
bundled presets' order, so reordering them changes every row's face; that is
accepted. The faces are stills (`AvatarRowFace(animate: false)`, `botLive` on
the wire): a collection of hundreds of live faces is a ticker per row. Until
the presets load the rows keep their glyph, and a row with a face has none,
since the native row draws both.

The list is the site's `index.json` per section
(`byterepair.github.io/entoli-marketplace`). The URL is
`marketplaceBaseUrl`, a const — promoted to a setting if it ever needs to be
one. The section path is `CompletionKind.folder`, which is `"skills"` /
`"agents"`, the site's own directory names: one fact, written once — and
anchored on the field's doc in `models.dart`, the place an edit would land.
Fetched beside it is `/ext/<folder>/index.json`, the site's record of where
every remote entry's files live, joined into the list by key, and
`collections.json`, in the same wait, so one provider has one loading and one
error state.

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
the way the library below sorts its own. The list's row is for scanning:
its byline (`CollectionItem.byline`) says who made it and the version, the
description is cut at a word near 140 characters, and **an entry another
repository serves is badged External** (`MarketplaceEntry.external`, a
location record), as is a collection whose every member is. A remote entry's
author is up to ten contributors, so the byline names the first and counts
the rest; the preview lists them all. Collections are drawn as cards
(`UiHint.cards`), their count as the byline, and a collection's page opens on
its own card; headings say how many sit under them, and a search that finds
nothing names what was typed.

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

The preview opens on the entry's own card — face, byline, External — and
keeps what it says apart: the description as a paragraph of its own, then
Details, a labelled row each for the authors, the version and the tags, and
for a remote entry its source directory on GitHub as a link. They were one
info row's subtitle once, joined by line breaks, which read as one block.

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

The preview loads when its page opens and holds what it fetched, as the
skill-install page does. A failure to reach the site is said with what was
caught — a timeout is not a 500 — beside Try Again, on the list and on the
preview alike.

## Installing

Both kinds land through the intake the app already has, and no second copy of
it was written.

**A skill is its `.skill`** — the site zips the whole directory
(`data/skills/<slug>/` including `references/` and `scripts/`) into
`_site/skills/<slug>.skill` at build time, one file per skill, served beside
the entry's directories. The page hands those bytes to `parseSkillPackage`
and `installSkillPackage` — the same call a picked `.skill` file and a
model-drafted one go through — under
`ReadOnlyDir.write` over `promptsDir(skill, project)`, replace-confirm first
where the name is taken, `reloadAllPromptLibraries` after, snack last. The
parser strips the shallowest `SKILL.md`'s prefix, so the zip's top-level
folder is not load-bearing.

**An agent is the agents settings page's import shape**, aimed at the site's
files rather than a picked one (a remote one's raw files at its record, where
a listing not naming the file answers it without a request): UTF-8 decode,
`PromptDocument.parse`, refuse an empty body, `isFolderName` on the file name
the entry carries — `installName`, the slug for a local entry, an ext key's
last segment for a remote one, whose remote directory is what the
marketplace names an agent by — replace-confirm, then one
`ReadOnlyDir.write` block writing `agentFilePath` and the face through
`writeAgentFace` — the entry's picture where it serves one, none where it
does not, so an agent installed over another does not keep the face of the
one it replaced. The library reload after it is what refreshes the face:
`agentPictureProvider` watches the project's library.

The destination is the page's last row, `Global` default — `InstallsPrompts`,
the mixin the skill-install page shares, so every install route offers the
same list, asks the same replace question and lands the same way. Install is
the page's bar action; what it says once the page has closed goes through
the stack's `saying`.