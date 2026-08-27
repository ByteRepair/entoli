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
  const dataDir = "/data/user/0/pkg/app_flutter/agent-chat";
  const skillsBundled = "$dataDir/skills-bundled";
  const userSkills = "$dataDir/skills";
  const home = "$dataDir/projects/default/workspace";
  const cwd = "$home/chats/abc-123";

  ShellDriver build({Proot from = proot, String? abi = "x86_64"}) => prootDriver(
        proot: from,
        rootfs: alpine,
        rootfsDir: "/data/user/0/pkg/cache/rootfs/alpine",
        skillsBundledDir: skillsBundled,
        userSkillsDir: userSkills,
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

  test("the project workspace is bound at /root, not the data dir at its own path",
      () {
    final command = build().commandFor(cwd, home);

    expect(valuesOf(command, "-b"), contains("$home:/root"));
    expect(valuesOf(command, "-b"), isNot(contains("$dataDir:$dataDir")));
  });

  test("skills are bound at clean guest paths", () {
    final command = build().commandFor(cwd, home);

    expect(valuesOf(command, "-b"), contains("$skillsBundled:/opt/skills-bundled"));
    expect(valuesOf(command, "-b"), contains("$userSkills:/opt/skills"));
  });

  test("the guest is given a resolver, since Android keeps no such file", () {
    final command = build().commandFor(cwd, home);

    expect(valuesOf(command, "-b"),
        contains("${proot.resolvConf}:/etc/resolv.conf"));
  });

  test("it runs proot, ends in the guest's shell, and chroots into the rootfs",
      () {
    final command = build().commandFor(cwd, home);

    expect(command.first, proot.binary);
    expect(command.last, "/bin/sh");
    expect(valuesOf(command, "-r"),
        ["/data/user/0/pkg/cache/rootfs/alpine"]);
  });

  test("the tracees are killed with the tracer, and hard links are survivable",
      () {
    final command = build().commandFor(cwd, home);

    expect(command, contains("--kill-on-exit"));
    expect(command, contains("--link2symlink"));
    expect(command, contains("-0"));
  });

  test("the working directory is the guest path of the chat workspace, not /", () {
    final command = build().commandFor(cwd, home);

    final w = valuesOf(command, "-w");
    expect(w, isNotEmpty);
    expect(w.first, isNot(contains(".")));
    expect(w.first, startsWith("/root"));
    expect(w.first, contains("chats/abc-123"));
  });

  test("the guest's own PATH, not the host's, and no HOME", () {
    final driver = build();

    expect(driver.environment["PATH"], contains("/usr/bin"));
    expect(driver.environment["PATH"], isNot(contains("/system/bin")));
    expect(driver.environment.containsKey("HOME"), isFalse);
  });

  test("a guest's HOME is the project's workspace, so the shell sets it", () {
    expect(build().projectHome, isTrue);
  });

  test("the guest root is /root", () {
    expect(build().guestRoot, "/root");
  });

  test("host-to-guest path mappings include skills", () {
    final mappings = build().hostToGuestPaths;
    expect(mappings[skillsBundled], "/opt/skills-bundled");
    expect(mappings[userSkills], "/opt/skills");
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
