import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/miniswe/local_shell.dart";

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
}
