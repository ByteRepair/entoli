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

  ProjectSettings load() => ProjectSettings.load(config, project: "work");
  String? file() =>
      config.documents.read(config.projectSettingsFile(project: "work"));

  test("defaults write nothing and absent keys load as inherit", () async {
    await (ProjectSettings()..environment = {}).save(config, project: "work");
    expect(file(), "{}");
    final loaded = load();
    expect(loaded.environment, isNull);
    expect(loaded.omada, false);
    expect(loaded.omadaOrdering, isNull);
    expect(loaded.turnMaxSteps, isNull);
    expect(loaded.description, isNull);
  });

  test("a value of the wrong shape is dropped, not the file", () async {
    await config.documents.write(
      config.projectSettingsFile(project: "work"),
      '{"omada": true, "omadaOrdering": "sideways", "environment": {"PORT": 8080}}',
    );
    final loaded = load();
    expect(loaded.omada, true);
    expect(loaded.omadaOrdering, isNull);
    expect(loaded.environment, isNull);
  });
}
