import "dart:io";

import "package:flutter/foundation.dart"
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/byte_repair_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/rootfs.dart" show alpine;
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
  /// the POSIX base (mkdir, find, chmod, mv, rm, head, uname, dirname) every
  /// machine this suite can run on has, whatever else it is missing.
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

  /// The POSIX base every fetch-path run needs, then the fetch itself: wget
  /// leaves a zip where `-O` told it to — logging the URL, its last argument,
  /// into the file answered — and unzip copies the staged [body] as the
  /// [binary] it lands under `-d`, [companion] riding beside it where a
  /// release ships one, in the [layout] the release's archive holds. Through
  /// /bin/cp, the stubs being the whole of the PATH and `cp` not among them;
  /// `uname` answers [os] for `-s` and [arch] for `-m`, Linux on x86_64
  /// unless told otherwise, so a run reads the same on every host — a mac's
  /// own answer is a refusal. Answers the log.
  Future<File> stubEsbmcFetch(
    String layout,
    String body, {
    String binary = "esbmc",
    String? companion,
    String os = "Linux",
    String arch = "x86_64",
  }) async {
    final log = File(p.join(config.dataDir, "wget.log"))..createSync();
    await stubTool("uname",
        'if [ "\$1" = "-s" ]; then echo "$os"; else echo "$arch"; fi');
    for (final name in [
      "mkdir", "mktemp", "find", "head", "mv", "rm", "chmod", "dirname"
    ]) {
      await stubReal(name);
    }
    await stubTool("wget", r'''
while [ $# -gt 0 ]; do
  case "$1" in -O) out="$2"; shift 2; continue ;; esac
  url="$1"; shift
done
echo zip > "$out"
echo "$url" >> ''' '"${log.path}"');
    final staged = p.join(config.dataDir, "esbmc-staged");
    final file = File(staged)..writeAsStringSync("#!/bin/sh\n$body\n");
    await Process.run("chmod", ["+x", file.path]);
    await stubTool("unzip", [
      r'while [ $# -gt 0 ]; do case "$1" in -d) d="$2"; shift ;; esac; shift; done',
      'mkdir -p "\$d/$layout"',
      '/bin/cp "$staged" "\$d/$layout/$binary"',
      if (companion != null) ': > "\$d/$layout/$companion"',
    ].join(" && ").replaceFirst("done && ", "done; "));
    return log;
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
    await stubReal("cp");
    await stubReal("chmod");
    await stubEsbmcOnPath();
    // A package manager that must not be called: nothing is missing.
    await stubTool("apk", 'echo "apk must not run" >&2; exit 1');
    await stubTool("wget", 'echo "wget must not run" >&2; exit 1');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains("esbmc version 99.0 stub"));
    // The machine's own copy is still what the gate asks after and the
    // turns find, so it lands in the bin directory whatever arm of the
    // fetch brought it: a run that fetched nothing reads the same to the
    // gate as one that did.
    final installed = File(p.join(bin, "esbmc"));
    expect(installed.existsSync(), isTrue);
    expect(installed.readAsStringSync(), contains("99.0 stub"));
  });

  test("missing tools with no package manager provided are skipped in one "
      "note, and the run carries on", () async {
    await stubReal("mkdir");
    await stubReal("uname");
    await stubReal("cp");
    await stubReal("chmod");
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
    await stubReal("cp");
    await stubReal("chmod");
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

  test("apk installs only what is missing", () async {
    await stubReal("mkdir");
    await stubReal("cp");
    await stubReal("chmod");
    await stubEsbmcOnPath();
    await stubTool("gh", "echo gh");
    final apkLog = File(p.join(config.dataDir, "apk.log"))..createSync();
    await stubTool("apk", 'echo "\$*" >> "${apkLog.path}"');

    final result = await runScript({
      "ENV_INSTALL_DIR": bin,
      "ENV_PACKAGE_MANAGER": "apk",
    });

    expect(result.exitCode, 0, reason: result.stderr);
    // No index refresh or whole-system upgrade, and gh is left alone.
    expect(apkLog.readAsLinesSync(), ["add --no-cache make"]);
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
    expect(Directory(bin).listSync().map((e) => p.basename(e.path)),
        isNot(contains(startsWith(".esbmc-download."))));
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

  /// One fetch run at a platform the script is told it is on: [fetchedFrom]
  /// stubs with [os]/[arch] and the store's env mirrored on it — the
  /// destination, the [binary] the release ships, [companion] beside it —
  /// runs the script, and answers the URL the wget stub was aimed at.
  Future<String> fetchedFrom(String os, String arch, String binary,
      {String? companion}) async {
    final log = await stubEsbmcFetch("bin",
        'echo "esbmc version 8.5 stub"',
        binary: binary,
        companion: companion,
        os: os,
        arch: arch);
    final result = await runScript({
      "ENV_INSTALL_DIR": bin,
      "ENV_ESBMC_BINARY": binary,
    });
    expect(result.exitCode, 0, reason: result.stderr);
    return log.readAsStringSync();
  }

  test("macOS without brew refuses rather than fetch a release that cannot "
      "start there", () async {
    final log = await stubEsbmcFetch("bin", 'echo "esbmc version 8.5 stub"',
        os: "Darwin", arch: "arm64");

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("needs Homebrew's libraries"));
    expect(log.readAsStringSync(), isEmpty);
  });

  test("a Linux arch with no release refuses before downloading", () async {
    final log = await stubEsbmcFetch("bin", 'echo "esbmc version 8.5 stub"',
        os: "Linux", arch: "armv7l");

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("no Linux release for armv7l"));
    expect(log.readAsStringSync(), isEmpty);
  });

  test("a failed download says so, and leaves no scratch", () async {
    await stubEsbmcFetch("bin", 'echo "esbmc version 8.5 stub"');
    await stubTool("wget", "exit 4");

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("could not download https://github.com/"));
    expect(Directory(bin).listSync(), isEmpty);
  });

  test("a scratch a killed run left is swept, never read", () async {
    // An older release's binary in an older run's extract, where a fixed
    // path would have had the next run's find pick it.
    final stale = Directory(p.join(bin, ".esbmc-download.old", "x", "bin"))
      ..createSync(recursive: true);
    File(p.join(stale.path, "esbmc")).writeAsStringSync("#!/bin/sh\necho stale\n");
    await stubEsbmcFetch("release/bin", 'echo "esbmc version 8.6 stub"');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains("8.6 stub"));
    expect(Directory(p.join(bin, ".esbmc-download.old")).existsSync(), isFalse);
  });

  test("Linux splits the release by the arch it runs on", () async {
    expect(await fetchedFrom("Linux", "aarch64", "esbmc"),
        contains("esbmc-linux-armv8.zip"));
    expect(await fetchedFrom("Linux", "x86_64", "esbmc"),
        contains("esbmc-linux.zip"));
  });

  test("Windows' release is the windows zip, installed with its extension",
      () async {
    expect(
        await fetchedFrom("MINGW64_NT-10.0-19045", "x86_64", "esbmc.exe"),
        contains("esbmc-windows.zip"));
    expect(File(p.join(bin, "esbmc.exe")).existsSync(), isTrue);
  });

  test("what loads the binary rides with it out of the archive", () async {
    // The windows release's shape: libz3.dll beside esbmc.exe — an install
    // that moved the binary alone would be a machine with no loader answer
    // to where its z3 is.
    await fetchedFrom("MINGW64_NT-10.0-19045", "x86_64", "esbmc.exe",
        companion: "libz3.dll");
    expect(File(p.join(bin, "esbmc.exe")).existsSync(), isTrue);
    expect(File(p.join(bin, "libz3.dll")).existsSync(), isTrue);
  });

  test("a platform the releases have no zip for refuses", () async {
    await stubReal("mkdir");
    await stubTool("uname", 'echo "FreeBSD"');

    final result = await runScript({"ENV_INSTALL_DIR": bin});

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("unsupported platform for ESBMC: FreeBSD"));
  });

  group("Homebrew", () {
    /// A brew that installs into [prefix] what the script links to, logging
    /// each install's arguments; `--prefix` answers [prefix]. The tools it
    /// lands answer `--version`, so the tail's check runs them.
    Future<({String brew, File log, String prefix})> stubBrew() async {
      final prefix = p.join(config.dataDir, "homebrew");
      final log = File(p.join(config.dataDir, "brew.log"))..createSync();
      await stubTool("brew", """
if [ "\$1" = "--prefix" ]; then echo "$prefix"; exit 0; fi
shift
echo "env \$HOMEBREW_NO_INSTALL_UPGRADE \$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" > "${log.path}.env"
echo "install \$*" >> "${log.path}"
for f in "\$@"; do
  case "\$f" in
    make) d="$prefix/opt/make/libexec/gnubin" ;;
    *)    d="$prefix/bin" ;;
  esac
  /bin/mkdir -p "\$d"
  printf '#!/bin/sh\\necho "%s from brew"\\n' "\$f" > "\$d/\$f"
  /bin/chmod +x "\$d/\$f"
done""");
      for (final name in ["mkdir", "rm", "ln"]) {
        await stubReal(name);
      }
      return (brew: p.join(stubs.path, "brew"), log: log, prefix: prefix);
    }

    test("no brew is a refusal naming Homebrew's install command, before "
        "anything is fetched", () async {
      await stubReal("mkdir");
      await stubTool("wget", 'echo "wget must not run" >&2; exit 1');

      final result = await runScript(
          {"ENV_INSTALL_DIR": bin, "ENV_PACKAGE_MANAGER": "brew"});

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains("Homebrew is not installed"));
      expect(result.stderr, contains(homebrewInstallCommand.replaceAll(r"\$", r"$")));
      expect(result.stderr, isNot(contains("wget must not run")));
    });

    test("what is missing is installed with brew and linked into the bin "
        "directory, make under its own name", () async {
      final brew = await stubBrew();

      final result = await runScript({
        "ENV_INSTALL_DIR": bin,
        "ENV_PACKAGE_MANAGER": "brew",
        "ENV_BREW": brew.brew,
      });

      expect(result.exitCode, 0, reason: result.stderr);
      // make and gh in one call, then the formula, never the release zip.
      expect(brew.log.readAsLinesSync(), ["install make gh", "install esbmc"]);
      expect(Link(p.join(bin, "esbmc")).targetSync(),
          p.join(brew.prefix, "bin", "esbmc"));
      expect(Link(p.join(bin, "gh")).targetSync(),
          p.join(brew.prefix, "bin", "gh"));
      expect(Link(p.join(bin, "make")).targetSync(),
          p.join(brew.prefix, "opt", "make", "libexec", "gnubin", "make"));
      expect(result.stdout, contains("esbmc from brew"));
      // Nothing the user already has is upgraded on the way.
      expect(File("${brew.log.path}.env").readAsStringSync().trim(), "env 1 1");
    });

    test("a link that does not run is setup's failure, not a success",
        () async {
      final brew = await stubBrew();
      await stubTool("make", "echo make");
      // A brew whose gh install claims success and lands nothing.
      await stubTool("brew", """
if [ "\$1" = "--prefix" ]; then echo "${brew.prefix}"; fi
exit 0""");

      final result = await runScript({
        "ENV_INSTALL_DIR": bin,
        "ENV_PACKAGE_MANAGER": "brew",
        "ENV_BREW": brew.brew,
      });

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains("gh was installed, but"));
    });

    test("an esbmc already linked and running is kept, and a stale one is "
        "replaced", () async {
      final brew = await stubBrew();
      await stubTool("make", "echo make");
      await stubTool("gh", "echo gh");
      Directory(bin).createSync(recursive: true);
      // A link to a keg an upgrade took away: present, unstartable.
      Link(p.join(bin, "esbmc")).createSync(p.join(brew.prefix, "gone"));

      final vars = {
        "ENV_INSTALL_DIR": bin,
        "ENV_PACKAGE_MANAGER": "brew",
        "ENV_BREW": brew.brew,
        "PATH": "$bin:${stubs.path}",
      };
      var result = await runScript(vars);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(brew.log.readAsLinesSync(), ["install esbmc"]);

      result = await runScript(vars);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(brew.log.readAsLinesSync(), ["install esbmc"]);
    });
  });

  test("the store passes its install dir and the binary's name, install only",
      () async {
    final s = ByteRepairStore(
      config: config,
      project: ByteRepairProject().dir,
      workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
      installDir: bin,
      installTimeout: const Duration(minutes: 30),
    );
    final shell = FakeShell((_) => const ShellResult(returnCode: 0, output: ""));
    await s.install(shell);

    expect(shell.environments.single?["ENV_INSTALL_DIR"], bin);
    // The name is this platform's `esbmcFileName` — the one encoding of the
    // name, what the script's find and the gate's check are both told.
    expect(shell.environments.single?["ENV_ESBMC_BINARY"],
        Platform.isWindows ? "esbmc.exe" : "esbmc");
    expect(shell.timeouts.single, const Duration(minutes: 30));
    // The version queries that follow a setup carry no install environment.
    await s.runToolVersion(shell, "esbmc");
    expect(shell.environments.last, isNull);
  });

  /// The env gate asked per platform, the way the store answers it for the
  /// settings page: the target overridden for the one test — a test body is
  /// the host's platform otherwise — and undone inside it, flutter_test
  /// checking the override before a tear-down runs.
  void withTarget(TargetPlatform platform, void Function() body) {
    debugDefaultTargetPlatformOverride = platform;
    try {
      body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  ByteRepairStore storeAt(String? installDir) => ByteRepairStore(
        config: config,
        project: ByteRepairProject().dir,
        workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
        installDir: installDir,
      );

  test('iOS: the "Host" env is gated, an installed Alpine is not', () async {
    withTarget(TargetPlatform.iOS, () {
      expect(
          storeAt(guestEsbmcInstallDir).capabilityBanner,
          'Byte Repair does not work when using the "Host" terminal '
          "environment on this platform, which has no shell to run "
          "anything in. Please install a Linux from the Terminal "
          "settings.");
    });
    // Picked is installed on iOS: the picker offers only what is on disk,
    // and a delete unpicks what it takes away.
    await AppSettings(rootfsId: alpine.id).save(config);
    withTarget(TargetPlatform.iOS, () {
      expect(storeAt(guestEsbmcInstallDir).capabilityBanner, isNull);
    });
  });

  test("the Android arm is unchanged, and the desktops answer by the "
      "destination they were built with", () {
    withTarget(TargetPlatform.android, () {
      expect(storeAt(guestEsbmcInstallDir).capabilityBanner,
          contains('"Host" terminal environment on this device'));
    });
    withTarget(TargetPlatform.macOS, () {
      expect(storeAt(bin).capabilityBanner, isNull);
      expect(storeAt(null).capabilityBanner,
          contains("nowhere to install the tools it sets up"));
    });
  });

  test("the install environment names the guest's package manager, and only "
      "where the install is a guest's", () async {
    // A host bin — the desktops' destination — declares nothing: their
    // package manager is not the app's to touch, static fetches instead.
    expect(storeAt(bin).installEnvironment(),
        isNot(contains("ENV_PACKAGE_MANAGER")));

    final guest = storeAt(guestEsbmcInstallDir);
    expect(guest.installEnvironment().keys,
        unorderedEquals(["ENV_INSTALL_DIR", "ENV_ESBMC_BINARY"]));
    await AppSettings(rootfsId: alpine.id).save(config);
    expect(guest.installEnvironment(),
        containsPair("ENV_PACKAGE_MANAGER", "apk"));
  });

  group("a mac's Homebrew", () {
    ByteRepairStore macStore(String? installDir, {required bool brew}) {
      final fake = p.join(config.dataDir, "brew");
      if (brew) File(fake).writeAsStringSync("");
      return ByteRepairStore(
        config: config,
        project: ByteRepairProject().dir,
        workspace: config.projectWorkspaceDir(project: ByteRepairProject().dir),
        installDir: installDir,
        brewPaths: [fake],
      );
    }

    test("the host install names brew and where it is", () {
      withTarget(TargetPlatform.macOS, () {
        final env = macStore(bin, brew: true).installEnvironment();
        expect(env, containsPair("ENV_PACKAGE_MANAGER", "brew"));
        expect(env, containsPair("ENV_BREW", p.join(config.dataDir, "brew")));
        expect(macStore(bin, brew: true).setupNotice, contains("Homebrew"));
        expect(macStore(bin, brew: true).prerequisite, isNull);
      });
    });

    test("no Homebrew is the install command to paste, and the run is told "
        "so by ENV_BREW's absence", () {
      withTarget(TargetPlatform.macOS, () {
        final store = macStore(bin, brew: false);
        expect(store.prerequisite?.command, homebrewInstallCommand);
        expect(store.installEnvironment(), isNot(contains("ENV_BREW")));
      });
    });

    test("Linux and Windows say nothing of it", () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        withTarget(platform, () {
          final store = macStore(bin, brew: true);
          expect(store.setupNotice, isNull);
          expect(store.prerequisite, isNull);
          expect(store.installEnvironment(),
              isNot(contains("ENV_PACKAGE_MANAGER")));
        });
      }
    });

    test("a deletion names links, not tools, Homebrew keeping its own", () {
      Directory(bin).createSync(recursive: true);
      withTarget(TargetPlatform.macOS, () {
        expect(macStore(bin, brew: true).environmentDeletion,
            contains("Homebrew keeps what it installed"));
      });
    });
  });

  group("environmentDeletion", () {
    test("nothing set up leaves the dialog the workspace and chats alone", () {
      expect(storeAt(bin).environmentDeletion, isNull);
    });

    test("a host install dir names the tools the setup fetched", () {
      Directory(bin).createSync(recursive: true);
      expect(storeAt(bin).environmentDeletion,
          "the tools the setup fetched into the app's cache directory");
    });

    test("the project's rootfs copy names the rootfs", () {
      Directory(p.join(config.projectDir(project: ByteRepairProject().dir), "rootfs"))
          .createSync(recursive: true);
      expect(
          storeAt(bin).environmentDeletion,
          "the Byte Repair rootfs (the Linux copy and everything "
          "installed into it)");
    });

    test("an unset install dir has nothing to name whatever is in the temp",
        () {
      // The bin directory alone is not the environment: a desktop whose
      // store was built with no destination — macOS — reads the null
      // whatever else sits beside the temp.
      Directory(bin).createSync(recursive: true);
      expect(storeAt(null).environmentDeletion, isNull);
    });

    test("the guest's install dir is no host tree to name", () async {
      // The store the guests build names `/usr/local/bin` — inside the
      // Linux — which on this host is a real directory. The compare
      // against the guest const is what keeps it out of a delete's host
      // reads, and the dialog the workspace-and-chats answer.
      Directory(bin).createSync(recursive: true);
      expect(storeAt(guestEsbmcInstallDir).environmentDeletion, isNull);
    });
  });

  test("the guest's install dir deletes the guest's own state, not the "
      "host's paths", () async {
    final project = ByteRepairProject().dir;
    final store = storeAt(guestEsbmcInstallDir);
    Directory(config.projectWorkspaceDir(project: project))
        .createSync(recursive: true);
    File(p.join(config.projectWorkspaceDir(project: project), "cloned.txt"))
        .writeAsStringSync("hello");
    File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true)
      ..writeAsStringSync("done");

    expect(await store.deleteEnvironment(), isNull);

    expect(Directory(config.projectWorkspaceDir(project: project)).existsSync(),
        isFalse);
    expect(File(config.setupCompleteFile(project: project)).existsSync(),
        isFalse);
    // The host tree the guests build is a path inside the Linux; nothing
    // host-side of the delete follows it.
    expect(Directory("/usr/local/bin").existsSync(), isTrue);
  });

  test("deleteEnvironment takes the trees the setup made, and the marker",
      () async {
    final project = ByteRepairProject().dir;
    final binDir = p.join(config.dataDir, "byte-repair", "bin");
    final store = ByteRepairStore(
      config: config,
      project: project,
      workspace: config.projectWorkspaceDir(project: project),
      installDir: binDir,
    );
    Directory(p.join(config.projectDir(project: project), "rootfs"))
        .createSync(recursive: true);
    Directory(config.projectWorkspaceDir(project: project)).createSync();
    File(p.join(config.projectWorkspaceDir(project: project), "cloned.txt"))
        .writeAsStringSync("hello");
    Directory(binDir).createSync(recursive: true);
    File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true)
      ..writeAsStringSync("done");

    expect(await store.deleteEnvironment(), isNull);

    expect(Directory(p.join(config.projectDir(project: project), "rootfs"))
        .existsSync(), isFalse);
    expect(Directory(config.projectWorkspaceDir(project: project)).existsSync(),
        isFalse);
    // The whole cache directory, `bin` being its last member — the same
    // `p.dirname(installDir)` the real store composes from the cache.
    expect(Directory(p.join(config.dataDir, "byte-repair")).existsSync(),
        isFalse);
    expect(File(config.setupCompleteFile(project: project)).existsSync(),
        isFalse);
  });
}