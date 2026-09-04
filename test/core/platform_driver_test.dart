import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/platform/io/platform.dart"
    show platformByteRepairBinDir, platformDriver, platformSetupComplete;
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/models.dart" show CompletionKind;
import "package:agent_chat/domain/shell.dart";

/// What a turn runs under on the machine itself, where the tools a built-in
/// project's setup fetched have to reach its commands and no one else's. The
/// driver is asked per command, so what is pinned here is the resolution,
/// not a shell process.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory second;
  late AppConfig config;
  late AppConfig unmarked;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp("platform-driver-test");
    second = await Directory.systemTemp.createTemp("platform-driver-test-2");
    config = AppConfig.forDirectory(temp.path, fileSystemIo);
    unmarked = AppConfig.forDirectory(second.path, fileSystemIo);
  });

  tearDown(() async {
    for (final dir in [temp, second]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  const binDir = "/cache/agent-chat/byte-repair/bin";

  ShellDriver? driverOf({String? project, String? bin = binDir}) =>
      platformDriver(
        defaultSkillsBundledDir: config.bundledSkillsDir(),
        defaultUserSkillsDir: config.promptsDir(CompletionKind.skill),
        rootfsId: null,
        project: project,
        config: config,
        byteRepairBinDir: bin,
      );

  test("an isolated project's turns find the fetched tools, on the machine "
      "itself", () {
    final path = driverOf(project: "byte-repair")!.environment["PATH"];
    // Ahead of the machine's own directories, so a fetched tool shadows a
    // system one rather than the other way round.
    expect(path, startsWith("$binDir:"));
  });

  test("no other project's turns see the bin directory", () {
    expect(driverOf(project: null)?.environment["PATH"], isNull);
    expect(driverOf(project: "some-project")?.environment["PATH"], isNull);
  });

  test("no bin directory, no injection", () {
    expect(driverOf(bin: null, project: "byte-repair")?.environment["PATH"],
        isNull);
    expect(driverOf(bin: null, project: null)?.environment["PATH"], isNull);
  });

  test("the bin directory is composed from the cache directory", () {
    expect(platformByteRepairBinDir("/cache/root"),
        "/cache/root/byte-repair/bin");
  });

  test("setup reads as done only where the marker names a binary that is "
      "there, since the cache can be cleared between setups", () {
    final project = ByteRepairProject().dir;
    final real = platformByteRepairBinDir(temp.path);
    // No marker: gated whatever else is true.
    expect(platformSetupComplete(config, project, byteRepairBinDir: real),
        isFalse);
    // Marker without the binary: the gate stays up, honestly.
    File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true)
      ..writeAsStringSync("done");
    expect(platformSetupComplete(config, project, byteRepairBinDir: real),
        isFalse);
    // Both: through.
    Directory(real!).createSync(recursive: true);
    File(p.join(real, "esbmc")).writeAsStringSync("");
    expect(platformSetupComplete(config, project, byteRepairBinDir: real),
        isTrue);
    // The binary alone is nothing without the marker.
    expect(platformSetupComplete(unmarked, project, byteRepairBinDir: real),
        isFalse);
  });
}