import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/domain/shell.dart";

List<String> _hostCommand(String _, String _) => const ["/bin/sh"];

void main() {
  /// The project workspace and, inside it, the chat's own — what the two
  /// arguments to `start` are on a real run.
  late Directory home;
  late Directory workspace;

  setUp(() {
    home = Directory.systemTemp.createTempSync("agent_chat_shell_");
    workspace = Directory(p.join(home.path, "chats", "c1"))..createSync(recursive: true);
  });
  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<dynamic> run(String command,
          {Duration timeout = const Duration(seconds: 10),
          Map<String, String> env = const {}}) =>
      LocalShell(environment: () => env)
          .start(command,
              cwd: workspace.path, home: home.path, timeout: timeout)
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

  test("the machine's own HOME stands: the workspace is not it", () async {
    final result = await run(r'echo "$HOME"');

    expect(result.output.trim(), isNot(home.path));
  });

  test("nothing waits for a keypress", () async {
    final result = await run(r'echo "$PAGER $TERM"');

    expect(result.output.trim(), "cat dumb");
  });

  test("a command that overruns is interrupted and says so", () async {
    final result = await run("echo starting; sleep 30",
        timeout: const Duration(milliseconds: 300));

    // A timeout is a Ctrl-C to the group, and the command dies as 130.
    expect(result.returnCode, 130);
    expect(result.output, "starting\n");
    expect(result.exceptionInfo, contains("timed out"));
  });

  test("what the command spawned is killed with it", () async {
    final marker = p.join(workspace.path, "survivor");
    final result = await run(
      "(trap '' INT; sleep 4; touch $marker) & echo started; sleep 30",
      timeout: const Duration(milliseconds: 300),
    );

    expect(result.exceptionInfo, contains("timed out"));
    // The background child ignores the group's SIGINT, so only the SIGKILL a
    // timeout escalates to can reach it — which is the whole point: the group
    // kill is what the test is about, and an interruptible child races the
    // kill to the touch and flakes. Ignoring INT leaves the sleep alive past
    // the interrupt and dead the moment the kill lands.
    await Future<void>.delayed(const Duration(seconds: 5));
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

  test("killing it early reports the interruption rather than an exit code",
      () async {
    final run = LocalShell()
        .start("sleep 30",
            cwd: workspace.path, home: home.path, timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await run.kill();

    final result = await run.result;
    expect(result.returnCode, 130);
    expect(result.exceptionInfo, contains("interrupted"));
  });

  test("a command that cannot start is a failed result, not a thrown one", () async {
    final result = await run("definitely-not-a-command");

    expect(result.returnCode, isNot(0));
    expect(result.output, contains("not found"));
  });

  test("the machine's own HOME stands, not the workspace's", () async {
    final result = await run(r'echo "$HOME"');

    expect(result.output.trim(), Platform.environment["HOME"]);
  });

  group("in one shell", () {
    /// The one session these tests share, so the second command sees the
    /// first.
    late LocalShell shell;
    late Directory sub;

    setUp(() {
      shell = LocalShell();
      sub = Directory(p.join(workspace.path, "sub"))..createSync();
    });

    ShellRun start(String command, {bool restart = false}) => shell.start(
        command,
        cwd: workspace.path,
        home: home.path,
        timeout: const Duration(seconds: 10),
        restart: restart);

    test("a cd and an export stand when the command is done", () async {
      await start("cd sub && export MARK=one").result;
      final result = await start("pwd; echo \$MARK").result;

      expect(result.output, "${sub.path}\none\n");
      expect(result.cwd, sub.path);
    });

    test("the place the shell is standing is what the composer is told",
        () async {
      final cwd = shell.sessionCwd(workspace.path);
      expect(cwd, isNotNull);
      expect(cwd!.value, workspace.path);

      await start("cd sub").result;

      expect(cwd.value, sub.path);
    });

    test("a stop leaves the shell where it was", () async {
      final run = start("cd sub && sleep 30");
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await run.kill();

      final killed = await run.result;
      expect(killed.returnCode, 130);
      expect(killed.exceptionInfo, contains("interrupted"));

      // The interrupted command's cd went ahead of its sleep, so it stands.
      final after = await start("pwd").result;
      expect(after.returnCode, 0);
      expect(after.cwd, sub.path);
    });

    test("a restart puts the shell back where it started", () async {
      await start("cd sub").result;
      final result = await start("pwd", restart: true).result;

      expect(result.output, "${workspace.path}\n");
      expect(result.cwd, workspace.path);
    });

    test("a command that exits takes the shell down, and the shell comes back",
        () async {
      final result = await start("echo hello; exit 3").result;
      expect(result.returnCode, 3);
      expect(result.output, "hello\n");

      // A command written while the shell is still dying is the one that
      // finds it gone; whatever follows it starts the shell again.
      await start("pwd").result;
      final after = await start("pwd").result;
      expect(after.returnCode, 0);
      expect(after.cwd, workspace.path);
    });

    test("one-shot commands keep the old contract: fresh every time",
        () async {
      final a = shell
          .start("cd sub && export MARK=one",
              cwd: workspace.path,
              home: home.path,
              timeout: const Duration(seconds: 10),
              oneShot: true)
          .result;
      final b = await shell
          .start("pwd; echo \$MARK",
              cwd: workspace.path,
              home: home.path,
              timeout: const Duration(seconds: 10),
              oneShot: true)
          .result;
      await a;

      expect(b.output, "${workspace.path}\n\n");
      expect(b.cwd, isNull);
    });

    test("closing a session closes the shell with it", () async {
      final cwd = shell.sessionCwd(workspace.path);
      await start("cd sub").result;
      expect(cwd!.value, sub.path);

      shell.closeSession(workspace.path);

      // What is asked again is a new bar, standing where the shell starts.
      final again = shell.sessionCwd(workspace.path);
      expect(again, isNot(cwd));
      expect(again!.value, workspace.path);
    });
  });

  group("the live view of a running command", () {
    test("grows as the command prints", () async {
      final shell = LocalShell();
      final run = shell.start(
          "echo one; sleep 1; echo two; sleep 1; echo three",
          cwd: workspace.path,
          home: home.path,
          timeout: const Duration(seconds: 10));
      final output = run.output!;

      // The first line has printed while the command is still running.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final early = output.value ?? "";
      expect(early, contains("one"));
      expect(early, isNot(contains("three")));

      final result = await run.result;
      expect((output.value ?? ""), contains("three"));
      expect(result.output, "one\ntwo\nthree\n");
      shell.closeSession(workspace.path);
    });

    test("never shows the sentinel, and the result is the whole output",
        () async {
      final result = await run("echo one; echo two");

      // The result is the whole of what the command printed, sentinel
      // stripped, as it ever was.
      expect(result.output, "one\ntwo\n");
    });

    test("a command the shell interrupted leaves the tail where it stopped",
        () async {
      final run = LocalShell()
          .start("echo started; sleep 30",
              cwd: workspace.path,
              home: home.path,
              timeout: const Duration(seconds: 30));
      final output = run.output!;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await run.kill();
      await run.result;

      expect(output.value ?? "", contains("started"));
    });

    test("holds a fragment that could be a sentinel out of the live view",
        () async {
      // The sentinel's head is `\n@@E`; a command printing that fragment
      // leaves the live view holding it back until the next chunk proves it
      // was ordinary output. What proves it here is the final result: the
      // parse swallowed nothing, and what was published never showed a whole
      // sentinel line.
      final result = await run(r'echo "before"; printf "\n@@E"; echo "after"');

      expect(result.output, "before\n\n@@Eafter\n");
    });

    test("the tail is bounded, and the whole is still in the result", () async {
      final shell = LocalShell();
      final run = shell.start(
          "seq 1 10000",
          cwd: workspace.path,
          home: home.path,
          timeout: const Duration(seconds: 30));
      final output = run.output!;
      final result = await run.result;

      expect(output.value!.length, lessThanOrEqualTo(8192));
      expect(result.output.length, greaterThan(40000));
      shell.closeSession(workspace.path);
    });

    test("a one-shot run streams its output the same way", () async {
      final shell = LocalShell();
      final run = shell.start(
          "echo one; sleep 1; echo two",
          cwd: workspace.path,
          home: home.path,
          timeout: const Duration(seconds: 10),
          oneShot: true);
      final output = run.output!;

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(output.value ?? "", contains("one"));

      final result = await run.result;
      expect((output.value ?? ""), contains("two"));
      expect(result.output, "one\ntwo\n");
    });
  });

  // The cwd is a directory the app lays out, and it may not be there when a
  // command is first asked to stand in it: a project workspace before any chat
  // exists (a built-in project's setup runs in one) or one deleted from the
  // Files app. The shell makes it rather than failing with an ENOENT that
  // names neither the directory nor the reason.
  group("a spawn cwd that is not there yet", () {
    test("a one-shot run creates it and runs", () async {
      final fresh = p.join(home.path, "not_yet");
      expect(Directory(fresh).existsSync(), isFalse);

      final result = await LocalShell().start("echo hi",
              cwd: fresh, home: home.path, timeout: const Duration(seconds: 5),
              oneShot: true)
          .result;

      expect(result.returnCode, 0);
      expect(result.output, "hi\n");
      expect(Directory(fresh).existsSync(), isTrue);
    });

    test("a persistent session recreates a deleted cwd on respawn", () async {
      final shell = LocalShell();
      final cwd = p.join(home.path, "session");
      Directory(cwd).createSync();
      await shell
          .start("echo first",
              cwd: cwd, home: home.path, timeout: const Duration(seconds: 5))
          .result;

      Directory(cwd).deleteSync(recursive: true);
      expect(Directory(cwd).existsSync(), isFalse);

      // `restart` forces a respawn, which has to put the directory back
      // before standing in it again.
      final result = await shell
          .start("echo second",
              cwd: cwd, home: home.path, timeout: const Duration(seconds: 5),
              restart: true)
          .result;

      expect(result.returnCode, 0);
      expect(result.output, "second\n");
      expect(Directory(cwd).existsSync(), isTrue);
    });
  });

  test("what the model is told names the shell, and the tools beside it", () {
    expect(
        LocalShell(
                driver: ({String? project}) =>
                    LocalShell.hostDriver(shell: () => "/system/bin/sh"))
            .platformDescription,
        contains("/system/bin/sh"));
    expect(
        LocalShell(driver: ({String? project}) => LocalShell.hostDriver(
              shell: () => "/system/bin/sh",
              tools: const Toolset(environment: {}, names: "git"),
            )).platformDescription,
        contains("git"));
  });

  test("the host driver answers for the machine, and for nothing where "
      "there is no shell", () {
    final driver = LocalShell.hostDriver(shell: () => "/bin/sh");

    expect(driver!.commandFor("", ""), ["/bin/sh"]);
    expect(driver.projectHome, isFalse);
    expect(LocalShell.hostDriver(shell: () => null), isNull);
  });

  test("what the home is is one answer: what composeEnvironment sets", () {
    final host = LocalShell(driver: ({String? project}) => LocalShell.hostDriver(
        shell: () => "/bin/sh"));
    expect(host.homeFor(home.path), Platform.environment["HOME"]);
    expect(host.machineHome, Platform.environment["HOME"]);

    final guest = LocalShell(
        driver: ({String? project}) => ShellDriver(
            commandFor: _hostCommand,
            environment: const {},
            projectHome: true,
            guestRoot: "/root",
            description: "guest"));
    expect(guest.homeFor(home.path), "/root");
  });

  group("inside a guest", () {
    /// What proot is on a device, faked with something every machine running
    /// these tests has: a prefix that really runs, ending in a shell.
    ShellDriver guest({Map<String, String> environment = const {}}) =>
        ShellDriver(
          commandFor: (_, _) => ["/usr/bin/env", "IN_GUEST=yes", "/bin/sh"],
          environment: environment,
          projectHome: true,
          description: "Alpine Linux 3.24.1 (x86_64), in which apk installs "
              "things. It is running under proot, so filesystem-heavy commands "
              "are slower than they look",
        );

    Future<dynamic> inGuest(
      String command, {
      ShellDriver? driver,
      Map<String, String> settings = const {},
    }) =>
        LocalShell(
          environment: () => settings,
          driver: ({String? project}) => driver ?? guest(),
        )
            .start(command,
                cwd: workspace.path, home: home.path, timeout: const Duration(seconds: 10))
            .result;

    test("the command is run by what the driver names, not by the machine's shell",
        () async {
      final result = await inGuest(r'echo "$IN_GUEST"');

      expect(result.output.trim(), "yes");
    });

    test("the guest's environment is what the command runs with", () async {
      final result = await inGuest(
        r'echo "[$IN_ALPINE]"',
        driver: guest(environment: {"IN_ALPINE": "1"}),
      );

      expect(result.output.trim(), "[1]");
    });

    test("a variable from settings still wins over the guest's own", () async {
      final result = await inGuest(
        r'echo "$LANG"',
        driver: guest(environment: {"LANG": "C.UTF-8"}),
        settings: {"LANG": "en_GB.UTF-8"},
      );

      expect(result.output.trim(), "en_GB.UTF-8");
    });

    test("home is the project's own workspace, not the guest's /root", () async {
      final result = await inGuest(r'echo "$HOME"');

      expect(result.output.trim(), home.path);
    });

    test("a home from settings still wins over the workspace", () async {
      final result = await inGuest(r'echo "$HOME"', settings: {"HOME": "/root"});

      expect(result.output.trim(), "/root");
    });

    test("what the model is told is the guest, not the machine it is on", () {
      final shell = LocalShell(driver: ({String? project}) => guest());

      expect(shell.platformDescription, contains("Alpine Linux 3.24.1"));
      expect(shell.platformDescription, contains("proot"));
    });

    test("brings its own shell, so a machine that has none can still run commands",
        () {
      expect(LocalShell(driver: ({String? project}) => guest()).canRunCommands, isTrue);
      expect(LocalShell(driver: ({String? project}) => null).canRunCommands, isFalse);
    });

    test("an environment named beside the driver is the shell's base, so a "
        "host driver can point at a directory its tools sit in", () {
      final driver = LocalShell.hostDriver(
          shell: () => "/bin/sh",
          environment: const {"PATH": "/cache/byte-repair/bin:/usr/bin"});

      expect(driver!.environment["PATH"], "/cache/byte-repair/bin:/usr/bin");
      // The toolset's own vars are still laid under it.
      final withTools = LocalShell.hostDriver(
          shell: () => "/bin/sh",
          environment: const {"PATH": "/cache/byte-repair/bin"},
          tools: const Toolset(environment: {"TMPDIR": "/tmp/app"}));
      expect(withTools!.environment,
          {"PATH": "/cache/byte-repair/bin", "TMPDIR": "/tmp/app"});
    });
  });

  group("what a command runs under", () {
    const host = ShellDriver(
      commandFor: _hostCommand,
      environment: {"PAGER": "less", "GIT_EXEC_PATH": "/data/tools/libexec"},
      projectHome: false,
      description: "host",
    );

    test("the driver's environment is the base, over the defaults", () {
      final env = LocalShell.composeEnvironment(
        defaults: const {"PAGER": "cat", "TERM": "dumb"},
        driver: host,
        home: "/home",
        app: const {},
      );

      expect(env, {"PAGER": "less", "TERM": "dumb", "GIT_EXEC_PATH": "/data/tools/libexec"});
      expect(env.containsKey("HOME"), isFalse);
    });

    test("the app's variables win over the driver's, and the project's over "
        "the app's", () {
      final env = LocalShell.composeEnvironment(
        defaults: const {},
        driver: host,
        home: "/home",
        app: const {"PAGER": "most", "OWN": "app"},
        project: const {"OWN": "project"},
      );

      expect(env["PAGER"], "most");
      expect(env["OWN"], "project");
    });

    test("HOME is the workspace where the driver takes one, and the machine's "
        "own where it does not", () {
      final guest = ShellDriver(
        commandFor: _hostCommand,
        environment: const {},
        projectHome: true,
        description: "guest",
      );
      expect(
          LocalShell.composeEnvironment(defaults: const {}, driver: guest,
              home: "/workspace", app: const {})["HOME"],
          "/workspace");
      expect(
          LocalShell.composeEnvironment(defaults: const {}, driver: host,
              home: "/workspace", app: const {})
              .containsKey("HOME"),
          isFalse);
    });

    test("a variable the store puts in the command environment survives the "
        "layering, and one a user set in settings cannot override it", () {
      // The store passes ENV_INSTALL_DIR as the command's own environment,
      // which is the project layer — the last one, over the app's settings.
      final env = LocalShell.composeEnvironment(
        defaults: const {},
        driver: host,
        home: "/home",
        app: const {"ENV_INSTALL_DIR": "/somewhere/else"},
        project: const {"ENV_INSTALL_DIR": "/cache/byte-repair/bin"},
      );

      expect(env["ENV_INSTALL_DIR"], "/cache/byte-repair/bin");
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
      expect(LocalShell(driver: ({String? project}) => null).canRunCommands, isFalse);
    });

    test("and a command sent to it anyway fails rather than throwing", () async {
      final result = await LocalShell(driver: ({String? project}) => null)
          .start("echo hi",
              cwd: workspace.path, home: home.path, timeout: const Duration(seconds: 1))
          .result;

      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("No shell"));
    });
  });
}
