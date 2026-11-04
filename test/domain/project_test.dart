import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/project.dart";

void main() {
  test(
    "projectNameFrom: typed kept, spaces dashed, path-hostile replaced, unusable null",
    () {
      // Typed plain: kept as it was typed.
      expect(projectNameFrom("Website"), "Website");
      // Spaces become dashes, so the name is one word in a path.
      expect(projectNameFrom("  my  side project "), "my-side-project");
      // The name ends up as a directory the model writes paths to.
      expect(projectNameFrom("../etc"), "etc");
      expect(projectNameFrom("a/b"), "a-b");
      expect(projectNameFrom(".hidden"), "hidden");
      // Nothing usable in it: not a name.
      expect(projectNameFrom("   "), isNull);
      expect(projectNameFrom("///"), isNull);
      expect(projectNameFrom("..."), isNull);
    },
  );

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
  test(
    "the default project's own directory is not a name a project can have",
    () {
      expect(isProjectName(defaultProjectDir), isFalse);
      expect(projectNameFrom("Default"), isNull);
      expect(projectNameFrom("default"), isNull);
    },
  );

  group("the empty-chat question", () {
    // The description set is the answer — the badge's own text, swept in by
    // the screen's animation; the app default is what nothing set asks; and
    // empty is the screen asking nothing, distinct from unset. The default
    // project is gated at the provider, which reads no description for it;
    // the function itself answers for any project that is not a built-in.
    test(
      "the description set, the app default where nothing set, nothing where empty",
      () {
        expect(
          emptyChatQuestionFor(null, description: null),
          defaultEmptyChatQuestion,
        );
        expect(
          emptyChatQuestionFor("work", description: null),
          defaultEmptyChatQuestion,
        );
        expect(
          emptyChatQuestionFor("work", description: "What are we building?"),
          "What are we building?",
        );
        expect(
          emptyChatQuestionFor(null, description: "What are we building?"),
          "What are we building?",
        );
        expect(emptyChatQuestionFor("work", description: ""), isNull);
        expect(emptyChatQuestionFor("work", description: "  "), isNull);
      },
    );
  });

  group("the built-in projects", () {
    // The built-in projects, in the order the menus offer them: the anonymous
    // one first, then My Team, then Byte Repair. Each is a directory under
    // projects/ like any other, but named by the app rather than the user.
    final anon = builtinProjects[0];
    final myTeam = builtinProjects[1];
    final byteRepair = builtinProjects[2];
    final anonDir = anon.dir;
    final myTeamDir = myTeam.dir;
    final byteRepairDir = byteRepair.dir;

    // Path construction accepts them, a chat can be in one, and each name
    // finds its own spec.
    test("are project-shaped directory names that find their spec", () {
      for (final project in builtinProjects) {
        expect(isProjectDirName(project.dir), isTrue, reason: project.dir);
        expect(isBuiltinProject(project.dir), isTrue, reason: project.dir);
        expect(builtinProjectOf(project.dir), same(project));
      }
      expect(isBuiltinProject("work"), isFalse);
    });

    // A second way to name one would be a second entry for it in every list,
    // so the user cannot create, rename or delete one.
    test("are not names the user may create a project with", () {
      expect(isProjectName(anonDir), isFalse);
      expect(projectNameFrom("anonymous"), isNull);
      expect(projectNameFrom("Anonymous"), isNull);
      expect(isProjectName(myTeamDir), isFalse);
      expect(projectNameFrom("my-team"), isNull);
      expect(projectNameFrom("My-Team"), isNull);
      expect(isProjectName(byteRepairDir), isFalse);
      expect(projectNameFrom("byte-repair"), isNull);
      expect(projectNameFrom("Byte-Repair"), isNull);
    });

    // The one answer the sidebar's settings gear reads, regardless of project
    // kind: the default has no page, a built-in answers from its spec, a
    // user's project always does.
    test("have a settings page where their spec says they have one", () {
      expect(projectHasSettingsPage(null), isFalse);
      expect(projectHasSettingsPage(defaultProjectDir), isFalse);
      expect(projectHasSettingsPage(anonDir), isFalse);
      expect(projectHasSettingsPage(myTeamDir), isTrue);
      expect(projectHasSettingsPage(byteRepairDir), isTrue);
      expect(projectHasSettingsPage("work"), isTrue);
    });

    // They are read as labels rather than paths, and are always there to
    // resolve to, since they cannot be deleted.
    test("are labelled and always resolve to themselves", () {
      expect(projectLabel(anonDir), anon.label);
      expect(projectLabel(myTeamDir), myTeam.label);
      expect(projectLabel(byteRepairDir), byteRepair.label);
      expect(projectOrDefault(anonDir, const []), anonDir);
      expect(projectOrDefault(myTeamDir, const []), myTeamDir);
      expect(projectOrDefault(byteRepairDir, const []), byteRepairDir);
      expect(projectOrDefault("deleted", const []), isNull);
    });

    // My Team's note is the room contract, and it is what any Omada project
    // without a note of its own falls through to; an Omada-off one ships none.
    test("an Omada built-in with no note of its own runs under My Team's", () {
      expect(
        const BuiltinProject(
          dir: "work",
          label: "work",
          omada: true,
        ).bundledInstructions,
        myTeam.bundledInstructions,
      );
      expect(
        const BuiltinProject(dir: "work", label: "work").bundledInstructions,
        isNull,
      );
    });

    // Offered after the default and before the user's projects, and not twice.
    test("are in everyProject once each, after the default", () {
      final all = everyProject(["work"]);
      expect(all, [null, anonDir, myTeamDir, byteRepairDir, "work"]);
      expect(all.where((p) => p == anonDir), hasLength(1));
      expect(all.where((p) => p == myTeamDir), hasLength(1));
      expect(all.where((p) => p == byteRepairDir), hasLength(1));
    });
  });
}
