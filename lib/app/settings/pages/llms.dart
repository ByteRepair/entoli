import "../../../domain/permission.dart";
import "../../../domain/settings/keys.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _llms = SettingsPageId.llms;

// What a project's and a chat's settings pages share of LLMs; the category
// itself is `ui/settings/llm_settings.dart`.
const llmSections = [
  SectionSpec(
    page: _llms,
    id: "agent",
    title: "Agent",
    weight: 10,
    description:
        "The built-in agent, running inside Entoli. It calls the "
        "model itself and runs its commands in the chat's workspace.",
  ),
  SectionSpec(page: _llms, id: "turns", title: "Turns", weight: 20),
];

final llmSettings = [
  SettingSpec(
    id: "approveMode",
    path: (page: _llms, section: "agent"),
    weight: 0,
    title: "Running commands",
    hint: UiHint.dropdown,
    build: (c) {
      final noClassifier =
          c.scope.resolve(SettingKeys.classifierProviderId) == null;
      final mode = c.scope.resolve(SettingKeys.approveMode);
      return c.choice(
        SettingKeys.approveMode,
        [
          for (final MapEntry(key: mode, value: label)
              in approveModeLabels.entries)
            SettingOption(
              mode,
              label,
              enabled: mode != ApproveMode.auto || !noClassifier,
            ),
        ],
        description: mode == ApproveMode.auto
            ? noClassifier
                  ? "No classifier model set — auto mode will ask for "
                        "every command."
                  : "The classifier can also refuse a command outright, "
                        "without asking you. Reads and writes inside the "
                        "chat's workspace pass; anything past it waits for "
                        "you. After several escalations in a turn, the rest "
                        "of the turn asks."
            : null,
      );
    },
  ),
  // Null is the backend's own default; Omada member turns run under it too,
  // and the round's own bound is the generations cap.
  SettingSpec(
    id: "turnMaxSteps",
    path: (page: _llms, section: "turns"),
    weight: 10,
    title: "Max steps per turn",
    hint: UiHint.slider,
    build: (c) => c.range(
      SettingKeys.turnMaxSteps,
      stops: SettingKeys.turnStepStops,
      unsetMeans: SettingKeys.defaultTurnMaxSteps,
    ),
  ),
];
