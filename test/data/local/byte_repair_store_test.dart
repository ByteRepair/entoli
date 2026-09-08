import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_byte_repair_store.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/shell.dart" show ShellResult;

import "../../data/builtin/builtin_fakes.dart" show FakeShell;
import "../../harness.dart";

/// What the setup contract is: where the script installs is the store's to
/// say, and the script answers to what it is told — never to what it can
/// probe. The script is exercised as a real process, over a PATH the test
/// lays down itself, so a run reads the same on a machine with make, gh and
/// esbmc already on it as on one with none of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppConfig config;
  late Directory stubs;
  late String scriptPath;
  late String bin;

  setUp(() async {
    config = tempConfig();
    final temp = config.dataDir;
    stubs = Directory(p.join(temp, "stubs"))..createSync();
    final body = await File(p.join(Directory.current.path, "assets",
            "scripts", "byte-repair-setup.sh"))
        .readAsString();
    scriptPath = p.join(temp, "setup.sh");
    File(scriptPath).writeAsStringSync(body);
    bin = p.join(temp, "bin");
  });

  /// A command the script may reach for, replaced by [body]. The stubs are
  /// the whole of the test's PATH, so what the script finds is what the test
  /// put there and nothing the machine happens to have.
  Future<void> stubTool(String name, String body) async {
    final file = File(p.join(stubs.path, name));
    await file.writeAsString("#!/bin/sh\n$body\n");
    await Process.run("chmod", ["+x", file.path]);
  }

  /// A tool the script runs unchanged, resolved off the host's own PATH —
  /// the POSIX base (mkdir, find, chmod, mv, rm, head, uname) every machine
  /// this suite can run on has, whatever else it is missing.
  Future<void> stubReal(String name) =>
      stubTool(name, 'PATH=/usr/bin:/bin exec $name "\$@"');

  Future<ProcessResult> runScript(Map<String, String> vars) =>
      Process.run("/bin/sh", [scriptPath], environment: {
        "PATH": stubs.path,
        ...vars,
      });

  /// An esbmc the script can find, so the 240 MB download is never reached —
  /// and a marker the version print reads, since what the tail runs is the
  /// found binary's own business.
  Future<void> stubEsbmcOnPath() async {
    await stubTool("esbmc", 'echo "esbmc version 99.0 stub"');
  }

  /// The POSIX base every fetch-path run reaches for, then the fetch itself:
  /// wget leaves a zip where the script told it to, and unzip copies [body]
  /// as the binary it lands, in the [layout] a release ships — through
  /// /bin/cp, the stubs being the whole of the PATH and `cp` not among them.
  /// The binary is staged beside the config first, made executable before
  /// the run, since the stubs are the whole of the PATH.
  Future<void> stubEsbmcFetch(String layout, String body) async {
    final staged = p.join(config.dataDir, "esbmc-staged");
    final file = File(staged)..writeAsStringSync("#!/bin/sh\n$body\n");
    await Process.run("chmod", ["+x", file.path]);
    for (final name in ["mkdir", "uname", "find", "head", "mv", "rm", "chmod"]) {
      await stubReal(name);
    }
    await stubTool("wget", 'echo zip > "\$3"');
    await stubTool("unzip",
        'mkdir -p /tmp/_esbmc_extract/$layout && '
        'cp "$staged" /tmp/_esbmc_extract/$layout/esbmc'
        .replaceFirst("cp ", "/bin/cp "));
  }

  test("the script refuses to run without ENV_INSTALL_DIR", () async {
    final result = await runScript(const {});
    expect(result.exitCode, isNot(0));
    expect(
        result.stderr,
        contains("ENV_INSTALL_DIR is not set. The installation directory "
            "must be set explicitly; nothing was installed."));
  });

  test("a tool already on PATH is never re-fetched", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();
    // A package manager that must not be called: nothing is missing.
    await stubTool("apk", 'echo "apk must not run" >&2; exit 1');
    await stubTool("wget", 'echo "wget must not run" >&2; exit 1');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains("esbmc version 99.0 stub"));
  });

  test("missing tools with no package manager provided are skipped in one "
      "note, and the run carries on", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stderr,
        contains("No package manager was provided; skipping: make gh"));
  });

  test("the guest's package manager installs once, under the distribution's "
      "own package names", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();
    final apkLog = File(p.join(config.dataDir, "apk.log"))..createSync();
    await stubTool("apk", 'echo "\$*" >> "${apkLog.path}"');

    final result = await runScript({
      "ENV_INSTALL_DIR": bin,
      "ENV_PACKAGE_MANAGER": "apk",
    });

    expect(result.exitCode, 0, reason: result.stderr);
    // One invocation for both tools — the index re-fetch per call is the
    // cost batching exists to avoid — and gh is github-cli on apk.
    expect(apkLog.readAsStringSync(), contains("add --no-cache make github-cli"));
  });

  test("a package manager the script does not know is a failure, not a skip",
      () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();

    final result = await runScript({
      "ENV_INSTALL_DIR": bin,
      "ENV_PACKAGE_MANAGER": "nix",
    });

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("Unknown package manager: nix"));
  });

  test("the ESBMC fetch lands the binary where ENV_INSTALL_DIR names", () async {
    // No package manager, so make and gh are skipped; the esbmc download is
    // what this run is for, landing in the release/bin layout a current
    // release ships.
    await stubEsbmcFetch("release/bin", 'echo "esbmc version 8.5 stub"');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    final installed = File(p.join(bin, "esbmc"));
    expect(installed.existsSync(), isTrue);
    expect(installed.statSync().modeString(), contains("x"));
    expect(installed.readAsStringSync(), contains("8.5 stub"));
    // The scratch the run made is gone with it.
    expect(File("/tmp/_esbmc.zip").existsSync(), isFalse);
  });

  test("an esbmc on PATH that cannot run is fetched rather than skipped", () async {
    // Found by command -v, dead when run — yet the apk call proves the fetch
    // path was taken, and the runnable staged binary is what it landed.
    await stubTool("esbmc", 'echo "libz3.so: cannot open shared object file" >&2; exit 127');
    final apkLog = File(p.join(config.dataDir, "apk.log"))..createSync();
    await stubTool("apk", 'echo "\$*" >> "${apkLog.path}"');
    await stubEsbmcFetch("bin", 'echo "esbmc version 8.5 stub"');

    final result = await runScript({
      "ENV_INSTALL_DIR": bin,
      "ENV_PACKAGE_MANAGER": "apk",
    });

    expect(result.exitCode, 0, reason: result.stderr);
    final installed = File(p.join(bin, "esbmc"));
    expect(installed.existsSync(), isTrue);
    expect(installed.readAsStringSync(), contains("8.5 stub"));
    expect(apkLog.readAsStringSync(), contains("add --no-cache make github-cli"));
  });

  test("a fetched esbmc that cannot run is setup's failure to report", () async {
    await stubTool("esbmc", 'echo "loader error" >&2; exit 127');
    await stubEsbmcFetch("bin", 'exit 127');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, isNot(0));
    expect(result.stderr,
        contains("cannot be run (see the error above); setup did not succeed"));
  });

  test("the store passes its install dir as ENV_INSTALL_DIR, install only",
      () async {
    final s = FileByteRepairStore(
      config: config,
      project: ByteRepairProject().dir,
      workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
      installDir: bin,
      installTimeout: const Duration(minutes: 30),
    );
    final shell = FakeShell((_) => const ShellResult(returnCode: 0, output: ""));
    await s.install(shell);

    expect(shell.environments.single?["ENV_INSTALL_DIR"], bin);
    expect(shell.timeouts.single, const Duration(minutes: 30));
    // The version queries that follow a setup carry no install environment.
    await s.runToolVersion(shell, "esbmc");
    expect(shell.environments.last, isNull);
  });
}