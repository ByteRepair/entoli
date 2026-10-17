import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../core/platform/platform.dart" as platform;
import "../../core/config.dart" show AppConfig;
import "../../data/prompts/prompt_export.dart";
import "../../data/prompts/skill_import.dart";
import "../../data/prompts/skill_validate.dart";
import "../../domain/frontmatter.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show promptsDirUserWritable;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../skills/skill_view.dart";
import "../widgets/add_button_row.dart";
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
/// Every row opens the skill view page, where the body, the files and — for
/// a folder the loader skipped — the conformance problems are shown. The scan
/// validates each folder in the project's own directory, so a skill that is
/// not loadable is a row with a warning badge rather than an absence.
///
/// The import flow and the install-to combobox are the footer, fixed to the
/// bottom of the page so they do not scroll with the list — the same shape
/// the skill-install preview page pins its Install button in. Export rides
/// every row, wherever the entry it names came from.
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

  /// What [project]'s own directory holds: each folder's conformance problems,
  /// empty where it would load. Null while the first scan is out: the library
  /// knows what is loaded, not where each one came from or what is wrong with
  /// what it could not take. Every other name on the list is inherited or
  /// bundled.
  Map<String, List<String>>? _userSkills;

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
    final problems = <String, List<String>>{};
    final dir = config.fs
        .directory(config.promptsDir(CompletionKind.skill, project: widget.project));
    if (await dir.exists()) {
      final folders = <(String, String)>[];
      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final folderName = config.fs.path.basename(entity.path);
        folders.add((folderName, entity.path));
      }
      // The reads are independent; a browser's IndexedDB makes each one a
      // round trip, so they go out together.
      final answers = await Future.wait([
        for (final (folderName, path) in folders)
          _folderProblems(config, path, folderName),
      ]);
      for (var i = 0; i < folders.length; i++) {
        problems[folders[i].$1] = answers[i];
      }
    }
    if (mounted) setState(() => _userSkills = problems);
  }

  /// What a folder in the user's own directory is wrong about — the same
  /// rules the loader skips on, computed here so the row and the view page
  /// say them without a reload. A folder with no SKILL.md in it is a problem
  /// of its own; the loader skips it silently, this makes it a row.
  Future<List<String>> _folderProblems(
      AppConfig config, String path, String folderName) async {
    final fs = config.fs;
    final file = fs.file(fs.path.join(path, "SKILL.md"));
    if (!await file.exists()) return ["no SKILL.md in it"];
    try {
      return skillFrontmatterProblems(
          Frontmatter.parse(await file.readAsString()), folderName);
    } catch (e) {
      return ["SKILL.md could not be read: $e"];
    }
  }

  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: const [_skillFiles]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    // The parse throws rather than awaits, so a refused file is a snack bar
    // rather than a busy bar.
    final SkillPackage package;
    try {
      package = parseSkillPackage(bytes);
    } on SkillImportException catch (e) {
      return _say("That file cannot be imported: $e.");
    }

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

  Future<void> _delete(String name) async {
    final confirmed = await confirm(
      context,
      title: "Remove $name?",
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
            .directory(skillDirectory(config, name, project: widget.project))
            .delete(recursive: true);
      });
      await _reload(widget.project);
      await _scan();
      _say("Removed $name.");
    });
  }

  /// Re-read the library of the project a change landed in. The global page's
  /// import can land in any of them, so it reloads every project's; a
  /// project's own pages have one target and reload that one alone.
  Future<void> _reload(String? target) => target == null
      ? reloadAllPromptLibraries(ref)
      : ref.read(promptLibraryProvider(target).notifier).reload();

  Future<void> _export(String name) => _guard(() => exportAndSave(
        ref.read(appConfigProvider),
        ref.read(backupHandoffProvider),
        CompletionKind.skill,
        name,
        project: widget.project,
      ));

  void _open(String name, {String? origin}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SkillViewPage(
          name: name,
          project: widget.project,
          origin: origin ?? _originLabel(name),
        ),
      ));

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (mounted) say(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final skills =
        ref.watch(promptLibraryProvider(widget.project)).entries(CompletionKind.skill);
    final userSkills = _userSkills;
    final loaded = {for (final skill in skills) skill.name};
    final notLoaded = [
      for (final entry in userSkills?.entries ?? const <MapEntry<String, List<String>>>[])
        if (entry.value.isNotEmpty && !loaded.contains(entry.key)) entry.key,
    ];
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              SectionHeader("Skills", description: description),
              for (final skill in skills) _row(skill, userSkills),
              for (final name in notLoaded) _notLoadedRow(name),
            ],
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
          AddButtonRow(
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

  /// The trailing half of a row. The variable part — remove where the
  /// scanned directory holds the entry and the directory is the user's to
  /// write into, the origin badge where it does not, nothing while the scan
  /// is still out — stands first, then the warning badge where the folder's
  /// SKILL.md does not conform, then Export: the trailing slot is
  /// right-aligned, so the row's right edge pins Export whether or not the
  /// scan has landed, and nothing flashes sideways when it does.
  Widget _row(PromptDocument skill, Map<String, List<String>>? userSkills) {
    final problems = userSkills?[skill.name];
    return ListTile(
      dense: true,
      title: Text(skill.name),
      // No subtitle: the description is the view page's content, and the row
      // is the way in, not a preview of it.
      onTap: () => _open(skill.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          switch (userSkills?.containsKey(skill.name)) {
            // The scan is still out: neither button nor badge is drawn.
            null => const SizedBox.shrink(),
            // The project's own — but only where the directory is the user's
            // to write into; a built-in's rows say what they are and stop
            // there.
            true when _writable => IconButton(
                icon: const Icon(Icons.close),
                tooltip: "Remove ${skill.name}",
                onPressed: () => _delete(skill.name),
              ),
            false => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(_originLabel(skill.name)),
              ),
            true => const SizedBox.shrink(),
          },
          if (problems != null && problems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.warning_amber_rounded,
                  size: 20, color: Theme.of(context).colorScheme.error),
            ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: "Export ${skill.name}",
            onPressed: () => _export(skill.name),
          ),
        ],
      ),
    );
  }

  /// A folder the loader skipped: not in the library, so not drawn by the
  /// rows above, and a row here is the only place it is anything but an
  /// absence. The view page says the problems; remove takes the folder away
  /// where the directory is the user's.
  Widget _notLoadedRow(String name) =>
      ListTile(
        dense: true,
        title: Text(name),
        subtitle: const Text("Not loaded"),
        onTap: () => _open(name, origin: "Not loaded"),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 20, color: Theme.of(context).colorScheme.error),
            if (_writable)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: "Remove $name",
                onPressed: () => _delete(name),
              )
            else
              const SizedBox(width: 48),
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: "Export $name",
              onPressed: () => _export(name),
            ),
          ],
        ),
      );

  /// Where an entry the project's directory does not hold came from: a preset
  /// the binary embeds, or a default-project entry this project inherits.
  String _originLabel(String name) =>
      isBundledPromptName(CompletionKind.skill, name, project: widget.project)
          ? "Bundled"
          : "Inherited";
}