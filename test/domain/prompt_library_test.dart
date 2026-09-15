import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

PromptDocument skill(String name, String source) =>
    PromptDocument.parse(CompletionKind.skill, name, source);

void main() {
  group("parsing", () {
    test("frontmatter and body come apart", () {
      final doc = skill("review", "---\ndescription: look it over\n---\n\nReview \$ARGUMENTS.\n");

      expect(doc.description, "look it over");
      expect(doc.body, "Review \$ARGUMENTS.");
      expect(doc.option, const CompletionOption(name: "review", description: "look it over"));
    });

    test("a file with no frontmatter is all body", () {
      final doc = skill("bare", "Just do the thing.\n");

      expect(doc.description, isNull);
      expect(doc.body, "Just do the thing.");
    });

    test("an unterminated block is not frontmatter", () {
      final doc = skill("broken", "---\ndescription: never closed\n\nstill going");

      expect(doc.frontmatter, isEmpty);
      expect(doc.body, startsWith("---"));
    });

    test("quotes around a value are the YAML's, not part of it", () {
      final doc = skill("quoted", '---\ndescription: "with: a colon"\n---\nbody');

      expect(doc.description, "with: a colon");
    });

    test("a nested key is skipped rather than half-read", () {
      final doc = PromptDocument.parse(CompletionKind.agent, "locked",
          "---\ndescription: careful\npermission:\n  edit: deny\n  bash: ask\n---\nbody");

      expect(doc.frontmatter, {"description": "careful"});
      expect(doc.body, "body");
    });

    test("windows line endings parse the same", () {
      final doc = skill("crlf", "---\r\ndescription: fine\r\n---\r\n\r\nbody\r\n");

      expect(doc.description, "fine");
      expect(doc.body, "body");
    });
  });

  group("library", () {
    test("entries come back sorted, whatever order they were found in", () {
      final library = PromptLibrary([
        skill("review", "---\n---\n"),
        skill("commit", "---\n---\n"),
        skill("explain", "---\n---\n"),
      ]);

      expect(library.entries(CompletionKind.skill).map((d) => d.name),
          ["commit", "explain", "review"]);
    });

    test("a later document of the same name replaces an earlier one", () {
      final library = PromptLibrary([
        skill("review", "---\ndescription: the preset\n---\n"),
        skill("review", "---\ndescription: the user's own\n---\n"),
      ]);

      expect(library.entries(CompletionKind.skill).single.description, "the user's own");
    });

    test("the kinds do not collide on a shared name", () {
      final library = PromptLibrary([
        skill("review", "---\ndescription: a skill\n---\n"),
        PromptDocument.parse(CompletionKind.agent, "review", "---\ndescription: an agent\n---\n"),
      ]);

      expect(library.find(CompletionKind.skill, "review")!.description, "a skill");
      expect(library.find(CompletionKind.agent, "review")!.description, "an agent");
    });

    test("a kind with nothing in it offers nothing", () {
      expect(PromptLibrary.empty.options(CompletionKind.agent), isEmpty);
      expect(PromptLibrary.empty.find(CompletionKind.skill, "review"), isNull);
    });
  });

  group("singleAgentMention", () {
    PromptLibrary libraryOf(List<String> names) => PromptLibrary(
          [for (final name in names) PromptDocument.parse(CompletionKind.agent, name, "")],
        );

    test("the one member mentioned is the handoff", () {
      expect(singleAgentMention("over to @reviewer now",
              libraryOf(["reviewer"])),
          "reviewer");
    });
    test("a name the library does not know is prose, not an address", () {
      expect(
          singleAgentMention("ask @stranger to look",
              libraryOf(["reviewer"])),
          isNull);
    });

    test("two members named is a round, not a handoff", () {
      expect(
          singleAgentMention("@reviewer and @second, look at this",
              libraryOf(["reviewer", "second"])),
          isNull);
    });

    test("a signature of a known member beside the handoff is two members",
        () {
      // Scout's reply opens with his own `@scout reporting.` — a mention of a
      // known member as far as the scan can see — beside the `@murasaki`
      // handoff. Two known members: a round, not a handoff. The scheduler
      // reads both as addressed, which is why the member-turn instructions
      // teach members not to open with their own handle.
      final text = "@scout reporting. The cache directory is absent.\n\n"
          "Over to **@murasaki**: the findings are two negative results. "
          "Your turn follows mine.";
      expect(singleAgentMention(text, libraryOf(["scout", "murasaki"])),
          isNull);
    });

    test("no mention names nobody", () {
      expect(singleAgentMention("all done here", libraryOf(["scout"])), isNull);
    });
  });

  group("mentionsIn", () {
    PromptLibrary libraryOf(List<String> names) => PromptLibrary(
          [for (final name in names) PromptDocument.parse(CompletionKind.agent, name, "")],
        );

    test("the members named, in the order they were named", () {
      expect(mentionsIn("@second first, then @reviewer",
              libraryOf(["reviewer", "second"])),
          ["second", "reviewer"]);
    });

    test("a name the library does not know is prose, not an address", () {
      expect(mentionsIn("ask @stranger to look", libraryOf(["reviewer"])),
          isEmpty);
    });

    test("one name twice is one address", () {
      expect(mentionsIn("@reviewer, @reviewer again",
              libraryOf(["reviewer", "second"])),
          ["reviewer"]);
    });

    test("no mention names nobody", () {
      expect(mentionsIn("all done here", libraryOf(["scout"])), isEmpty);
    });
  });
}
