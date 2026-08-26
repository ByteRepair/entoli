import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/builtin_project.dart";
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

  group("the built-in projects", () {
    // The one the app ships today: a directory under projects/ like any
    // other, but named by the app rather than the user.
    final builtIn = builtinProjects.single;
    final dir = builtIn.dir;

    test("is a project-shaped directory name", () {
      expect(dir, "anonymous");
      expect(builtIn.label, "Anonymous");
      expect(isProjectDirName(dir), isTrue);
      expect(isBuiltinProject(dir), isTrue);
      expect(builtinProjectOf(dir), same(builtIn));
    });

    // A second way to name it would be a second entry for it in every list,
    // so the user cannot create, rename or delete one.
    test("is not a name the user may create a project with", () {
      expect(isProjectName(dir), isFalse);
      expect(projectNameFrom("anonymous"), isNull);
      expect(projectNameFrom("Anonymous"), isNull);
    });

    // It is read as a label rather than a path, and is always there to resolve
    // to, since it cannot be deleted.
    test("is labelled and always resolves to itself", () {
      expect(projectLabel(dir), builtIn.label);
      expect(projectOrDefault(dir, const []), dir);
      expect(projectOrDefault("deleted", const []), isNull);
    });

    // The only AGENTS.md it has is the one the app ships, in code rather than
    // on a disk a user could delete or edit away from under a turn.
    test("ships its own instructions and reads no file", () {
      expect(builtIn, isA<AnonymousProject>());
      expect(builtIn.bundledInstructions, contains("anonymous chat"));
      expect(
          const BuiltinProject(dir: "work", label: "work")
              .bundledInstructions,
          isNull);
    });

    // Offered after the default and before the user's projects, and not twice.
    test("is in everyProject once, after the default", () {
      final all = everyProject(["work"]);
      expect(all, [null, dir, "work"]);
      expect(all.where((p) => p == dir), hasLength(1));
    });
  });
}
