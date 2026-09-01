import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_icon.dart";
import "../../domain/app_theme.dart";
import "../../domain/corner_radius.dart";
import "../../domain/theme_colour.dart";
import "../../data/backup.dart";
import "../../core/platform/platform.dart" as platform;
import "../../domain/llm_provider.dart";
import "../../domain/permission.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../chat/widgets/activity_label.dart";
import "../sidebar/sidebar.dart";
import "../theme.dart";
import "../widgets/add_button_row.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/busy.dart";
import "../widgets/app_mark.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/environment_section.dart";
import "../widgets/formatting.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/provider_dialog.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "agents_settings.dart";
import "assistant_settings.dart";
import "byte_repair_settings.dart";
import "local_model_settings.dart";
import "reminders.dart";
import "skills_settings.dart";
import "sync_settings.dart";
import "terminal_settings.dart";
import "voice_settings.dart";

/// The page's categories, in the order they are offered. Everything an
/// endpoint is is Providers, everything a model is asked to do is LLMs, General
/// is the app itself, Data is all of it at once — the chats, the settings and
/// the workspaces as one file to keep — and About is the app rather than
/// anything it does, which is why it is last.
enum SettingsCategory {
  general("General", Icons.tune),
  terminal("Terminal", Icons.terminal),
  onDevice("On-device", Icons.memory),
  voice("Voice", Icons.graphic_eq),
  reminders("Reminders", Icons.alarm),
  skills("Skills", Icons.extension),
  agents("Agents", Icons.person_outline),
  byteRepair("Byte Repair", Icons.verified_user),
  sync("Sync", Icons.sync),
  providers("Providers", Icons.cloud_outlined),
  llms("LLMs", Icons.auto_awesome_outlined),
  memory("Memory", Icons.psychology),
  data("Data", Icons.inventory_2_outlined),
  about("About", Icons.info_outline);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialCategory});

  final SettingsCategory? initialCategory;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsCategory _category = widget.initialCategory ?? SettingsCategory.general;

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
      // Its own category for the reason Voice is one: the picker is a line and
      // the catalog under it is the rest of the page.
      SettingsCategory.terminal => const [
          TerminalSection(),
          // Draws its own divider, since a build with no proot in it has no
          // catalog to put under one.
          RootfsCatalogSection(),
        ],
      // Beside Terminal rather than under LLMs, and for the same reason it is:
      // what is picked is two lines and the catalog under it is the rest of the
      // page. Where a model runs is also a machine question rather than a
      // question about models — the LLMs category is what a chat is answered
      // by, and a model here appears there like any other.
      SettingsCategory.onDevice => const [
          LocalModelSection(),
          // Draws its own divider, since a build with no server in it has no
          // catalog to put under one.
          LocalModelCatalogSection(),
        ],
      // Its own category rather than a section under General: the two pickers
      // are two lines and the catalog under them is the rest of the page.
      SettingsCategory.voice => const [
          VoiceSection(),
          Divider(),
          AssistantSection(),
          // Draws its own dividers, since on Android there is no catalog and a
          // divider with nothing under it is a line across the bottom of the
          // page.
          VoiceCatalogSections(),
        ],
      // Says so and offers nothing where there is no clock to schedule with —
      // see the section itself.
      SettingsCategory.reminders => const [RemindersSection()],
      SettingsCategory.skills => const [SkillsSection()],
      SettingsCategory.agents => const [AgentsSection()],
      SettingsCategory.byteRepair => const [ByteRepairSection()],
      SettingsCategory.sync => const [SyncSection()],
      SettingsCategory.providers => const [_ProvidersEditor()],
      SettingsCategory.llms => const [_DefaultsSection()],
      // The two things the agent carries between conversations: the files the
      // user writes (instructions) and the ones it writes (memories).
      SettingsCategory.memory => const [
          _InstructionsSection(),
          Divider(),
          _AutoMemorySection(),
        ],
      SettingsCategory.data => const [_BackupSection()],
      SettingsCategory.about => const [_AboutSection()],
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

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final switchesLauncher = ref.watch(launcherIconsProvider).available;
    final hasSystemPalette = ref.watch(systemAccentProvider) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
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
            onSelectionChanged: (picked) => notifier.setAppTheme(picked.first),
          ),
        ),
        if (hasSystemPalette)
          SwitchListTile(
            title: const Text("Material 3 Expressive"),
            subtitle: const Text(
                "Build the palette from the colour the system is themed to, so "
                "the app follows the wallpaper the way the rest of the phone "
                "does."),
            value: settings.systemPalette,
            onChanged: notifier.setSystemPalette,
          ),
        // One accent is the seed of the whole palette, secondary included, so
        // while the system is picking there is nothing here to pick.
        if (ref.watch(paletteAccentProvider) == null) ...[
          _ChoiceRow(
            label: "Primary colour",
            children: [
              for (final colour in ThemeColour.values)
                _ColourChoice(
                  colour: colour,
                  selected: colour == settings.primaryColour,
                  onTap: () => notifier.setPrimaryColour(colour),
                ),
            ],
          ),
          _ChoiceRow(
            label: "Secondary colour",
            children: [
              for (final colour in ThemeColour.values)
                _ColourChoice(
                  colour: colour,
                  selected: colour == settings.secondaryColour,
                  onTap: () => notifier.setSecondaryColour(colour),
                ),
            ],
          ),
        ],
        _ChoiceRow(
          label: "Corners",
          children: [
            for (final corner in CornerRadius.values)
              _CornerChoice(
                corner: corner,
                selected: corner == settings.cornerRadius,
                onTap: () => notifier.setCornerRadius(corner),
              ),
          ],
        ),
        _ChoiceRow(
          label: "Icon",
          children: [
            for (final icon in AppIcon.values)
              _IconChoice(
                icon: icon,
                selected: icon == settings.appIcon,
                onTap: () => notifier.setAppIcon(icon),
              ),
          ],
        ),
      ],
    );
  }
}

/// A labelled row of choices, wrapping where the window is too narrow for all
/// of them.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LabelledField(
        label: label,
        child: Wrap(spacing: 12, runSpacing: 12, children: children),
      );
}

/// The eight seeds, as the colours themselves: a swatch says what it does and
/// a name in a dropdown would not.
class _ColourChoice extends StatelessWidget {
  const _ColourChoice({
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  final ThemeColour colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _Choice(
        tooltip: colour.label,
        label: colour.label,
        selected: selected,
        onTap: onTap,
        fill: colour.colour,
        width: 40,
        height: 40,
        // The tick sits on the swatch rather than on the surface, so it is read
        // against the colour it is marking.
        child: selected
            ? Icon(Icons.check,
                size: 18,
                color: ThemeData.estimateBrightnessForColor(colour.colour) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black)
            : null,
      );
}

/// A corner drawn at its own radius, which is the whole of what the choice is.
class _CornerChoice extends StatelessWidget {
  const _CornerChoice({
    required this.corner,
    required this.selected,
    required this.onTap,
  });

  final CornerRadius corner;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pixels = "${corner.radius.round()}";
    return _Choice(
      tooltip: pixels,
      label: pixels,
      selected: selected,
      onTap: onTap,
      corners: BorderRadius.circular(corner.radius),
      fill: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      width: 44,
      height: 44,
    );
  }
}

/// One of a row of things to pick: a swatch, a corner, an app icon. A [corners]
/// of null is a circle. The ring the selected one wears is here rather than at
/// each of the three, which is what keeps them the same ring.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.label,
    this.corners,
    this.fill,
    this.width,
    this.height,
    this.padding,
    this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  /// What a reader is told, where the choice draws no text of its own.
  final String? label;
  final BorderRadius? corners;
  final Color? fill;
  final double? width;
  final double? height;
  final EdgeInsets? padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: corners,
          customBorder: corners == null ? const CircleBorder() : null,
          child: Container(
            width: width,
            height: height,
            padding: padding,
            decoration: BoxDecoration(
              color: fill,
              shape: corners == null ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: corners,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// What this build is, who made it, and where the source is. The libraries are
/// Flutter's own licence page rather than a list kept here — see "What the app
/// is".
class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  static final _repository = Uri.parse("https://github.com/Yiannis128/agent-chat");
  static const _madeBy = "Made by Yiannis Charalambous";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("About"),
        ListTile(
          leading: const AppMark(size: 40),
          title: const Text(appTitle),
          subtitle: version == null ? null : Text("Version $version"),
        ),
        const ListTile(
          leading: Icon(Icons.person_outline),
          title: Text(_madeBy),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text("Source on GitHub"),
          subtitle: Text("$_repository"),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => ref.read(linkOpenerProvider).open(context, _repository),
        ),
        ListTile(
          leading: const Icon(Icons.balance_outlined),
          title: const Text("Open source libraries"),
          subtitle: const Text("Everything Entoli is built on, and its licence."),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: appTitle,
            applicationVersion: version,
            applicationIcon: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: AppMark(size: 48),
            ),
            applicationLegalese: _madeBy,
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
  Widget build(BuildContext context) => _Choice(
        tooltip: icon.description,
        selected: selected,
        onTap: onTap,
        corners: BorderRadius.circular(16),
        width: 104,
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: [
            AppIconImage(icon, size: 48),
            const SizedBox(height: 10),
            Text(icon.label, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      );
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
        const SectionHeader("New chats"),
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
        const SectionHeader(
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

/// Whether the agent reads AGENTS.md at all, and the sub-gates of a file it
/// does read: the imports it follows, the nested ones a read pulls in, and
/// the patterns that keep a file out.
class _InstructionsSection extends ConsumerWidget {
  const _InstructionsSection();

  Future<void> _editExcludes(BuildContext context, WidgetRef ref) async {
    final text = await promptForText(
      context,
      title: "Excluded files",
      initial: ref.read(appSettingsProvider).instructionExcludes.join("\n"),
      confirmLabel: "Save",
      hint: "One glob per line. ** spans directories, * and ? do not; a "
          "pattern without a / matches a file name.",
      maxLines: 5,
    );
    if (text == null) return;
    final patterns = [
      for (final line in text.split("\n"))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    await ref
        .read(appSettingsProvider.notifier)
        .setInstructionExcludes(patterns);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final excludes = settings.instructionExcludes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Instructions",
          description: "The AGENTS.md files are read into every turn: yours, "
              "at the root of your data directory, and the project's, in its "
              "workspace: rules the user wrote down once. The rows below reach "
              "further than those two, or keep one of them out.",
        ),
        SwitchListTile(
          title: const Text("Follow @file imports"),
          subtitle: const Text(
              "An @path inside an AGENTS.md pulls in the file it names."),
          value: settings.instructionImports,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setInstructionImports(value),
        ),
        SwitchListTile(
          title: const Text("Nested AGENTS.md"),
          subtitle: const Text(
              "Reading a file pulls in a subdirectory's own AGENTS.md."),
          value: settings.nestedInstructions,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setNestedInstructions(value),
        ),
        EditableRow(
          title: "Excluded files",
          subtitle: excludes.isEmpty ? "None" : excludes.join("\n"),
          removeLabel: "Clear exclusions",
          onTap: () => _editExcludes(context, ref),
          onRemove: () => ref
              .read(appSettingsProvider.notifier)
              .setInstructionExcludes(const []),
        ),
      ],
    );
  }
}

/// Whether the auto-memory subsystem runs: the master gate, its three sub-gates
/// and the background model that writes memories.
class _AutoMemorySection extends ConsumerWidget {
  const _AutoMemorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final on = settings.autoMemory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Auto memory",
          description: "A per-project store of short facts the agent reads into "
              "relevant turns and writes from finished ones.",
        ),
        SwitchListTile(
          title: const Text("Keep memories"),
          subtitle: const Text(
              "Off, the agent keeps no memories and recalls none."),
          value: on,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setAutoMemory(value),
        ),
        SwitchListTile(
          title: const Text("Recall relevant memories"),
          subtitle: const Text(
              "Each turn is offered the memories its prompt is about."),
          value: on && settings.memoryRecall,
          onChanged: on
              ? (value) => ref.read(appSettingsProvider.notifier).setMemoryRecall(value)
              : null,
        ),
        SwitchListTile(
          title: const Text("Write memories after a turn"),
          subtitle: const Text(
              "A background model keeps the facts a finished turn leaves "
              "behind. Needs a model below."),
          value: on && settings.memoryExtraction,
          onChanged: on
              ? (value) =>
                  ref.read(appSettingsProvider.notifier).setMemoryExtraction(value)
              : null,
        ),
        SwitchListTile(
          title: const Text("Memory tools"),
          subtitle: const Text(
              "The agent can save a memory it judges worth keeping, and "
              "search the store while a turn runs."),
          value: on && settings.memoryAgentTool,
          onChanged: on
              ? (value) =>
                  ref.read(appSettingsProvider.notifier).setMemoryAgentTool(value)
              : null,
        ),
        if (on)
          LabelledField(
            label: "Memory LLM",
            child: OptionalModelPicker(
              offLabel: "Off",
              helperText: "What writes memories in the background. Off, "
                  "extraction is inert and the store only ever holds what the "
                  "agent or you saved.",
              choice: (
                providerId: settings.memoryProviderId,
                modelId: settings.memoryModelId,
              ),
              onChanged: (choice) =>
                  ref.read(appSettingsProvider.notifier).setMemoryModel(choice),
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
        const SectionHeader(
          "Temporary chats",
          description: "Chats that are hidden and then deleted after a delay "
              "from when their TTL was enabled. A project or an individual chat "
              "can override this.",
        ),
        LabelledField(
          label: "Delete chats after",
          child: DropdownButtonFormField<TempChatTtl>(
            initialValue: settings.tempChatTtl,
            isExpanded: true,            items: [
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
        SectionHeader(
          "Providers",
          description: providers.isEmpty
              ? "None yet. The agent cannot answer until one is added."
              : "Where the models come from. Each is an endpoint, a key, and "
                  "the models it offers.",
        ),
        for (final provider in providers)
          EditableRow(
            title: provider.displayName,
            subtitle: _describe(provider),
            removeLabel: "Remove ${provider.id}",
            onTap: () => _upsert(context, ref,
                initial: provider, title: "Edit ${provider.displayName}"),
            onRemove: () => _remove(ref, provider),
          ),
        AddButtonRow(
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

  @override
  Widget build(BuildContext context, WidgetRef ref) => EnvironmentSection(
        env: ref.watch(appSettingsProvider).environment,
        description: "Passed to every command the agent runs. A command already "
            "running keeps what it started with.",
        onSaved: (env) =>
            ref.read(appSettingsProvider.notifier).setEnvironment(env),
      );
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
          : "This permanently removes ${plural(count, "chat")}, "
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
  final _busy = ValueNotifier(false);

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _export() => _guard(() async {
        final bytes = await writeBackup(ref.read(appConfigProvider));
        await ref.read(backupHandoffProvider).save(backupFilename(DateTime.now()), bytes);
        _say("Backup written — ${formatSize(bytes.length)}.");
      });

  Future<void> _import() async {
    // A courtesy rather than a safeguard: the restart stops the turn either
    // way, and killing someone's work without saying so is the rude version.
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
          "project, workspace and setting — is replaced by what is in it, and "
          "Entoli starts again on what was restored.",
      confirmLabel: "Restore",
      destructive: true,
    );
    if (!confirmed) return;

    // The restore runs inside the restart, with no session over the files it
    // replaces: everything that writes to them — a turn, the sweep, a
    // checkpoint — belongs to the session, so stopping it is what a check
    // against one writer could only approximate.
    final config = ref.read(appConfigProvider);
    await _guard(() => ref.read(appRestartProvider).restart(
          // `deleteTree` is the io side's `removeTree`-backed clear, which
          // `chmod`s past proot's mode-0000 bind stubs deep inside a
          // `projects/<project>/rootfs/` tree the restore is about to replace.
          // See `restoreBackup` for why every top-level dir goes through it.
          whileStopped: () => restoreBackup(
            config,
            backup,
            deleteTree: platform.deleteTree,
          ),
        ));
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _describe(Backup backup) {
    final made = backup.createdAt;
    final when = made == null
        ? "A backup"
        : "A backup from ${formatAge(DateTime.now().difference(made))}";
    return "$when, holding ${plural(backup.chats, "chat")} and "
        "${formatSize(backup.size)}.";
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            "Backup",
            description: "Every chat, project, workspace, prompt and setting as "
                "one zip. Restoring one replaces what is here.",
          ),
          // The icons the explorer already uses for the same two directions:
          // a download leaves the app, an upload arrives in it.
          AddButtonRow(
            child: ValueListenableBuilder(
              valueListenable: _busy,
              builder: (context, busy, _) => Row(
                spacing: 12,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text("Export"),
                    onPressed: busy ? null : _export,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file),
                    label: const Text("Import"),
                    onPressed: busy ? null : _import,
                  ),
                ],
              ),
            ),
          ),
          BusyBar(_busy),
        ],
      );
}
