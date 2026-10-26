import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/directory_tools.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/builtin_project.dart" show AgentCapability;
import "package:agent_chat/domain/file_tools.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  /// The chat workspace, the project workspace, and a directory beside both
  /// — the one a grant is about. Set by [makeRooms].
  late String chatWs;
  late String projectWs;
  late String outside;

  setUp(() => session = BuiltinSession());

  final finish = saidOnly("done");

  /// The directories a test lays out before scripting its model calls into
  /// them. `add_directory` wants [outside]; a grant over a workspace shape is
  /// answered without a banner.
  void makeRooms() {
    final tempDir = Directory.systemTemp.createTempSync("agent-dir-test");
    projectWs = p.join(tempDir.path, "project-ws");
    chatWs = p.join(projectWs, "chats", "chat-1");
    outside = p.join(tempDir.path, "beside");
    Directory(chatWs).createSync(recursive: true);
    Directory(outside).createSync(recursive: true);
    addTearDown(() => tempDir.deleteSync(recursive: true));
    shell = FakeShell((_) => ok(""));
  }

  /// One directory beside the rooms, created — `add_directory` refuses a
  /// path that names nothing, so a test granting one has it stand there.
  void makeDir(String path) => Directory(path).createSync(recursive: true);

  /// The [which]'th tool result a turn reported, zero-based.
  ToolResult results(List<AgentEvent> events, {int which = 0}) =>
      events.whereType<ToolResultEvent>().toList()[which].result;

  String textOf(ToolResult result) =>
      [result.output, result.exceptionInfo ?? ""].join(" ");

  /// The agent under test. [grants] is what the approval banners are
  /// answered, in the order they come.
  BuiltinAgent agentOver(
    FakeLlmClient client, {
    List<ApprovalResponse> grants = const [],
    List<String> writableDirs = const [],
    String? dataDir,
    ApproveMode approveMode = ApproveMode.never,
  }) {
    final allowed = [...grants];
    return BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      fs: fileSystemIo,
      workspace: chatWs,
      projectWorkspace: projectWs,
      model: "fake-model",
      approveMode: approveMode,
      approve: (_) async =>
          allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
      answer: (request) => Future.value(request.unanswered),
      policy: () async => StandingPermissions(writableDirs: writableDirs),
      dataDir: dataDir,
    );
  }

  group("add_directory refusals", () {
    test(
        "the data directory, everything containing and inside it refuses",
        () async {
      makeRooms();
      final dir = Directory.systemTemp.createTempSync("agent-dir-house");
      final dataDir = p.join(dir.path, "agent-data");
      Directory(dataDir).createSync();
      final beneath = p.join(dataDir, "projects");
      Directory(beneath).createSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": dataDir})],
        [fileCall(addDirectoryName, {"path": dir.path})],
        [fileCall(addDirectoryName, {"path": beneath})],
        [fileCall(addDirectoryName, {"path": outside})],
        [finish],
      ]);
      final events = await agentOver(
        client,
        dataDir: dataDir,
        grants: [ApprovalResponse.allow, ApprovalResponse.allow,
          ApprovalResponse.allow],
      ).run(userMessage("go")).toList();
      final banners = events
          .whereType<ApprovalRequestEvent>()
          .where((e) => e.approval.toolName == addDirectoryName)
          .toList();
      // The first three never reached a banner; the one beside the data tree
      // did, and the scripted allow answered it.
      expect(banners, hasLength(1));
      expect(textOf(results(events, which: 0)), contains("not grantable"));
      expect(textOf(results(events, which: 1)), contains("not grantable"));
      expect(textOf(results(events, which: 2)), contains("not grantable"));
      expect(textOf(results(events, which: 3)),
          contains(outside));
    });

    test("a path that names nothing refuses", () async {
      makeRooms();
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": p.join(outside, "no-such")})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(textOf(results(events)), contains("not found"));
    });

    test("a file where a directory was asked for refuses", () async {
      makeRooms();
      File(p.join(outside, "a-file")).writeAsStringSync("x");
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": p.join(outside, "a-file")})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(textOf(results(events)), contains("not a directory"));
    });

    test("a directory the workspaces hold needs no grant", () async {
      makeRooms();
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": chatWs})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(textOf(results(events)), contains("already allowed"));
    });

    test("missing argument rejects without a banner", () async {
      makeRooms();
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(textOf(results(events)), contains('takes {"path"'));
    });
  });

  group("add_directory answers", () {
    test("allow grants the turn: writes under the grant stop asking",
        () async {
      makeRooms();
      final granted = p.join(outside, "granted");
      makeDir(granted);
      final file = p.join(granted, "made-by-write.txt");
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": granted})],
        [fileCall(writeToolName, {"path": file, "content": "hi"})],
        [finish],
      ]);
      final events = await agentOver(client,
              grants: [ApprovalResponse.allow],
              approveMode: ApproveMode.ask)
          .run(userMessage("go")).toList();
      expect(textOf(results(events)), contains("Allowed for the rest of"));
      expect(File(file).readAsStringSync(), "hi");
      // No second banner: the grant the first one made covers the write.
      expect(
          events
              .whereType<ApprovalRequestEvent>()
              .where((e) => e.approval.toolName == writeToolName),
          isEmpty);
    });

    test("deny grants nothing: writes keep raising the ordinary banner",
        () async {
      makeRooms();
      final granted = p.join(outside, "granted");
      makeDir(granted);
      final file = p.join(granted, "made-by-write.txt");
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": granted})],
        [fileCall(writeToolName, {"path": file, "content": "hi"})],
        [finish],
      ]);
      final events = await agentOver(client,
              grants: [ApprovalResponse.deny, ApprovalResponse.allow],
              approveMode: ApproveMode.ask)
          .run(userMessage("go")).toList();
      final denial = results(events, which: 0);
      expect(textOf(denial), contains("Denied"));
      expect(textOf(denial), contains("carry on"));
      // The write behind a refused grant is its own banner — the per-write
      // path the denial promised — and the allow there let it land.
      final writeBanner = events
          .whereType<ApprovalRequestEvent>()
          .lastWhere((e) => e.approval.toolName == writeToolName);
      expect(writeBanner.approval.toolName, writeToolName);
      expect(File(file).readAsStringSync(), "hi");
    });

    test("allow in chat grants the turn too, beside the persisted half",
        () async {
      makeRooms();
      final granted = p.join(outside, "granted");
      makeDir(granted);
      final file = p.join(granted, "made-by-write.txt");
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": granted})],
        [fileCall(writeToolName, {"path": file, "content": "hi"})],
        [finish],
      ]);
      final events = await agentOver(client,
              grants: [ApprovalResponse.alwaysAllowChat],
              approveMode: ApproveMode.ask)
          .run(userMessage("go")).toList();
      expect(textOf(results(events)), contains("Allowed in this chat"));
      expect(File(file).readAsStringSync(), "hi");
      // One banner: the directory's own. The write under it ran free.
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
    });

    test("the approval hands the resolved path to the tier that answers",
        () async {
      makeRooms();
      final granted = p.join(outside, "granted");
      makeDir(granted);
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": granted})],
        [finish],
      ]);
      final events = await agentOver(client, grants: [ApprovalResponse.deny])
          .run(userMessage("go")).toList();
      final approval = events.whereType<ApprovalRequestEvent>().single.approval;
      expect(approval.toolName, addDirectoryName);
      expect(approval.argumentsText, granted);
      // The field an "always" answer persists from.
      expect(approval.deniedDirs, [granted]);
    });
  });

  group("writable_directories", () {
    test("lists the workspaces and the granted directories", () async {
      makeRooms();
      final standing = p.join(outside, "standing");
      makeDir(p.join(outside, "mid-turn"));
      final client = FakeLlmClient([
        [fileCall(addDirectoryName, {"path": p.join(outside, "mid-turn")})],
        [fileCall(writableDirectoriesName, {})],
        [finish],
      ]);
      final events = await agentOver(client,
              grants: [ApprovalResponse.alwaysAllowChat],
              writableDirs: [standing])
          .run(userMessage("go")).toList();
      final output = results(events, which: 1).output;
      expect(output, contains("Workspace: $chatWs"));
      expect(output, contains("Project workspace: $projectWs"));
      expect(output, contains("mid-turn"));
      expect(output, contains(standing));
    });

    test("nothing granted says so", () async {
      makeRooms();
      final client = FakeLlmClient([
        [fileCall(writableDirectoriesName, {})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("go")).toList();
      expect(results(events).output, contains("No directories"));
    });

    test("an already-workspace-shaped grant is not listed beside them",
        () async {
      makeRooms();
      final client = FakeLlmClient([
        [fileCall(writableDirectoriesName, {})],
        [finish],
      ]);
      final events =
          await agentOver(client, writableDirs: [projectWs])
              .run(userMessage("go")).toList();
      final after = results(events).output
          .split("Project workspace: $projectWs")
          .last;
      expect(after, isNot(contains(projectWs)));
    });
  });

  group("offered where someone can answer", () {
    test("a one-shot turn takes the list, not the grant request", () {
      final tools = agentTools(
          caps: AgentCapabilities.full, offerMemory: false, oneShot: true);
      expect(tools.map((t) => t.name), isNot(contains(addDirectoryName)));
      expect(tools.map((t) => t.name), contains(writableDirectoriesName));
    });

    test("a headless turn takes neither grant request nor banner rides",
        () {
      final tools = agentTools(
          caps: AgentCapabilities.forTurn(
              commands: true,
              webSearch: false,
              disabled: {AgentCapability.ask}),
          offerMemory: false);
      expect(tools.map((t) => t.name), isNot(contains(addDirectoryName)));
      expect(tools.map((t) => t.name), contains(writableDirectoriesName));
    });
  });

  group("the file gate reads the same grant store", () {
    test("a granted directory makes the file tools free", () {
      final granted = p.join("/roots", "granted");
      expect(
          outsideWorkspaces(fileSystemIo, p.join(granted, "x.txt"), "/ws",
              "/pws", granted: [granted]),
          isFalse);
    });

    test("a standing grant covers the write tool without a banner",
        () async {
      makeRooms();
      final file = p.join(outside, "standing", "made-by-write.txt");
      final client = FakeLlmClient([
        [fileCall(writeToolName, {"path": file, "content": "hi"})],
        [finish],
      ]);
      final events = await agentOver(client,
              writableDirs: [p.join(outside, "standing")],
              approveMode: ApproveMode.ask)
          .run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(File(file).readAsStringSync(), "hi");
    });

    test("a path past every grant still asks", () async {
      makeRooms();
      final file = p.join(outside, "ungranted", "made-by-write.txt");
      final client = FakeLlmClient([
        [fileCall(writeToolName, {"path": file, "content": "hi"})],
        [finish],
      ]);
      final events = await agentOver(client,
              writableDirs: [p.join(outside, "standing")],
              grants: [ApprovalResponse.allow],
              approveMode: ApproveMode.ask)
          .run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>().last.approval.toolName,
          writeToolName);
    });
  });
}