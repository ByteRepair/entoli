import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/project_edits.dart";
import "../../app/settings/confinement.dart";
import "../../app/settings/scope.dart";
import "../../domain/builtin_project.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../domain/settings/keys.dart";
import "../../domain/shell.dart" show isTildePath;
import "../../domain/temp_chat_ttl.dart";
import "../../domain/tristate.dart";
import "../../providers.dart";
import "../chat/widgets/view_only_bar.dart" show DeviceNotice;
import "../memory/memory_page.dart";
import "../profile/profile_page.dart";
import "../settings/permissions_section.dart";
import "../settings/project_prompts_page.dart";
import "../settings/general_settings.dart" show OmadaRows;
import "../settings/scoped.dart";
import "../settings/terminal_settings.dart" show SandboxSettings;
import "../widgets/add_button_row.dart";
import "../widgets/busy.dart";
import "../widgets/destructive_button.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/page_bar.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../workspace/workspace_page.dart";

/// A project's settings: what it is, what its turns are told and may do,
/// its memory, its rounds and how long its chats live, and deleting it. A
/// paired device's project is read from there and written there, and is
/// read only while the device is away.
class ProjectSettingsPage extends ConsumerWidget {
  const ProjectSettingsPage({super.key, required this.project, this.device});

  final String project;

  /// The paired device the project is on, null for this one.
  final String? device;

  ProjectRef get _at => (device: device, project: project);
  bool get _remote => device != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final at = _at;
    Widget page(Widget body) => Scaffold(
      appBar: PageBar(
        title: "Project Settings",
        subtitle: projectLabel(project),
      ),
      body: body,
    );
    if (ref.watch(projectGoneProvider(at))) {
      return page(
        const Center(child: Text("This project is no longer on that device.")),
      );
    }
    if (!ref.watch(projectLoadedProvider(at))) {
      return page(const Center(child: CircularProgressIndicator()));
    }
    final frozen = ref.watch(projectFrozenProvider(at));
    final address = ProjectAddress(project, device: device);
    final builtIn = builtinProjectOf(project);
    final config = ref.watch(appConfigProvider);
    final settings = ref.watch(projectSettingsOf(at));
    final omada = builtIn?.omada ?? settings.omada;
    final count = ref.watch(projectChatCountProvider(at));
    final rows = <Widget>[
      ListTile(
        title: const Text("Project name"),
        subtitle: Text(project),
        trailing: OutlinedButton(
          onPressed: () =>
              copyToClipboard(context, project, said: "Copied project name"),
          child: const Text("Copy"),
        ),
      ),
      if (!_remote)
        ListTile(
          title: const Text("Path"),
          subtitle: Text(config.projectDir(project: project)),
          trailing: OutlinedButton(
            onPressed: () => copyToClipboard(
              context,
              config.projectDir(project: project),
              said: "Copied project path",
            ),
            child: const Text("Copy"),
          ),
        ),
      if (builtIn == null) _DescriptionRow(at: at),
      if (!_remote)
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text("Workspace"),
          subtitle: const Text("Browse files"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openWorkspace(
            context,
            root: config.projectWorkspaceDir(project: project),
            title: "Project workspace",
          ),
        ),
      ListTile(
        leading: const Icon(Icons.chat_bubble_outline),
        title: const Text("Chats"),
        subtitle: Text("$count"),
      ),
      const Divider(),
      const SectionHeader("What its turns are told"),
      if (!_remote &&
          (builtIn?.bundledInstructions == null ||
              builtIn?.includesUserInstructions == true))
        _InstructionsRow(project: project),
      for (final kind in CompletionKind.values)
        _Opener(
          icon: kind == CompletionKind.skill
              ? Icons.extension_outlined
              : Icons.smart_toy_outlined,
          title: kind.label,
          label: switch (ref.watch(promptLibraryOf(at)).entries(kind).length) {
            0 => "None",
            final n => "$n",
          },
          onTap: () => openProjectPrompts(context, kind, address),
        ),
      const Divider(),
      const SectionHeader("Commands"),
      ScopedEnvironment(setting: SettingKeys.environment, at: address),
      PermissionRulesSection(at: address),
      SandboxSettings(at: address),
      // Folders on this machine, granted to the host's sandbox: not a paired
      // device's, and not where nothing is confined.
      if (!_remote && ref.watch(pickedConfinementProvider).enforcesSandbox) ...[
        const Divider(),
        _WorkFolders(project: project),
      ],
      if (builtIn == null) ...[
        const Divider(),
        const SectionHeader("Memory"),
        _MemoryChoice(at: at),
        _Opener(
          icon: Icons.psychology_outlined,
          title: "Memories",
          subtitle: "Browse, add, pin, delete",
          onTap: () =>
              openMemories(context, project: at, title: "Project memories"),
        ),
      ],
      const Divider(),
      const SectionHeader("Rounds"),
      // A built-in's answer is its spec: the state shown, not offered.
      SwitchListTile(
        title: const Text("Omada"),
        subtitle: const Text(
          "Several named agents take part in a chat's replies, alongside "
          "the main one.",
        ),
        value: omada,
        onChanged: builtIn != null
            ? null
            : (on) => guarded(
                context,
                () => ref.read(projectSettingsOf(at).notifier).setOmada(on),
              ),
      ),
      if (omada) OmadaRows(at: address),
      // A turn is a turn in every project, built-ins included.
      ScopedCount(
        setting: SettingKeys.turnMaxSteps,
        at: address,
        title: "Max steps per turn",
        stops: SettingKeys.turnStepStops,
        unsetMeans: SettingKeys.defaultTurnMaxSteps,
      ),
      const Divider(),
      const SectionHeader("Temporary chats"),
      InheritableDropdown<TempChatTtl>(
        label: "Delete chats after",
        value: settings.tempChatTtl,
        // What `ChatRepository._resolveTempTtl` falls to below this level.
        inherited: inheritedTempTtl(
          project,
          app: scopeOf(ref, address).inherited(SettingKeys.tempChatTtl)!,
        ).label,
        options: tempChatTtlLabels,
        // The notifier's, which a remote project's sends to its device.
        onChanged: (ttl) => guarded(
          context,
          () => ref.read(projectSettingsOf(at).notifier).setTempChatTtl(ttl),
        ),
      ),
      if (builtIn == null) ...[
        const Divider(),
        DestructiveButton(
          icon: Icons.delete,
          label: "Delete Project",
          confirmTitle: "Delete project?",
          confirmMessage: deleteProjectMessage(project, count),
          confirmMessageOf: () async => deleteProjectMessage(
            project,
            await ref.read(projectEditsProvider).chatCount(at),
          ),
          onConfirmed: () => _delete(context, ref),
        ),
      ],
    ];
    return page(
      ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_remote)
            DeviceNotice(
              what: "project",
              deviceName:
                  ref.watch(syncPeersProvider.select((p) => p[device]?.name)) ??
                  "The device",
              online: !frozen,
            ),
          // What the device last said, readable and not written until it is
          // back. Row by row, so the list still scrolls.
          for (final row in rows) frozen ? AbsorbPointer(child: row) : row,
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final edits = ref.read(projectEditsProvider);
    final navigator = Navigator.of(context);
    if (device case final device?) {
      await guarded(context, () async {
        if (!await edits.deleteRemote(device, project)) {
          if (context.mounted) {
            say(context, "The project was not deleted there.");
          }
          return;
        }
        navigator.popUntil((route) => route.isFirst);
      });
      return;
    }
    navigator.popUntil((route) => route.isFirst);
    await guarded(context, () => edits.delete(project));
  }
}

/// A row that opens a page over this one, saying what it holds.
class _Opener extends StatelessWidget {
  const _Opener({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.label,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final label = this.label;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null) Text(label),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// What the new-chat screen asks over the project's badge. Blank is an
/// answer of its own, the screen asking nothing; the reset is the way back
/// to the app's question.
class _DescriptionRow extends ConsumerWidget {
  const _DescriptionRow({required this.at});

  final ProjectRef at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description = ref.watch(
      projectSettingsOf(at).select((s) => s.description),
    );
    final notifier = ref.read(projectSettingsOf(at).notifier);
    return ListTile(
      title: const Text("Description"),
      subtitle: Text(
        emptyChatQuestionFor(at.project, description: description) ?? "Empty",
      ),
      trailing: description == null
          ? null
          : ResetButton(
              resetLabel: "the default question",
              onReset: () =>
                  guarded(context, () => notifier.setDescription(null)),
            ),
      onTap: () async {
        final text = await promptForText(
          context,
          title: "Description",
          initial: description ?? "",
          hint: defaultEmptyChatQuestion,
          helper: projectDescriptionHelp,
          minLines: 2,
          maxLines: 5,
          confirmLabel: "Save",
          allowBlank: true,
        );
        if (text == null || !context.mounted) return;
        await guarded(context, () => notifier.setDescription(text));
      },
    );
  }
}

/// The project's instructions, and whether there are any: looked at again
/// when the editor closes.
class _InstructionsRow extends ConsumerStatefulWidget {
  const _InstructionsRow({required this.project});

  final String project;

  @override
  ConsumerState<_InstructionsRow> createState() => _InstructionsRowState();
}

class _InstructionsRowState extends ConsumerState<_InstructionsRow> {
  late bool _set;

  @override
  void initState() {
    super.initState();
    _set = _isSet();
  }

  bool _isSet() => File(
    ref
        .read(appConfigProvider)
        .projectInstructionsFile(project: widget.project),
  ).existsSync();

  @override
  Widget build(BuildContext context) {
    return _Opener(
      icon: Icons.edit_outlined,
      title: "Instructions",
      label: _set ? "Set" : "Not set",
      onTap: () async {
        await openProfile(context, project: widget.project);
        if (mounted) setState(() => _set = _isSet());
      },
    );
  }
}

/// Which memories this project's chats keep: none, the default project's,
/// or its own.
class _MemoryChoice extends ConsumerWidget {
  const _MemoryChoice({required this.at});

  final ProjectRef at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(projectSettingsOf(at).select((s) => s.memory));
    return LabelledField(
      label: "Project memory",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<Tristate>(
            segments: const [
              ButtonSegment(value: Tristate.off, label: Text("Off")),
              ButtonSegment(value: Tristate.inherit, label: Text("Shared")),
              ButtonSegment(value: Tristate.on, label: Text("Own")),
            ],
            selected: {value},
            onSelectionChanged: (picked) => guarded(
              context,
              () => ref
                  .read(projectSettingsOf(at).notifier)
                  .setMemory(picked.first),
            ),
          ),
          const SizedBox(height: 8),
          mutedParagraph(context, switch (value) {
            Tristate.off => "This project's chats have no memory.",
            Tristate.inherit =>
              "This project's chats share the default project's memories.",
            Tristate.on => "This project keeps memories of its own.",
          }),
        ],
      ),
    );
  }
}

/// A project's work folders: the directories outside the workspaces its
/// turns may write to, granted up front. See "Work folders" in
/// `lib/ui/settings/AGENTS.md`.
class _WorkFolders extends ConsumerWidget {
  const _WorkFolders({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirs = ref.watch(
      projectSettingsProvider(project).select((s) => s.writableDirs),
    );
    final edits = ref.read(projectEditsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Work folders",
          description:
              "Folders outside the workspace that this project's commands "
              "may write to, with nothing to approve.",
        ),
        if (dirs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: mutedParagraph(context, "No folders yet."),
          ),
        for (final dir in dirs)
          EditableRow(
            title: dir,
            // One the turn is not granted is said rather than left looking
            // live; a `~` path is the turn's to resolve.
            subtitle: isTildePath(dir)
                ? null
                : edits.refusal(project, dir)?.row,
            removeLabel: "Remove $dir",
            onRemove: () =>
                guarded(context, () => edits.removeFolder(project, dir)),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text("Add Folder…"),
            onPressed: () => guarded(context, () async {
              final refused = await edits.addFolder(project);
              if (refused != null && context.mounted) {
                say(context, refused.message);
              }
            }),
          ),
        ),
      ],
    );
  }
}
