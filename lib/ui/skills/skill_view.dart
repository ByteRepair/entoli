import "dart:convert";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../data/prompts/prompt_export.dart";
import "../../data/prompts/skill_validate.dart";
import "../../domain/frontmatter.dart";
import "../../providers.dart";
import "../chat/widgets/reply_style.dart";

/// A full page showing one skill the library offers: its description, the
/// SKILL.md body rendered, its files, and — where its frontmatter does not
/// conform to the Agent Skills spec — the problems, which is where a skill
/// the loader skipped says why. Pushed from a skills settings row; back
/// gesture closes.
class SkillViewPage extends ConsumerStatefulWidget {
  const SkillViewPage({
    super.key,
    required this.name,
    this.project,
    required this.origin,
  });

  final String name;

  /// The project whose library the skill was read from. Null is the default
  /// project, the way it is everywhere a project is named.
  final String? project;

  /// Where the entry came from — the settings row's own label, repeated here.
  final String origin;

  @override
  ConsumerState<SkillViewPage> createState() => _SkillViewPageState();
}

class _SkillViewPageState extends ConsumerState<SkillViewPage> {
  List<(String, Uint8List)>? _entries;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = ref.read(appConfigProvider);
    final entries = await skillSourceEntries(config, widget.name,
        project: widget.project);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              "The skill's files could not be read. It may have been removed.",
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final skillMd =
        entries.firstWhere((e) => e.$1 == "SKILL.md", orElse: () => ("", Uint8List(0))).$2;
    final parsed = Frontmatter.parse(utf8.decode(skillMd));
    final name = parsed.name ?? widget.name;
    final problems = entries.any((e) => e.$1 == "SKILL.md")
        ? skillProblems(
            name: name,
            description: parsed.description,
            frontmatter: parsed.scalars,
            folderName: widget.name,
          )
        : <String>[];
    final otherFiles =
        entries.where((e) => e.$1 != "SKILL.md").toList()..sort((a, b) => a.$1.compareTo(b.$1));

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("${widget.origin} · ${widget.name}", style: theme.textTheme.bodySmall),
          if (parsed.description != null) ...[
            const SizedBox(height: 4),
            Text(parsed.description!, style: theme.textTheme.bodyMedium),
          ],
          if (problems.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ProblemsCard(problems: problems),
          ],
          if (parsed.metadata.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text("Metadata", style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final entry in parsed.metadata.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text("${entry.key}: ${entry.value}",
                    style: theme.textTheme.bodySmall),
              ),
          ],
          const SizedBox(height: 24),
          Text("SKILL.md", style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: parsed.body,
              styleSheet: replyStyleSheet(theme),
            ),
          ),
          if (otherFiles.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text("Files", style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (path, bytes) in otherFiles)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file_outlined,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(path, style: theme.textTheme.bodyMedium),
                    ),
                    Text(_sizeLabel(bytes),
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _sizeLabel(Uint8List bytes) {
    if (bytes.length < 1024) return "${bytes.length} B";
    return "${(bytes.length / 1024).toStringAsFixed(1)} KB";
  }
}

/// What does not conform, said plainly with the way out: the skill is not
/// loaded, and the fix is to edit and reinstall it. This card is where a
/// skill the loader skipped explains itself, beside the log line the load
/// wrote.
class _ProblemsCard extends StatelessWidget {
  const _ProblemsCard({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Not loaded — does not conform to the Agent Skills spec",
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text("• $problem",
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            ),
          const SizedBox(height: 8),
          Text(
            "Fix the SKILL.md and import the skill again.",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}