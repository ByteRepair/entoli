import "package:agent_chat/domain/frontmatter.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("top-level scalars parse", () {
    final parsed = Frontmatter.parse("---\nname: s\ndescription: d\n---\n\nBody.");
    expect(parsed.scalars, {"name": "s", "description": "d"});
    expect(parsed.body, "Body.");
  });

  test("metadata map parses with quotes stripped", () {
    final parsed = Frontmatter.parse(
        "---\nname: s\ndescription: d\nmetadata:\n  argument-hint: \"the question\"\n  agent: general\n  subtask: \"true\"\n---\n\nBody.");
    expect(parsed.metadata, {
      "argument-hint": "the question",
      "agent": "general",
      "subtask": "true",
    });
    expect(parsed.scalars, {"name": "s", "description": "d"});
  });

  test("nested non-metadata blocks are dropped", () {
    final parsed = Frontmatter.parse(
        "---\nname: s\ndescription: d\npermissions:\n  bash: allow\n---\n\nBody.");
    expect(parsed.metadata, isEmpty);
    expect(parsed.scalars, {"name": "s", "description": "d"});
  });

  test("metadata ends where the next top-level key starts", () {
    final parsed = Frontmatter.parse(
        "---\nname: s\nmetadata:\n  a: b\nlicense: MIT\n---\n\nBody.");
    expect(parsed.metadata, {"a": "b"});
    expect(parsed.scalars["license"], "MIT");
  });

  test("no frontmatter: everything is the body", () {
    final parsed = Frontmatter.parse("Just text.");
    expect(parsed.scalars, isEmpty);
    expect(parsed.body, "Just text.");
  });

  test("unclosed frontmatter: everything is the body", () {
    final parsed = Frontmatter.parse("---\nname: s\n\nBody.");
    expect(parsed.scalars, isEmpty);
  });

  test("metadata nested one level deeper than two spaces is still read", () {
    final parsed = Frontmatter.parse(
        "---\nmetadata:\n\ta: b\n---\n\nBody.");
    expect(parsed.metadata, {"a": "b"});
  });

  test("a nested value under a metadata key is dropped", () {
    final parsed = Frontmatter.parse(
        "---\nmetadata:\n  a: b\n  nested:\n    deep: x\n---\n\nBody.");
    expect(parsed.metadata, {"a": "b"});
  });
}