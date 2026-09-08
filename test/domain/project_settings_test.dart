import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/domain/project_settings.dart";

import "../harness.dart";

void main() {
  late AppConfig config;

  setUp(() {
    config = tempConfig();
    // A project's settings sit in the project, which a fresh config has not
    // made yet.
    Directory(config.projectDir(project: "work")).createSync(recursive: true);
  });

  test("a project's environment survives a save and a load", () async {
    final settings = ProjectSettings()
      ..environment = {"KEY": "value", "PATH": "/usr/local/bin"};
    await settings.save(config, project: "work");

    expect(ProjectSettings.load(config, project: "work").environment,
        {"KEY": "value", "PATH": "/usr/local/bin"});
  });

  test("one that sets none loads back with a null, an empty map saved as one",
      () async {
    expect(ProjectSettings.load(config, project: "work").environment, isNull);

    await (ProjectSettings()..environment = {}).save(config, project: "work");

    expect(ProjectSettings.load(config, project: "work").environment, isNull);
  });

  test("a value that is not a string is not an environment", () async {
    await config.documents.write(
        config.projectSettingsFile(project: "work"),
        '{"environment": {"PORT": 8080}}');

    expect(ProjectSettings.load(config, project: "work").environment, isNull);
  });

  test("a copy carries everything a save would otherwise drop", () {
    final settings = ProjectSettings()
      ..environment = {"KEY": "value"}
      ..omada = true
      ..omadaOrdering = OmadaOrdering.parallel;
    final copy = settings.copy();
    expect(copy.environment, {"KEY": "value"});
    expect(copy.omada, true);
    expect(copy.omadaOrdering, OmadaOrdering.parallel);
  });

  test("omada off writes nothing and an absent key loads as off", () async {
    final settings = ProjectSettings()..omada = false;
    await settings.save(config, project: "work");
    expect(config.documents.read(config.projectSettingsFile(project: "work")),
        isNot(contains("omada")));
    expect(ProjectSettings.load(config, project: "work").omada, false);
  });

  test("omada and its ordering survive a save and a load", () async {
    await (ProjectSettings()
          ..omada = true
          ..omadaOrdering = OmadaOrdering.parallel)
        .save(config, project: "work");
    final loaded = ProjectSettings.load(config, project: "work");
    expect(loaded.omada, true);
    expect(loaded.omadaOrdering, OmadaOrdering.parallel);

    // The ordering can also be set where the toggle is off — the section's
    // business, but the settings' is to carry what it is handed.
    await (ProjectSettings()..omadaOrdering = OmadaOrdering.sequential)
        .save(config, project: "work");
    final cleared = ProjectSettings.load(config, project: "work");
    expect(cleared.omada, false);
    expect(cleared.omadaOrdering, OmadaOrdering.sequential);
  });

  test("an ordering name that is not one is not an ordering", () async {
    await config.documents.write(config.projectSettingsFile(project: "work"),
        '{"omada": true, "omadaOrdering": "sideways"}');
    final loaded = ProjectSettings.load(config, project: "work");
    expect(loaded.omada, true);
    expect(loaded.omadaOrdering, isNull);
  });

  test("the step limit survives a save and a load", () async {
    await (ProjectSettings()..turnMaxSteps = 80).save(config, project: "work");
    final loaded = ProjectSettings.load(config, project: "work");
    expect(loaded.turnMaxSteps, 80);

    // Absent is inherit: nothing written, nothing named.
    Directory(config.projectDir(project: "elsewhere")).createSync(recursive: true);
    expect(ProjectSettings.load(config, project: "elsewhere").turnMaxSteps,
        isNull);
  });
}
