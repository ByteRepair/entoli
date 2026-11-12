import "../../../core/formatting.dart" show plural;
import "../../../domain/app_theme.dart";
import "../../../domain/corner_radius.dart";
import "../../../domain/omada_ordering.dart";
import "../../../domain/settings/keys.dart";
import "../../../domain/temp_chat_ttl.dart";
import "../../../domain/theme_colour.dart";
import "../../../providers.dart";
import "../../frontend.dart";
import "../../selection.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.general;

final generalSections = [
  SectionSpec(
    page: _page,
    id: "appearance",
    title: "Appearance",
    weight: 0,
    describe: (_) => "How the app looks.",
  ),
  const SectionSpec(
    page: _page,
    id: "omada",
    title: "Omada",
    weight: 10,
    description:
        "Team chats: several named agents take part in a "
        "project's replies, alongside the main one.",
  ),
  const SectionSpec(
    page: _page,
    id: "tempChats",
    title: "Temporary chats",
    weight: 20,
    description:
        "Chats that are hidden and then deleted after a delay "
        "from when their TTL was enabled. A project or an individual chat "
        "can override this.",
  ),
  const SectionSpec(
    page: _page,
    id: "environment",
    title: "Environment",
    weight: 30,
    description:
        "Passed to every command the agent runs. A command already "
        "running keeps what it started with.",
  ),
  const SectionSpec(
    page: _page,
    id: "update",
    title: "Update",
    weight: 40,
    description:
        "Checked when the app starts: if the latest release is "
        "newer than this build, that one is downloaded and put in its "
        "place.",
  ),
  const SectionSpec(
    page: _page,
    id: "danger",
    title: "Danger Zone",
    weight: 50,
  ),
];

/// Apple's look, whose colours and corners are not the app's to pick.
bool _appleLook(SettingContext c) =>
    c.ref.watch(frontendProvider).native &&
    (c.scope.resolve(SettingKeys.liquidGlass) ?? true);

SwatchLook _swatch(ThemeColour a, [ThemeColour? b]) =>
    SwatchLook(a.argb, b == null || b == a ? null : b.argb);

final generalSettings = [
  SettingSpec(
    id: "appTheme",
    path: (page: _page, section: "appearance"),
    weight: 0,
    title: "Theme",
    hint: UiHint.segmented,
    build: (c) => c.choice(SettingKeys.appTheme, [
      for (final theme in AppTheme.values) SettingOption(theme, theme.label),
    ]),
  ),
  SettingSpec(
    id: "systemPalette",
    path: (page: _page, section: "appearance"),
    weight: 10,
    title: "Material 3 Expressive",
    description:
        "Build the palette from the colour the system is themed to, so "
        "the app follows the wallpaper the way the rest of the phone "
        "does.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(
      SettingKeys.systemPalette,
      visible: c.ref.watch(systemAccentProvider) != null,
    ),
  ),
  SettingSpec(
    id: "liquidGlass",
    path: (page: _page, section: "appearance"),
    weight: 20,
    title: "Liquid Glass",
    description:
        "Uses native system UI for drawing some parts of the app. "
        "Changing this requires an app restart.",
    hint: UiHint.toggle,
    build: (c) {
      final launched = c.ref.watch(frontendProvider);
      return c.toggle(
        SettingKeys.liquidGlass,
        visible: launched.native,
        // What this launch draws is settled at launch, so a switch that no
        // longer matches it says so rather than appearing to do nothing.
        // Switched back to what it started with, there is nothing to
        // restart for.
        after: (on) => (on ?? true) == launched.swiftUI
            ? null
            : SettingNotice(
                "Quit and reopen Entoli for Liquid Glass to turn "
                "${(on ?? true) ? "on" : "off"}.",
                title: "Restart Entoli",
              ),
      );
    },
  ),
  SettingSpec(
    id: "colourTheme",
    path: (page: _page, section: "appearance"),
    weight: 30,
    title: "Theme colours",
    hint: UiHint.swatches,
    build: (c) {
      final primary = c.scope.resolve(SettingKeys.primaryColour);
      final secondary = c.scope.resolve(SettingKeys.secondaryColour);
      final notifier = c.ref.read(appSettingsProvider.notifier);
      return ChoiceController<ColourTheme>(
        c.spec,
        options: [
          for (final theme in ColourTheme.values)
            SettingOption(
              theme,
              theme.label,
              look: _swatch(theme.primary, theme.secondary),
            ),
        ],
        value: ColourTheme.values
            .where((t) => t.primary == primary && t.secondary == secondary)
            .firstOrNull,
        // One accent is the seed of the whole palette, secondary included,
        // so while the system is picking there is nothing here to pick.
        visible: c.ref.watch(paletteAccentProvider) == null && !_appleLook(c),
        onSet: (theme) async {
          if (theme != null) await notifier.setColourTheme(theme);
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "customColours",
    path: (page: _page, section: "appearance"),
    weight: 40,
    title: "Custom colours",
    hint: UiHint.swatches,
    build: (c) {
      SettingOption<ThemeColour> option(ThemeColour colour) =>
          SettingOption(colour, colour.label, look: _swatch(colour));
      final keys = [SettingKeys.primaryColour, SettingKeys.secondaryColour];
      return SlotsController<ThemeColour>(
        c.spec,
        slots: [
          for (final (i, label) in ["Primary", "Secondary"].indexed)
            SettingOption(
              c.scope.resolve(keys[i])!,
              label,
              look: _swatch(c.scope.resolve(keys[i])!),
            ),
        ],
        groups: [
          OptionGroup("Bold colours", [
            for (final colour in ThemeColour.inGroup(ThemeColourGroup.bold))
              option(colour),
          ]),
          OptionGroup("Pastel colours", [
            for (final colour in ThemeColour.inGroup(ThemeColourGroup.pastel))
              option(colour),
          ]),
        ],
        visible: c.ref.watch(paletteAccentProvider) == null && !_appleLook(c),
        onSet: (slot, colour) => c.scope.write(keys[slot], colour),
      );
    },
  ),
  SettingSpec(
    id: "cornerRadius",
    path: (page: _page, section: "appearance"),
    weight: 50,
    title: "Corners",
    hint: UiHint.corners,
    build: (c) => c.choice(SettingKeys.cornerRadius, [
      for (final corner in CornerRadius.values)
        SettingOption(
          corner,
          "${corner.radius.round()}",
          look: CornerLook(corner.radius),
        ),
    ], visible: !_appleLook(c)),
  ),
  SettingSpec(
    id: "showCommandChips",
    path: (page: _page, section: "appearance"),
    weight: 70,
    title: "Show command chips in start page",
    // Discovery rather than decoration: the chips are the one place a
    // `/skill` or `@agent` is named before its trigger is typed.
    description:
        "Names the commands and agents a new chat can start with, under "
        "its question. Off, typing / or @ in the composer is what shows "
        "them.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.showCommandChips),
  ),
  SettingSpec(
    id: "omadaByDefault",
    path: (page: _page, section: "omada"),
    weight: 0,
    title: "On by default for new projects",
    description:
        "The new-project dialog starts with team chats switched on. "
        "Existing projects are untouched.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.omadaByDefault),
  ),
  SettingSpec(
    id: "omadaOrdering",
    path: (page: _page, section: "omada"),
    weight: 10,
    title: "Default round order",
    hint: UiHint.dropdown,
    build: (c) => c.choice(
      SettingKeys.omadaOrdering,
      [
        for (final MapEntry(key: order, value: label)
            in omadaOrderingLabels.entries)
          SettingOption(order, label),
      ],
      unsetMeans: defaultOmadaOrdering,
      footnote:
          omadaOrderingDescriptions[c.scope.resolve(
                SettingKeys.omadaOrdering,
              ) ??
              defaultOmadaOrdering],
    ),
  ),
  SettingSpec(
    id: "omadaMaxGenerations",
    path: (page: _page, section: "omada"),
    weight: 20,
    title: "Max generations per round",
    hint: UiHint.slider,
    build: (c) => c.range(
      SettingKeys.omadaMaxGenerations,
      stops: SettingKeys.omadaGenerationStops,
      footnote:
          "How many waves of agent-to-agent work one round may run before "
          "it stops for you — your message starts the round, and a member "
          "handing off to another starts the next wave. A project can set "
          "its own.",
    ),
  ),
  SettingSpec(
    id: "tempChatTtl",
    path: (page: _page, section: "tempChats"),
    weight: 0,
    title: "Delete chats after",
    hint: UiHint.dropdown,
    // The setter re-anchors every chat to now, so the badges appear at once.
    build: (c) {
      final notifier = c.ref.read(appSettingsProvider.notifier);
      return c.choice(
        SettingKeys.tempChatTtl,
        [
          for (final MapEntry(key: ttl, value: label)
              in tempChatTtlLabels.entries)
            SettingOption(ttl, label),
        ],
        write: (ttl) async {
          if (ttl != null) await notifier.setTempChatTtl(ttl);
        },
      );
    },
  ),
  SettingSpec(
    id: "environment",
    path: (page: _page, section: "environment"),
    weight: 0,
    title: "Environment",
    hint: UiHint.keyValues,
    build: (c) => c.keyValues(SettingKeys.environment),
  ),
  SettingSpec(
    id: "autoUpdate",
    path: (page: _page, section: "update"),
    weight: 0,
    title: "Automatically update",
    description:
        "Look for a newer release on startup and replace this build. "
        "Linux and macOS run it on the next launch; Windows installs "
        "it when the app quits, with the installer's usual prompt.",
    hint: UiHint.toggle,
    // Drawn only where the platform half exists, and saying nothing where it
    // does not: a phone reaches its newest build by means of its own.
    build: (c) => c.toggle(
      SettingKeys.autoUpdate,
      visible: c.ref.watch(appUpdateHostProvider).available,
    ),
  ),
  SettingSpec(
    id: "deleteAllChats",
    path: (page: _page, section: "danger"),
    weight: 0,
    title: "Delete all chats",
    hint: UiHint.button,
    glyph: SettingGlyph.deleteForever,
    build: (c) {
      final repository = c.ref.read(chatRepositoryProvider);
      final selection = c.ref.read(selectedChatIdProvider.notifier);
      return ActionController(
        c.spec,
        label: "Delete all chats",
        destructive: true,
        confirm: () async {
          final count = (await repository.listChats()).length;
          return SettingConfirm(
            title: "Delete all chats?",
            message: count == 0
                ? "There are no chats to delete."
                : "This permanently removes ${plural(count, "chat")}, "
                      "including their workspaces. It cannot be undone.",
            confirmLabel: count == 0 ? null : "Delete all",
            destructive: true,
          );
        },
        // The sidebar's list follows the repository's deletions.
        run: () async {
          selection.select(null);
          await repository.deleteAllChats();
          return null;
        },
      );
    },
  ),
];
