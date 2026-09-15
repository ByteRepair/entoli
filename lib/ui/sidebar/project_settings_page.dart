import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/builtin_project.dart";
import "../../domain/models.dart";
import "../../domain/project.dart"
    show defaultEmptyChatQuestion, emptyChatQuestionFor;
import "../../domain/project_settings.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../memory/memory_page.dart";
import "../profile/profile_page.dart";
import "../settings/agents_settings.dart";
import "../settings/skills_settings.dart";
import "../fonts.dart";
import "../widgets/destructive_button.dart";
import "../widgets/dialogs.dart";
import "../widgets/environment_section.dart";
import "../widgets/resettable_field.dart";
import "../workspace/workspace_page.dart";
import "sidebar.dart";

/// Delete a project, its chats, and its shared workspace. Confirms first
/// (unless [confirm] is false — the settings page's `DestructiveButton` has
/// already asked), deselects the project and its chats, and invalidates the
/// lists so the UI reflects the deletion. Shared by the sidebar's project
/// menu and the project settings page so the invalidations agree.
Future<void> deleteProject(
  BuildContext context,
  WidgetRef ref,
  String project, {
  bool popToRoot = false,
  bool confirm = true,
}) async {
  if (confirm) {
    final count = (ref.read(chatListProvider).value ?? const [])
        .where((c) => c.project == project)
        .length;
    if (!await _confirmDeleteProject(context, project, count)) return;
  }
  await ref.read(chatRepositoryProvider).deleteProject(project);
  selectProject(ref, null);
  // The other reference to a project that no longer exists. Both ends resolve a
  // dangling name to the default project anyway, but leaving it written down
  // means the next save writes it back — and recreating a project of that name
  // would silently re-arm the setting.
  final settings = ref.read(appSettingsProvider);
  if (settings.assistantProject == project) {
    await ref.read(appSettingsProvider.notifier).setAssistantProject(null);
  }
  ref.invalidate(projectListProvider);
  ref.invalidate(chatListProvider);
  if (context.mounted && popToRoot) Navigator.of(context).popUntil((r) => r.isFirst);
}

Future<bool> _confirmDeleteProject(BuildContext context, String project, int count) {
  return confirm(
    context,
    title: "Delete project?",
    message: "Delete \"$project\", its $count ${count == 1 ? "chat" : "chats"} "
        "and its shared workspace? This cannot be undone.",
    confirmLabel: "Delete",
    destructive: true,
  );
}

class ProjectSettingsPage extends ConsumerWidget {
  const ProjectSettingsPage({super.key, required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider).value ?? const [];
    final count = chats.where((c) => c.project == project).length;
    final path = ref.watch(appConfigProvider).projectDir(project: project);
    // A built-in reaches this page where its spec says it has one; the rows a
    // built-in cannot use — its own memory store, and deletion — are hidden
    // for one. `isProjectName` refuses a built-in, so `deleteProject` would
    // throw, and a built-in with `MemoryPolicy.app` reads the default project's
    // store rather than keeping one of its own.
    final builtIn = builtinProjectOf(project);

    return Scaffold(
      appBar: AppBar(title: const Text("Project settings")),
      body: ListView(
        children: [
          _CopyField(
            label: "Project name",
            value: project,
            snack: "Copied project name",
          ),
          const Divider(),
          _CopyField(
            label: "Path",
            value: path,
            snack: "Copied project path",
          ),
          if (builtIn == null) ...[
            const Divider(),
            _DescriptionRow(project: project),
          ],
          const Divider(),
          WorkspaceTile(
            root: ref.watch(appConfigProvider).projectWorkspaceDir(project: project),
            title: "Project workspace",
          ),
          if (builtIn == null) ...[
            const Divider(),
            _UseProjectMemoryRow(project: project),
            MemoryTile(
              dir: ref.watch(appConfigProvider).memoryDir(project: project),
              title: "Project memories",
            ),
          ],
          const Divider(),
          ListTile(
            title: const Text("Chats"),
            trailing: Text("$count"),
          ),
          if (builtIn == null) ...[
            const Divider(),
            _OmadaRow(project: project),
            if (ref.watch(projectSettingsProvider(project).select((s) => s.omada))) ...[
              _OmadaOrderingRow(project: project),
              _OmadaMaxGenerationsRow(project: project),
            ],
          ],
          // A direct turn's step limit is a question about turns, not about
          // Omada — built-ins included, where a project's own limit is the
          // one a built-in note's turns also answer to.
          const Divider(),
          _TurnMaxStepsRow(project: project),
          // A built-in that ships its own note reads no file, so there is no
          // instructions to edit for one — unless it asks for the user's files
          // on top of the note, in which case the project AGENTS.md is the
          // file the row opens.
          if (builtIn?.bundledInstructions == null ||
              builtIn?.includesUserInstructions == true) ...[
            const Divider(),
            _ProfileRow(project: project),
          ],
          // What a turn in this project is told by name: the shared skills and
          // agents pages against this project's directories. The built-ins'
          // pages are view-only — the sections gate themselves on the spec —
          // but what they hold is shown, the way the Memory rows are.
          const Divider(),
          _PromptsRow(
            project: project,
            kind: CompletionKind.skill,
            icon: Icons.extension_outlined,
          ),
          const Divider(),
          _PromptsRow(
            project: project,
            kind: CompletionKind.agent,
            icon: Icons.smart_toy_outlined,
          ),
          const Divider(),
          _TempChatTtlRow(project: project),
          const Divider(),
          _EnvironmentRow(project: project),
          if (builtIn == null) ...[
            const Divider(),
            DestructiveButton(
              icon: Icons.delete,
              label: "Delete project",
              confirmTitle: "Delete project?",
              confirmMessage: "Delete \"$project\", its $count "
                  "${count == 1 ? "chat" : "chats"} and its shared workspace? "
                  "This cannot be undone.",
              onConfirmed: () => deleteProject(context, ref, project,
                  popToRoot: true, confirm: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField({
    required this.label,
    required this.value,
    required this.snack,
  });

  final String label;
  final String value;
  final String snack;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(
        value,
        style: const TextStyle(fontFamily: monoFamily),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: "Copy",
        onPressed: () => copyToClipboard(context, value, said: snack),
      ),
    );
  }
}

/// What the new-chat screen asks over this project's badge. Null is the
/// app-wide question; empty means the screen asks nothing. The reset button
/// is the way back to null — a blank save is the other value, not the
/// default's.
class _DescriptionRow extends ConsumerWidget {
  const _DescriptionRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description =
        ref.watch(projectSettingsProvider(project).select((s) => s.description));
    return ListTile(
      title: const Text("Description"),
      // What the screen asks for this project, the resolver owning the
      // null/blank/text cases; null out of it is the blank answer, shown
      // here as what it is.
      subtitle: Text(
        emptyChatQuestionFor(project, description: description) ?? "Empty",
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: ResetButton(
        resetLabel: "default",
        onReset: () =>
            ref.read(projectSettingsProvider(project).notifier).setDescription(null),
      ),
      onTap: () async {
        final text = await promptForText(
          context,
          title: "Description",
          initial: description ?? "",
          hint: defaultEmptyChatQuestion,
          confirmLabel: "Save",
          allowBlank: true,
        );
        if (text == null || !context.mounted) return;
        ref.read(projectSettingsProvider(project).notifier).setDescription(text);
      },
    );
  }
}

/// Opens the editor for the project's instructions, and says whether the
/// file is there.
class _ProfileRow extends ConsumerStatefulWidget {
  const _ProfileRow({required this.project});

  final String project;

  @override
  ConsumerState<_ProfileRow> createState() => _ProfileRowState();
}

class _ProfileRowState extends ConsumerState<_ProfileRow> {
  bool? _set;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final config = ref.read(appConfigProvider);
    final path = config.projectInstructionsFile(project: widget.project);
    final there = await config.fs.file(path).exists();
    if (mounted) setState(() => _set = there);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.rule),
      title: const Text("Instructions"),
      subtitle: Text(_set == null ? "" : (_set! ? "Set" : "Not set")),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ProfilePage(project: widget.project)),
        );
        _check();
      },
    );
  }
}

/// Whether this project keeps its own memory store or shares the default
/// project's. Off, its chats read and write the default project's memories.
class _UseProjectMemoryRow extends ConsumerWidget {
  const _UseProjectMemoryRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(projectSettingsProvider(project).select((s) => s.useProjectMemory));
    return SwitchListTile(
      title: const Text("Project memory"),
      subtitle: const Text(
          "Off, this project's chats share the default project's memories."),
      value: on,
      onChanged: (value) =>
          ref.read(projectSettingsProvider(project).notifier).setUseProjectMemory(value),
    );
  }
}

/// Whether this project's chats can carry several agents in one round. A
/// user project's toggle; the page gates it off for a built-in.
class _OmadaRow extends ConsumerWidget {
  const _OmadaRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(projectSettingsProvider(project).select((s) => s.omada));
    return SwitchListTile(
      title: const Text("Omada"),
      subtitle: const Text(
          "Several named agents take part in a chat's replies, alongside the "
          "main one."),
      value: on,
      onChanged: (value) =>
          ref.read(projectSettingsProvider(project).notifier).setOmada(value),
    );
  }
}

/// The project's default for how its rounds run, shown only while the
/// project's Omada toggle is on. Null is sequential, the same answer the
/// section's labels name.
class _OmadaOrderingRow extends ConsumerWidget {
  const _OmadaOrderingRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref
        .watch(projectSettingsProvider(project).select((s) => s.omadaOrdering));
    final app = ref.watch(appSettingsProvider).omadaOrdering;
    final effective = value ?? app ?? OmadaOrdering.sequential;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InheritableDropdown<OmadaOrdering>(
          label: "Round order",
          value: value,
          // Null here resolves to the app's default, not the enum's own.
          inherited: omadaOrderingLabels[app ?? OmadaOrdering.sequential],
          options: omadaOrderingLabels,
          onChanged: (v) =>
              ref.read(projectSettingsProvider(project).notifier).setOmadaOrdering(v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(omadaOrderingDescriptions[effective]!,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

/// How many handoff generations a round may run here, overriding the app
/// default. Shown only while the project's Omada toggle is on; Default names
/// what the app setting says now.
class _OmadaMaxGenerationsRow extends ConsumerWidget {
  const _OmadaMaxGenerationsRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InheritableSlider(
      label: "Max generations per round",
      value: ref.watch(projectSettingsProvider(project)
          .select((s) => s.omadaMaxGenerations)),
      stops: AppSettings.omadaGenerationStops,
      inherited: ref.watch(appSettingsProvider).omadaMaxGenerations,
      onChanged: (v) => ref
          .read(projectSettingsProvider(project).notifier)
          .setOmadaMaxGenerations(v),
    );
  }
}

/// How many model calls a direct turn may make here, overriding the app
/// default. Not an Omada row — a turn is a turn in every project — but shown
/// beside the round settings, the same level of override.
class _TurnMaxStepsRow extends ConsumerWidget {
  const _TurnMaxStepsRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InheritableSlider(
      label: "Max steps per turn",
      value: ref.watch(
          projectSettingsProvider(project).select((s) => s.turnMaxSteps)),
      stops: AppSettings.turnStepStops,
      inherited: ref.watch(appSettingsProvider).turnMaxSteps ??
          AppSettings.defaultTurnMaxSteps,
      onChanged: (v) =>
          ref.read(projectSettingsProvider(project).notifier).setTurnMaxSteps(v),
    );
  }
}

/// The project's own command variables, beside the app-level ones. A name set
/// here wins over one set there, and nothing set here is anything but the
/// app's where the project sets none.
class _EnvironmentRow extends ConsumerWidget {
  const _EnvironmentRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final count = settings.environment?.length ?? 0;
    return ListTile(
      leading: const Icon(Icons.key_outlined),
      title: const Text("Environment"),
      subtitle: Text(count == 0
          ? "Default (inherited)"
          : "$count variable${count == 1 ? "" : "s"}"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ProjectEnvironmentPage(project: project),
        ),
      ),
    );
  }
}

class _ProjectEnvironmentPage extends ConsumerWidget {
  const _ProjectEnvironmentPage({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    return Scaffold(
      appBar: AppBar(title: const Text("Environment")),
      body: EnvironmentSection(
        env: settings.environment ?? const {},
        description: "Passed to every command the project's chats run, over the "
            "app-level variables. A command already running keeps what it "
            "started with.",
        onSaved: (env) => ref
            .read(projectSettingsProvider(project).notifier)
             .setEnvironment(env.isEmpty ? null : env),
       ),
    );
  }
}

/// The project's temporary-chat TTL override. Null means inherit the app
/// default; the inherited value is named in the Default entry.
class _TempChatTtlRow extends ConsumerWidget {
  const _TempChatTtlRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final appTtl = ref.watch(appSettingsProvider).tempChatTtl;
    return InheritableDropdown<TempChatTtl>(
      label: "Temporary chats",
      value: settings.tempChatTtl,
      inherited: appTtl.label,
      options: tempChatTtlLabels,
      onChanged: (v) =>
          ref.read(projectSettingsProvider(project).notifier).setTempChatTtl(v),
    );
  }
}

/// The row that opens one of the shared prompt pages — skills or agents —
/// against this project's directories. The subtitle counts the entries the
/// project's library serves, inherited and bundled included, since that is
/// what a turn in the project is offered; the page itself says which are the
/// project's own.
class _PromptsRow extends ConsumerWidget {
  const _PromptsRow({
    required this.project,
    required this.kind,
    required this.icon,
  });

  final String project;
  final CompletionKind kind;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref.watch(promptLibraryProvider(project)).entries(kind).length;
    return ListTile(
      leading: Icon(icon),
      title: Text(kind.label),
      subtitle: Text(count == 0 ? "None" : "$count"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text("${kind.label} — $project")),
            // The section owns the scroll: its footer (import, install-to)
            // is pinned to the bottom of the page rather than one row more
            // of a list here.
            body: switch (kind) {
              CompletionKind.skill => SkillsSection(project: project),
              CompletionKind.agent => AgentsSection(project: project),
            },
          ),
        ),
      ),
    );
  }
}
