import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/proot.dart";
import "package:agent_chat/domain/file_tools.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/domain/shell.dart";

/// What proot is asked to do is the whole of what this feature does, and it is
/// the one part of it that can be pinned on a machine with no Android on it.
void main() {
  const proot = Proot(
    binary: "/data/app/pkg/lib/x86_64/libproot.so",
    loader: "/data/app/pkg/lib/x86_64/libproot-loader.so",
    tmpDir: "/data/user/0/pkg/cache/tools/tmp",
    resolvConf: "/data/user/0/pkg/cache/tools/etc/resolv.conf",
  );
  const dataDir = "/data/user/0/pkg/app_flutter/entoli";
  const defaultSkillsBundled = "$dataDir/projects/default/skills-bundled";
  const defaultUserSkills = "$dataDir/projects/default/skills";
  const home = "$dataDir/projects/default/workspace";
  const cwd = "$home/chats/abc-123";

  ShellDriver build({
    Proot from = proot,
    String? abi = "x86_64",
    String? projectSkillsBundled,
    String? projectUserSkills,
  }) =>
      prootDriver(
        proot: from,
        rootfs: alpine,
        rootfsDir: "/data/user/0/pkg/cache/rootfs/alpine",
        defaultSkillsBundledDir: defaultSkillsBundled,
        defaultUserSkillsDir: defaultUserSkills,
        projectSkillsBundledDir: projectSkillsBundled,
        projectUserSkillsDir: projectUserSkills,
        abi: abi,
      );

  /// The value of the argument after [flag], as a list because a bind is given
  /// several times over.
  List<String> valuesOf(List<String> command, String flag) => [
        for (var i = 0; i < command.length - 1; i++)
          if (command[i] == flag) command[i + 1],
      ];

  test("the loader is named where it is, since it is the one file really exec'd",
      () {
    final driver = build();

    expect(driver.environment["PROOT_LOADER"], proot.loader);
    expect(driver.environment.containsKey("PROOT_LOADER_32"), isFalse);
  });

  test("a 32-bit loader is named where the architecture has one", () {
    final driver = build(
        from: const Proot(
      binary: "/lib/libproot.so",
      loader: "/lib/libproot-loader.so",
      loader32: "/lib/libproot-loader32.so",
      tmpDir: "/tmp",
      resolvConf: "/tmp/resolv.conf",
    ));

    expect(driver.environment["PROOT_LOADER_32"], "/lib/libproot-loader32.so");
  });

  test("the binds: the project workspace at /root, the skills and the "
      "resolver at clean guest paths, and nothing of the data dir", () {
    final driver = build();
    final binds = valuesOf(driver.commandFor(cwd, home), "-b");

    expect(binds, containsAll([
      "$home:/root",
      "$defaultSkillsBundled:/opt/skills-bundled",
      "$defaultUserSkills:/opt/skills",
      // Android keeps no resolv.conf of its own.
      "${proot.resolvConf}:/etc/resolv.conf",
    ]));
    expect(binds, isNot(contains("$dataDir:$dataDir")));
    expect(driver.hostToGuestPaths[defaultSkillsBundled], "/opt/skills-bundled");
    expect(driver.hostToGuestPaths[defaultUserSkills], "/opt/skills");
  });

  test("a read-only dir is bound at its own path unless bound already, and "
      "each is kept from the fake root", () {
    const resources = "$dataDir/projects/default/chats/abc-123/resources";
    final command = build().commandFor(cwd, home,
        readOnly: [resources, defaultSkillsBundled, defaultUserSkills]);

    expect(valuesOf(command, "-b"), contains("$resources:$resources"));
    expect(valuesOf(command, "-b"),
        isNot(contains("$defaultSkillsBundled:$defaultSkillsBundled")),
        reason: "a skills directory is reached at its clean path");
    expect(valuesOf(command, "--read-only"),
        [resources, defaultSkillsBundled, defaultUserSkills]);
    expect(command.indexOf("--read-only"), greaterThan(command.indexOf("-0")),
        reason: "beside the fake root it qualifies");
  });

  test("a project's own skills dirs are bound beside the default's", () {
    const projectSkillsBundled = "$dataDir/projects/byte-repair/skills-bundled";
    const projectUserSkills = "$dataDir/projects/byte-repair/skills";
    final driver = build(
        projectSkillsBundled: projectSkillsBundled,
        projectUserSkills: projectUserSkills);
    final command = driver.commandFor(cwd, home);

    expect(valuesOf(command, "-b"),
        contains("$projectSkillsBundled:/opt/skills-bundled-project"));
    expect(valuesOf(command, "-b"),
        contains("$projectUserSkills:/opt/skills-project"));
    expect(driver.hostToGuestPaths[projectSkillsBundled],
        "/opt/skills-bundled-project");
    expect(driver.hostToGuestPaths[projectUserSkills], "/opt/skills-project");
  });

  test("it runs proot as root in the rootfs, kills tracees with the tracer, "
      "survives hard links, and ends in the guest's shell", () {
    final command = build().commandFor(cwd, home);

    expect(command.first, proot.binary);
    expect(command.last, "/bin/sh");
    expect(valuesOf(command, "-r"), ["/data/user/0/pkg/cache/rootfs/alpine"]);
    expect(command, containsAll(["--kill-on-exit", "--link2symlink", "-0"]));
  });

  test("the working directory is the guest path of the chat workspace, not /", () {
    expect(valuesOf(build().commandFor(cwd, home), "-w"), ["/root/chats/abc-123"]);
  });

  test("the guest's own environment: its PATH and package manager, no HOME "
      "(the shell sets the project's), nothing of the parent's", () {
    final driver = build();

    expect(driver.environment["PATH"], contains("/usr/bin"));
    expect(driver.environment["PATH"], isNot(contains("/system/bin")));
    expect(driver.environment.containsKey("HOME"), isFalse);
    expect(driver.environment["ENV_PACKAGE_MANAGER"], "apk");
    expect(driver.includeParentEnvironment, isFalse);
    expect(driver.projectHome, isTrue);
    expect(driver.guestRoot, "/root");
  });

  test("what the model is told is the distribution, the architecture it is "
      "running as, and how to install anything else", () {
    expect(build().description, contains("Alpine Linux 3.24.1 (x86_64)"));
    expect(build().description, contains("apk"));
    expect(build().description, contains("home directory"));
  });

  test("an unknown architecture is named as the distribution alone, rather "
      "than guessed at", () {
    expect(build(abi: null).description, startsWith("Alpine Linux 3.24.1,"));
  });

  test("guestWorkspacePath computes the guest path from home and cwd", () {
    expect(guestWorkspacePath("/root", home, cwd), "/root/chats/abc-123");
    expect(guestWorkspacePath("/root", home, home), "/root");
  });
}
