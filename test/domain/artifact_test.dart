import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/artifact.dart";

void main() {
  test("parses path, title, and derives entryFile", () {
    final args = artifactArgsFrom('{"path": "report/index.html", "title": "Demo"}');
    expect(args, isNotNull);
    expect(args!.path, "report/index.html");
    expect(args.entryFile, "index.html");
    expect(args.title, "Demo");
    expect(args.artifactId, isNull);
  });

  test("entryFile is the basename for a bare file", () {
    final args = artifactArgsFrom('{"path": "chart.html"}');
    expect(args!.entryFile, "chart.html");
  });

  test("entryFile is the basename for a nested path", () {
    final args = artifactArgsFrom('{"path": "report/sub/page.html"}');
    expect(args!.entryFile, "page.html");
  });

  test("title defaults to empty string", () {
    final args = artifactArgsFrom('{"path": "report/"}');
    expect(args!.title, "");
  });

  test("parses artifact_id for update in place", () {
    final args = artifactArgsFrom('{"path": "report/index.html", "artifact_id": "existing-id"}');
    expect(args!.artifactId, "existing-id");
  });

  test("null when path is missing", () {
    expect(artifactArgsFrom('{"title": "no path"}'), isNull);
  });

  test("null when path is empty", () {
    expect(artifactArgsFrom('{"path": ""}'), isNull);
  });

  test("null when json is invalid", () {
    expect(artifactArgsFrom("not json"), isNull);
  });

  test("null when empty", () {
    expect(artifactArgsFrom(""), isNull);
    expect(artifactArgsFrom(null), isNull);
  });
}