import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

PromptDocument command(String name, String source) =>
    PromptDocument.parse(CompletionKind.command, name, source);

void main() {
  group("parsing", () {
    test("frontmatter and body come apart", () {
      final doc = command("review", "---\ndescription: look it over\n---\n\nReview \$ARGUMENTS.\n");

      expect(doc.description, "look it over");
      expect(doc.body, "Review \$ARGUMENTS.");
      expect(doc.option, const CompletionOption(name: "review", description: "look it over"));
    });

    test("a file with no frontmatter is all body", () {
      final doc = command("bare", "Just do the thing.\n");

      expect(doc.description, isNull);
      expect(doc.body, "Just do the thing.");
    });

    test("an unterminated block is not frontmatter", () {
      final doc = command("broken", "---\ndescription: never closed\n\nstill going");

      expect(doc.frontmatter, isEmpty);
      expect(doc.body, startsWith("---"));
    });

    test("quotes around a value are the YAML's, not part of it", () {
      final doc = command("quoted", '---\ndescription: "with: a colon"\n---\nbody');

      expect(doc.description, "with: a colon");
    });

    test("a nested key is skipped rather than half-read", () {
      final doc = PromptDocument.parse(CompletionKind.agent, "locked",
          "---\ndescription: careful\npermission:\n  edit: deny\n  bash: ask\n---\nbody");

      expect(doc.frontmatter, {"description": "careful"});
      expect(doc.body, "body");
    });

    test("windows line endings parse the same", () {
      final doc = command("crlf", "---\r\ndescription: fine\r\n---\r\n\r\nbody\r\n");

      expect(doc.description, "fine");
      expect(doc.body, "body");
    });
  });

  group("library", () {
    test("entries come back sorted, whatever order they were found in", () {
      final library = PromptLibrary([
        command("review", "---\n---\n"),
        command("commit", "---\n---\n"),
        command("explain", "---\n---\n"),
      ]);

      expect(library.entries(CompletionKind.command).map((d) => d.name),
          ["commit", "explain", "review"]);
    });

    test("a later document of the same name replaces an earlier one", () {
      final library = PromptLibrary([
        command("review", "---\ndescription: the preset\n---\n"),
        command("review", "---\ndescription: the user's own\n---\n"),
      ]);

      expect(library.entries(CompletionKind.command).single.description, "the user's own");
    });

    test("the kinds do not collide on a shared name", () {
      final library = PromptLibrary([
        command("review", "---\ndescription: a command\n---\n"),
        PromptDocument.parse(CompletionKind.agent, "review", "---\ndescription: an agent\n---\n"),
      ]);

      expect(library.find(CompletionKind.command, "review")!.description, "a command");
      expect(library.find(CompletionKind.agent, "review")!.description, "an agent");
    });

    test("a kind with nothing in it offers nothing", () {
      expect(PromptLibrary.empty.options(CompletionKind.agent), isEmpty);
      expect(PromptLibrary.empty.find(CompletionKind.command, "review"), isNull);
    });
  });
}
