import "dart:convert";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../core/log.dart";
import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/agent_pictures.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/agent_picture.dart";
import "../widgets/dialogs.dart";
import "../widgets/install_destination.dart";
import "../widgets/nothing.dart";
import "unreachable.dart";
import "marketplace.dart";

/// Everything one entry is previewed and installed with, fetched at open:
/// the README, and the bytes an Install puts somewhere — a skill's whole
/// `.skill` package, or an agent's prompt and its picture. A null member is a
/// file the entry does not carry (`profile.png` most often), which is an
/// answer rather than a failure.
class EntryPreview {
  const EntryPreview({
    this.package,
    this.packageProblem,
    this.prompt,
    this.promptSource,
    this.picture,
    this.readme,
  });

  /// The skill's whole package, parsed by the same intake a picked `.skill`
  /// file goes through — null where it is absent or refused, which
  /// [packageProblem] says. Null for an agent.
  final SkillPackage? package;

  /// Why [package] is null: "no package served", or the parser's own reason
  /// where it refused one. Also the press's refusal line, so the rule and
  /// its saying are written once. Null for an agent.
  final String? packageProblem;

  /// The agent's prompt, parsed but not written. Null for a skill.
  final PromptDocument? prompt;

  /// The agent's PROMPT.md as it arrived, which is what an install writes —
  /// the file is the agent, not a rendering of one.
  final String? promptSource;

  /// The agent's picture, where it carries one. Null for a skill, and for an
  /// agent without a `profile.png`.
  final Uint8List? picture;

  /// The README as text, drawn by the page the way a reply is. Null where the
  /// entry ships none.
  final String? readme;

  /// Where the bottom bar's Install should be live: there must be something
  /// the press can actually put somewhere. Read by the bar's guard and by
  /// either install's refusal — one predicate, so the button cannot be shown
  /// for an entry the press would then refuse on.
  bool installable(CompletionKind kind) => switch (kind) {
        CompletionKind.skill => package != null,
        CompletionKind.agent =>
          promptSource != null && (prompt?.body.isNotEmpty ?? false),
      };
}

/// One entry of the marketplace, previewed and installed. Pushed from the
/// list's row, which already holds [entry] — the page is about what the index
/// could not carry. Installing lands through the same doors the settings
/// pages' import flows use: a skill through its `.skill` package
/// (`parseSkillPackage` / `installSkillPackage`), an agent the way an
/// imported `.md` lands.
class MarketplaceEntryPreviewPage extends ConsumerStatefulWidget {
  const MarketplaceEntryPreviewPage({
    super.key,
    required this.kind,
    required this.entry,
  });

  final CompletionKind kind;
  final MarketplaceEntry entry;

  @override
  ConsumerState<MarketplaceEntryPreviewPage> createState() =>
      _MarketplaceEntryPreviewPageState();
}

class _MarketplaceEntryPreviewPageState
    extends ConsumerState<MarketplaceEntryPreviewPage> {
  EntryPreview? _preview;
  bool _failed = false;
  bool _installing = false;

  /// Where Install puts the entry: null is the default project, the way a
  /// project is named everywhere. The dropdown beside Install picks it.
  String? _destination;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final client = ref.read(marketplaceClientProvider);
    final kind = widget.kind;
    final slug = widget.entry.slug;
    try {
      // The entry's files are independent round-trips to one host, so they
      // go out together: serially this is one round-trip apiece on the
      // spinner the user is staring at.
      final answers = await Future.wait(<Future<Uint8List?>>[
        fetchMarketplaceEntryFile(client, kind, slug, "README.md"),
        fetchMarketplaceEntryFile(
            client,
            kind,
            slug,
            switch (kind) {
              // The package sits beside the entry's directory on the site,
              // which fetchMarketplaceEntryFile's `.skill` file name spells.
              CompletionKind.skill => ".skill",
              CompletionKind.agent => "PROMPT.md",
            }),
        // A skill has no third file; an agent's picture is there or not.
        kind == CompletionKind.skill
            ? Future<Uint8List?>.value()
            : fetchMarketplaceEntryFile(client, kind, slug, "profile.png"),
      ]);
      final readmeBytes = answers[0];
      final bodyBytes = answers[1];
      final picture = answers[2];
      // Only a skill parses an intake package out of the body, and only an
      // agent holds its prompt's source for the install to write.
      SkillPackage? package;
      String? problem;
      String? promptSource;
      PromptDocument? prompt;
      if (kind == CompletionKind.skill) {
        if (bodyBytes == null) {
          problem = "No installable package is served for this skill.";
        } else {
          try {
            package = parseSkillPackage(bodyBytes);
          } catch (e) {
            problem = "$e";
          }
        }
      } else {
        promptSource =
            bodyBytes == null ? null : utf8.decode(bodyBytes, allowMalformed: true);
        prompt = promptSource == null
            ? null
            : PromptDocument.parse(CompletionKind.agent, "", promptSource);
      }
      if (mounted) {
        setState(() {
          _preview = EntryPreview(
            readme: readmeBytes == null
                ? null
                : utf8.decode(readmeBytes, allowMalformed: true),
            package: package,
            packageProblem: problem,
            prompt: prompt,
            promptSource: promptSource,
            picture: picture,
          );
          _failed = false;
        });
      }
    } catch (e) {
      logFailure("marketplace", "could not fetch $slug's preview", e);
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      final landed = switch (widget.kind) {
        CompletionKind.skill => await _installSkill(),
        CompletionKind.agent => await _installAgent(),
      };
      if (!mounted) return;
      if (landed != null) {
        _say(installedSnack("Installed", landed, _destination));
        Navigator.of(context).pop();
      }
    } catch (e) {
      logFailure("marketplace", "could not install ${widget.entry.slug}", e);
      _say("Installing failed: $e");
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// The name that landed, or null where the user said no or there is
  /// nothing installable. The parse ran at load — the same intake a picked
  /// `.skill` file goes through — and [EntryPreview.packageProblem] already
  /// holds what a refusal says.
  Future<String?> _installSkill() async {
    final config = ref.read(appConfigProvider);
    final target = _destination;
    final preview = _preview;
    final pkg = preview?.package;
    if (pkg == null) {
      _say(preview?.packageProblem ??
          "The marketplace has no package for this skill.");
      return null;
    }
    if (await config.fs
        .directory(skillDirectory(config, pkg.name, project: target))
        .exists()) {
      if (!mounted) return null;
      final confirmed = await confirm(
        context,
        title: "Replace ${pkg.name}?",
        message: "A skill with that name is already installed there. Installing "
            "this one replaces it, files included.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return null;
    }
    await platform.withWritableDir(
      config.promptsDir(CompletionKind.skill, project: target),
      () => installSkillPackage(config, pkg, project: target),
    );
    await reloadAllPromptLibraries(ref);
    return pkg.name;
  }

  /// The agents settings page's import shape, aimed at the site's files
  /// rather than a picked one: parse, refuse an empty body, a name that can
  /// be a file name, replace-confirm where the name is taken, then the `.md`
  /// and the picture written in one writable block.
  Future<String?> _installAgent() async {
    final config = ref.read(appConfigProvider);
    final target = _destination;
    final preview = _preview;
    final source = preview?.promptSource;
    final document = preview?.prompt;
    if (source == null || document == null || document.body.isEmpty) {
      _say("This agent cannot be installed: there is no prompt in it.");
      return null;
    }
    final name = widget.entry.slug;
    if (!isFolderName(name)) {
      _say("This agent cannot be installed: its name cannot be a file name.");
      return null;
    }
    final agentExists = await config.fs
        .file(agentFilePath(config, name, project: target))
        .exists();
    if (agentExists) {
      if (!mounted) return null;
      final confirmed = await confirm(
        context,
        title: "Replace $name?",
        message: "An agent with that name is already installed. Installing "
            "this one replaces it.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return null;
    }
    final picture = preview!.picture;
    await platform.withWritableDir(
      config.promptsDir(CompletionKind.agent, project: target),
      () async {
        final file = config.fs.file(agentFilePath(config, name, project: target));
        await file.create(recursive: true);
        await file.writeAsString(source);
        if (picture != null) {
          await config.fs
              .file(agentPicturePath(config, name, project: target))
              .writeAsBytes(picture);
        }
      },
    );
    // The picture the agent page draws is its own provider's read. A global
    // write lands where every project inherits from, so the whole family
    // goes down; a project's is read there and nowhere else.
    if (_destination == null) {
      ref.invalidate(agentPictureProvider);
    } else {
      ref.invalidate(agentPictureProvider((project: _destination, name: name)));
    }
    await reloadAllPromptLibraries(ref);
    return name;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final preview = _preview;
    final installable = _failed || preview == null
        ? false
        : preview.installable(widget.kind);
    return Scaffold(
      appBar: AppBar(title: Text("Marketplace · ${widget.kind.label}")),
      body: _failed
          ? Unreachable(onRetry: _load)
          : preview == null
              ? const Center(child: CircularProgressIndicator())
              : _Body(
                  entry: entry,
                  preview: preview,
                  destinationValue: _destination,
                  destinationChanged: (value) =>
                      setState(() => _destination = value),
                ),
      bottomNavigationBar: installable
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _installing ? null : _install,
                  icon: _installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.install_desktop),
                  label:
                      Text(_installing ? "Installing…" : "Install $_kindWord"),
                ),
              ),
            )
          : null,
    );
  }

  /// The singular the buttons say: "Install skill" / "Install agent" — the
  /// kind's own label is the plural its tab carries.
  String get _kindWord =>
      widget.kind == CompletionKind.skill ? "skill" : "agent";
}

class _Body extends StatelessWidget {
  const _Body({
    required this.entry,
    required this.preview,
    required this.destinationValue,
    required this.destinationChanged,
  });

  final MarketplaceEntry entry;
  final EntryPreview preview;
  final String? destinationValue;
  final ValueChanged<String?> destinationChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = entry.metaLine;
    final files =
        preview.package?.entries.where((e) => e.$1 != "SKILL.md").toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (preview.picture != null) ...[
          Center(
            child: AgentPictureImage(bytes: preview.picture, size: 72),
          ),
          const SizedBox(height: 12),
        ],
        Text(entry.name, style: theme.textTheme.headlineSmall),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            meta,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (entry.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(entry.description, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 24),
        if (preview.readme != null)
          MarkdownBody(
            data: preview.readme!,
            styleSheet: replyStyleSheet(theme),
          )
        else
          const Nothing("This entry ships no README."),
        if (preview.packageProblem != null) ...[
          const SizedBox(height: 16),
          Nothing(preview.packageProblem!),
        ],
        if (files != null && files.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text("Files", style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final (name, _) in files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(name, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
        ],
        const SizedBox(height: 24),
        InstallDestination(
          value: destinationValue,
          onChanged: destinationChanged,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}