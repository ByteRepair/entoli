import "dart:io";

import "package:flutter/foundation.dart"
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/platform/host.dart"
    show byteRepairBinDir, platformDriver, setupComplete;
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/models.dart" show CompletionKind;
import "package:agent_chat/domain/shell.dart";

import "../fakes.dart";
import "../harness.dart";

/// What a turn runs under on the machine itself, where the tools a built-in
/// project's setup fetched have to reach its commands and no one else's. The
/// driver is asked per command, so what is pinned here is the resolution,
/// not a shell process.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppConfig config;
  late AppConfig unmarked;

  setUp(() {
    config = tempConfig();
    unmarked = tempConfig();
  });

  const binDir = "/cache/entoli/byte-repair/bin";

  ShellDriver? driverOf({String? project, String? bin = binDir}) =>
      platformDriver(
        defaultSkillsBundledDir: config.bundledSkillsDir(),
        defaultUserSkillsDir: config.promptsDir(CompletionKind.skill),
        rootfsId: null,
        project: project,
        config: config,
        byteRepairBinDir: bin,
      );

  test(
    "PATH injection happens iff the project is isolated and a bin exists",
    () {
      final path = driverOf(project: "byte-repair")!.environment["PATH"];
      // Ahead of the machine's own directories, so a fetched tool shadows a
      // system one rather than the other way round.
      expect(path, startsWith("$binDir:"));

      // No other project's turns see the bin directory.
      expect(driverOf(project: null)?.environment["PATH"], isNull);
      expect(driverOf(project: "some-project")?.environment["PATH"], isNull);

      // And no bin directory, no injection.
      expect(
        driverOf(bin: null, project: "byte-repair")?.environment["PATH"],
        isNull,
      );
      expect(driverOf(bin: null, project: null)?.environment["PATH"], isNull);
    },
  );

  test(
    "the bin directory goes ahead of the login PATH, not the inherited one",
    () {
      final driver = platformDriver(
        defaultSkillsBundledDir: config.bundledSkillsDir(),
        defaultUserSkillsDir: config.promptsDir(CompletionKind.skill),
        project: "byte-repair",
        config: config,
        byteRepairBinDir: binDir,
        loginPath: "/home/u/.local/bin:/usr/bin",
      );
      expect(
        driver!.environment["PATH"],
        "$binDir:/home/u/.local/bin:/usr/bin",
      );
    },
  );

  test("the guest binds a project's skill directories only where they exist "
      "on disk", () {
    final project = ByteRepairProject().dir;
    const proot = Proot(
      binary: "/data/app/pkg/lib/arm/libproot.so",
      loader: "/data/app/pkg/lib/arm/libproot-loader.so",
      tmpDir: "/cache/entoli/tools/tmp",
      resolvConf: "/cache/entoli/tools/etc/resolv.conf",
    );
    final home = config.projectWorkspaceDir(project: project);
    final cwd = p.join(home, "chats", "abc-123");
    // The value of the argument after [flag], as in `proot_test.dart`.
    List<String> bindsOf(ShellDriver driver) {
      final command = driver.commandFor(cwd, home);
      return [
        for (var i = 0; i < command.length - 1; i++)
          if (command[i] == "-b") command[i + 1],
      ];
    }

    // Neither directory is written yet: byte-repair ships agents alone, and
    // a turn has not run to make the rest. proot refuses a binding to a
    // path that is not there, so the driver binds none of byte-repair's.
    ShellDriver? guest() => platformDriver(
      defaultSkillsBundledDir: config.bundledSkillsDir(),
      defaultUserSkillsDir: config.promptsDir(CompletionKind.skill),
      projectSkillsBundledDir: config.bundledSkillsDir(project: project),
      projectUserSkillsDir: config.promptsDir(
        CompletionKind.skill,
        project: project,
      ),
      proot: proot,
      store: FakeRootfsStore(installed: {"alpine"}),
      rootfsId: "alpine",
      abi: "x86_64",
      project: project,
      config: config,
    );

    expect(
      guest()!.hostToGuestPaths.keys.any((k) => k.contains("byte-repair")),
      isFalse,
    );

    // The directories existing is the only difference: the setup or a first
    // turn made them, and the next command binds and maps them.
    Directory(
      config.bundledSkillsDir(project: project),
    ).createSync(recursive: true);
    Directory(
      config.promptsDir(CompletionKind.skill, project: project),
    ).createSync(recursive: true);

    final driver = guest()!;
    final mapped = driver.hostToGuestPaths;
    expect(
      mapped[config.bundledSkillsDir(project: project)],
      "/opt/skills-bundled-project",
    );
    expect(
      mapped[config.promptsDir(CompletionKind.skill, project: project)],
      "/opt/skills-project",
    );
    expect(
      bindsOf(driver).where((b) => b.contains("/skills")),
      containsAll([
        "${config.bundledSkillsDir(project: project)}:"
            "/opt/skills-bundled-project",
        "${config.promptsDir(CompletionKind.skill, project: project)}:"
            "/opt/skills-project",
      ]),
    );
  });

  test("the bin directory is composed from the cache directory, and the "
      "store's install dir is the same answer", () {
    expect(byteRepairBinDir("/cache/root"), "/cache/root/byte-repair/bin");
  });

  test("setup reads as done only where the marker names a binary that is "
      "there, since the cache can be cleared between setups", () {
    // The env clause the guests' answer carries is skipped here: this host
    // is a desktop's, and the test's target is named so the check reads so
    // — the flutter-test target default would have it guest-gate.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final project = ByteRepairProject().dir;
      final real = byteRepairBinDir(config.dataDir);
      // No marker: gated whatever else is true.
      expect(setupComplete(config, project, real), isFalse);
      // Marker without the binary: the gate stays up, honestly.
      File(config.setupCompleteFile(project: project))
        ..createSync(recursive: true)
        ..writeAsStringSync("done");
      expect(setupComplete(config, project, real), isFalse);
      // Both: through.
      Directory(real!).createSync(recursive: true);
      File(p.join(real, "esbmc")).writeAsStringSync("");
      expect(setupComplete(config, project, real), isTrue);
      // The binary alone is nothing without the marker.
      expect(setupComplete(unmarked, project, real), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test("a guest env with no rootfs picked gates the marker alone too", () {
    // The env half of the same gate, at the seam it lives on: Android's
    // and iOS's "Host" env cannot run a setup, so a marker left from an
    // earlier one under a rootfs is not "done".
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final project = ByteRepairProject().dir;
      File(config.setupCompleteFile(project: project))
        ..createSync(recursive: true)
        ..writeAsStringSync("done");
      expect(setupComplete(config, project, null), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
