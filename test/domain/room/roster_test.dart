import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/domain/room/roster.dart";

void main() {
  final library = PromptLibrary([
    for (final name in ["build", "review"])
      PromptDocument.parse(
        CompletionKind.agent,
        name,
        "---\ndescription: $name\n---\n\nDo $name.\n",
      ),
  ]);
  Roster roster({bool omada = true}) => Roster(omada: omada, library: library);

  Message said(String text, {Map<String, String> documents = const {}}) =>
      Message(
        id: "u",
        role: MessageRole.user,
        createdAt: DateTime(2026),
        parts: [MessagePart.text(text: text)],
        documents: documents,
      );

  Message reply(String text, {String? author}) => Message(
    id: "r",
    role: MessageRole.assistant,
    createdAt: DateTime(2026),
    parts: [MessagePart.text(text: text)],
    author: author,
  );

  test("a say addresses the members its documents name, the library knows", () {
    final m = said(
      "@build and @ghost, go",
      documents: {"@build": "Do build.", "@ghost": "Boo."},
    );
    expect(roster().mentioned(m), ["build"]);
    expect(roster().addressees(m), ["@build"]);
    expect(roster().answering(m), "build");
  });

  test("a direct chat holds Athena alone: every say is hers", () {
    final m = said("@build, go", documents: {"@build": "Do build."});
    final direct = roster(omada: false);
    expect(direct.mentioned(m), ["athena"]);
    expect(direct.addressees(m), ["@athena"]);
    expect(direct.answering(m), "athena");
  });

  test("a say naming no one in the room is the default route's", () {
    expect(roster().mentioned(said("hello")), ["athena"]);
    expect(
      roster(
        omada: true,
      ).mentioned(said("@ghost, go", documents: {"@ghost": "Boo."})),
      ["athena"],
    );
  });

  test("a command and a callback go to the default route, whoever they "
      "name", () {
    for (final text in ["!grep @build", "/compact @build"]) {
      final m = said(text, documents: {"@build": "Do build."});
      expect(roster().mentioned(m), ["athena"], reason: text);
      expect(roster().answering(m), "athena", reason: text);
    }
  });

  test("a reply hands off to who it names in the room, never its own "
      "author", () {
    final r = reply("@build, then @review, signed @review", author: "@review");
    expect(roster().mentioned(r), ["build"]);
    expect(roster(omada: false).mentioned(r), isEmpty);
    expect(roster().answering(reply("over to @build")), "build");
    // A reply naming nobody is answered, where something must answer it, by
    // the default route.
    expect(roster().answering(reply("all done")), "athena");
  });

  test("a reaction addresses whoever wrote what it reacts to", () {
    Message to(Message m) =>
        reactionTo(m, Reaction.thumbsUp, id: "x", at: DateTime(2026));
    final member = to(reply("A plan.", author: "@build"));
    expect(roster().mentioned(member), ["build"]);
    expect(roster().answering(member), "build");
    expect(roster(omada: false).answering(member), "athena");
    // Athena's reply, and the user's own message, are Athena's to answer.
    for (final m in [
      to(reply("Done.", author: "@athena")),
      to(said("@build, go")),
    ]) {
      expect(roster().mentioned(m), ["athena"]);
    }
  });
}
