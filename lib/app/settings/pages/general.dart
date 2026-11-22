import "../../../domain/omada_ordering.dart";
import "../../../domain/settings/keys.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.general;

// What a project's settings page shares of General; the category itself is
// `ui/settings/general_settings.dart`.
const generalSections = [
  SectionSpec(
    page: _page,
    id: "omada",
    title: "Omada",
    weight: 10,
    description:
        "Team chats: several named agents take part in a "
        "project's replies, alongside the main one.",
  ),
  SectionSpec(
    page: _page,
    id: "environment",
    title: "Environment",
    weight: 30,
    description:
        "Passed to every command the agent runs. A command already "
        "running keeps what it started with.",
  ),
];

final generalSettings = [
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
    id: "environment",
    path: (page: _page, section: "environment"),
    weight: 0,
    title: "Environment",
    hint: UiHint.keyValues,
    build: (c) => c.keyValues(SettingKeys.environment),
  ),
];
