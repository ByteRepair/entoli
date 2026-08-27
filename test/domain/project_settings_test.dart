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
    final settings = ProjectSettings()..environment = {"KEY": "value"};
    expect(settings.copy().environment, {"KEY": "value"});
  });
}
