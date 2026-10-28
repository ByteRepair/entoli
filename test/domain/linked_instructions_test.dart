import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/linked_instructions.dart";

void main() {
  const global = "/data/AGENTS.md";

  test("every file is on until a project switches it off", () {
    final linked = const LinkedInstructions(files: ["/a.md"])
        .withOff("work", ["/a.md"]);

    expect(linked.isOn("work", "/a.md"), isFalse);
    expect(linked.isOn("other", "/a.md"), isTrue);
    expect(linked.isOn(null, "/a.md"), isTrue);
  });

  test("unlinking a file drops its switches, the global file's stay", () {
    final linked = const LinkedInstructions(files: ["/a.md", "/b.md"])
        .withOff("work", ["/a.md", global])
        .withOff("home", ["/a.md"])
        .withFiles(["/b.md"], keep: global);

    expect(linked.off, {"work": [global]});
  });

  test("a project with nothing switched off leaves no entry", () {
    final linked = const LinkedInstructions(files: ["/a.md"])
        .withOff("work", ["/a.md"])
        .withOff("work", const []);

    expect(linked.off, isEmpty);
  });

  test("deleting a project with no switches changes nothing", () {
    const linked = LinkedInstructions(files: ["/a.md"]);

    expect(identical(linked.withoutProject("work"), linked), isTrue);
  });

  test("survives a round trip", () {
    final linked = const LinkedInstructions(files: ["/a.md"])
        .withOff("work", [global]);

    final back = LinkedInstructions.fromJson(linked.toJson());

    expect(back.files, ["/a.md"]);
    expect(back.off, {"work": [global]});
  });
}
