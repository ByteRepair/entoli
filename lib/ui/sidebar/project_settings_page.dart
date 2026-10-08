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
import "../settings/permissions_section.dart";
import "../settings/skills_settings.dart";
import "../settings/writable_dirs_section.dart";
import "../widgets/destructive_button.dart";
import "../widgets/dialogs.dart" show confirm, promptForText;
import "../widgets/environment_section.dart";
import "../widgets/resettable_field.dart";
import "../widgets/settings_card.dart";
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

  /// The fixed width every card in the rows below takes, the row deciding the
  /// per-screen answer from its own constraints.
  static const cardWidth = 160.0;

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
          // The cards: what the project is, what it holds, and how a turn
          // reaches out of it. Name and path copy themselves — the whole card
          // is the button the copy icon used to be — description keeps its
          // dialog on the tap, workspace and the prompts pages keep their
          // pushes, and chats states its count without one.
          SettingsCardRow(children: [
            _NameCard(project: project),
            _PathCard(path: path),
            if (builtIn == null) _DescriptionCard(project: project),
            // A row card, held to the width the rest of the row was given,
            // rather than filling the parent the way a lone line's tile does.
            SizedBox(
              width: ProjectSettingsPage.cardWidth,
              child: WorkspaceTile(
                root: ref
                    .watch(appConfigProvider)
                    .projectWorkspaceDir(project: project),
                title: "Project workspace",
              ),
            ),
            _ChatsCard(count: count),
          ]),
          const Divider(),
          // Instructions, skills and agents: what a turn in this project is
          // told by name. The built-ins' pages are view-only — the sections
          // gate themselves on the spec — but what they hold is shown, the way
          // the Memory rows are.
          SettingsCardRow(children: [
            if (builtIn?.bundledInstructions == null ||
                builtIn?.includesUserInstructions == true)
              _ProfileCard(project: project),
            _PromptsCard(
              project: project,
              kind: CompletionKind.skill,
              icon: Icons.extension_outlined,
            ),
            _PromptsCard(
              project: project,
              kind: CompletionKind.agent,
              icon: Icons.smart_toy_outlined,
            ),
          ]),
          const Divider(),
          SettingsCardRow(children: [
            _EnvironmentCard(project: project),
            if (builtIn == null) _PermissionsCard(project: project),
          ]),
          const Divider(),
          if (builtIn == null) ...[
            _UseProjectMemoryRow(project: project),
            MemoryTile(
              dir: ref.watch(appConfigProvider).memoryDir(project: project),
              title: "Project memories",
            ),
            const Divider(),
          ],
          // The Omada rows: the toggle — read-only for a built-in, whose
          // answer is its spec — and the ordering and round limit, shown
          // wherever the answer is on.
          _OmadaRow(project: project, builtIn: builtIn),
          if (ref.watch(omadaOnProvider(project))) ...[
            _OmadaOrderingRow(project: project),
            _OmadaMaxGenerationsRow(project: project),
          ],
          // A direct turn's step limit is a question about turns, not about
          // Omada — built-ins included, where a project's own limit is the
          // one a built-in note's turns also answer to.
          const Divider(),
          _TurnMaxStepsRow(project: project),
          const Divider(),
          _TempChatTtlRow(project: project),
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

class _NameCard extends StatelessWidget {
  const _NameCard({required this.project});

  final String project;

  @override
  Widget build(BuildContext context) {
    return SettingsCard.copy(
      icon: Icons.badge_outlined,
      title: "Project name",
      value: project,
      said: "Copied project name",
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return SettingsCard.copy(
      icon: Icons.route,
      title: "Path",
      value: path,
      said: "Copied project path",
    );
  }
}

/// What the new-chat screen asks over this project's badge. Null is the
/// app-wide question; empty means the screen asks nothing. The reset button
/// is the way back to null — a blank save is the other value, not the
/// default's.
class _DescriptionCard extends ConsumerWidget {
  const _DescriptionCard({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description =
        ref.watch(projectSettingsProvider(project).select((s) => s.description));
    return SettingsCard(
      icon: Icons.description_outlined,
      title: "Description",
      // What the screen asks for this project, the resolver owning the
      // null/blank/text cases; null out of it is the blank answer, shown
      // here as what it is.
      subtitle: emptyChatQuestionFor(project, description: description) ?? "Empty",
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

class _ChatsCard extends StatelessWidget {
  const _ChatsCard({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      icon: Icons.forum_outlined,
      title: "Chats",
      subtitle: count == 1 ? "1" : "$count",
    );
  }
}

/// Opens the editor for the project's instructions, and says whether the
/// file is there.
class _ProfileCard extends ConsumerStatefulWidget {
  const _ProfileCard({required this.project});

  final String project;

  @override
  ConsumerState<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<_ProfileCard> {
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
    return SettingsCard(
      icon: Icons.rule,
      title: "Instructions",
      subtitle: _set == null ? "" : (_set! ? "Set" : "Not set"),
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
/// user project's toggle; a built-in's is the same row with the switch
/// disabled, its answer being its spec — the state shown, not offered.
class _OmadaRow extends ConsumerWidget {
  const _OmadaRow({required this.project, required this.builtIn});

  final String project;
  final BuiltinProject? builtIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(omadaOnProvider(project));
    return SwitchListTile(
      title: const Text("Omada"),
      subtitle: const Text(
          "Several named agents take part in a chat's replies, alongside the "
          "main one."),
      value: on,
      onChanged: builtIn == null
          ? (value) =>
              ref.read(projectSettingsProvider(project).notifier).setOmada(value)
          : null,
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
class _EnvironmentCard extends ConsumerWidget {
  const _EnvironmentCard({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final count = settings.environment?.length ?? 0;
    return SettingsCard(
      icon: Icons.key_outlined,
      title: "Environment",
      subtitle: count == 0
          ? "Default (inherited)"
          : "$count variable${count == 1 ? "" : "s"}",
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
class _PromptsCard extends ConsumerWidget {
  const _PromptsCard({
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
    return SettingsCard(
      icon: icon,
      title: kind.label,
      subtitle: count == 0 ? "None" : "$count",
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

/// The project's own permission rules, a page like the environment's — the
/// same section widget both serve, over this tier's save.
class _PermissionsCard extends ConsumerWidget {
  const _PermissionsCard({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final count = settings.permissions.length;
    return SettingsCard(
      icon: Icons.shield_outlined,
      title: "Permissions",
      subtitle: count == 0
          ? "Default (inherited)"
          : "$count rule${count == 1 ? "" : "s"}",
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ProjectPermissionsPage(project: project),
        ),
      ),
    );
  }
}

class _ProjectPermissionsPage extends ConsumerWidget {
  const _ProjectPermissionsPage({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(project));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text("Permissions")),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            "The app's own permissions (Settings > General > Agent) apply "
            "before these, in every project, without being listed here.",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 4),
        PermissionsSection(
          rules: settings.permissions,
          description: "Standing rules for this project's chats. Writes "
              "outside the workspaces that a rule grants are also where the "
              "sandbox's write grant widens.",
          onSaved: (rules) => ref
              .read(projectSettingsProvider(project).notifier)
              .setProjectPermissions(rules),
        ),
        const Divider(),
        WritableDirsSection(
          dirs: settings.writableDirs,
          description: "Directories the project's sandboxed commands may "
              "write to, beside the workspace.",
          onSaved: (dirs) => ref
              .read(projectSettingsProvider(project).notifier)
              .setWritableDirs(dirs),
        ),
        const Divider(),
        _SandboxRepromptRow(project: project),
      ]),
    );
  }
}

/// Whether a sandbox-denied write is offered back here, over the app
/// default. Null inherits; the row says what the effective answer is and a
/// switch puts this project's own in place — the same
/// inherit-then-override shape the TTL row keeps.
class _SandboxRepromptRow extends ConsumerWidget {
  const _SandboxRepromptRow({required this.project});

  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(
        projectSettingsProvider(project).select((s) => s.sandboxReprompt));
    final inherited = ref.watch(
        projectSettingsProvider(null).select((s) => s.sandboxReprompt ?? true));
    return SwitchListTile(
      title: const Text("Offer to rerun sandbox-denied commands"),
      subtitle: Text(override == null
          ? "Default (${inherited ? "on" : "off"}). A switch here overrides "
              "the app's default for this project's chats."
          : override
              ? "On for this project's chats."
              : "Off for this project's chats."),
      value: override ?? inherited,
      onChanged: (value) => ref
          .read(projectSettingsProvider(project).notifier)
          .setProjectSandboxReprompt(value),
    );
  }
}
