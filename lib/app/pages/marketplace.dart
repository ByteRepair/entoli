import "dart:convert";
import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/agent_face.dart";
import "../../domain/app_link.dart" show SharedEntryLink;
import "../../domain/models.dart";
import "../../domain/project.dart" show projectLabel;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
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
    .family<List<MarketplaceEntry>, CompletionKind>((ref, kind) async {
      final client = ref.watch(marketplaceClientProvider);
      try {
        return await fetchMarketplaceEntries(client, kind);
      } catch (e) {
        // Once, where it is caught, rather than on every redraw of the error.
        logFailure("marketplace", "could not fetch ${kind.label}", e);
        rethrow;
      }
    }, retry: (_, _) => null);

/// The marketplace: what the site ships, Skills or Agents, the site's own
/// entries first and the remote ones under External, each alphabetical. A
/// search over the name and the description and a filter by tags narrow the
/// list in the order it is drawn; an entry opens its preview, where it is
/// installed. See `lib/ui/marketplace/AGENTS.md`.
class MarketplaceAppPage extends AppPage {
  CompletionKind _kind = CompletionKind.skill;
  String _query = "";

  /// The tags ticked per kind; an entry passes carrying every one.
  final _tagged = {for (final kind in CompletionKind.values) kind: <String>{}};

  @override
  String get address => "marketplace";

  @override
  String title(SettingReader reader) => "Marketplace";

  @override
  List<PageSection> sections(SettingReader reader) {
    final listed = reader.watch(marketplaceEntriesProvider(_kind));
    final tagged = _tagged[_kind]!;
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
        TextController(
          part("search", "Search", hint: UiHint.input),
          value: _query,
          prompt: "Search",
          allowBlank: true,
          onSet: (text) async {
            _query = text;
            changed();
            return null;
          },
        ),
        ActionController(
          part("tags", "Tags", hint: UiHint.open, glyph: SettingGlyph.tune),
          label: tagged.isEmpty ? "All" : "${tagged.length} ticked",
          enabled: listed.hasValue,
          run: () async {
            pages.open(
              MarketplaceTagsAppPage(
                kind: _kind,
                tags: tagsOf(listed.value!),
                ticked: tagged,
                onTicked: changed,
              ),
            );
            return null;
          },
        ),
      ]),
      ...switch (listed) {
        AsyncValue(hasValue: true, :final value?) => _lists(value, tagged),
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

  List<PageSection> _lists(List<MarketplaceEntry> all, Set<String> tagged) {
    if (all.isEmpty) {
      return [notice("empty", "The marketplace lists no ${_kind.folder} yet.")];
    }
    final shown = entriesMatching(all, _query, tagged);
    final groups = groupByOrigin(shown);
    SettingController list(String id, List<MarketplaceEntry> entries) =>
        CollectionController<MarketplaceEntry>(
          part(id, "Entries", hint: UiHint.info),
          items: entries,
          removable: false,
          emptyLabel: "Nothing matches here.",
          describe: (entry) => CollectionItem(
            entry.name,
            subtitle: [
              if (entry.description.isNotEmpty) entry.description,
              if (entry.metaLine.isNotEmpty) entry.metaLine,
            ].join("\n"),
            glyph: _kind == CompletionKind.skill
                ? SettingGlyph.skill
                : SettingGlyph.agent,
            editable: false,
            takesImage: false,
            tap: "open",
          ),
          act: (index, _) async {
            pages.open(
              MarketplaceEntryAppPage(kind: _kind, entry: entries[index]),
            );
            return null;
          },
        );
    return [
      PageSection("local", "", [list("local", groups.local)]),
      // A heading that separates nothing is no heading at all.
      if (groups.remote.isNotEmpty)
        PageSection("remote", externalHeading, [list("remote", groups.remote)]),
    ];
  }
}

/// A section's tags, each with how many entries carry it, ticked into the
/// list's own set so going back is already filtered.
class MarketplaceTagsAppPage extends AppPage {
  MarketplaceTagsAppPage({
    required this.kind,
    required this.tags,
    required this.ticked,
    required this.onTicked,
  });

  final CompletionKind kind;
  final List<(String, int)> tags;
  final Set<String> ticked;

  /// Told as a tag is ticked, so the list behind redraws.
  final void Function() onTicked;

  @override
  String get address => "marketplace-tags/${kind.name}";

  @override
  String title(SettingReader reader) => "Tags";

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("tags", "", [
      if (tags.isEmpty) noticeRow("none", "Nothing here carries a tag."),
      for (final (tag, count) in tags)
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
class MarketplaceEntryAppPage extends AppPage with InstallsPrompts {
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
    final preview = this.preview;
    if (_failure case final failure?) {
      return [failed("Could not reach the marketplace", failure, retry: _load)];
    }
    if (preview == null) {
      return [notice("loading", "Reading the entry…")];
    }
    final package = preview.package;
    return [
      PageSection("about", "", [
        InfoController(
          part("about", entry.name, hint: UiHint.info),
          rows: [
            InfoRow(
              entry.name,
              subtitle: [
                if (entry.description.isNotEmpty) entry.description,
                if (entry.metaLine.isNotEmpty) entry.metaLine,
              ].join("\n"),
              glyph: kind == CompletionKind.skill
                  ? SettingGlyph.skill
                  : SettingGlyph.agent,
            ),
          ],
        ),
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
