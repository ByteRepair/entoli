import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/background_jobs.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/domain/shell_job.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late FakeShell shell;
  late BackgroundJobs jobs;
  late String workspace;

  final finish = saidOnly("done");

  BuiltinAgent agentOver(FakeLlmClient client, {bool background = true}) {
    final tempDir = Directory.systemTemp.createTempSync("background-jobs-test");
    addTearDown(() => tempDir.deleteSync(recursive: true));
    workspace = p.join(tempDir.path, "project", "chats", "chat-1");
    Directory(workspace).createSync(recursive: true);
    shell = FakeShell((_) => ok("output"), canRunInBackground: background);
    jobs = BackgroundJobs(fileSystemIo);
    return BuiltinAgent(
      session: BuiltinSession(),
      client: client,
      shell: shell,
      fs: fileSystemIo,
      workspace: workspace,
      projectWorkspace: p.dirname(p.dirname(workspace)),
      model: "fake-model",
      approveMode: ApproveMode.never,
      approve: (_) async => ApprovalResponse.allow,
      answer: (request) => Future.value(request.unanswered),
      backgroundJobs: background ? jobs.forChat("chat-1") : null,
    );
  }

  List<ToolResult> results(List<AgentEvent> events) =>
      events.whereType<ToolResultEvent>().map((e) => e.result).toList();

  Map<String, dynamic>? bashProperties(FakeLlmClient client) =>
      client.calls.first.tools.firstWhere((t) => t.name == "bash").schema[
          "properties"] as Map<String, dynamic>?;

  test("bash offers background only where the chat can keep a job", () async {
    final offered = FakeLlmClient([[finish]]);
    await agentOver(offered).run(userMessage("go")).toList();
    expect(bashProperties(offered), contains("background"));

    final withheld = FakeLlmClient([[finish]]);
    await agentOver(withheld, background: false).run(userMessage("go")).toList();
    expect(bashProperties(withheld), isNot(contains("background")));
  });

  test("a background call answers at once with its pid and log", () async {
    final client = FakeLlmClient([
      [bashCall("npm run dev", extra: {"background": true})],
      [finish],
    ]);
    final agent = agentOver(client);
    shell.hang.add(backgroundScript("call-1", "npm run dev"));
    final events = await agent.run(userMessage("go")).toList();

    expect(shell.ran, [backgroundScript("call-1", "npm run dev")]);
    expect(shell.oneShots, [true]);
    expect(shell.timeouts, [BackgroundJobs.timeout]);
    final result = results(events).single;
    // The job rides on the result as a fact, for the reply to draw as one.
    expect(result.jobId, 1);
    final output = result.output;
    expect(output, contains("job 1"));
    expect(output, contains("kill -- -4000"));
    expect(output, contains("chat:.entoli-jobs/call-1.log"));

    final job = jobs.forChat("chat-1").jobs.value.single;
    expect(job.pid, 4000);
    expect(job.callId, "call-1");
    expect(job.logPath, p.join(workspace, ".entoli-jobs", "call-1.log"));
  });

  test("the next call hears how a job ended, once", () async {
    final client = FakeLlmClient([
      [bashCall("serve", id: "c1", extra: {"background": true})],
      [bashCall("ls", id: "c2")],
      [bashCall("pwd", id: "c3")],
      [finish],
    ]);
    final agent = agentOver(client);
    shell.hang.add(backgroundScript("c1", "serve"));
    // Stopped from the pill between the first call and the second.
    var stopped = false;
    final events = <AgentEvent>[];
    await for (final event in agent.run(userMessage("go"))) {
      events.add(event);
      if (!stopped && event is ToolResultEvent) {
        stopped = true;
        await jobs.forChat("chat-1").stop(1);
        await pumpEventQueue();
      }
    }

    final [started, second, third] = results(events);
    expect(started.notes, isEmpty);
    expect(second.notes, ["Background job 1 (`serve`) was stopped."]);
    expect(second.output, "output");
    expect(third.notes, isEmpty);
    expect(jobs.forChat("chat-1").jobs.value, isEmpty);
  });

  test("a job's id is not reused after it ends", () async {
    jobs = BackgroundJobs(fileSystemIo);
    shell = FakeShell((_) => ok(""), canRunInBackground: true);
    final chat = jobs.forChat("chat-1");
    ShellRun spawn(String script) => shell.start(script,
        cwd: "/w", home: "/w", timeout: Duration.zero);
    await chat.start("a", callId: "c1", workspace: "/w", spawn: spawn);
    await pumpEventQueue();
    expect(chat.jobs.value, isEmpty);
    final second =
        await chat.start("b", callId: "c2", workspace: "/w", spawn: spawn);
    expect(second.id, 2);
  });

  test("closing a chat kills its jobs", () async {
    final client = FakeLlmClient([
      [bashCall("serve", extra: {"background": true})],
      [finish],
    ]);
    final agent = agentOver(client);
    shell.hang.add(backgroundScript("call-1", "serve"));
    final ended = jobs.forChat("chat-1").ended.toList();
    await agent.run(userMessage("go")).toList();
    await jobs.closeChat("chat-1");
    expect(shell.killed, [backgroundScript("call-1", "serve")]);
    // Killed with the chat: no end to record.
    expect(await ended, isEmpty);
    expect(jobs.forChat("chat-1").jobs.value, isEmpty);
  });

  test("the log tail reads the end of the file", () async {
    jobs = BackgroundJobs(fileSystemIo);
    final tempDir = Directory.systemTemp.createTempSync("background-log");
    addTearDown(() => tempDir.deleteSync(recursive: true));
    File(p.join(tempDir.path, backgroundLog("c1")))
      ..createSync(recursive: true)
      ..writeAsStringSync("hello\n");
    shell = FakeShell((_) => ok(""), canRunInBackground: true);
    final chat = jobs.forChat("c");
    final job = await chat.start("x",
        callId: "c1",
        workspace: tempDir.path,
        spawn: (script) => shell.start(script,
            cwd: tempDir.path, home: tempDir.path, timeout: Duration.zero));
    // The fake run has already ended, so the tail is read once and closes.
    await pumpEventQueue();
    expect(await chat.log(job).toList(), ["hello\n"]);
  });

  test("a job that ends says how, with the end of its log", () async {
    jobs = BackgroundJobs(fileSystemIo);
    final tempDir = Directory.systemTemp.createTempSync("background-end");
    addTearDown(() => tempDir.deleteSync(recursive: true));
    File(p.join(tempDir.path, backgroundLog("c1")))
      ..createSync(recursive: true)
      ..writeAsStringSync([for (var i = 1; i <= 15; i++) "line $i"].join("\n"));
    shell = FakeShell((_) => ShellResult(returnCode: 3, output: ""),
        canRunInBackground: true);
    final chat = jobs.forChat("c");
    final ended = chat.ended.first;
    await chat.start("x",
        callId: "c1",
        workspace: tempDir.path,
        spawn: (script) => shell.start(script,
            cwd: tempDir.path, home: tempDir.path, timeout: Duration.zero));
    final (:callId, :end) = await ended;
    expect(callId, "c1");
    expect(end.jobId, 1);
    expect(end.exitCode, 3);
    expect(end.tail, [for (var i = 6; i <= 15; i++) "line $i"].join("\n"));
  });

  group("jobTail", () {
    test("keeps the last ten lines", () {
      expect(jobTail("a\nb\nc\n"), "a\nb\nc");
      expect(jobTail([for (var i = 0; i < 20; i++) "$i"].join("\n")),
          [for (var i = 10; i < 20; i++) "$i"].join("\n"));
    });

    test("cuts from the top past a kilobyte, never inside a character", () {
      final tail = jobTail("é" * 2000);
      expect(utf8.encode(tail).length, lessThanOrEqualTo(1024));
      expect(tail, startsWith("…é"));
      expect(tail, endsWith("é"));
    });
  });

  test("a call id that is not a file name still names one log", () {
    expect(backgroundLog("toolu_01/ab:c"), ".entoli-jobs/toolu_01_ab_c.log");
  });
}
