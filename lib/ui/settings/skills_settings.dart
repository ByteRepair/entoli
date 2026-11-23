import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/file_picker.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/project.dart" show promptsDirUserWritable;
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart";
import "package:entoli_core/store/prompts/skill_import.dart";

import "../../app/marketplace/install.dart" show PromptInstall;
import "../../app/prompts/own_prompts.dart";
import "../../app/prompts/skill_files.dart";
import "../../app/settings/scope.dart";
import "../../providers.dart";
import "../skills/skill_view.dart";
import "../widgets/add_button_row.dart";
import "../widgets/install_destination.dart";
import "../widgets/section_header.dart";
import "copy_install_link.dart";

const _skillFiles = FileTypes(
  label: "Skill",
  extensions: ["skill", "zip"],
  mimeTypes: ["application/zip"],
  uniformTypeIdentifiers: ["public.zip-archive"],
);

/// What the agent can be told to do by name, at [at]: the default project's
/// on the app's page, a project's on its own. Every row opens the skill's
/// view page; a folder of the project's own that the loader skipped is a
/// row of its own, with a warning, rather than an absence.
///
/// The import flow, and on the app's page where it lands, is the footer,
/// fixed to the bottom of the page so it does not scroll with the list.
class SkillsSettings extends ConsumerStatefulWidget {
  const SkillsSettings({super.key, this.at});

  /// Null is the app's page, the default project's, which imports into any
  /// project; a project's imports into itself.
  final ProjectAddress? at;

  @override
  ConsumerState<SkillsSettings> createState() => _SkillsSettingsState();
}

class _SkillsSettingsState extends ConsumerState<SkillsSettings> {
  final _busy = ValueNotifier(false);

  ProjectAddress get _address => widget.at ?? const ProjectAddress(null);

  bool get _global => widget.at == null;

  String? get _project => _address.project;

  bool get _local => _address.device == null;

  bool get _writable => _local && promptsDirUserWritable(_project);

  SkillFiles get _files =>
      SkillFiles(ref.read(appConfigProvider), project: _project);

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  Future<void> _import() async {
    final target = _global ? ref.read(skillDestinationProvider) : _project;
    SkillPackage? package;
    await _guard(() async {
      final file = await ref.read(filePickerProvider).file(types: _skillFiles);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      try {
        package = parseSkillPackage(bytes);
      } on SkillImportException catch (e) {
        if (mounted) say(context, "That file cannot be imported: $e.");
      }
    });
    final skill = package;
    if (skill == null || !mounted) return;
    final replacing = PromptInstall(
      ref.read,
      target: target,
    ).replacingSkill(skill, doing: "Importing");
    if (replacing != null &&
        !await confirm(
          context,
          title: replacing.title,
          message: replacing.message,
          confirmLabel: "Replace",
        )) {
      return;
    }
    if (!mounted) return;
    await _guard(() async {
      await _files.install(skill, target: target);
      await ref.read(promptChangesProvider).reload(target);
      if (mounted) {
        notify(context, installedSnack("Imported", skill.name, target));
      }
    });
  }

  Future<void> _delete(String name) async {
    final confirmed = await confirm(
      context,
      title: "Remove $name?",
      message:
          "The skill and its files are deleted. A bundled skill of the "
          "same name, if there is one, is back the next time the library "
          "loads.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _guard(() async {
      await _files.delete(name);
      await ref.read(promptChangesProvider).reload(_project);
      if (mounted) notify(context, "Removed $name.");
    });
  }

  void _open(String name, String origin) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          SkillViewPage(name: name, project: _project, origin: origin),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final skills = ref
        .watch(promptLibraryOf(_address.ref))
        .entries(CompletionKind.skill);
    // Null while the scan is out.
    final own = _local ? ref.watch(ownSkillsProvider(_project)).value : null;
    final loaded = {for (final skill in skills) skill.name};
    final skipped = [
      for (final name in own?.keys ?? const <String>[])
        if (!loaded.contains(name)) name,
    ]..sort();
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
              for (final skill in skills) _row(skill.name, own),
              for (final name in skipped) _row(name, own, loaded: false),
            ],
          ),
        ),
        if (_writable) ...[
          if (_global)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: InstallDestination(
                value: ref.watch(skillDestinationProvider),
                onChanged: ref.read(skillDestinationProvider.notifier).pick,
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

  /// No subtitle: the description is the view page's, and the row the way
  /// in. The variable part of the trailing slot stands first and Export
  /// last, so nothing flashes sideways when the scan lands. A paired
  /// device's files are not here to open or export.
  Widget _row(
    String name,
    Map<String, List<String>>? own, {
    bool loaded = true,
  }) {
    final inDir = own?.containsKey(name);
    final problems = own?[name] ?? const [];
    final origin = !loaded
        ? "Not loaded"
        : promptOrigin(CompletionKind.skill, name, _project);
    return ListTile(
      dense: true,
      title: Text(name),
      subtitle: loaded ? null : const Text("Not loaded"),
      onTap: _local ? () => _open(name, origin) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inDir == true && _writable)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove $name",
              onPressed: () => _delete(name),
            )
          else if (inDir == false)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(origin),
            ),
          if (problems.isNotEmpty || !loaded)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (_local)
            PromptRowActions(
              kind: CompletionKind.skill,
              name: name,
              project: _project,
              guard: _guard,
              linkable: loaded,
            ),
        ],
      ),
    );
  }
}
