import "dart:convert";
import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/agent_face.dart";
import "../../domain/app_link.dart" show SharedEntryLink;
import "../../domain/chat_search.dart" show searchNeedle;
import "../../domain/models.dart";
import "../../domain/project.dart" show projectLabel;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../../domain/bot_avatar/spec.dart";
import "../marketplace/face.dart";
import "../marketplace/groups.dart";
import "../prompts/agent_files.dart";
import "../prompts/skill_files.dart";
import "../marketplace/marketplace.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// One section's list, fetched on first watch and fetched again on a reopen
/// rather than showing what may have changed underneath it. Riverpod's own
/// retry is off: the retry is the user's Try Again, not ten rounds of
/// backoff they cannot see or stop.
final marketplaceEntriesProvider = FutureProvider.autoDispose
    .family<MarketplaceListing, CompletionKind>((ref, kind) async {
      final client = ref.watch(marketplaceClientProvider);
      try {
        return await fetchMarketplaceEntries(client, kind);
      } catch (e) {
        // Once, where it is caught, rather than on every redraw of the error.
        logFailure("marketplace", "could not fetch ${kind.label}", e);
        rethrow;
      }
    }, retry: (_, _) => null);

/// The rows both marketplace lists draw: an entry opening its preview, and a
/// collection opening its page.
mixin ListsMarketplaceEntries on AppPage {
  /// The presets the rows' faces are picked from; none while they load, when
  /// the rows keep their glyphs.
  List<BotAvatarSpec> _presets = const [];

  /// Read once per build, before the lists.
  void watchFaces(SettingReader reader) =>
      _presets = reader.watch(botAvatarPresetsProvider).value ?? const [];

  RowFace? _face(String key) => switch (marketplaceFace(key, _presets)) {
    final spec? => AvatarRowFace(spec, animate: false),
    null => null,
  };

  SettingController entryList(
    CompletionKind kind,
    String id,
    List<MarketplaceEntry> entries,
  ) => CollectionController<MarketplaceEntry>(
    part(id, "Entries", hint: UiHint.info),
    items: entries,
    removable: false,
    emptyLabel: "Nothing matches here.",
    // The row is for scanning: who made it, the description cut short;
    // the rest is the preview's.
    describe: (entry) => CollectionItem(
      entry.name,
      byline: switch ([
        ?entry.byline,
        if (entry.version case final version?) "v$version",
      ]) {
        [] => null,
        final parts => parts.join(" · "),
      },
      subtitle: _short(entry.description),
      badge: entry.external ? _external : null,
      face: _face(entry.slug),
      // Native draws a glyph beside a face, so a face replaces it.
      glyph: _presets.isNotEmpty
          ? null
          : kind == CompletionKind.skill
          ? SettingGlyph.skill
          : SettingGlyph.agent,
      editable: false,
      takesImage: false,
      tap: "open",
    ),
    act: (index, _) async {
      pages.open(MarketplaceEntryAppPage(kind: kind, entry: entries[index]));
      return null;
    },
  );

  /// Collections as cards; [opens] false is a collection page's own header.
  SettingController collectionCards(
    CompletionKind kind,
    List<MarketplaceCollection> collections, {
    String id = "collections",
    bool opens = true,
  }) => CollectionController<MarketplaceCollection>(
    part(id, "Collections", hint: UiHint.cards),
    items: collections,
    removable: false,
    describe: (collection) => CollectionItem(
      collection.name,
      byline: _count(kind, collection.members.length),
      subtitle: collection.summary,
      badge: collection.external ? _external : null,
      face: _face(collection.slug),
      glyph: _presets.isNotEmpty ? null : SettingGlyph.folder,
      editable: false,
      takesImage: false,
      tap: opens ? "open" : null,
    ),
    act: (index, _) async {
      pages.open(
        MarketplaceCollectionAppPage(
          kind: kind,
          collection: collections[index],
        ),
      );
      return null;
    },
  );

  /// One entry as the head of its own page: its face, who made it, and
  /// whether it is another repository's.
  SettingController entryCard(MarketplaceEntry entry) =>
      CollectionController<MarketplaceEntry>(
        part("card", entry.name, hint: UiHint.cards),
        items: [entry],
        removable: false,
        describe: (entry) => CollectionItem(
          entry.name,
          byline: entry.byline,
          badge: entry.external ? _external : null,
          face: _face(entry.slug),
          glyph: _presets.isNotEmpty ? null : SettingGlyph.skill,
          editable: false,
          takesImage: false,
        ),
      );

  /// The Tags row, opening [kind]'s picker over [tags]; [scope] keeps a
  /// collection's picker apart from the front page's. Null where no tag
  /// would narrow the list.
  ActionController? tagsRow(
    CompletionKind kind,
    Set<String> ticked,
    List<(String, int)> tags, {
    String? scope,
  }) => tags.isEmpty && ticked.isEmpty
      ? null
      : ActionController(
          part("tags", "Tags", hint: UiHint.open, glyph: SettingGlyph.tune),
          label: ticked.isEmpty ? "All" : "${ticked.length} ticked",
          run: () async {
            pages.open(
              MarketplaceTagsAppPage(
                kind: kind,
                scope: scope,
                tags: tags,
                ticked: ticked,
                onTicked: changed,
              ),
            );
            return null;
          },
        );

  TextController searchRow(String query, void Function(String) onQuery) =>
      TextController(
        part("search", "Search", hint: UiHint.input),
        value: query,
        prompt: "Search",
        allowBlank: true,
        onSet: (text) async {
          onQuery(text);
          changed();
          return null;
        },
      );
}

/// [text] cut at a word to about two lines of a row.
String _short(String text, [int max = 140]) {
  if (text.length <= max) return text;
  final cut = text.lastIndexOf(" ", max);
  return "${text.substring(0, cut > max ~/ 2 ? cut : max).trimRight()}…";
}

/// What a row of another repository's says it is.
const _external = "External";

/// A heading with how many sit under it.
String _counted(String heading, int n) => "$heading · $n";

String _count(CompletionKind kind, int n) => switch (kind) {
  CompletionKind.skill => n == 1 ? "1 skill" : "$n skills",
  CompletionKind.agent => n == 1 ? "1 agent" : "$n agents",
};

/// The marketplace: what the site ships, Skills or Agents. The front page
/// lists the collections, then every entry in none, alphabetically; a search
/// over names and descriptions also reaches into the collections. An entry
/// opens its preview, where it is installed. See
/// `lib/app/marketplace/AGENTS.md`.
class MarketplaceAppPage extends AppPage with ListsMarketplaceEntries {
  CompletionKind _kind = CompletionKind.skill;
  String _query = "";

  /// The tags ticked per kind; a front-page entry passes carrying every one.
  final _tagged = {for (final kind in CompletionKind.values) kind: <String>{}};

  @override
  String get address => "marketplace";

  @override
  String title(SettingReader reader) => "Marketplace";

  @override
  List<PageSection> sections(SettingReader reader) {
    watchFaces(reader);
    final listed = reader.watch(marketplaceEntriesProvider(_kind));
    final tagged = _tagged[_kind]!;
    final grouped = switch (listed.value) {
      final listing? => groupIntoCollections(
        listing.entries,
        listing.collections,
      ),
      null => null,
    };
    return [
      PageSection("browse", "", [
        ChoiceController<CompletionKind>(
          part("kind", "Section", hint: UiHint.segmented),
          options: [
            for (final kind in CompletionKind.values)
              SettingOption(kind, kind.label),
          ],
          value: _kind,
          onSet: (kind) async {
            if (kind != null) _kind = kind;
            changed();
            return null;
          },
        ),
        searchRow(_query, (text) => _query = text),
      ]),
      ...switch (listed) {
        AsyncValue(hasValue: true, :final value?) => _lists(
          value.entries.isEmpty,
          grouped!,
          tagged,
        ),
        AsyncValue(:final error?) => [
          failed(
            "Could not reach the marketplace",
            error,
            retry: () async =>
                app.invalidate(marketplaceEntriesProvider(_kind)),
          ),
        ],
        _ => [notice("loading", "Reading the marketplace…")],
      },
    ];
  }

  List<PageSection> _lists(
    bool empty,
    (List<MarketplaceEntry>, List<MarketplaceCollection>) grouped,
    Set<String> tagged,
  ) {
    if (empty) {
      return [notice("empty", "The marketplace lists no ${_kind.folder} yet.")];
    }
    final (front, collections) = grouped;
    final shownFront = entriesMatching(front, _query, tagged);
    // The tags filter these entries alone, so they sit over them rather
    // than over the collections.
    PageSection frontSection(String heading) => PageSection("front", heading, [
      ?tagsRow(_kind, tagged, tagsOf(front)),
      entryList(_kind, "front", shownFront),
    ]);
    if (searchNeedle(_query).isEmpty) {
      return [
        if (collections.isNotEmpty)
          PageSection(
            "collections",
            _counted("Collections", collections.length),
            [collectionCards(_kind, collections)],
          ),
        // A heading that separates nothing is no heading at all.
        if (front.isNotEmpty)
          frontSection(
            collections.isEmpty ? "" : _counted(_kind.label, shownFront.length),
          ),
      ];
    }
    // A search reaches into the collections: a matching collection, and
    // the matching members of every one under its name.
    final matched = collectionsMatching(collections, _query);
    final members = [
      for (final collection in collections)
        if (entriesMatching(collection.members, _query, const {})
            case final hits when hits.isNotEmpty)
          (collection, hits),
    ];
    final nothing = shownFront.isEmpty && matched.isEmpty && members.isEmpty;
    return [
      if (nothing) notice("nomatch", "Nothing matches \"${_query.trim()}\"."),
      if (matched.isNotEmpty)
        PageSection("collections", _counted("Collections", matched.length), [
          collectionCards(_kind, matched),
        ]),
      // Kept while a tag is ticked, so the ticks can be undone.
      if (shownFront.isNotEmpty || tagged.isNotEmpty)
        frontSection(_counted(_kind.label, shownFront.length)),
      for (final (collection, hits) in members)
        PageSection(
          "in-${collection.slug}",
          _counted(collection.name, hits.length),
          [entryList(_kind, "in-${collection.slug}", hits)],
        ),
    ];
  }
}

/// One collection's members, searched and filtered by tag on their own.
/// Handed the members already fetched, so it fetches nothing.
class MarketplaceCollectionAppPage extends AppPage
    with ListsMarketplaceEntries {
  MarketplaceCollectionAppPage({required this.kind, required this.collection});

  final CompletionKind kind;
  final MarketplaceCollection collection;
  String _query = "";
  final _tagged = <String>{};

  @override
  String get address =>
      "marketplace-collection/${kind.name}/${collection.slug}";

  @override
  String title(SettingReader reader) => collection.name;

  @override
  String? subtitle(SettingReader reader) => "Marketplace · ${kind.label}";

  @override
  List<PageSection> sections(SettingReader reader) {
    watchFaces(reader);
    return [
      PageSection("about", "", [
        collectionCards(kind, [collection], id: "about", opens: false),
      ]),
      PageSection("browse", "", [
        searchRow(_query, (text) => _query = text),
        ?tagsRow(
          kind,
          _tagged,
          tagsOf(collection.members),
          scope: collection.slug,
        ),
      ]),
      PageSection("members", _count(kind, collection.members.length), [
        entryList(
          kind,
          "members",
          entriesMatching(collection.members, _query, _tagged),
        ),
      ]),
    ];
  }
}

/// A list's tags, each with how many entries carry it, ticked into the
/// list's own set so going back is already filtered, and searched by name.
class MarketplaceTagsAppPage extends AppPage {
  MarketplaceTagsAppPage({
    required this.kind,
    required this.tags,
    required this.ticked,
    required this.onTicked,
    this.scope,
  });

  final CompletionKind kind;
  final List<(String, int)> tags;
  final Set<String> ticked;

  /// The collection whose tags these are; null is the front page's.
  final String? scope;

  /// Told as a tag is ticked, so the list behind redraws.
  final void Function() onTicked;

  String _query = "";

  // Distinct per list: `open` raises a page already open at an address.
  @override
  String get address => switch (scope) {
    final scope? => "marketplace-tags/${kind.name}/$scope",
    null => "marketplace-tags/${kind.name}",
  };

  @override
  String title(SettingReader reader) => "Tags";

  @override
  List<PageSection> sections(SettingReader reader) {
    final needle = searchNeedle(_query);
    final shown = [
      for (final tag in tags)
        if (tag.$1.toLowerCase().contains(needle)) tag,
    ];
    return [
      PageSection("search", "", [
        TextController(
          part("search", "Search", hint: UiHint.input),
          value: _query,
          prompt: "Search tags",
          allowBlank: true,
          onSet: (text) async {
            _query = text;
            changed();
            return null;
          },
        ),
      ]),
      PageSection("tags", "", [
        if (tags.isEmpty)
          noticeRow("none", "No tag narrows this list.")
        else if (shown.isEmpty)
          noticeRow("nomatch", "No tag matches \"${_query.trim()}\"."),
        for (final (tag, count) in shown)
          ToggleController(
            part("tag-$tag", tag, hint: UiHint.toggle, description: "$count"),
            value: ticked.contains(tag),
            effective: ticked.contains(tag),
            onSet: (on) async {
              if (on ?? false) {
                ticked.add(tag);
              } else {
                ticked.remove(tag);
              }
              changed();
              onTicked();
              return null;
            },
          ),
      ]),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    if (ticked.isNotEmpty)
      ActionController(
        part("clear", "Clear"),
        run: () async {
          ticked.clear();
          changed();
          onTicked();
          return null;
        },
      ),
  ];
}

/// What a preview fetched at open: the README, the parsed `.skill` or why
/// the parser refused it, an agent's prompt and its picture.
class EntryPreview {
  const EntryPreview({
    this.package,
    this.packageProblem,
    this.prompt,
    this.promptSource,
    this.picture,
    this.readme,
  });

  final SkillPackage? package;

  /// Why there is nothing to install, shown where the button would be.
  final String? packageProblem;

  final PromptDocument? prompt;

  /// An agent's PROMPT.md as served, which is what is written.
  final String? promptSource;

  final Uint8List? picture;
  final String? readme;

  /// The one answer to whether Install is offered, which either install's
  /// refusal reads too.
  bool installable(CompletionKind kind) => switch (kind) {
    CompletionKind.skill => package != null,
    CompletionKind.agent =>
      promptSource != null && (prompt?.body.isNotEmpty ?? false),
  };
}

/// A link carrying an entry whole: the entry it names and its preview, with
/// nothing fetched. A link cut short on its way is said, with no Install.
(MarketplaceEntry, EntryPreview) sharedEntry(SharedEntryLink link) {
  final kind = link.kind;
  MarketplaceEntry entry(String name, String? description) => MarketplaceEntry(
    slug: name,
    name: name,
    description: description ?? "",
    author: "",
  );
  final shared = entry(link.name ?? "Shared ${kind.name}", null);
  final bytes = link.bytes;
  if (bytes == null) {
    return (
      shared,
      const EntryPreview(
        packageProblem:
            "This link is incomplete: it was cut short on its way here, so "
            "there is nothing to install. Ask for it again, or for the file.",
      ),
    );
  }
  switch (kind) {
    case CompletionKind.skill:
      try {
        final package = parseSkillPackage(bytes);
        return (
          entry(package.name, package.description),
          EntryPreview(package: package, readme: package.body),
        );
      } catch (e) {
        return (shared, EntryPreview(packageProblem: "$e"));
      }
    case CompletionKind.agent:
      final source = utf8.decode(bytes, allowMalformed: true);
      final prompt = PromptDocument.parse(kind, "", source);
      final name = link.name ?? prompt.frontmatter["name"];
      if (name == null) {
        return (
          shared,
          const EntryPreview(packageProblem: "The link names no agent."),
        );
      }
      return (
        entry(name, prompt.description),
        EntryPreview(prompt: prompt, promptSource: source, readme: prompt.body),
      );
  }
}

/// Where an install lands, and the install itself: Global or one of the
/// user's projects, a name taken there asked about first, the libraries
/// read again after.
mixin InstallsPrompts on AppPage {
  /// Null is the default project, "Global".
  String? destination;

  SettingController destinationField(SettingReader reader) {
    final projects =
        reader.watch(projectListProvider).value ?? const <String>[];
    return ChoiceController<String>(
      part("destination", "Install to", hint: UiHint.dropdown),
      options: [for (final p in projects) SettingOption(p, projectLabel(p))],
      value: destination,
      unsettable: true,
      inheritedLabel: "Global",
      onSet: (project) async {
        destination = project;
        changed();
        return null;
      },
    );
  }

  SettingConfirm? replacingSkill(SkillPackage package) {
    if (!SkillFiles(
      app.read(appConfigProvider),
    ).has(package.name, target: destination)) {
      return null;
    }
    return SettingConfirm(
      title: "Replace ${package.name}?",
      message:
          "A skill with that name is already installed there. Installing "
          "this one replaces it, files included.",
      confirmLabel: "Replace",
    );
  }

  Future<SettingNotice?> installSkill(SkillPackage package) async {
    final target = destination;
    await SkillFiles(
      app.read(appConfigProvider),
    ).install(package, target: target);
    await reloadAllPromptLibraries(app.read);
    pages.leave(
      this,
      saying: installedSnack("Installed", package.name, target),
    );
    return null;
  }

  /// What a package holds besides its SKILL.md.
  SettingController packageFiles(SkillPackage package) => InfoController(
    part("files", "Files", hint: UiHint.info),
    rows: [
      for (final (name, _) in package.entries)
        if (name != "SKILL.md") InfoRow(name, glyph: SettingGlyph.file),
    ],
  );
}

/// One marketplace entry before it is installed: who made it, what it says
/// of itself, what it holds, and where it goes. Fetched at open, or handed
/// whole by a link.
class MarketplaceEntryAppPage extends AppPage
    with InstallsPrompts, ListsMarketplaceEntries {
  MarketplaceEntryAppPage({
    required this.kind,
    required this.entry,
    this.preview,
  });

  final CompletionKind kind;
  final MarketplaceEntry entry;

  /// What was fetched, or what a link carried whole.
  EntryPreview? preview;
  String? _failure;

  @override
  String get address => "marketplace/${kind.name}/${entry.slug}";

  @override
  void opened() {
    if (preview == null) _load();
  }

  Future<void> _load() async {
    _failure = null;
    changed();
    final client = app.read(marketplaceClientProvider);
    try {
      // Together: each is a round trip to one host.
      final [readme, body, picture] = await Future.wait(<Future<Uint8List?>>[
        fetchMarketplaceEntryFile(client, kind, entry, "README.md"),
        switch (kind) {
          CompletionKind.skill => fetchMarketplaceSkillPackage(
            client,
            kind,
            entry,
          ),
          CompletionKind.agent => fetchMarketplaceEntryFile(
            client,
            kind,
            entry,
            "PROMPT.md",
          ),
        },
        kind == CompletionKind.skill
            ? Future<Uint8List?>.value()
            : fetchMarketplaceEntryFile(client, kind, entry, "profile.png"),
      ]);
      SkillPackage? package;
      String? problem;
      String? source;
      if (kind == CompletionKind.skill) {
        if (body == null) {
          problem = "No installable package is served for this skill.";
        } else {
          try {
            package = parseSkillPackage(body);
          } catch (e) {
            problem = "$e";
          }
        }
      } else if (body != null) {
        source = utf8.decode(body, allowMalformed: true);
      }
      preview = EntryPreview(
        readme: readme == null
            ? null
            : utf8.decode(readme, allowMalformed: true),
        package: package,
        packageProblem: problem,
        promptSource: source,
        prompt: source == null
            ? null
            : PromptDocument.parse(CompletionKind.agent, "", source),
        picture: picture,
      );
    } on MarketplacePackageProblem catch (e) {
      // The page read fine; there is just nothing to install.
      logFailure("marketplace", "${entry.slug}'s listing is stale", e);
      preview = EntryPreview(packageProblem: "$e");
    } catch (e) {
      logFailure("marketplace", "could not fetch ${entry.slug}'s preview", e);
      _failure = "$e";
    }
    changed();
  }

  @override
  String title(SettingReader reader) => entry.name;

  @override
  String? subtitle(SettingReader reader) => "Marketplace · ${kind.label}";

  @override
  List<PageSection> sections(SettingReader reader) {
    watchFaces(reader);
    final preview = this.preview;
    if (_failure case final failure?) {
      return [failed("Could not reach the marketplace", failure, retry: _load)];
    }
    if (preview == null) {
      return [notice("loading", "Reading the entry…")];
    }
    final package = preview.package;
    final details = _details();
    return [
      PageSection("about", "", [
        entryCard(entry),
        if (preview.packageProblem case final problem?)
          noticeRow("problem", problem, tone: NoticeTone.warning),
        if (kind == CompletionKind.agent &&
            preview.packageProblem == null &&
            !preview.installable(kind))
          noticeRow(
            "noPrompt",
            "This agent cannot be installed: there is no prompt in it.",
            tone: NoticeTone.warning,
          ),
      ]),
      if (entry.description.isNotEmpty)
        PageSection("description", "Description", [
          NoticeController(
            part("description", "", hint: UiHint.paragraph),
            lines: [NoticeLine(entry.description)],
          ),
        ]),
      if (details.isNotEmpty) PageSection("details", "Details", details),
      if (preview.readme case final readme? when readme.trim().isNotEmpty)
        PageSection("readme", "README", [
          DocumentController(
            part("readme", "README"),
            text: readme,
            name: "README.md",
          ),
        ]),
      if (package != null)
        PageSection("files", "Files", [packageFiles(package)]),
      if (preview.installable(kind))
        PageSection("install", "", [destinationField(reader)]),
    ];
  }

  /// What is known of the entry, a labelled row each; an entry a link
  /// carried knows little.
  List<SettingController> _details() {
    NoticeController field(String id, String label, String value) =>
        NoticeController(
          part(id, label, hint: UiHint.field),
          lines: [NoticeLine(value)],
        );
    final authors = entry.authors;
    return [
      if (authors.isNotEmpty)
        field(
          "author",
          authors.length == 1 ? "Author" : "Authors",
          authors.join(", "),
        ),
      if (entry.version case final version?)
        field("version", "Version", version),
      if (entry.tags.isNotEmpty) field("tags", "Tags", entry.tags.join(", ")),
      if (entry.location case final location?)
        InfoController(
          part("source", "Source", hint: UiHint.info),
          rows: [
            InfoRow(
              "Source",
              subtitle: "${location.repo}/${location.dir}",
              glyph: SettingGlyph.globe,
              link: location.page,
            ),
          ],
        ),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) {
    final preview = this.preview;
    if (preview == null || !preview.installable(kind)) return const [];
    return [
      ActionController(
        part("install", "Install"),
        confirm: () async => switch (kind) {
          CompletionKind.skill => replacingSkill(preview.package!),
          CompletionKind.agent => _replacingAgent(),
        },
        run: () async {
          try {
            return switch (kind) {
              CompletionKind.skill => await installSkill(preview.package!),
              CompletionKind.agent => await _installAgent(preview),
            };
          } catch (e) {
            logFailure("marketplace", "could not install ${entry.slug}", e);
            return SettingNotice("Installing failed: $e");
          }
        },
      ),
    ];
  }

  SettingConfirm? _replacingAgent() {
    final name = entry.installName;
    if (!isFolderName(name)) {
      return const SettingConfirm.note(
        "This agent cannot be installed: its name cannot be a file name.",
      );
    }
    if (!AgentFiles(
      app.read(appConfigProvider),
      project: destination,
    ).has(name)) {
      return null;
    }
    return SettingConfirm(
      title: "Replace $name?",
      message:
          "An agent with that name is already installed. Installing this one "
          "replaces it.",
      confirmLabel: "Replace",
    );
  }

  /// The settings' import shape, aimed at the site's files: the face goes
  /// with it, or none, so an agent installed over another does not keep the
  /// face of the one it replaced.
  Future<SettingNotice?> _installAgent(EntryPreview preview) async {
    final name = entry.installName;
    final target = destination;
    final picture = preview.picture;
    await AgentFiles(app.read(appConfigProvider), project: target).write(
      name,
      preview.promptSource!,
      face: picture == null ? null : AgentPhoto(picture),
    );
    await reloadAllPromptLibraries(app.read);
    pages.leave(this, saying: installedSnack("Installed", name, target));
    return null;
  }
}

/// A skill a turn drafted, before it is installed: its SKILL.md, what else
/// it holds, and where it goes.
class SkillInstallAppPage extends AppPage with InstallsPrompts {
  SkillInstallAppPage({required this.chatId, required this.installId});

  final String chatId;
  final String installId;

  SkillPackage? _package;
  bool _loading = true;

  @override
  String get address => "skill-install/$chatId/$installId";

  @override
  void opened() => _load();

  Future<void> _load() async {
    try {
      final bytes = await app
          .read(chatStoreProvider)
          .readSkillInstall(chatId, installId);
      if (bytes != null) {
        _package = parseSkillPackage(Uint8List.fromList(bytes));
      }
    } catch (_) {
      _package = null;
    }
    _loading = false;
    changed();
  }

  @override
  String title(SettingReader reader) => _package?.name ?? "Install Skill";

  @override
  List<PageSection> sections(SettingReader reader) {
    final package = _package;
    if (_loading || package == null) {
      return [
        notice(
          "state",
          _loading
              ? "Reading the skill…"
              : "The skill package could not be read. It may have been "
                    "deleted with the chat.",
        ),
      ];
    }
    return [
      if (package.description case final description?
          when description.isNotEmpty)
        notice("about", description),
      PageSection("skill", "SKILL.md", [
        DocumentController(
          part("body", "SKILL.md"),
          text: package.body,
          name: "SKILL.md",
        ),
      ]),
      PageSection("files", "Files", [packageFiles(package)]),
      PageSection("install", "", [destinationField(reader)]),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    if (_package case final package?)
      ActionController(
        part("install", "Install"),
        confirm: () async => replacingSkill(package),
        run: () => installSkill(package),
      ),
  ];
}
