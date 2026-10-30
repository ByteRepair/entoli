import "package:agent_chat/data/prompts/skill_validate.dart";
import "package:agent_chat/domain/frontmatter.dart";
import "package:flutter_test/flutter_test.dart";

Frontmatter _parse(String source) => Frontmatter.parse(source);

void main() {
  group("conforming skills", () {
    test("minimal spec shape", () {
      final parsed = _parse(
        "---\nname: pdf-processing\ndescription: Handle PDFs.\n---\n\nBody.",
      );
      final problems = skillFrontmatterProblems(parsed, "pdf-processing");
      expect(problems, isEmpty);
    });

    test("no frontmatter body-only is a problem", () {
      final parsed = _parse("Just a body.");
      final problems = skillFrontmatterProblems(parsed, "pdf");
      expect(problems, contains("no description in the SKILL.md frontmatter"));
    });
  });

  group("name rules", () {
    Frontmatter named(String name) =>
        _parse("---\nname: $name\ndescription: d\n---\n\nBody.");

    test("names the grammar refuses", () {
      // Each carries its own reason; only the shape is being asked about, so
      // one not-empty assertion per row.
      for (final name in [
        "PDF-Processing", // uppercase
        "-pdf", // leading hyphen
        "pdf--processing", // consecutive hyphens
        "pdf-", // trailing hyphen
      ]) {
        expect(
          skillFrontmatterProblems(named(name), name),
          isNotEmpty,
          reason: "$name is not a skill name",
        );
      }
      expect(skillNameOk("pdf_processing"), isFalse, reason: "underscore");
    });

    test("the 64-character cap, hyphens counting", () {
      final long = "a" * 65;
      expect(
        skillFrontmatterProblems(named(long), long),
        contains("name is 65 characters (max 64)"),
      );
      expect(skillNameOk("a" * 64), isTrue);

      // Hyphens and digits are characters like any other: the list of 64
      // names joined by 63 hyphens is 127 long.
      final joined = List.filled(64, "a").join("-");
      expect(skillNameOk(joined), isFalse);
    });

    test("name and folder must match", () {
      final parsed = named("pdf-processing");
      final problems = skillFrontmatterProblems(parsed, "pdf");
      expect(
        problems,
        contains(
          "frontmatter name \"pdf-processing\" does not match the "
          "folder \"pdf\"",
        ),
      );
    });

    test("no name and empty folder refused", () {
      expect(
        skillFrontmatterProblems(_parse("---\ndescription: d\n---\n\nB."), ""),
        contains(
          "no name — not in the frontmatter and the folder is not "
          "named either",
        ),
      );
    });
  });

  group("description rules", () {
    test("over 1024 characters refused", () {
      final parsed = _parse(
        "---\nname: s\ndescription: ${"d" * 1025}\n---\n\nB.",
      );
      expect(
        skillFrontmatterProblems(parsed, "s"),
        contains("description is 1025 characters (max 1024)"),
      );
    });
  });

  group("unknown keys", () {
    test("old top-level extension keys refused", () {
      final parsed = _parse(
        "---\nname: s\ndescription: d\nargument-hint: args\nuser-invocable: \"false\"\n---\n\nB.",
      );
      final problems = skillFrontmatterProblems(parsed, "s");
      expect(
        problems.any(
          (p) => p.startsWith(
            'unknown frontmatter key '
            '"argument-hint"',
          ),
        ),
        isTrue,
      );
      expect(
        problems.any(
          (p) => p.startsWith(
            'unknown frontmatter key '
            '"user-invocable"',
          ),
        ),
        isTrue,
      );
    });

    test("metadata map accepted", () {
      final parsed = _parse(
        "---\nname: s\ndescription: d\nmetadata:\n  argument-hint: \"the question\"\n  disable-model-invocation: \"true\"\n---\n\nB.",
      );
      expect(skillFrontmatterProblems(parsed, "s"), isEmpty);
      expect(parsed.metadata["argument-hint"], "the question");
      expect(parsed.metadata["disable-model-invocation"], "true");
    });

    test("nested blocks other than metadata dropped without error", () {
      final parsed = _parse(
        "---\nname: s\ndescription: d\nallowed-tools: Read Write\n---\n\nB.",
      );
      expect(skillFrontmatterProblems(parsed, "s"), isEmpty);
    });
  });

  group("compatibility", () {
    test("over 500 characters refused", () {
      final parsed = _parse(
        "---\nname: s\ndescription: d\ncompatibility: ${"c" * 501}\n---\n\nB.",
      );
      expect(
        skillFrontmatterProblems(parsed, "s"),
        contains("compatibility is 501 characters (max 500)"),
      );
    });
  });
}
