import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";

import "../harness.dart";

/// The on-disk layout, as the relative paths it composes.
void main() {
  late AppConfig config;

  setUp(() => config = tempConfig());

  String relative(String path) => p.relative(path, from: config.dataDir);

  test("the default project is a directory under projects/, like every other", () {
    expect(relative(config.projectDir()), p.join("projects", "default"));
    expect(relative(config.projectDir(project: "work")), p.join("projects", "work"));
  });

  test("a chat's workspace is in the project's, not beside its conversation", () {
    expect(relative(config.workspaceDir("c1")),
        p.join("projects", "default", "workspace", "chats", "c1"));
    expect(relative(config.chatDir("c1")),
        p.join("projects", "default", "chats", "c1"));
  });

  test("sync is one directory in the data dir, not a project's", () {
    expect(relative(config.syncDir), "sync");
  });

  test("a project's settings sit in the project, the app's in the data dir", () {
    expect(relative(config.projectSettingsFile()),
        p.join("projects", "default", "project.json"));
    expect(relative(config.settingsFile), "settings.json");
  });
}
