import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/skill_import.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show promptsDirUserWritable;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/install_destination.dart";
import "../widgets/section_header.dart";

const _skillFiles = XTypeGroup(
  label: "Skill",
  extensions: ["skill", "zip"],
  mimeTypes: ["application/zip"],
  uniformTypeIdentifiers: ["public.zip-archive"],
  webWildCards: ["application/zip"],
);

/// What the agent can be told to do by name. The list is the library's; the
/// page's own question is where each one came from — a bundled skill is
/// Entoli's and not deletable, the user's are imported here and are.
///
/// [project] is whose set the page reads and whose directory it writes: null
/// is the app-level page and the default project, a name is that project's
/// settings page. A built-in project's page is view-only — it shows the
/// entries its directory, the default's and the bundled presets make up, with
/// nothing to change any of them, since a turn in it answers to the spec.
class SkillsSection extends ConsumerStatefulWidget {
  const SkillsSection({super.key, this.project});

  final String? project;

  @override
  ConsumerState<SkillsSection> createState() => _SkillsSectionState();
}

class _SkillsSectionState extends ConsumerState<SkillsSection> {
  final _busy = ValueNotifier(false);

  /// Which skills live in [project]'s own directory. Null while the first
  /// scan is out: the library knows what is loaded, not where each one came
  /// from. Every other name on the list is inherited or bundled.
  Set<String>? _userSkills;

  /// Where a skill imported here goes. Null is the default project — the
  /// global page offers every project; a project's own page has no choice to
  /// offer, so the field stays null and means this [SkillsSection.project].
  String? _destination;

  bool get _writable => promptsDirUserWritable(widget.project);

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
    final dir = config.fs
        .directory(config.promptsDir(CompletionKind.skill, project: widget.project));
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

    // The destination dropdown's pick on the global page, the page's own
    // project on a project page. The global page's scan reads only the
    // default project's directory, so what lands elsewhere is visible in the
    // snack bar, not in the list.
    final target = widget.project ?? _destination;
    final config = ref.read(appConfigProvider);
    final replacing = await config.fs
        .directory(skillDirectory(config, package.name, project: target))
        .exists();
    if (!mounted) return;
    if (replacing) {
      final confirmed = await confirm(
        context,
        title: "Replace ${package.name}?",
        message: "A skill with that name is already installed there. Importing "
            "this one replaces it, files included.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return;
    }

    await _guard(() async {
      final config = ref.read(appConfigProvider);
      await platform.withWritableDir(
          config.promptsDir(CompletionKind.skill, project: target), () async {
        await installSkillPackage(config, package, project: target);
      });
      await _reload(target);
      await _scan();
      _say(installedSnack("Imported", package.name, target));
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
      await platform.withWritableDir(
          config.promptsDir(CompletionKind.skill, project: widget.project),
          () async {
        await config.fs
            .directory(skillDirectory(config, skill.name, project: widget.project))
            .delete(recursive: true);
      });
      await _reload(widget.project);
      await _scan();
      _say("Removed ${skill.name}.");
    });
  }

  /// Re-read the library of the project a change landed in. The global page's
  /// import can land in any of them, so it reloads every project's; a
  /// project's own pages have one target and reload that one alone.
  Future<void> _reload(String? target) => target == null
      ? reloadAllPromptLibraries(ref)
      : ref.read(promptLibraryProvider(target).notifier).reload();

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
    final skills =
        ref.watch(promptLibraryProvider(widget.project)).entries(CompletionKind.skill);
    final userSkills = _userSkills;
    final description = !_writable
        ? "Named procedures the agent can load in this project, offered as "
            "/name in the composer. Shown read-only: the entries are this "
            "project's, the default project's, or the app's own."
        : skills.isEmpty
            ? "Named procedures the agent can load, offered as /name in the "
                "composer. None are installed yet."
            : "Named procedures the agent can load, offered as /name in the "
                "composer. The bundled ones ship with the app; the rest are "
                "yours.";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Skills", description: description),
        for (final skill in skills) _row(skill, userSkills),
        if (skills.isEmpty && userSkills != null && userSkills.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Something in the skills directory is not loadable — a folder "
              "with no SKILL.md in it.",
            ),
          ),
        if (_writable) ...[
          if (widget.project == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: InstallDestination(
                value: _destination,
                onChanged: (value) => setState(() => _destination = value),
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
        ],
        BusyBar(_busy),
      ],
    );
  }

  /// The trailing half of a row: an entry the scanned directory holds is this
  /// project's own and can be removed, an inherited or bundled one is not
  /// here and says which, and while the scan is still out neither is drawn —
  /// a remove button that flashes in is a row lying twice in a second.
  Widget _row(PromptDocument skill, Set<String>? userSkills) =>
      ListTile(
        dense: true,
        title: Text(skill.name),
        subtitle: skill.description == null ? null : Text(skill.description!),
        trailing: switch (userSkills?.contains(skill.name)) {
          // The scan is still out: neither button nor badge is drawn.
          null => null,
          // The project's own — but only where the directory is the user's to
          // write into; a built-in's rows say what they are and stop there.
          true when _writable => IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove ${skill.name}",
              onPressed: () => _delete(skill),
            ),
          false => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(_originLabel(CompletionKind.skill, skill.name)),
            ),
          true => null,
        },
      );

  /// Where an entry the project's directory does not hold came from: a preset
  /// the binary embeds, or a default-project entry this project inherits.
  String _originLabel(CompletionKind kind, String name) =>
      isBundledPromptName(kind, name, project: widget.project)
          ? "Bundled"
          : "Inherited";
}

