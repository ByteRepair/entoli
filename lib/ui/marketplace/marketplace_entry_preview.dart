import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/marketplace/install.dart";
import "../../app/marketplace/marketplace.dart";
import "../../app/marketplace/preview.dart";
import "package:entoli_chat/domain/agent_face.dart";
import "package:entoli_chat/domain/models.dart";
import "../../providers.dart";
import "package:entoli_chat/ui/chat/widgets/markdown_text.dart";
import "package:entoli_chat/ui/widgets/agent_picture.dart";
import "../widgets/install_bar.dart";
import "../widgets/install_destination.dart";
import "../widgets/nothing.dart";
import "package:entoli_chat/ui/widgets/notice.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";
import "../widgets/section_header.dart";
import "marketplace_rows.dart";
import "unreachable.dart";

/// Opens [entry]'s preview; [preview] is one a link carried whole, so
/// nothing is fetched.
Future<void> openMarketplaceEntry(
  BuildContext context, {
  required CompletionKind kind,
  required MarketplaceEntry entry,
  EntryPreview? preview,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        MarketplaceEntryPreviewPage(kind: kind, entry: entry, preview: preview),
  ),
);

/// One marketplace entry before it is installed: who made it, what it says
/// of itself, its README, what it holds, and where it goes.
class MarketplaceEntryPreviewPage extends ConsumerStatefulWidget {
  const MarketplaceEntryPreviewPage({
    super.key,
    required this.kind,
    required this.entry,
    this.preview,
  });

  final CompletionKind kind;
  final MarketplaceEntry entry;
  final EntryPreview? preview;

  @override
  ConsumerState<MarketplaceEntryPreviewPage> createState() =>
      _MarketplaceEntryPreviewPageState();
}

class _MarketplaceEntryPreviewPageState
    extends ConsumerState<MarketplaceEntryPreviewPage> {
  late EntryPreview? _preview = widget.preview;
  String? _failure;
  final _installing = ValueNotifier(false);

  /// Null is Global, the default project.
  String? _destination;

  @override
  void initState() {
    super.initState();
    if (_preview == null) _load();
  }

  @override
  void dispose() {
    _installing.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failure = null);
    try {
      final preview = await loadEntryPreview(
        ref.read(marketplaceClientProvider),
        widget.kind,
        widget.entry,
      );
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) setState(() => _failure = "$e");
    }
  }

  Future<void> _install(EntryPreview preview) async {
    final install = PromptInstall(ref.read, target: _destination);
    switch (widget.kind) {
      case CompletionKind.skill:
        final package = preview.package!;
        await runInstall(
          context,
          _installing,
          replacing: install.replacingSkill(package),
          install: () => install.skill(package),
        );
      case CompletionKind.agent:
        final name = widget.entry.installName;
        if (PromptInstall.agentRefusal(name) case final refusal?) {
          say(context, refusal);
          return;
        }
        await runInstall(
          context,
          _installing,
          replacing: install.replacingAgent(name),
          install: () => install.agent(
            name,
            preview.promptSource!,
            picture: preview.picture,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final installable =
        _failure == null && (preview?.installable(widget.kind) ?? false);
    return Scaffold(
      appBar: PageBar(
        title: widget.entry.name,
        subtitle: "Marketplace · ${widget.kind.label}",
      ),
      body: switch ((_failure, preview)) {
        (final failure?, _) => Unreachable(onRetry: _load, detail: failure),
        (_, null) => const Center(child: CircularProgressIndicator()),
        (_, final preview?) => _Body(
          kind: widget.kind,
          entry: widget.entry,
          preview: preview,
          destination: installable
              ? InstallDestination(
                  value: _destination,
                  onChanged: (value) => setState(() => _destination = value),
                )
              : null,
        ),
      },
      bottomNavigationBar: installable
          ? ValueListenableBuilder(
              valueListenable: _installing,
              builder: (context, installing, _) => InstallBar(
                installing: installing,
                label: switch (widget.kind) {
                  CompletionKind.skill => "Install skill",
                  CompletionKind.agent => "Install agent",
                },
                onPressed: () => _install(preview!),
              ),
            )
          : null,
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.kind,
    required this.entry,
    required this.preview,
    required this.destination,
  });

  final CompletionKind kind;
  final MarketplaceEntry entry;
  final EntryPreview preview;
  final Widget? destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = [
      for (final file in [...?preview.package?.entries])
        if (file.$1 != "SKILL.md") file,
    ];
    final problem =
        preview.packageProblem ??
        (kind == CompletionKind.agent && !preview.installable(kind)
            ? "This agent cannot be installed: there is no prompt in it."
            : null);
    final readme = preview.readme;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MarketplaceCard(
            slug: entry.slug,
            icon: kindIcon(kind),
            title: entry.name,
            byline: entry.byline,
            external: entry.external,
            face: switch (preview.picture) {
              final picture? => AgentPictureImage(
                face: AgentPhoto(picture),
                size: 48,
              ),
              null => null,
            },
          ),
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              problem,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (entry.description.isNotEmpty) ...[
          const SectionHeader("Description"),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(entry.description, style: theme.textTheme.bodyMedium),
          ),
        ],
        ..._details(context),
        const SectionHeader("README"),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: readme != null && readme.trim().isNotEmpty
              ? MarkdownText(readme)
              : const Align(
                  alignment: Alignment.centerLeft,
                  child: Nothing("This entry ships no README."),
                ),
        ),
        if (files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: PackageFileList(entries: files),
          ),
        if (destination case final destination?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: destination,
          ),
      ],
    );
  }

  /// What is known of the entry, a labelled row each; an entry a link
  /// carried knows little.
  List<Widget> _details(BuildContext context) {
    final authors = entry.authors;
    final rows = [
      if (authors.isNotEmpty)
        _Field(authors.length == 1 ? "Author" : "Authors", authors.join(", ")),
      if (entry.version case final version?) _Field("Version", version),
      if (entry.tags.isNotEmpty) _Field("Tags", entry.tags.join(", ")),
      if (entry.location case final location?)
        Consumer(
          builder: (context, ref, _) => ListTile(
            leading: const Icon(Icons.public),
            title: const Text("Source"),
            subtitle: Text("${location.repo}/${location.dir}"),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () =>
                ref.read(linkOpenerProvider).open(context, location.page),
          ),
        ),
    ];
    return [if (rows.isNotEmpty) const SectionHeader("Details"), ...rows];
  }
}

/// A label and what is known under it.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) =>
      ListTile(dense: true, title: Text(label), subtitle: Text(value));
}
