import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/room/roster.dart";

void main() {
  final library = PromptLibrary([
    for (final name in ["build", "review"])
      PromptDocument.parse(
          CompletionKind.agent, name, "---\ndescription: $name\n---\n\nDo $name.\n"),
  ]);
  Roster roster({bool omada = true}) => Roster(omada: omada, library: library);

  Message said(String text, {Map<String, String> documents = const {}}) =>
      Message(
          id: "u",
          role: MessageRole.user,
          createdAt: DateTime(2026),
          parts: [MessagePart.text(text: text)],
          documents: documents);

  Message reply(String text, {String? author}) => Message(
      id: "r",
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      parts: [MessagePart.text(text: text)],
      author: author);

  test("a say addresses the members its documents name, the library knows",
      () {
    final m = said("@build and @ghost, go",
        documents: {"@build": "Do build.", "@ghost": "Boo."});
    expect(roster().mentioned(m), ["build"]);
    expect(roster().addressees(m), ["@build"]);
    expect(roster().authorFor(m), "@build");
    expect(roster().answering(m), "build");
  });

  test("a direct chat addresses no one and stamps nothing", () {
    final m = said("@build, go", documents: {"@build": "Do build."});
    final direct = roster(omada: false);
    expect(direct.mentioned(m), isEmpty);
    expect(direct.authorFor(m), isNull);
    expect(direct.answering(m), isNull);
  });

  test("a command and a callback address no one they name", () {
    for (final text in ["!grep @build", "/compact @build"]) {
      final m = said(text, documents: {"@build": "Do build."});
      expect(roster().mentioned(m), isEmpty, reason: text);
      expect(roster().authorFor(m), isNull, reason: text);
    }
  });

  test("a reply hands off to who it names, never its own author", () {
    final r = reply("@build, then @review, signed @review", author: "@review");
    expect(roster().mentioned(r), ["build"]);
    expect(roster().answering(reply("over to @build")), "build");
    // Two names is a round, not a single answerer.
    expect(roster().answering(reply("@build and @review")), isNull);
  });

  test("a name the library lost is prose", () {
    expect(roster().known("ghost"), isNull);
    expect(roster().known("build"), "build");
    expect(roster(omada: false).known("build"), "build",
        reason: "a member's reply is carried on by them after the toggle");
  });
}
