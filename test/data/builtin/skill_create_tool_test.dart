import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/skill_create_tool.dart";
import "package:agent_chat/data/prompts/skill_import.dart"
    show SkillImportException;
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

const _skillMd = "---\nname: demo\ndescription: does the demo thing\n---\n\nDo it.\n";

void main() {
  late Directory workspace;
  late Directory projectWorkspace;
  late BuiltinSession session;

  /// What the model's `create_skill` call is answered with, in order.
  final List<({String path, String? name})> packaged = [];

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp("create-skill-ws");
    projectWorkspace = await Directory.systemTemp.createTemp("create-skill-proj");
    session = BuiltinSession();
    packaged.clear();
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
    await projectWorkspace.delete(recursive: true);
  });

  /// Writes [dir]/SKILL.md (and any [extra] files) under the workspace.
  Future<String> writeSkill(String dir, String skillMd,
      [Map<String, String> extra = const {}]) async {
    final path = "${workspace.path}/$dir";
    Directory(path).createSync(recursive: true);
    File("$path/SKILL.md").writeAsStringSync(skillMd);
    extra.forEach((name, content) {
      final file = File("$path/$name");
      file.createSync(recursive: true);
      file.writeAsStringSync(content);
    });
    return dir;
  }

  BuiltinAgent agentWith(FakeLlmClient client,
      {ApproveMode approveMode = ApproveMode.never,
      void Function()? onPackage,
      Object? packageError}) =>
      BuiltinAgent(
        session: session,
        client: client,
        shell: FakeShell((_) => ok(""), canRunCommands: true),
        fs: fileSystemIo,
        workspace: workspace.path,
        projectWorkspace: projectWorkspace.path,
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: approveMode,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        packageSkill: (path, name) async {
          packaged.add((path: path, name: name));
          onPackage?.call();
          if (packageError != null) throw packageError;
          return (installId: "install-1", name: name ?? path.split("/").last);
        },
      );

  LlmCompletion createCall(String path, {String? name, String id = "cs-1"}) =>
      LlmCompletion(
        message: LlmMessage(
          role: LlmRole.assistant,
          toolCalls: [
            LlmToolCall(
              id: id,
              name: createSkillToolName,
              argumentsJson: jsonEncode({"path": path, "name": ?name}),
            ),
          ],
        ),
      );

  final finish = saidOnly("done");

  group("offering", () {
    test("the create_skill tool is offered iff a packager is wired", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client).run(userMessage("hi")).toList();

      expect(client.calls.first.tools.map((t) => t.name),
          contains(createSkillToolName));

      // No packager wired: not offered.
      final without = FakeLlmClient([[finish]]);
      final agent = BuiltinAgent(
        session: session,
        client: without,
        shell: FakeShell((_) => ok(""), canRunCommands: true),
        fs: fileSystemIo,
        workspace: workspace.path,
        projectWorkspace: projectWorkspace.path,
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
      );
      await agent.run(userMessage("hi")).toList();

      expect(without.calls.first.tools.map((t) => t.name),
          isNot(contains(createSkillToolName)));
    });
  });

  group("packaging", () {
    test("a draft skill is packaged and offered, named from the frontmatter",
        () async {
      final dir = await writeSkill("skills/demo", _skillMd);
      final client = FakeLlmClient([
        [createCall(dir)],
        [finish],
      ]);
      final events =
          await agentWith(client).run(userMessage("go")).toList();

      expect(packaged, hasLength(1));
      expect(packaged.single.path, dir);

      final install = events.whereType<SkillInstallEvent>().single;
      expect(install.installId, "install-1");
      expect(install.title, "demo");

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "cs-1")
          .result;
      expect(result.returnCode, 0);
      expect(result.output, contains("demo"));
    });

    test("a name argument wins over the frontmatter", () async {
      final dir = await writeSkill("skills/demo", _skillMd);
      final client = FakeLlmClient([
        [createCall(dir, name: "renamed")],
        [finish],
      ]);
      final events =
          await agentWith(client).run(userMessage("go")).toList();

      final install = events.whereType<SkillInstallEvent>().single;
      expect(install.title, "renamed");
      // The packager is told the name the model chose, so the staged package
      // lands where its card says it will.
      expect(packaged.single.name, "renamed");
    });

  });

  group("refusals", () {
    test("a directory that does not exist is refused, and nothing is offered",
        () async {
      final client = FakeLlmClient([
        [createCall("skills/ghost")],
        [finish],
      ]);
      final events =
          await agentWith(client).run(userMessage("go")).toList();

      expect(packaged, isEmpty);
      expect(events.whereType<SkillInstallEvent>(), isEmpty);
      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "cs-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("does not exist"));
    });

    test("a directory with no SKILL.md is refused", () async {
      final client = FakeLlmClient([
        [createCall("skills/incomplete")],
        [finish],
      ]);
      // Make the directory exist but hold no SKILL.md.
      Directory("${workspace.path}/skills/incomplete").createSync(recursive: true);
      final events =
          await agentWith(client).run(userMessage("go")).toList();

      expect(packaged, isEmpty);
      expect(events.whereType<SkillInstallEvent>(), isEmpty);
      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "cs-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("no SKILL.md"));
    });

    test("a frontmatter that does not conform is refused with the reasons",
        () async {
      final dir = await writeSkill("skills/upper",
          "---\nname: Upper\ndescription: d\n---\n\nDo it.\n");
      final client = FakeLlmClient([
        [createCall(dir)],
        [finish],
      ]);
      final events = await agentWith(
              client,
              packageError: const SkillImportException(
                  'name "Upper" is not lowercase letters, digits and hyphens '
                  'with no doubled or leading/trailing hyphen'))
          .run(userMessage("go"))
          .toList();

      expect(events.whereType<SkillInstallEvent>(), isEmpty);
      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "cs-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("Agent Skills spec"));
      expect(result.exceptionInfo, contains('name "Upper"'));
    });

    test("a call with no path is a format error", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(
                    id: "cs-1",
                    name: createSkillToolName,
                    argumentsJson: '{}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events =
          await agentWith(client).run(userMessage("go")).toList();

      expect(packaged, isEmpty);
      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "cs-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains('"path" argument was missing'));
    });
  });

  group("the workspace gate", () {
    test("a path the workspaces do not hold is offered for approval first",
        () async {
      // A skill directory outside both workspaces, on the real disk.
      final outside =
          await Directory.systemTemp.createTemp("create-skill-outside");
      addTearDown(() => outside.delete(recursive: true));
      File("${outside.path}/SKILL.md").writeAsStringSync(_skillMd);

      final client = FakeLlmClient([
        [createCall(outside.path)],
        [finish],
      ]);
      final events = await agentWith(client, approveMode: ApproveMode.ask)
          .run(userMessage("go"))
          .toList();

      // The banner went up before the package was made.
      expect(events.whereType<ApprovalRequestEvent>(), isNotEmpty);
      expect(packaged, hasLength(1));
      expect(events.whereType<SkillInstallEvent>(), hasLength(1));
    });
  });
}
