import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

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

  test("the default project is labelled rather than left blank", () {
    expect(projectLabel(null), defaultProjectLabel);
    expect(projectLabel("work"), "work");
  });

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

    test("are project-shaped directory names", () {
      expect(anonDir, "anonymous");
      expect(anon.label, anonProjectLabel);
      expect(isProjectDirName(anonDir), isTrue);
      expect(isBuiltinProject(anonDir), isTrue);
      expect(builtinProjectOf(anonDir), same(anon));

      expect(myTeamDir, "my-team");
      expect(myTeam.label, myTeamProjectLabel);
      expect(isProjectDirName(myTeamDir), isTrue);
      expect(isBuiltinProject(myTeamDir), isTrue);
      expect(builtinProjectOf(myTeamDir), same(myTeam));

      expect(byteRepairDir, "byte-repair");
      expect(byteRepair.label, byteRepairProjectLabel);
      expect(isProjectDirName(byteRepairDir), isTrue);
      expect(isBuiltinProject(byteRepairDir), isTrue);
      expect(builtinProjectOf(byteRepairDir), same(byteRepair));
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

    // The only AGENTS.md each has is the one the app ships, in code rather
    // than on a disk a user could delete or edit away from under a turn.
    // Byte Repair is the exception that proves the rule: it ships a note and
    // also reads the user's files on top of it, so it has a settings page to
    // edit them from; anonymous does not. My Team's note is the room
    // contract, and it is what any Omada project without a note of its own
    // falls through to.
    test("ship their own instructions and read no file", () {
      expect(anon, isA<AnonymousProject>());
      expect(anon.bundledInstructions, contains("anonymous chat"));
      expect(anon.includesUserInstructions, isFalse);
      expect(anon.hasSettingsPage, isFalse);
      expect(myTeam, isA<MyTeamProject>());
      expect(myTeam.bundledInstructions, contains("team project"));
      expect(myTeam.includesUserInstructions, isTrue);
      expect(myTeam.hasSettingsPage, isTrue);
      expect(byteRepair, isA<ByteRepairProject>());
      expect(byteRepair.bundledInstructions, contains("ESBMC"));
      expect(byteRepair.includesUserInstructions, isTrue);
      expect(byteRepair.hasSettingsPage, isTrue);
      // A future Omada-on built-in that ships no note of its own runs under
      // My Team's; an Omada-off one ships none.
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
      expect(
        const BuiltinProject(
          dir: "work",
          label: "work",
        ).includesUserInstructions,
        isFalse,
      );
      expect(
        const BuiltinProject(dir: "work", label: "work").hasSettingsPage,
        isFalse,
      );
    });

    // Anonymous ships a 24h TTL and its own question; Byte Repair inherits the
    // app default TTL and ships its own question. A built-in with neither
    // leaves both null, the way a user's project does.
    test("ship their own TTL defaults and empty-chat questions", () {
      expect(anon.tempChatTtl, TempChatTtl.hours24);
      expect(
        anon.emptyChatQuestion,
        "What would you like to discuss anonymously?",
      );
      expect(
        myTeam.emptyChatQuestion,
        "Speak to a team of collaborating agents. Use @ to converse.",
      );
      expect(myTeam.tempChatTtl, isNull);
      expect(byteRepair.tempChatTtl, isNull);
      expect(byteRepair.emptyChatQuestion, "What would you like to verify?");
      expect(
        const BuiltinProject(dir: "work", label: "work").tempChatTtl,
        isNull,
      );
      expect(
        const BuiltinProject(dir: "work", label: "work").emptyChatQuestion,
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

    // Byte Repair keeps full capabilities — profile, memory and a shared
    // workspace — where Anonymous takes them away. My Team is the same shape,
    // plus the Omada flag the room is.
    test("Byte Repair inherits profile, memory and shares its workspace", () {
      expect(byteRepair.profilePolicy, ProfilePolicy.inherit);
      expect(byteRepair.memory, MemoryPolicy.app);
      expect(byteRepair.sharedWorkspace, isTrue);
      expect(byteRepair.disabled, isEmpty);
      expect(anon.profilePolicy, ProfilePolicy.none);
      expect(anon.memory, MemoryPolicy.off);
      expect(anon.sharedWorkspace, isFalse);
      expect(myTeam.profilePolicy, ProfilePolicy.inherit);
      expect(myTeam.memory, MemoryPolicy.app);
      expect(myTeam.sharedWorkspace, isTrue);
      expect(myTeam.omada, isTrue);
    });

    // Byte Repair opts into rootfs isolation: packages installed inside the
    // guest are scoped to that project alone. Anonymous and user projects do
    // not, sharing the base rootfs in cache.
    test("Byte Repair opts into rootfs isolation, others do not", () {
      expect(byteRepair.rootfsIsolation, isTrue);
      expect(anon.rootfsIsolation, isFalse);
      expect(
        const BuiltinProject(dir: "work", label: "work").rootfsIsolation,
        isFalse,
      );
    });

    // Byte Repair requires setup before turns can be sent: the chat page
    // gates the composer on a `.setup-complete` marker. Anonymous and user
    // projects do not.
    test("Byte Repair requires setup, others do not", () {
      expect(byteRepair.requiresSetup, isTrue);
      expect(anon.requiresSetup, isFalse);
      expect(
        const BuiltinProject(dir: "work", label: "work").requiresSetup,
        isFalse,
      );
    });
  });
}
