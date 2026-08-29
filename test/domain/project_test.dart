import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

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
    // The built-in projects, in the order the menus offer them: the anonymous
    // one first, then Byte Repair. Each is a directory under projects/ like
    // any other, but named by the app rather than the user.
    final anon = builtinProjects[0];
    final byteRepair = builtinProjects[1];
    final anonDir = anon.dir;
    final byteRepairDir = byteRepair.dir;

    test("are project-shaped directory names", () {
      expect(anonDir, "anonymous");
      expect(anon.label, anonProjectLabel);
      expect(isProjectDirName(anonDir), isTrue);
      expect(isBuiltinProject(anonDir), isTrue);
      expect(builtinProjectOf(anonDir), same(anon));

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
      expect(isProjectName(byteRepairDir), isFalse);
      expect(projectNameFrom("byte-repair"), isNull);
      expect(projectNameFrom("Byte-Repair"), isNull);
    });

    // They are read as labels rather than paths, and are always there to
    // resolve to, since they cannot be deleted.
    test("are labelled and always resolve to themselves", () {
      expect(projectLabel(anonDir), anon.label);
      expect(projectLabel(byteRepairDir), byteRepair.label);
      expect(projectOrDefault(anonDir, const []), anonDir);
      expect(projectOrDefault(byteRepairDir, const []), byteRepairDir);
      expect(projectOrDefault("deleted", const []), isNull);
    });

    // The only AGENTS.md each has is the one the app ships, in code rather
    // than on a disk a user could delete or edit away from under a turn.
    test("ship their own instructions and read no file", () {
      expect(anon, isA<AnonymousProject>());
      expect(anon.bundledInstructions, contains("anonymous chat"));
      expect(byteRepair, isA<ByteRepairProject>());
      expect(byteRepair.bundledInstructions, contains("ESBMC"));
      expect(
          const BuiltinProject(dir: "work", label: "work")
              .bundledInstructions,
          isNull);
    });

    // Anonymous ships a 24h TTL and its own question; Byte Repair inherits the
    // app default TTL and ships its own question. A built-in with neither
    // leaves both null, the way a user's project does.
    test("ship their own TTL defaults and empty-chat questions", () {
      expect(anon.tempChatTtl, TempChatTtl.hours24);
      expect(anon.emptyChatQuestion, "What would you like to discuss anonymously?");
      expect(byteRepair.tempChatTtl, isNull);
      expect(byteRepair.emptyChatQuestion, "What would you like to verify?");
      expect(const BuiltinProject(dir: "work", label: "work").tempChatTtl, isNull);
      expect(
          const BuiltinProject(dir: "work", label: "work").emptyChatQuestion,
          isNull);
    });

    // Offered after the default and before the user's projects, and not twice.
    test("are in everyProject once each, after the default", () {
      final all = everyProject(["work"]);
      expect(all, [null, anonDir, byteRepairDir, "work"]);
      expect(all.where((p) => p == anonDir), hasLength(1));
      expect(all.where((p) => p == byteRepairDir), hasLength(1));
    });

    // Byte Repair keeps full capabilities — profile, memory and a shared
    // workspace — where Anonymous takes them away.
    test("Byte Repair inherits profile, memory and shares its workspace", () {
      expect(byteRepair.profilePolicy, ProfilePolicy.inherit);
      expect(byteRepair.memory, MemoryPolicy.app);
      expect(byteRepair.sharedWorkspace, isTrue);
      expect(byteRepair.disabled, isEmpty);
      expect(anon.profilePolicy, ProfilePolicy.none);
      expect(anon.memory, MemoryPolicy.off);
      expect(anon.sharedWorkspace, isFalse);
    });
  });
}
