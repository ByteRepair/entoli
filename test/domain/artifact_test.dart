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

  test("entryFile is the basename, for a bare path and a nested one", () {
    expect(artifactArgsFrom('{"path": "chart.html"}')!.entryFile, "chart.html");
    expect(artifactArgsFrom('{"path": "report/sub/page.html"}')!.entryFile,
        "page.html");
  });

  test("title defaults to empty string", () {
    final args = artifactArgsFrom('{"path": "report/"}');
    expect(args!.title, "");
  });

  test("parses artifact_id for update in place", () {
    final args = artifactArgsFrom('{"path": "report/index.html", "artifact_id": "existing-id"}');
    expect(args!.artifactId, "existing-id");
  });

  test("null where no path can come of it", () {
    // The key is not there.
    expect(artifactArgsFrom('{"title": "no path"}'), isNull);
    // Or the path is empty.
    expect(artifactArgsFrom('{"path": ""}'), isNull);
    // The json is not json, or nothing at all.
    expect(artifactArgsFrom("not json"), isNull);
    expect(artifactArgsFrom(""), isNull);
    expect(artifactArgsFrom(null), isNull);
  });
}