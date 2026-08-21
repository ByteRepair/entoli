import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";

import "../harness.dart";

/// The on-disk layout, and moving a data directory written to the one that came
/// before it. Everything here is the io filesystem; `web_filesystem_test.dart`
/// runs the same migration over IndexedDB, where a rename is a different animal.
void main() {
  late AppConfig config;

  setUp(() => config = tempConfig());

  String relative(String path) => p.relative(path, from: config.dataDir);

  void write(String path, String text) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  group("the layout", () {
    test("the default project is a directory under projects/, like every other",
        () {
      expect(relative(config.projectDir()), p.join("projects", "default"));
      expect(relative(config.projectDir(project: "work")), p.join("projects", "work"));
    });

    test("a chat's workspace is in the project's, not beside its conversation", () {
      expect(relative(config.workspaceDir("c1")),
          p.join("projects", "default", "workspace", "chats", "c1"));
      expect(relative(config.chatDir("c1")),
          p.join("projects", "default", "chats", "c1"));
    });

    test("a project's settings sit in the project, the app's in the data dir", () {
      expect(relative(config.projectSettingsFile()),
          p.join("projects", "default", "project.json"));
      expect(relative(config.settingsFile), "settings.json");
    });
  });

  group("migrating what came before", () {
    /// The layout before this one: the default project *was* the data
    /// directory, and a chat's workspace sat in its own chat directory.
    void writeOldLayout() {
      write("${config.dataDir}/chats/old/state.json", "{}");
      write("${config.dataDir}/chats/old/workspace/note.txt", "kept");
      write("${config.dataDir}/workspace/shared.txt", "shared");
      write("${config.dataDir}/project.json", '{"model":"m"}');
    }

    test("the default project's chats, workspace and settings move under it",
        () async {
      writeOldLayout();

      await config.migrate();

      expect(File(config.stateFile("old")).existsSync(), isTrue);
      expect(File("${config.projectWorkspaceDir()}/shared.txt").readAsStringSync(),
          "shared");
      expect(File(config.projectSettingsFile()).readAsStringSync(), '{"model":"m"}');
      expect(Directory("${config.dataDir}/chats").existsSync(), isFalse);
      expect(Directory("${config.dataDir}/workspace").existsSync(), isFalse);
    });

    test("a chat's workspace moves into the workspace its project shares",
        () async {
      writeOldLayout();
      write("${config.chatsDir(project: "work")}/w1/state.json", "{}");
      write("${config.chatsDir(project: "work")}/w1/workspace/build.log", "ran");

      await config.migrate();

      expect(File("${config.workspaceDir("old")}/note.txt").readAsStringSync(), "kept");
      expect(File("${config.workspaceDir("w1", project: "work")}/build.log")
          .readAsStringSync(), "ran");
      expect(Directory("${config.chatDir("old")}/workspace").existsSync(), isFalse);
    });

    test("a projects/default that already exists is merged into, not stepped on",
        () async {
      writeOldLayout();
      write(config.stateFile("already"), '{"id":"already"}');
      write("${config.projectWorkspaceDir()}/shared.txt", "was here first");

      await config.migrate();

      expect(File(config.stateFile("already")).readAsStringSync(), '{"id":"already"}');
      expect(File(config.stateFile("old")).existsSync(), isTrue);
      // Left where it was rather than deleted with the directory around it.
      expect(File("${config.projectWorkspaceDir()}/shared.txt").readAsStringSync(),
          "was here first");
      expect(File("${config.dataDir}/workspace/shared.txt").readAsStringSync(),
          "shared");
    });

    test("running again over what it already moved does nothing", () async {
      writeOldLayout();
      await config.migrate();

      await config.migrate();

      expect(File("${config.workspaceDir("old")}/note.txt").readAsStringSync(), "kept");
      expect(File(config.projectSettingsFile()).readAsStringSync(), '{"model":"m"}');
    });

    test("a data directory that was never in the old layout is untouched",
        () async {
      write(config.stateFile("c1"), "{}");

      await config.migrate();

      expect(File(config.stateFile("c1")).existsSync(), isTrue);
      expect(Directory(config.projectWorkspaceDir()).existsSync(), isTrue);
    });
  });
}
