import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/saved_output.dart";

void main() {
  late String project;
  late String workspace;

  setUp(() {
    final temp = Directory.systemTemp.createTempSync("saved_output_test_");
    addTearDown(() => temp.deleteSync(recursive: true));
    project = p.join(temp.path, "workspace");
    workspace = p.join(project, "chats", "c1");
    Directory(workspace).createSync(recursive: true);
  });

  test("a call id that comes round again does not write over the file an "
      "earlier result names", () async {
    final first = await saveOutput(
      "first",
      callId: "call_0",
      workspace: workspace,
      projectWorkspace: project,
    );
    final second = await saveOutput(
      "second",
      callId: "call_0",
      workspace: workspace,
      projectWorkspace: project,
    );

    expect(first, p.join(workspace, savedOutputDir, "call_0.txt"));
    expect(second, p.join(workspace, savedOutputDir, "call_0-2.txt"));
    expect(File(first!).readAsStringSync(), "first");
    expect(File(second!).readAsStringSync(), "second");
  });

  test("inside a guest the path is the guest's, which `tail` and `read` both "
      "take", () async {
    final shown = await saveOutput(
      "out",
      callId: "toolu/01:x",
      workspace: workspace,
      projectWorkspace: project,
      guestRoot: "/root",
    );

    expect(shown, "/root/chats/c1/$savedOutputDir/toolu_01_x.txt");
    expect(
      File(
        p.join(workspace, savedOutputDir, "toolu_01_x.txt"),
      ).readAsStringSync(),
      "out",
    );
  });

  test("a save that cannot be written answers nothing", () async {
    // A file where the directory has to go.
    File(p.join(workspace, savedOutputDir)).writeAsStringSync("");

    expect(
      await saveOutput(
        "out",
        callId: "c",
        workspace: workspace,
        projectWorkspace: project,
      ),
      isNull,
    );
  });
}
