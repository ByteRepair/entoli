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

  // The parser reads real YAML, so every scalar form the Agent Skills spec
  // allows parses as the spec means it.

  test("folded block scalar description", () {
    final parsed = Frontmatter.parse(
        "---\ndescription: >-\n  Folded text spans\n  multiple lines.\nmetadata:\n  author: A\n---\n\nBody.");
    expect(parsed.description, "Folded text spans multiple lines.");
    expect(parsed.metadata, {"author": "A"});
  });

  test("literal block scalar", () {
    final parsed = Frontmatter.parse(
        "---\ndescription: |\n  line one\n  line two\n---\n\nBody.");
    expect(parsed.description, "line one\nline two\n");
  });

  test("trailing comment is not part of the value", () {
    final parsed =
        Frontmatter.parse("---\nname: s # the name\ndescription: d\n---\n");
    expect(parsed.scalars["name"], "s");
  });

  test("escaped quotes inside a double-quoted value", () {
    final parsed =
        Frontmatter.parse("---\ndescription: \"say \\\"hi\\\" now\"\n---\n");
    expect(parsed.description, 'say "hi" now');
  });

  test("numbers and booleans stringify", () {
    final parsed =
        Frontmatter.parse("---\ndescription: 123\ntruthy: true\n---\n");
    expect(parsed.scalars, {"description": "123", "truthy": "true"});
  });

  test("empty block parses to nothing", () {
    final parsed = Frontmatter.parse("---\n---\n\nBody.");
    expect(parsed.scalars, isEmpty);
    expect(parsed.body, "Body.");
  });

  test("malformed yaml falls back to the legacy scalar parse", () {
    // `name: [unclosed` is not YAML; the strict path refuses it and the
    // legacy regex parse still extracts the plain keys — no throw, no lost
    // frontmatter.
    final parsed = Frontmatter.parse(
        "---\nname: [unclosed\ndescription: d\n---\n\nBody.");
    expect(parsed.scalars, {"name": "[unclosed", "description": "d"});
    expect(parsed.body, "Body.");
  });

  test("an empty metadata map is kept empty, not dropped", () {
    final parsed =
        Frontmatter.parse("---\nname: s\ndescription: d\nmetadata:\n---\n");
    expect(parsed.metadata, isEmpty);
    expect(parsed.scalars["name"], "s");
  });

  test("fences may carry trailing whitespace", () {
    final parsed =
        Frontmatter.parse("---  \nname: s\ndescription: d\n---  \n\nBody.");
    expect(parsed.scalars, {"name": "s", "description": "d"});
    expect(parsed.body, "Body.");
  });

  test("crlf sources parse", () {
    final parsed = Frontmatter.parse(
        "---\r\nname: s\r\ndescription: d\r\nmetadata:\r\n  a: b\r\n---\r\n\r\nBody.\r\n");
    expect(parsed.scalars, {"name": "s", "description": "d"});
    expect(parsed.metadata, {"a": "b"});
    expect(parsed.body, "Body.");
  });

  test("only tools is read as a list; a list under any other key stays "
      "dropped", () {
    final parsed =
        Frontmatter.parse("---\ntools: [read, bash]\ntags: [a, b]\n---\nB");
    expect(parsed.scalars["tools"], "read, bash");
    expect(parsed.scalars, isNot(contains("tags")));
  });
}