import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/domain/shell.dart";

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync("agent_chat_shell_"));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  Future<dynamic> run(String command,
          {Duration timeout = const Duration(seconds: 10),
          Map<String, String> env = const {}}) =>
      LocalShell(environment: () => env)
          .start(command, cwd: workspace.path, timeout: timeout)
          .result;

  test("reports what the command printed and the code it exited with", () async {
    final result = await run("echo hello; exit 3");

    expect(result.returnCode, 3);
    expect(result.output, "hello\n");
    expect(result.exceptionInfo, isNull);
  });

  test("errors land in the output, in the order they happened", () async {
    final result = await run("echo first; echo second >&2; echo third");

    expect(result.returnCode, 0);
    expect(result.output, "first\nsecond\nthird\n");
  });

  test("runs in the workspace, so a relative path is one of its own", () async {
    File(p.join(workspace.path, "note.txt")).writeAsStringSync("here");
    final result = await run("cat note.txt");

    expect(result.output, "here");
  });

  test("a variable from settings reaches the command", () async {
    final result = await run(r'echo "$MY_TOKEN"', env: {"MY_TOKEN": "abc123"});

    expect(result.output.trim(), "abc123");
  });

  test("nothing waits for a keypress", () async {
    final result = await run(r'echo "$PAGER $TERM"');

    expect(result.output.trim(), "cat dumb");
  });

  test("a command that overruns is killed and says so", () async {
    final result = await run("echo starting; sleep 30",
        timeout: const Duration(milliseconds: 300));

    expect(result.returnCode, -1);
    expect(result.output, "starting\n");
    expect(result.exceptionInfo, contains("timed out"));
  });

  test("what the command spawned is killed with it", () async {
    final marker = p.join(workspace.path, "survivor");
    final result = await run(
      "(sleep 2; touch $marker) & echo started; sleep 30",
      timeout: const Duration(milliseconds: 300),
    );

    expect(result.exceptionInfo, contains("timed out"));
    // The background child outlives its shell unless the whole group goes.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(File(marker).existsSync(), isFalse);
  });

  test("a child that escaped the group does not hold the result open", () async {
    final result = await run(
      "setsid sleep 5 & echo started; sleep 5",
      timeout: const Duration(milliseconds: 300),
    ).timeout(const Duration(seconds: 4));

    expect(result.exceptionInfo, contains("timed out"));
    expect(result.output, "started\n");
  });

  test("nor does a daemon a command that exited left behind", () async {
    final result =
        await run("setsid sleep 5 & echo started").timeout(const Duration(seconds: 4));

    expect(result.returnCode, 0);
    expect(result.output, "started\n");
  });

  test("killing it early reports the interruption rather than an exit code", () async {
    final run = LocalShell()
        .start("sleep 30", cwd: workspace.path, timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await run.kill();

    final result = await run.result;
    expect(result.returnCode, -1);
    expect(result.exceptionInfo, contains("interrupted"));
  });

  test("a command that cannot start is a failed result, not a thrown one", () async {
    final result = await run("definitely-not-a-command");

    expect(result.returnCode, isNot(0));
    expect(result.output, contains("not found"));
  });

  test("off a guest, home is left as the machine's own", () async {
    final result = await run(r'echo "$HOME"');

    expect(result.output.trim(), Platform.environment["HOME"]);
  });

  test("what the model is told names the shell, and the tools beside it", () {
    expect(LocalShell(shell: () => "/system/bin/sh").platformDescription,
        contains("/system/bin/sh"));
    expect(
        LocalShell(
          shell: () => "/system/bin/sh",
          tools: const Toolset(environment: {}, names: "git"),
        ).platformDescription,
        contains("git"));
  });

  group("inside a sandbox", () {
    /// What proot is on a device, faked with something every machine running
    /// these tests has: a prefix that really runs, ending in a shell.
    Sandbox guest({Map<String, String> environment = const {}}) => Sandbox(
          command: ["/usr/bin/env", "IN_GUEST=yes", "/bin/sh"],
          environment: environment,
          description: "Alpine Linux 3.24.1 (x86_64), in which apk installs things",
        );

    Future<dynamic> inGuest(
      String command, {
      Sandbox? sandbox,
      Toolset? tools,
      Map<String, String> settings = const {},
    }) =>
        LocalShell(
          environment: () => settings,
          tools: tools,
          sandbox: () => sandbox ?? guest(),
        ).start(command, cwd: workspace.path, timeout: const Duration(seconds: 10)).result;

    test("the command is run by what the sandbox names, not by the machine's shell",
        () async {
      final result = await inGuest(r'echo "$IN_GUEST"');

      expect(result.output.trim(), "yes");
    });

    test("the guest's environment stands in place of the bundled tools', which "
        "name directories that are not in there", () async {
      final result = await inGuest(
        r'echo "[$GIT_EXEC_PATH][$IN_ALPINE]"',
        sandbox: guest(environment: {"IN_ALPINE": "1"}),
        tools: const Toolset(
            environment: {"GIT_EXEC_PATH": "/data/tools/libexec"}, names: "git"),
      );

      expect(result.output.trim(), "[][1]");
    });

    test("a variable from settings still wins over the guest's own", () async {
      final result = await inGuest(
        r'echo "$LANG"',
        sandbox: guest(environment: {"LANG": "C.UTF-8"}),
        settings: {"LANG": "en_GB.UTF-8"},
      );

      expect(result.output.trim(), "en_GB.UTF-8");
    });

    test("home is the chat's own workspace, not the guest's /root", () async {
      final result = await inGuest(r'echo "$HOME"');

      expect(result.output.trim(), workspace.path);
    });

    test("a home from settings still wins over the workspace", () async {
      final result = await inGuest(r'echo "$HOME"', settings: {"HOME": "/root"});

      expect(result.output.trim(), "/root");
    });

    test("what the model is told is the guest, not the machine it is on", () {
      final shell = LocalShell(shell: () => "/system/bin/sh", sandbox: guest);

      expect(shell.platformDescription, contains("Alpine Linux 3.24.1"));
      expect(shell.platformDescription, contains("proot"));
      expect(shell.platformDescription, isNot(contains("/system/bin/sh")));
    });

    test("brings its own shell, so a machine that has none can still run commands",
        () {
      expect(LocalShell(shell: () => null, sandbox: guest).canRunCommands, isTrue);
      expect(LocalShell(shell: () => null).canRunCommands, isFalse);
    });
  });

  group("resolving the shell", () {
    String? resolve(String path, Set<String> present) => LocalShell.resolveShell(
        path: path, isExecutable: (candidate) => present.contains(candidate));

    test("takes bash from PATH ahead of any sh", () {
      expect(resolve("/usr/local/bin:/usr/bin", {"/usr/bin/bash", "/usr/local/bin/sh"}),
          "/usr/bin/bash");
    });

    test("takes the first PATH entry that has one", () {
      expect(resolve("/a:/b", {"/a/bash", "/b/bash"}), "/a/bash");
    });

    test("falls back to sh where there is no bash anywhere", () {
      expect(resolve("/usr/bin", {"/usr/bin/sh"}), "/usr/bin/sh");
    });

    test("finds Android's shell, which no PATH of its own names", () {
      expect(resolve("", {"/system/bin/sh"}), "/system/bin/sh");
    });

    test("a machine with nothing to run commands in says so", () {
      expect(resolve("/usr/bin", const {}), isNull);
      expect(LocalShell(shell: () => null).canRunCommands, isFalse);
    });

    test("and a command sent to it anyway fails rather than throwing", () async {
      final result = await LocalShell(shell: () => null)
          .start("echo hi", cwd: workspace.path, timeout: const Duration(seconds: 1))
          .result;

      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("No shell"));
    });
  });
}
