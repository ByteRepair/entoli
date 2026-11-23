import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/view/chat/widgets/markdown_text.dart";
import "package:entoli_core/view/widgets/page_bar.dart";

import "../../app/marketplace/install.dart";
import "../../data/prompts/skill_import.dart";
import "../widgets/install_bar.dart";
import "../widgets/install_destination.dart";
import "../widgets/nothing.dart";

/// Opens the skill a turn drafted and packaged, to install it.
Future<void> openSkillInstall(
  BuildContext context, {
  required String chatId,
  required String installId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        SkillInstallPreviewPage(chatId: chatId, installId: installId),
  ),
);

/// A skill a turn drafted, before it is installed: its SKILL.md, what else
/// it holds, and where it goes.
class SkillInstallPreviewPage extends ConsumerStatefulWidget {
  const SkillInstallPreviewPage({
    super.key,
    required this.chatId,
    required this.installId,
  });

  final String chatId;
  final String installId;

  @override
  ConsumerState<SkillInstallPreviewPage> createState() =>
      _SkillInstallPreviewPageState();
}

class _SkillInstallPreviewPageState
    extends ConsumerState<SkillInstallPreviewPage> {
  late final Future<SkillPackage?> _package = readDraftedSkill(
    ref.read,
    widget.chatId,
    widget.installId,
  );
  final _installing = ValueNotifier(false);

  /// Null is Global, the default project.
  String? _destination;

  @override
  void dispose() {
    _installing.dispose();
    super.dispose();
  }

  Future<void> _install(SkillPackage package) {
    final install = PromptInstall(ref.read, target: _destination);
    return runInstall(
      context,
      _installing,
      replacing: install.replacingSkill(package),
      install: () => install.skill(package),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _package,
    builder: (context, snapshot) {
      final package = snapshot.data;
      return Scaffold(
        appBar: PageBar(title: package?.name ?? "Install Skill"),
        body: switch ((snapshot.connectionState, package)) {
          (ConnectionState.done, final package?) => _body(context, package),
          (ConnectionState.done, null) => const Nothing(
            "The skill package could not be read. It may have been deleted "
            "with the chat.",
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
        bottomNavigationBar: package == null
            ? null
            : ValueListenableBuilder(
                valueListenable: _installing,
                builder: (context, installing, _) => InstallBar(
                  installing: installing,
                  label: "Install skill",
                  onPressed: () => _install(package),
                ),
              ),
      );
    },
  );

  Widget _body(BuildContext context, SkillPackage package) {
    final theme = Theme.of(context);
    final files = [
      for (final file in package.entries)
        if (file.$1 != "SKILL.md") file,
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (package.description case final description?
            when description.isNotEmpty)
          Text(description, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        Text("SKILL.md", style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(16),
          child: MarkdownText(package.body),
        ),
        if (files.isNotEmpty) ...[
          const SizedBox(height: 24),
          PackageFileList(entries: files),
        ],
        const SizedBox(height: 24),
        InstallDestination(
          value: _destination,
          onChanged: (value) => setState(() => _destination = value),
        ),
      ],
    );
  }
}
