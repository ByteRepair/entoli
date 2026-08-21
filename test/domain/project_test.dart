import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/project.dart";

void main() {
  test("a plain name is kept as it was typed", () {
    expect(projectNameFrom("Website"), "Website");
  });

  test("spaces become dashes, so the name is one word in a path", () {
    expect(projectNameFrom("  my  side project "), "my-side-project");
  });

  // The name ends up as a directory the model writes paths to.
  test("anything a path cannot hold is replaced", () {
    expect(projectNameFrom("../etc"), "etc");
    expect(projectNameFrom("a/b"), "a-b");
    expect(projectNameFrom(".hidden"), "hidden");
  });

  test("a name with nothing usable in it is not a name", () {
    expect(projectNameFrom("   "), isNull);
    expect(projectNameFrom("///"), isNull);
    expect(projectNameFrom("..."), isNull);
  });

  // What `projectNameFrom` produces is what the path helpers will accept.
  test("what a name is sanitized into is a project name", () {
    expect(isProjectName(projectNameFrom("my side project")!), isTrue);
    expect(isProjectName("../etc"), isFalse);
    expect(isProjectName(".hidden"), isFalse);
    expect(isProjectName(""), isFalse);
  });

  // The default project is `null` above the filesystem and that directory
  // below it, so a second project answering to the same name is two entries
  // for one place.
  test("the default project's own directory is not a name a project can have",
      () {
    expect(isProjectName(defaultProjectDir), isFalse);
    expect(projectNameFrom("Default"), isNull);
    expect(projectNameFrom("default"), isNull);
  });

  test("the default project is labelled rather than left blank", () {
    expect(projectLabel(null), defaultProjectLabel);
    expect(projectLabel("work"), "work");
  });
}
