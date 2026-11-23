import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/formatting.dart" show plural;
import "package:entoli_core/model/app_theme.dart";
import "package:entoli_core/model/corner_radius.dart";
import "package:entoli_core/model/omada_ordering.dart";
import "package:entoli_core/model/settings/keys.dart";
import "package:entoli_core/model/temp_chat_ttl.dart";
import "package:entoli_core/model/theme_colour.dart";
import "package:entoli_core/view/theme.dart" show ThemeColourValue;
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart";

import "../../app/selection.dart";
import "../../app/settings/scope.dart";
import "../../providers.dart";
import "../widgets/choice.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

const _app = AppAddress();

/// Settings > General: how the app looks, Omada's app-wide defaults,
/// temporary chats, the environment, updates, and deleting every chat.
class GeneralSettings extends StatelessWidget {
  const GeneralSettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      _AppearanceSection(),
      Divider(),
      _OmadaSection(),
      Divider(),
      _TempChatSection(),
      Divider(),
      SectionHeader(
        "Environment",
        description:
            "Passed to every command the agent runs. A command already "
            "running keeps what it started with.",
      ),
      ScopedEnvironment(setting: SettingKeys.environment, at: _app),
      // Draws its own divider, since a platform that updates itself by
      // other means has nothing to put under one.
      _UpdatesSection(),
      Divider(),
      _DeleteAllChats(),
    ],
  );
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, _app);
    final notifier = ref.read(appSettingsProvider.notifier);
    final primary = scope.resolve(SettingKeys.primaryColour)!;
    final secondary = scope.resolve(SettingKeys.secondaryColour)!;
    final corner = scope.resolve(SettingKeys.cornerRadius)!;
    void set(Future<void> Function() write) => guarded(context, write);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader("Appearance", description: "How the app looks."),
        ScopedChoice(
          setting: SettingKeys.appTheme,
          at: _app,
          title: "Theme",
          segmented: true,
          options: {for (final theme in AppTheme.values) theme: theme.label},
        ),
        if (ref.watch(systemAccentProvider) != null)
          const ScopedSwitch(
            setting: SettingKeys.systemPalette,
            at: _app,
            title: "Material 3 Expressive",
            subtitle:
                "Build the palette from the colour the system is themed to, "
                "so the app follows the wallpaper the way the rest of the "
                "phone does.",
          ),
        // One accent is the seed of the whole palette, secondary included,
        // so while the system is picking there is nothing here to pick.
        if (ref.watch(paletteAccentProvider) == null) ...[
          _ChoiceRow(
            label: "Theme colours",
            children: [
              for (final theme in ColourTheme.values)
                _ColourChoice(
                  label: theme.label,
                  colour: theme.primary,
                  second: theme.secondary,
                  selected:
                      theme.primary == primary && theme.secondary == secondary,
                  onTap: () => set(() => notifier.setColourTheme(theme)),
                ),
            ],
          ),
          _CustomColours(
            primary: primary,
            secondary: secondary,
            onPrimary: (colour) =>
                set(() => scope.write(SettingKeys.primaryColour, colour)),
            onSecondary: (colour) =>
                set(() => scope.write(SettingKeys.secondaryColour, colour)),
          ),
        ],
        _ChoiceRow(
          label: "Corners",
          children: [
            for (final option in CornerRadius.values)
              _CornerChoice(
                corner: option,
                selected: option == corner,
                onTap: () =>
                    set(() => scope.write(SettingKeys.cornerRadius, option)),
              ),
          ],
        ),
        // Discovery rather than decoration: the chips are the one place a
        // `/skill` or `@agent` is named before its trigger is typed.
        const ScopedSwitch(
          setting: SettingKeys.showCommandChips,
          at: _app,
          title: "Show command chips in start page",
          subtitle:
              "Names the commands and agents a new chat can start with, "
              "under its question. Off, typing / or @ in the composer is "
              "what shows them.",
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

enum _Slot { primary, secondary }

/// The two seeds picked one at a time from one set of swatches: a switch says
/// which is being picked, and wears each one's current colour, so a theme's
/// pair is visible here even though no swatch below is it.
class _CustomColours extends StatefulWidget {
  const _CustomColours({
    required this.primary,
    required this.secondary,
    required this.onPrimary,
    required this.onSecondary,
  });

  final ThemeColour primary;
  final ThemeColour secondary;
  final ValueChanged<ThemeColour> onPrimary;
  final ValueChanged<ThemeColour> onSecondary;

  @override
  State<_CustomColours> createState() => _CustomColoursState();
}

class _CustomColoursState extends State<_CustomColours> {
  var _slot = _Slot.primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final selected = _slot == _Slot.primary ? widget.primary : widget.secondary;
    final onPick = _slot == _Slot.primary
        ? widget.onPrimary
        : widget.onSecondary;
    Widget dot(ThemeColour colour) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: colour.colour,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
    );
    Widget group(String name, ThemeColourGroup group) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: groupStyle),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final colour in ThemeColour.inGroup(group))
              _ColourChoice(
                label: colour.label,
                colour: colour,
                selected: colour == selected,
                onTap: () => onPick(colour),
              ),
          ],
        ),
      ],
    );
    return LabelledField(
      label: "Custom colours",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<_Slot>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _Slot.primary,
                icon: dot(widget.primary),
                label: const Text("Primary"),
              ),
              ButtonSegment(
                value: _Slot.secondary,
                icon: dot(widget.secondary),
                label: const Text("Secondary"),
              ),
            ],
            selected: {_slot},
            onSelectionChanged: (picked) =>
                setState(() => _slot = picked.first),
          ),
          const SizedBox(height: 16),
          group("Bold colours", ThemeColourGroup.bold),
          const SizedBox(height: 16),
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
    return Choice(
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
      // On the swatch rather than the surface, so it is read against the
      // colour it marks; across a split, against the two mixed.
      child: selected
          ? Icon(
              Icons.check,
              size: 18,
              color:
                  ThemeData.estimateBrightnessForColor(
                        Color.lerp(a, b, 0.5)!,
                      ) ==
                      Brightness.dark
                  ? Colors.white
                  : Colors.black,
            )
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
    return Choice(
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

/// What a new project starts as, how deep its agent rounds may go, and the
/// scheduling a project that never chose runs under. A project's own page
/// overrides the last two.
class _OmadaSection extends StatelessWidget {
  const _OmadaSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Omada",
          description:
              "Team chats: several named agents take part in a "
              "project's replies, alongside the main one.",
        ),
        ScopedSwitch(
          setting: SettingKeys.omadaByDefault,
          at: _app,
          title: "On by default for new projects",
          subtitle:
              "The new-project dialog starts with team chats switched on. "
              "Existing projects are untouched.",
        ),
        OmadaRows(
          at: _app,
          footnotePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          footnoteMuted: false,
        ),
      ],
    );
  }
}

/// How rounds run at [at] where Omada is on: their order, and how many
/// waves one may run.
class OmadaRows extends ConsumerWidget {
  const OmadaRows({
    super.key,
    required this.at,
    this.footnotePadding = const EdgeInsets.fromLTRB(16, 0, 16, 8),
    this.footnoteMuted = true,
  });

  final ScopeAddress at;
  final EdgeInsets footnotePadding;
  final bool footnoteMuted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordering =
        scopeOf(ref, at).resolve(SettingKeys.omadaOrdering) ??
        defaultOmadaOrdering;
    Widget footnote(String text) => Padding(
      padding: footnotePadding,
      child: footnoteMuted
          ? mutedParagraph(context, text)
          : Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ScopedChoice(
          setting: SettingKeys.omadaOrdering,
          at: at,
          title: "Default round order",
          options: omadaOrderingLabels,
          unsetMeans: defaultOmadaOrdering,
        ),
        footnote(omadaOrderingDescriptions[ordering]!),
        ScopedCount(
          setting: SettingKeys.omadaMaxGenerations,
          at: at,
          title: "Max generations per round",
          stops: SettingKeys.omadaGenerationStops,
          unsetMeans: SettingKeys.defaultOmadaMaxGenerations,
        ),
        footnote(
          "How many waves of agent-to-agent work one round may run before "
          "it stops for you — your message starts the round, and a member "
          "handing off to another starts the next wave. A project can set "
          "its own.",
        ),
      ],
    );
  }
}

class _TempChatSection extends ConsumerWidget {
  const _TempChatSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Temporary chats",
          description:
              "Chats that are hidden and then deleted after a delay "
              "from when their TTL was enabled. A project or an individual "
              "chat can override this.",
        ),
        ScopedChoice(
          setting: SettingKeys.tempChatTtl,
          at: _app,
          title: "Delete chats after",
          options: tempChatTtlLabels,
          // The setter re-anchors every chat to now, so the badges appear at
          // once.
          write: (ttl) async {
            if (ttl != null) await notifier.setTempChatTtl(ttl);
          },
        ),
      ],
    );
  }
}

/// The app keeping itself current, where the platform's half exists — the
/// three desktops. Drawn nowhere else and saying nothing: a phone reaches its
/// newest build by means of its own.
class _UpdatesSection extends ConsumerWidget {
  const _UpdatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appUpdateHostProvider).available) {
      return const SizedBox.shrink();
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(),
        SectionHeader(
          "Update",
          description:
              "Checked when the app starts: if the latest release is "
              "newer than this build, that one is downloaded and put in its "
              "place.",
        ),
        ScopedSwitch(
          setting: SettingKeys.autoUpdate,
          at: _app,
          title: "Automatically update",
          subtitle:
              "Look for a newer release on startup and replace this build. "
              "Linux and macOS run it on the next launch; Windows installs "
              "it when the app quits, with the installer's usual prompt.",
        ),
      ],
    );
  }
}

class _DeleteAllChats extends ConsumerWidget {
  const _DeleteAllChats();

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(chatRepositoryProvider);
    final count = (await ref.read(chatListProvider.future)).length;
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
    // The sidebar's list follows the repository's deletions.
    ref.read(selectedChatIdProvider.notifier).select(null);
    await repository.deleteAllChats();
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
            onPressed: () =>
                guarded(context, () => _confirmAndDelete(context, ref)),
          ),
        ),
      ],
    );
  }
}
