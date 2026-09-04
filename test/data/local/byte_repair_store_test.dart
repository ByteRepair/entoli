import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/byte_repair_store.dart";
import "package:agent_chat/data/local/file_byte_repair_store.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/shell.dart";

/// What the setup contract is: where the script installs is the store's to
/// say, and the script answers to what it is told — never to what it can
/// probe. The script is exercised as a real process, over a PATH the test
/// lays down itself, so a run reads the same on a machine with make, gh and
/// esbmc already on it as on one with none of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late Directory stubs;
  late AppConfig config;
  late String scriptPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp("byte-repair-test");
    stubs = Directory(p.join(temp.path, "stubs"))..createSync();
    config = AppConfig.forDirectory(temp.path, fileSystemIo);
    final body = await File(p.join(Directory.current.path, "assets",
            "scripts", "byte-repair-setup.sh"))
        .readAsString();
    scriptPath = p.join(temp.path, "setup.sh");
    File(scriptPath).writeAsStringSync(body);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
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

  Future<ProcessResult> runScript(Map<String, String> vars) {
    final bin = p.join(temp.path, "bin");
    Directory(bin).createSync();
    return Process.run("/bin/sh", [scriptPath], environment: {
      "PATH": stubs.path,
      ...vars,
    });
  }

  /// An esbmc the script can find, so the 240 MB download is never reached —
  /// and a marker the version print reads, since what the tail runs is the
  /// found binary's own business.
  Future<void> stubEsbmcOnPath() async {
    await stubTool("esbmc", 'echo "esbmc version 99.0 stub"');
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

    final result = await runScript({"ENV_INSTALL_DIR": p.join(temp.path, "bin")});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains("esbmc version 99.0 stub"));
  });

  test("a missing tool with no package manager provided is skipped, and the "
      "run carries on", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();
    // make and gh are absent and nothing was declared to install them with:
    // a note each, and no abort — the host's package manager is not ours to
    // reach for, and a missing make is the versions list's honest row.
    final result = await runScript({"ENV_INSTALL_DIR": p.join(temp.path, "bin")});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stderr, contains("No package manager was provided; skipping: make"));
    expect(result.stderr, contains("No package manager was provided; skipping: gh"));
  });

  test("the guest's package manager installs under the distribution's own "
      "package names", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();
    final apkLog = File(p.join(temp.path, "apk.log"))..createSync();
    await stubTool("apk", 'echo "\$*" >> "${apkLog.path}"');

    final result = await runScript({
      "ENV_INSTALL_DIR": p.join(temp.path, "bin"),
      "ENV_PACKAGE_MANAGER": "apk",
    });

    expect(result.exitCode, 0, reason: result.stderr);
    final calls = apkLog.readAsStringSync();
    // gh is github-cli on apk, and make is make; the script settles the
    // mapping, not the call site.
    expect(calls, contains("add --no-cache make"));
    expect(calls, contains("add --no-cache github-cli"));
  });

  test("a package manager the script does not know is a failure, not a skip",
      () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubEsbmcOnPath();

    final result = await runScript({
      "ENV_INSTALL_DIR": p.join(temp.path, "bin"),
      "ENV_PACKAGE_MANAGER": "nix",
    });

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("Unknown package manager: nix"));
  });

  test("the ESBMC fetch lands the binary where ENV_INSTALL_DIR names", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubReal("find");
    await stubReal("head");
    await stubReal("mv");
    await stubReal("rm");
    await stubReal("chmod");
    // No package manager, so make and gh are skipped; the esbmc download is
    // what this run is for. The stub wget leaves a file where the script
    // told it to, and the stub unzip copies a prepared binary into the
    // release/bin layout a current release ships — through dart:io, since
    // the stubs are the whole of the PATH and `cp` is not among them.
    final fakeEsbmc = File(p.join(temp.path, "esbmc-fake"))
      ..writeAsStringSync('#!/bin/sh\necho "esbmc version 8.5 stub"\n');
    await Process.run("chmod", ["+x", fakeEsbmc.path]);
    await stubTool("wget", 'echo zip > "\$3"');
    await stubTool("unzip",
        'mkdir -p /tmp/_esbmc_extract/release/bin && '
        'cp "${fakeEsbmc.path}" /tmp/_esbmc_extract/release/bin/esbmc'
        .replaceFirst("cp ", "/bin/cp "));

    final bin = p.join(temp.path, "bin");
    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    final installed = File(p.join(bin, "esbmc"));
    expect(installed.existsSync(), isTrue);
    expect(installed.statSync().modeString(), contains("x"));
    expect(installed.readAsStringSync(), contains("8.5 stub"));
    // The scratch the run made is gone with it.
    expect(File("/tmp/_esbmc.zip").existsSync(), isFalse);
  });

  test("the store passes its install dir as ENV_INSTALL_DIR", () async {
    final bin = p.join(temp.path, "bin");
    final s = FileByteRepairStore(
      config: config,
      project: ByteRepairProject().dir,
      workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
      installDir: bin,
    );
    // The env contract is visible through the shell start, not the script;
    // a fake shell is the witness.
    String? seen;
    final shell = _RecordingShell((command, environment) {
      seen = environment["ENV_INSTALL_DIR"];
      return null;
    });
    await s.install(shell);
    expect(seen, bin);
  });

  test("the guest install dir is the rootfs's own /usr/local/bin", () {
    expect(guestEsbmcInstallDir, "/usr/local/bin");
  });
}

class _RecordingShell extends Shell {
  _RecordingShell(this.onStart);

  final String? Function(String command, Map<String, String> environment)
      onStart;

  @override
  String get platformDescription => "test";

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool sharedHome = true,
      bool oneShot = false,
      bool restart = false,
      String? project}) {
    final override = onStart(command, environment ?? const {});
    if (override != null) return _Failed(override);
    return _Ok();
  }
}

class _Failed implements ShellRun {
  _Failed(this.message);

  final String message;

  @override
  Future<ShellResult> get result async => ShellResult.failed(message);

  @override
  Future<void> kill() async {}
}

class _Ok implements ShellRun {
  @override
  Future<ShellResult> get result async =>
      const ShellResult(returnCode: 0, output: "");

  @override
  Future<void> kill() async {}
}