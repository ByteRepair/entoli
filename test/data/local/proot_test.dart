import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/proot.dart";
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

  Sandbox build({Proot from = proot, String? abi = "x86_64"}) => prootSandbox(
        proot: from,
        rootfs: alpine,
        rootfsDir: "/data/user/0/pkg/cache/rootfs/alpine",
        dataDir: dataDir,
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
    final sandbox = build();

    expect(sandbox.environment["PROOT_LOADER"], proot.loader);
    // Nothing to name, so nothing is said: proot would otherwise be handed an
    // empty path for an architecture that has no 32-bit guests.
    expect(sandbox.environment.containsKey("PROOT_LOADER_32"), isFalse);
  });

  test("a 32-bit loader is named where the architecture has one", () {
    final sandbox = build(
        from: const Proot(
      binary: "/lib/libproot.so",
      loader: "/lib/libproot-loader.so",
      loader32: "/lib/libproot-loader32.so",
      tmpDir: "/tmp",
      resolvConf: "/tmp/resolv.conf",
    ));

    expect(sandbox.environment["PROOT_LOADER_32"], "/lib/libproot-loader32.so");
  });

  test("the data directory is bound at its own path, so every path the app has "
      "handed the model still means what it meant", () {
    final sandbox = build();

    expect(valuesOf(sandbox.command, "-b"), contains("$dataDir:$dataDir"));
  });

  test("the guest is given a resolver, since Android keeps no such file", () {
    final sandbox = build();

    expect(valuesOf(sandbox.command, "-b"),
        contains("${proot.resolvConf}:/etc/resolv.conf"));
  });

  test("it runs proot, ends in the guest's shell, and chroots into the rootfs",
      () {
    final sandbox = build();

    expect(sandbox.command.first, proot.binary);
    expect(sandbox.command.last, "/bin/sh");
    expect(valuesOf(sandbox.command, "-r"),
        ["/data/user/0/pkg/cache/rootfs/alpine"]);
  });

  test("the tracees are killed with the tracer, and hard links are survivable",
      () {
    final sandbox = build();

    expect(sandbox.command, contains("--kill-on-exit"));
    expect(sandbox.command, contains("--link2symlink"));
    expect(sandbox.command, contains("-0"));
  });

  test("the guest's own PATH, not the host's, and no HOME — the chat's "
      "workspace is that, and only the shell knows it", () {
    final sandbox = build();

    expect(sandbox.environment["PATH"], contains("/usr/bin"));
    expect(sandbox.environment["PATH"], isNot(contains("/system/bin")));
    expect(sandbox.environment.containsKey("HOME"), isFalse);
  });

  test("what the model is told is the distribution, the architecture it is "
      "running as, and how to install anything else", () {
    expect(build().description, contains("Alpine Linux 3.24.1 (x86_64)"));
    expect(build().description, contains("apk"));
    expect(build().description, contains("same paths"));
  });

  test("an unknown architecture is named as the distribution alone, rather "
      "than guessed at", () {
    expect(build(abi: null).description, startsWith("Alpine Linux 3.24.1,"));
  });
}
