import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_icon.dart";
import "../../domain/app_theme.dart";
import "../../domain/backup.dart";
import "../../domain/llm_provider.dart";
import "../../domain/permission.dart";
import "../../domain/project.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/app_mark.dart";
import "../widgets/dialogs.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/provider_dialog.dart";
import "../widgets/provider_model_selector.dart";
import "../widgets/resettable_field.dart";
import "../workspace/workspace_page.dart";

/// The page's categories, in the order they are offered. Everything an
/// endpoint is is Providers, everything a model is asked to do is LLMs, General
/// is the app itself, and Data is all of it at once — the chats, the settings
/// and the workspaces as one file to keep.
enum SettingsCategory {
  general("General", Icons.tune),
  providers("Providers", Icons.cloud_outlined),
  llms("LLMs", Icons.auto_awesome_outlined),
  data("Data", Icons.inventory_2_outlined);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SettingsCategory _category = SettingsCategory.general;

  /// The state is kept where the category is a page of its own too, so that a
  /// window widened while one is open lands on it rather than on General.
  void _open(SettingsCategory category, {required bool push}) {
    setState(() => _category = category);
    if (push) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => _CategoryPage(category)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page is the whole window, so its width is the window's — no
    // `LayoutBuilder`, which would run the Scaffold's build during layout.
    final wide = MediaQuery.sizeOf(context).width >= navBreakpoint;
    final categories = _Categories(
      // Nothing is selected where the list is the whole page: a category there
      // is somewhere to go rather than what is showing beside it.
      selected: wide ? _category : null,
      onSelect: (category) => _open(category, push: !wide),
    );
    final bar = AppBar(title: const Text("Settings"));

    if (!wide) return Scaffold(appBar: bar, body: categories);
    return Scaffold(
      appBar: bar,
      body: Row(
        children: [
          SizedBox(width: navPanelWidth, child: categories),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListView(key: ValueKey(_category), children: _sectionsOf(_category)),
          ),
        ],
      ),
    );
  }
}

/// One category as a page over the list, which is what a narrow window gets in
/// place of the panel. Leaving it is the back gesture, so the bar holds nothing
/// but the name of what is on it.
class _CategoryPage extends StatelessWidget {
  const _CategoryPage(this.category);

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    // Widened, the page behind is already showing this category beside its
    // panel, and two of it is one too many.
    if (MediaQuery.sizeOf(context).width >= navBreakpoint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          Navigator.of(context).pop();
        }
      });
    }
    return Scaffold(
      appBar: AppBar(title: Text(category.label)),
      body: ListView(children: _sectionsOf(category)),
    );
  }
}

/// What is filed under a category, whether it is drawn beside the list or on a
/// page of its own.
List<Widget> _sectionsOf(SettingsCategory category) => switch (category) {
      // The agent's own settings are here rather than under LLMs: the mode is a
      // behaviour, and the classifier picker travels with it because auto mode
      // is unusable without one.
      SettingsCategory.general => const [
          _WorkspaceSection(),
          Divider(),
          _AppearanceSection(),
          Divider(),
          _AgentSection(),
          Divider(),
          _TempChatSection(),
          Divider(),
          _EnvironmentSection(),
          Divider(),
          _DeleteAllChats(),
        ],
      SettingsCategory.providers => const [_ProvidersEditor()],
      SettingsCategory.llms => const [_DefaultsSection()],
      SettingsCategory.data => const [_BackupSection()],
    };

/// The categories as a list: beside the page where there is room for one, and
/// the page itself where there is not. Material, not Scaffold, since the page
/// owns that.
class _Categories extends StatelessWidget {
  const _Categories({required this.selected, required this.onSelect});

  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context) => Material(
        child: SafeArea(
          child: ListView(
            children: [
              for (final category in SettingsCategory.values)
                ListTile(
                  selected: category == selected,
                  leading: Icon(category.icon),
                  title: Text(category.label),
                  trailing: selected == null ? const Icon(Icons.chevron_right) : null,
                  onTap: () => onSelect(category),
                ),
            ],
          ),
        ),
      );
}

/// A section heading and, under it, a line saying what the section is for.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// The default project has no settings page of its own, so this is the only way
/// to the workspace the chats outside a project share.
class _WorkspaceSection extends ConsumerWidget {
  const _WorkspaceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = "${projectLabel(null)} workspace";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          name,
          description: "Where the agent puts work meant for another chat, for "
              "every chat outside a project.",
        ),
        WorkspaceTile(
          root: ref.watch(appConfigProvider).projectWorkspaceDir(),
          title: name,
        ),
      ],
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final switchesLauncher = ref.watch(launcherIconsProvider).available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          "Appearance",
          description: switchesLauncher
              ? "How the app looks, and the icon it wears here and on the home "
                  "screen."
              : "How the app looks, and the icon it wears. The launcher's own "
                  "icon is set when the app is installed, so it does not "
                  "follow this.",
        ),
        LabelledField(
          label: "Theme",
          child: SegmentedButton<AppTheme>(
            segments: [
              for (final theme in AppTheme.values)
                ButtonSegment(value: theme, label: Text(theme.label)),
            ],
            selected: {settings.appTheme},
            onSelectionChanged: (picked) =>
                ref.read(appSettingsProvider.notifier).setAppTheme(picked.first),
          ),
        ),
        LabelledField(
          label: "Icon",
          child: Row(
            spacing: 12,
            children: [
              for (final icon in AppIcon.values)
                _IconChoice(
                  icon: icon,
                  selected: icon == settings.appIcon,
                  onTap: () =>
                      ref.read(appSettingsProvider.notifier).setAppIcon(icon),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final AppIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Tooltip(
        message: icon.description,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 104,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                AppIconImage(icon, size: 48),
                const SizedBox(height: 10),
                Text(icon.label, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a new chat gets. A live reference, not a snapshot: retargeting it
/// retargets every chat that pinned nothing.
class _DefaultsSection extends ConsumerWidget {
  const _DefaultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader("New chats"),
        // Nothing above the app level to inherit from: Default means whatever
        // the backend picks.
        LabelledField(
          label: "LLM",
          child: ModelPicker(
            choice: (
              providerId: settings.defaultProviderId,
              modelId: settings.defaultModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setDefault(choice),
          ),
        ),
        LabelledField(
          label: "Title LLM",
          child: OptionalModelPicker(
            offLabel: "Off",
            helperText: "Names a chat from its first message. Off, chats stay "
                "\"New chat\" until you rename them.",
            choice: (
              providerId: settings.titleProviderId,
              modelId: settings.titleModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setTitleModel(choice),
          ),
        ),
      ],
    );
  }
}

/// The endpoints the agent calls and how it gates commands.
class _AgentSection extends ConsumerWidget {
  const _AgentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final noClassifier = settings.classifierProviderId == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Agent",
          description: "The built-in agent, running inside Entoli. It calls the "
              "model itself and runs its commands in the chat's workspace.",
        ),
        LabelledField(
          label: "Running commands",
          child: DropdownButtonFormField<ApproveMode>(
            initialValue: settings.approveMode,
            isExpanded: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              helperText: settings.approveMode == ApproveMode.auto && noClassifier
                  ? "No classifier model set — auto mode will ask for every command."
                  : null,
            ),
            items: [
              for (final entry in approveModeLabels.entries)
                DropdownMenuItem(
                  value: entry.key,
                  enabled: entry.key != ApproveMode.auto || !noClassifier,
                  child: Text(entry.value),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                ref.read(appSettingsProvider.notifier).setApproveMode(value);
              }
            },
          ),
        ),
        LabelledField(
          label: "Classifier LLM",
          child: OptionalModelPicker(
            offLabel: "Off",
            helperText: "Classifies commands as safe, dangerous, or uncertain. "
                "Off, auto mode asks for every command.",
            choice: (
              providerId: settings.classifierProviderId,
              modelId: settings.classifierModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setClassifierModel(choice),
          ),
        ),
      ],
    );
  }
}

class _TempChatSection extends ConsumerWidget {
  const _TempChatSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Temporary chats",
          description: "Chats that are hidden and then deleted after a delay "
              "from when their TTL was enabled. A project or an individual chat "
              "can override this.",
        ),
        LabelledField(
          label: "Delete chats after",
          child: DropdownButtonFormField<TempChatTtl>(
            initialValue: settings.tempChatTtl,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final entry in tempChatTtlLabels.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) {
              if (value != null) {
                ref.read(appSettingsProvider.notifier).setTempChatTtl(value);
              }
            },
          ),
        ),
      ],
    );
  }
}

class _ProvidersEditor extends ConsumerWidget {
  const _ProvidersEditor();

  /// One upsert for both routes in: editing an entry and adding one that turns
  /// out to share an id mean the same thing, and two entries under one name
  /// would show the same models twice.
  Future<void> _upsert(
    BuildContext context,
    WidgetRef ref, {
    LlmProviderConfig? initial,
    String title = "Add provider",
  }) async {
    final saved = await promptForProvider(context, initial: initial, title: title);
    if (saved == null) return;
    final providers = [
      ...ref.read(appSettingsProvider).llmProviders.where((p) => p.id != saved.id),
      saved,
    ];
    await ref.read(appSettingsProvider.notifier).setProviders(providers);
  }

  Future<void> _remove(WidgetRef ref, LlmProviderConfig provider) async {
    final providers =
        ref.read(appSettingsProvider).llmProviders.where((p) => p.id != provider.id).toList();
    await ref.read(appSettingsProvider.notifier).setProviders(providers);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(appSettingsProvider).llmProviders;
    final configured = providers.map((p) => p.id).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          "Providers",
          description: providers.isEmpty
              ? "None yet. The agent cannot answer until one is added."
              : "Where the models come from. Each is an endpoint, a key, and "
                  "the models it offers.",
        ),
        for (final provider in providers)
          _EditableRow(
            title: provider.displayName,
            subtitle: _describe(provider),
            removeLabel: "Remove ${provider.id}",
            onTap: () => _upsert(context, ref,
                initial: provider, title: "Edit ${provider.displayName}"),
            onRemove: () => _remove(ref, provider),
          ),
        _AddButtonRow(
          // The button's own context, which is what the menu is anchored under.
          child: Builder(
            builder: (context) => OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Add provider"),
              onPressed: () => _add(context, ref, configured),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref, Set<String> configured) async {
    final chosen = await showAnchoredMenu<VoidCallback>(context, [
      // One already configured is edited from its row rather than added again.
      for (final preset in llmProviderPresets)
        if (!configured.contains(preset.id))
          PopupMenuItem(
            value: () => _upsert(context, ref, initial: preset),
            child: Text(preset.displayName),
          ),
      PopupMenuItem(
        value: () => _upsert(context, ref),
        child: const Text("Custom…"),
      ),
    ]);
    if (context.mounted) chosen?.call();
  }

  String _describe(LlmProviderConfig provider) {
    final key = provider.apiKey.isNotEmpty
        ? "key set"
        : provider.apiKeyEnv != null
            ? "\$${provider.apiKeyEnv}"
            : "no key";
    final models =
        provider.models.isEmpty ? "models from endpoint" : "${provider.models.length} models";
    return "${provider.baseUrl} · $key · $models";
  }
}

/// What the agent's commands run under, and where a provider that names its
/// key rather than holding it looks.
class _EnvironmentSection extends ConsumerWidget {
  const _EnvironmentSection();

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? name}) async {
    final env = ref.read(appSettingsProvider).environment;
    final pair = await promptForPair(
      context,
      title: name == null ? "Add variable" : "Edit $name",
      nameLabel: "Name",
      valueLabel: "Value",
      name: name ?? "",
      value: name == null ? "" : env[name] ?? "",
    );
    if (pair == null) return;
    // A rename drops the old key rather than leaving both behind.
    final next = {...env}..remove(name);
    next[pair.name] = pair.value;
    await ref.read(appSettingsProvider.notifier).setEnvironment(next);
  }

  Future<void> _remove(WidgetRef ref, String name) async {
    final next = {...ref.read(appSettingsProvider).environment}..remove(name);
    await ref.read(appSettingsProvider.notifier).setEnvironment(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(appSettingsProvider).environment;
    final names = env.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Environment",
          description: "Passed to every command the agent runs. A command already "
              "running keeps what it started with.",
        ),
        for (final name in names)
          _EditableRow(
            title: name,
            // These are mostly API keys, and settings is a page people show
            // people.
            subtitle: "•" * env[name]!.length.clamp(0, 24),
            removeLabel: "Remove $name",
            onTap: () => _edit(context, ref, name: name),
            onRemove: () => _remove(ref, name),
          ),
        _AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add variable"),
            onPressed: () => _edit(context, ref),
          ),
        ),
      ],
    );
  }
}

/// One entry in an editable list: tap the row to change it, the cross to drop
/// it. Both list sections here are the same affordance over different data.
class _EditableRow extends StatelessWidget {
  const _EditableRow({
    required this.title,
    required this.subtitle,
    required this.removeLabel,
    required this.onTap,
    required this.onRemove,
  });

  final String title;
  final String subtitle;
  final String removeLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: onTap,
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: removeLabel,
          onPressed: onRemove,
        ),
      );
}

class _AddButtonRow extends StatelessWidget {
  const _AddButtonRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: child);
}

class _DeleteAllChats extends ConsumerWidget {
  const _DeleteAllChats();

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final count = (await ref.read(chatRepositoryProvider).listChats()).length;
    if (!context.mounted) return;

    final confirmed = await confirm(
      context,
      title: "Delete all chats?",
      message: count == 0
          ? "There are no chats to delete."
          : "This permanently removes $count ${count == 1 ? "chat" : "chats"}, "
              "including their workspaces. It cannot be undone.",
      confirmLabel: count == 0 ? null : "Delete all",
      destructive: true,
    );
    if (!confirmed) return;

    ref.read(selectedChatIdProvider.notifier).select(null);
    await ref.read(chatRepositoryProvider).deleteAllChats();
    ref.invalidate(chatListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        icon: const Icon(Icons.delete_forever),
        label: const Text("Delete all chats"),
        onPressed: () => _confirmAndDelete(context, ref),
      ),
    );
  }
}

/// Everything the app holds, out as one file and back in. The format is
/// `domain/backup.dart`'s; this is the two buttons, and what the second of them
/// has to ask before it goes ahead.
class _BackupSection extends ConsumerStatefulWidget {
  const _BackupSection();

  @override
  ConsumerState<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<_BackupSection> {
  /// Both buttons and the bar read it, so it is state rather than a notifier —
  /// the section is a heading and two buttons, and rebuilding it is nothing.
  var _busy = false;

  Future<void> _export() => _guard(() async {
        final bytes = await ref.read(chatRepositoryProvider).exportBackup();
        await ref.read(backupHandoffProvider).save(backupFilename(DateTime.now()), bytes);
        _say("Backup written — ${formatSize(bytes.length)}.");
      });

  Future<void> _import() async {
    if (_busy) return;
    // Restoring under a turn would pull the chat it is writing to out from
    // under it, and the turn would carry on appending to a log that is gone.
    if (ref.read(agentBackendProvider).runningTurns.value.isNotEmpty) {
      return _say("A turn is still running. Stop it first.");
    }
    final bytes = await ref.read(backupHandoffProvider).pick();
    if (bytes == null || !mounted) return;

    final Backup backup;
    try {
      backup = parseBackup(bytes);
    } on BackupFormatException catch (e) {
      return _say("That file cannot be restored: $e.");
    }
    if (!mounted) return;

    final confirmed = await confirm(
      context,
      title: "Restore this backup?",
      message: "${_describe(backup)}\n\nEverything here now — every chat, "
          "project, workspace and setting — is replaced by what is in it. Your "
          "own commands and agents come back too, but only appear after the "
          "app is restarted.",
      confirmLabel: "Restore",
      destructive: true,
    );
    if (!confirmed) return;

    await _guard(() async {
      await ref.read(chatRepositoryProvider).importBackup(backup);
      if (!mounted) return;
      // What the app is holding was read out of the files that have just been
      // replaced: the selection points at a chat that may be gone, and every
      // provider below reads through the config.
      ref.read(selectedChatIdProvider.notifier).select(null);
      ref.read(selectedProjectProvider.notifier).select(null);
      ref.invalidate(appSettingsProvider);
      ref.invalidate(projectSettingsProvider);
      ref.invalidate(chatListProvider);
      ref.invalidate(projectListProvider);
      ref.invalidate(availableModelsProvider);
      _say("Restored ${backup.chats} ${backup.chats == 1 ? "chat" : "chats"}.");
    });
  }

  /// One at a time, and a failure is said rather than thrown: both routes end
  /// at a plugin — a save dialog, a share sheet, a chooser — and a platform
  /// that refuses is the ordinary case rather than a bug.
  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (e) {
      _say("That did not work: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _describe(Backup backup) {
    final made = backup.createdAt;
    final when = made == null ? "A backup" : "A backup from ${_day(made.toLocal())}";
    return "$when, holding ${backup.chats} "
        "${backup.chats == 1 ? "chat" : "chats"} and ${formatSize(backup.size)}.";
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            "Backup",
            description: "Every chat, project, workspace, prompt and setting as "
                "one zip. Restoring one replaces what is here.",
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              spacing: 12,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: const Text("Export"),
                  onPressed: _busy ? null : _export,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text("Import"),
                  onPressed: _busy ? null : _import,
                ),
              ],
            ),
          ),
          // Two logical pixels where the buttons are dead, rather than a
          // spinner over the page: a big export takes a while and there is
          // nothing to do in the meantime but watch it.
          SizedBox(
            height: 2,
            child: _busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
        ],
      );
}

const _months = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

String _day(DateTime when) =>
    "${when.day} ${_months[when.month - 1]} ${when.year}";
