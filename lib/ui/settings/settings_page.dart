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
import "../../domain/project_settings.dart"
    show OmadaOrdering, defaultOmadaOrdering, omadaOrderingLabels,
        omadaOrderingDescriptions;
import "../../domain/temp_chat_ttl.dart";
import "../../domain/app_settings.dart";
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
import "permissions_section.dart";
import "../widgets/formatting.dart";
import "../widgets/nav_drawer.dart";
import "../widgets/provider_dialog.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "agents_settings.dart";
import "assistant_settings.dart";
import "byte_repair_settings.dart";
import "llm_settings.dart";
import "local_model_settings.dart";
import "memory_settings.dart";
import "privacy_policy_page.dart";
import "shortcuts_settings.dart";
import "triggers.dart";
import "skills_settings.dart";
import "sync_settings.dart";
import "terminal_settings.dart";
import "voice_settings.dart";
import "welcome_page.dart";

/// The page's categories, in the order they are offered and the groups they
/// are offered in. General, Providers, On-device and LLMs are the app and the
/// plumbing that answers a chat — everything an endpoint is, where a model can
/// run without a network, and everything a model is asked to do; Memory, Voice
/// and Triggers are what a conversation does beyond the text; Agents and
/// Skills are what a message addresses by name; Terminal and Byte Repair are
/// where commands run; Sync and Data are the device and all of it at once —
/// the chats, the settings and the workspaces as one file to keep; and
/// Welcome, Shortcuts and About are the app rather than anything it does,
/// which is why they are last.
enum SettingsCategory {
  general("General", Icons.tune),
  providers("Providers", Icons.cloud_outlined),
  onDevice("On-device", Icons.memory),
  llms("LLMs", Icons.auto_awesome_outlined),
  memory("Memory", Icons.psychology, dividerAbove: true),
  voice("Voice", Icons.graphic_eq),
  triggers("Triggers", Icons.alarm),
  agents("Agents", Icons.person_outline, dividerAbove: true),
  skills("Skills", Icons.extension),
  terminal("Terminal", Icons.terminal, dividerAbove: true),
  byteRepair("Byte Repair", Icons.verified_user),
  sync("Sync", Icons.sync, dividerAbove: true),
  data("Data", Icons.inventory_2_outlined),
  welcome("Welcome", Icons.waving_hand, dividerAbove: true),
  shortcuts("Shortcuts", Icons.keyboard_outlined),
  about("About", Icons.info_outline);

  const SettingsCategory(this.label, this.icon, {this.dividerAbove = false});

  final String label;
  final IconData icon;

  /// A divider drawn above the category's tile, where one group of categories
  /// ends and another begins.
  final bool dividerAbove;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialCategory, this.focus = false});

  final SettingsCategory? initialCategory;

  /// Pushed for one category — the welcome tour's setup rows, the Byte Repair
  /// bar — rather than arrived at through the settings list. That category is
  /// the whole page on a wide window too, with nothing behind it: back leaves
  /// settings rather than a list it skipped, and the panel is not drawn
  /// beside what it was not used to pick.
  final bool focus;

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
    // One rule, not two: a named category is the whole page unless the window
    // is wide enough for the panel and nobody asked to focus. Narrow has no
    // panel for a preselected category to sit beside, so there it is the page
    // whatever the caller asked for.
    final fullPage =
        widget.initialCategory != null && (widget.focus || !wide);
    if (fullPage) {
      return _categoryScaffold(widget.initialCategory!);
    }
    final categories = _Categories(
      // Nothing is selected where the list is the whole page: a category there
      // is somewhere to go rather than what is showing beside it.
      selected: wide ? _category : null,
      onSelect: (category) => _open(category, push: !wide),
    );
    final bar = AppBar(title: const Text("Settings"));

    if (!wide) {
      return Scaffold(appBar: bar, body: categories);
    }
    return Scaffold(
      appBar: bar,
      body: Row(
        children: [
          SizedBox(width: navPanelWidth, child: categories),
          const VerticalDivider(width: 1),
          Expanded(child: _categoryBody(_category, key: ValueKey(_category))),
        ],
      ),
    );
  }
}

/// A category as the whole page: the bar holds nothing but its name, and
/// leaving it is the back gesture.
Scaffold _categoryScaffold(SettingsCategory category) => Scaffold(
      appBar: AppBar(title: Text(category.label)),
      body: _categoryBody(category),
    );

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
    return _categoryScaffold(category);
  }
}

/// What a category draws in either layout. Welcome is the tour, a pager with
/// its own bar that cannot scroll in a list, and Skills and Agents scroll
/// their own list to keep their footers fixed to the bottom — everything
/// else is its sections.
Widget _categoryBody(SettingsCategory category, {Key? key}) =>
    switch (category) {
      SettingsCategory.welcome => const WelcomeTour(),
      SettingsCategory.skills => const SkillsSection(),
      SettingsCategory.agents => const AgentsSection(),
      _ => ListView(key: key, children: _sectionsOf(category)),
    };

/// What is filed under a category, whether it is drawn beside the list or on a
/// page of its own. [SettingsCategory.welcome] is not filed anywhere: the tour
/// is a body of its own, which [_categoryBody] renders whole.
List<Widget> _sectionsOf(SettingsCategory category) => switch (category) {
      // The agent's own settings are here rather than under LLMs: the mode is a
      // behaviour, and the classifier picker travels with it because auto mode
      // is unusable without one.
      SettingsCategory.general => const [
          _AppearanceSection(),
          Divider(),
          _AgentSection(),
          Divider(),
          _OmadaSection(),
          Divider(),
          _TempChatSection(),
          Divider(),
          _EnvironmentSection(),
          // Draws its own divider, since a platform that updates itself by
          // other means has nothing to put under one.
          _UpdatesSection(),
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
      // Neither the assistant section nor the catalog draws at all where the
      // platform has no gesture / nothing to download, and each opens its own
      // divider, so a page of two rows is not left hairlines around nothing.
      SettingsCategory.voice => const [
          VoiceSection(),
          AssistantSection(),
          VoiceCatalogSections(),
        ],
      // Says so and offers nothing where there is no clock to schedule with —
      // see the section itself.
      SettingsCategory.triggers => const [TriggersSection()],
      // Rendered by [_categoryBody] whole rather than filed here, for the
      // footers pinned to their bottoms.
      SettingsCategory.skills => const [],
      SettingsCategory.agents => const [],
      SettingsCategory.byteRepair => const [ByteRepairSection()],
      SettingsCategory.sync => const [SyncSection()],
      SettingsCategory.providers => const [_ProvidersEditor()],
      SettingsCategory.llms => const [
          DefaultsSection(),
          Divider(),
          TurnsSection(),
        ],
      // The two things the agent carries between conversations: the files the
      // user writes (instructions) and the ones it writes (memories).
      SettingsCategory.memory => const [
          InstructionsSection(),
          Divider(),
          AutoMemorySection(),
        ],
      SettingsCategory.data => const [_BackupSection()],
      SettingsCategory.shortcuts => const [ShortcutsSection()],
      SettingsCategory.about => const [_AboutSection()],
      // Rendered by [_categoryBody] rather than filed here: the tour is a
      // pager with its own bar, not a list of sections.
      SettingsCategory.welcome => const [],
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
              for (final category in SettingsCategory.values) ...[
                if (category.dividerAbove) const Divider(),
                ListTile(
                  selected: category == selected,
                  leading: Icon(category.icon),
                  title: Text(category.label),
                  trailing: selected == null ? const Icon(Icons.chevron_right) : null,
                  onTap: () => onSelect(category),
                ),
              ],
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
            label: "Theme colours",
            children: [
              for (final theme in ColourTheme.values)
                _ColourChoice(
                  label: theme.label,
                  colour: theme.primary,
                  second: theme.secondary,
                  selected: theme.primary == settings.primaryColour &&
                      theme.secondary == settings.secondaryColour,
                  onTap: () => notifier.setColourTheme(theme),
                ),
            ],
          ),
          _ColourRows(
            label: "Primary colour",
            selected: settings.primaryColour,
            onPick: notifier.setPrimaryColour,
          ),
          _ColourRows(
            label: "Secondary colour",
            selected: settings.secondaryColour,
            onPick: notifier.setSecondaryColour,
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

/// One seed's swatches, bold above pastel, each group under its own name.
class _ColourRows extends StatelessWidget {
  const _ColourRows({
    required this.label,
    required this.selected,
    required this.onPick,
  });

  final String label;
  final ThemeColour selected;
  final ValueChanged<ThemeColour> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupStyle = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget group(String name, ThemeColourGroup group) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: groupStyle),
            const SizedBox(height: 6),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final colour in ThemeColour.inGroup(group))
                _ColourChoice(
                  label: colour.label,
                  colour: colour,
                  selected: colour == selected,
                  onTap: () => onPick(colour),
                ),
            ]),
          ],
        );
    return LabelledField(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          group("Bold colours", ThemeColourGroup.bold),
          const SizedBox(height: 12),
          group("Pastel colours", ThemeColourGroup.pastel),
        ],
      ),
    );
  }
}

/// The seeds as the colours themselves: a swatch says what it does and a name
/// in a dropdown would not. A [second] colour splits it diagonally, a theme
/// being its two seeds.
class _ColourChoice extends StatelessWidget {
  const _ColourChoice({
    required this.label,
    required this.colour,
    this.second,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final ThemeColour colour;
  final ThemeColour? second;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = colour.colour;
    final b = (second ?? colour).colour;
    return _Choice(
      tooltip: label,
      label: label,
      selected: selected,
      onTap: onTap,
      fill: a,
      gradient: a == b
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [a, a, b, b],
              stops: const [0, 0.5, 0.5, 1],
            ),
      width: 40,
      height: 40,
      // The tick sits on the swatch rather than on the surface, so it is read
      // against the colour it is marking — across a split, against the two
      // mixed, since it straddles the line.
      child: selected
          ? Icon(Icons.check,
              size: 18,
              color: ThemeData.estimateBrightnessForColor(Color.lerp(a, b, 0.5)!) ==
                      Brightness.dark
                  ? Colors.white
                  : Colors.black)
          : null,
    );
  }
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
    this.gradient,
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

  /// Painted over [fill] where given.
  final Gradient? gradient;
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
              gradient: gradient,
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

  static final _repository = Uri.parse("https://github.com/ByteRepair/entoli");
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
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text("Privacy policy"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
          ),
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
              helperText: settings.approveMode == ApproveMode.auto
                  ? noClassifier
                      ? "No classifier model set — auto mode will ask for "
                          "every command."
                      : "The classifier can also refuse a command outright, "
                          "without asking you. Reads and writes inside the "
                          "chat's workspace pass; anything past it waits for "
                          "you. After several escalations in a turn, the rest "
                          "of the turn asks."
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
          child: ModelPicker(
            nullLabel: "Off",
            defaultOf: LlmProviderConfig.lightDefaultOf,
            helperOffText: "Classifies commands as safe, dangerous, or "
                "uncertain. Off, auto mode asks for every command.",
            choice: (
              providerId: settings.classifierProviderId,
              modelId: settings.classifierModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setClassifierModel(choice),
          ),
        ),
        Divider(),
        const _DefaultPermissionsSection(),
      ],
    );
  }
}

/// The default project's permissions, which is what General holds: the tier
/// every other project inherits before its own. The project settings page
/// edits the same file for its own project; built-ins read it and add
/// nothing.
class _DefaultPermissionsSection extends ConsumerWidget {
  const _DefaultPermissionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(projectSettingsProvider(null));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PermissionsSection(
          rules: settings.permissions,
          description: "Standing rules, consulted before the classifier and "
              "the banner. A deny outranks an ask, which outranks an allow; a "
              "command with segments a rule does not cover still waits.",
          onSaved: (rules) => ref
              .read(projectSettingsProvider(null).notifier)
              .setProjectPermissions(rules),
        ),
        SwitchListTile(
          title: const Text("Offer to rerun sandbox-denied commands"),
          subtitle: Text((settings.sandboxReprompt ?? true)
              ? "When the sandbox denies a write, one banner offers to rerun "
                  "it unconfined, or to widen the grant to the denied "
                  "directory. A project can override this."
              : "Off: a denial is reported to the model and the turn moves "
                  "on. A project can override this."),
          value: settings.sandboxReprompt ?? true,
          onChanged: (value) => ref
              .read(projectSettingsProvider(null).notifier)
              .setProjectSandboxReprompt(value),
        ),
      ],
    );
  }
}

/// The room the settings page has for Omada at app level: what a new project
/// starts as, how deep its agent rounds may go, and the scheduling a project
/// that never chose runs under. A project's own page overrides the last two.
class _OmadaSection extends ConsumerWidget {
  const _OmadaSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Omada",
          description: "Team chats: several named agents take part in a "
              "project's replies, alongside the main one.",
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text("On by default for new projects"),
          subtitle: const Text(
              "The new-project dialog starts with team chats switched on. "
              "Existing projects are untouched."),
          value: settings.omadaByDefault,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setOmadaByDefault(value),
        ),
        InheritableDropdown<OmadaOrdering>(
          label: "Default round order",
          value: settings.omadaOrdering,
          inherited: omadaOrderingLabels[defaultOmadaOrdering],
          options: omadaOrderingLabels,
          onChanged: (v) =>
              ref.read(appSettingsProvider.notifier).setOmadaOrdering(v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
              omadaOrderingDescriptions[
                  settings.omadaOrdering ?? defaultOmadaOrdering]!,
              style: Theme.of(context).textTheme.bodySmall),
        ),
        InheritableSlider(
          label: "Max generations per round",
          value: settings.omadaMaxGenerations,
          stops: AppSettings.omadaGenerationStops,
          inherited: AppSettings.defaultOmadaMaxGenerations,
          onChanged: (v) => ref
              .read(appSettingsProvider.notifier)
              .setOmadaMaxGenerations(
                  v ?? AppSettings.defaultOmadaMaxGenerations),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            "How many waves of agent-to-agent work one round may run before "
            "it stops for you — your message starts the round, and a member "
            "handing off to another starts the next wave. A project can set "
            "its own.",
            style: Theme.of(context).textTheme.bodySmall,
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

/// The nudge an empty Providers page stands in for: a recommended provider,
/// the reason for it, and the two ways to act on it — signing up, or pasting
/// a key already in hand. Gone the moment a provider of any kind is configured.
class _RecommendedProvider extends ConsumerStatefulWidget {
  const _RecommendedProvider();

  @override
  ConsumerState<_RecommendedProvider> createState() =>
      _RecommendedProviderState();
}

class _RecommendedProviderState extends ConsumerState<_RecommendedProvider> {
  static final _signUp = Uri.parse("https://signin.ollama.com/sign-up");
  static final _privacy = Uri.parse("https://ollama.com/privacy");

  static final _ollamaCloud =
      llmProviderPresets.firstWhere((p) => p.id == "ollama-cloud");

  final _apiKey = TextEditingController();

  @override
  void dispose() {
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _addWithKey() async {
    final key = _apiKey.text.trim();
    if (key.isEmpty) return;
    // Notifier first: adding the provider unmounts this card on the next
    // frame, and the save must outlive it rather than resume on a defunct
    // ref. The key goes to the store (setKey), never onto the config.
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.upsertProvider(_ollamaCloud, setKey: key);
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _apiKey.text.trim().isNotEmpty;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Entoli works with both privacy-respecting and other providers. "
              "We recommend Ollama Cloud: it does not keep or train on your "
              "prompts and outputs.",
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, _signUp),
              child: const Text("Sign up"),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, _privacy),
              child: const Text("Ollama Cloud privacy policy"),
            ),
            const Divider(height: 32),
            const Text("Already have a key?"),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: "Ollama API key"),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasKey ? _addWithKey : null,
              child: const Text("Add Ollama Cloud"),
            ),
          ],
        ),
      ),
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
    // Notifier first: this page can go away while the dialog is open, and the
    // save must outlive it rather than resume on a defunct ref.
    final notifier = ref.read(appSettingsProvider.notifier);
    final secrets = ref.read(appSecretsProvider);
    final saved = await promptForProvider(
      context,
      initial: initial,
      storedKey: initial == null ? null : secrets.providerKey(initial.id),
      encrypted: secrets.encrypted,
      title: title,
    );
    if (saved == null) return;
    // A renamed provider is a move: the stored key follows the new id and the
    // old entry goes, in the same upsert — the notifier owns both stores.
    await notifier.upsertProvider(saved.config,
        fromId: initial?.id, setKey: saved.setKey);
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
        if (providers.isEmpty) const _RecommendedProvider(),
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
            subtitle: _describe(provider,
                storedKey: ref.read(appSecretsProvider).providerKey(provider.id)),
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

  String _describe(LlmProviderConfig provider, {String? storedKey}) {
    final key = storedKey != null
        ? "key stored"
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("Danger Zone"),
        Padding(
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
        ),
      ],
    );
  }
}

/// The app keeping itself current, where the platform it runs on is one this
/// feature serves — the three desktops. Drawn nowhere else and saying nothing
/// where it is not drawn: a phone and a browser already reach their newest
/// build by means of their own, which a row here would only stand in front of.
class _UpdatesSection extends ConsumerWidget {
  const _UpdatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appUpdateHostProvider).available) {
      return const SizedBox.shrink();
    }
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Update",
          description: "Checked when the app starts: if the latest release is "
              "newer than this build, that one is downloaded and put in its "
              "place.",
        ),
        SwitchListTile(
          title: const Text("Automatically update"),
          subtitle: const Text(
              "Look for a newer release on startup and replace this build. "
              "Linux and macOS run it on the next launch; Windows installs "
              "it when the app quits, with the installer's usual prompt."),
          value: settings.autoUpdate,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setAutoUpdate(value),
        ),
      ],
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
    if (mounted) say(context, message);
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
