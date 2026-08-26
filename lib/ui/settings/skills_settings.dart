import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../data/prompts/skill_import.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/section_header.dart";

const _skillFiles = XTypeGroup(
  label: "Skill",
  extensions: ["skill", "zip"],
  mimeTypes: ["application/zip"],
  uniformTypeIdentifiers: ["public.zip-archive"],
  webWildCards: ["application/zip"],
);

/// What the agent can be told to do by name. The list is the library's, the
/// page's own question is where each one came from — a bundled skill is
/// Entoli's and not deletable, the user's are imported here and are.
class SkillsSection extends ConsumerStatefulWidget {
  const SkillsSection({super.key});

  @override
  ConsumerState<SkillsSection> createState() => _SkillsSectionState();
}

class _SkillsSectionState extends ConsumerState<SkillsSection> {
  final _busy = ValueNotifier(false);

  /// Which skills live in the user's directory. Null while the first scan is
  /// out: the library knows what is loaded, not where each one came from.
  Set<String>? _userSkills;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final config = ref.read(appConfigProvider);
    final names = <String>{};
    final dir = config.fs.directory(config.promptsDir(CompletionKind.skill));
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is Directory) names.add(config.fs.path.basename(entity.path));
      }
    }
    if (mounted) setState(() => _userSkills = names);
  }

  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: const [_skillFiles]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    final package = _guardSync(() => parseSkillPackage(bytes));
    if (package == null) return;

    final config = ref.read(appConfigProvider);
    final replacing =
        await config.fs.directory(skillDirectory(config, package.name)).exists();
    if (!mounted) return;
    if (replacing) {
      final confirmed = await confirm(
        context,
        title: "Replace ${package.name}?",
        message: "A skill with that name is already installed. Importing this "
            "one replaces it, files included.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return;
    }

    await _guard(() async {
      await installSkillPackage(ref.read(appConfigProvider), package);
      await ref.read(promptLibraryProvider.notifier).reload();
      await _scan();
      _say("Imported ${package.name}.");
    });
  }

  Future<void> _delete(PromptDocument skill) async {
    final confirmed = await confirm(
      context,
      title: "Remove ${skill.name}?",
      message: "The skill and its files are deleted. A bundled skill of the "
          "same name, if there is one, is back the next time the library "
          "loads.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (!confirmed) return;

    await _guard(() async {
      final config = ref.read(appConfigProvider);
      await config.fs.directory(skillDirectory(config, skill.name)).delete(recursive: true);
      await ref.read(promptLibraryProvider.notifier).reload();
      await _scan();
      _say("Removed ${skill.name}.");
    });
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  /// The parse is fast and throws rather than awaits, so it goes through the
  /// busy bar by hand: a refused file is a snack bar, not a half-open bar.
  SkillPackage? _guardSync(SkillPackage Function() work) {
    try {
      return work();
    } on SkillImportException catch (e) {
      _say("That file cannot be imported: $e.");
      return null;
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final skills = ref.watch(promptLibraryProvider).entries(CompletionKind.skill);
    final userSkills = _userSkills;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Skills",
          description: skills.isEmpty
              ? "Named procedures the agent can load, offered as /name in the "
                  "composer. None are installed yet."
              : "Named procedures the agent can load, offered as /name in the "
                  "composer. The bundled ones ship with the app; the rest are "
                  "yours.",
        ),
        for (final skill in skills) _row(skill, userSkills),
        if (skills.isEmpty && userSkills != null && userSkills.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Something in the skills directory is not loadable — a folder "
              "with no SKILL.md in it.",
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ValueListenableBuilder(
            valueListenable: _busy,
            builder: (context, busy, _) => OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text("Import skill"),
              onPressed: busy ? null : _import,
            ),
          ),
        ),
        BusyBar(_busy),
      ],
    );
  }

  /// The trailing half of a row: the user's skills can be removed, the
  /// bundled ones say so, and while the scan is still out neither is drawn —
  /// a remove button that flashes in is a row lying twice in a second.
  Widget _row(PromptDocument skill, Set<String>? userSkills) => ListTile(
        dense: true,
        title: Text(skill.name),
        subtitle: skill.description == null ? null : Text(skill.description!),
        trailing: switch (userSkills?.contains(skill.name)) {
          null => null,
          true => IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove ${skill.name}",
              onPressed: () => _delete(skill),
            ),
          false => const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Text("Bundled"),
            ),
        },
      );
}
