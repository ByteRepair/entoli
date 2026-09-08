import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";

import "../harness.dart";

void main() {
  late AppConfig config;
  late FileChatStore store;

  setUp(() {
    config = tempConfig();
    store = FileChatStore(config);
  });

  List<String> logLines(String id) =>
      const LineSplitter().convert(File(config.convFile(id)).readAsStringSync())
        ..removeWhere((line) => line.isEmpty);

  Message userMessage(String id, String text) => Message(
        id: id,
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [MessagePart.text(text: text)],
      );

  test("save writes state.json and a log of records", () async {
    await writeChatTo(store, Chat(state: makeState("c1"), messages: [userMessage("m1", "hello")]));

    expect(File(config.stateFile("c1")).existsSync(), isTrue);
    expect(File(config.convFile("c1")).existsSync(), isTrue);
    expect(Directory(config.resourcesDir("c1")).existsSync(), isTrue);
    expect(Directory(config.workspaceDir("c1")).existsSync(), isTrue);

    final stateJson = jsonDecode(File(config.stateFile("c1")).readAsStringSync()) as Map<String, dynamic>;
    expect(stateJson["id"], "c1");
    expect(stateJson["title"], "Test chat c1");

    // One line per record: the message, then the part it holds.
    final lines = logLines("c1").map(
        (line) => jsonDecode(line) as Map<String, dynamic>).toList();
    expect(lines, hasLength(2));
    expect(lines[0]["runtimeType"], "message");
    expect(lines[0]["role"], "user");
    expect(lines[1]["runtimeType"], "part");
    expect(lines[1]["index"], 0);
  });

  test("append adds to the log without rewriting what is there", () async {
    await writeChatTo(store, Chat(state: makeState("c1"), messages: [userMessage("m1", "hello")]));
    final before = logLines("c1");

    await store.append("c1", [
      ChatRecord.message(
          id: "m2", role: MessageRole.assistant, createdAt: DateTime.utc(2026, 1, 1)),
      const ChatRecord.part(
          messageId: "m2", index: 0, part: MessagePart.text(text: "hi")),
    ]);

    expect(logLines("c1").take(before.length), before);
    expect(logLines("c1"), hasLength(before.length + 2));

    final loaded = await store.load("c1");
    expect(loaded.messages, hasLength(2));
    expect((loaded.messages[1].parts.single as TextPart).text, "hi");
  });

  test("a line left half-written by a kill is dropped, and the rest stands", () async {
    await writeChatTo(store, Chat(state: makeState("c1"), messages: [userMessage("m1", "hello")]));
    // What a process dying mid-append leaves behind.
    File(config.convFile("c1")).writeAsStringSync(
        '{"runtimeType":"message","id":"m2","role":"assis',
        mode: FileMode.append);

    final loaded = await store.load("c1");
    expect(loaded.messages, hasLength(1));
    expect((loaded.messages.single.parts.single as TextPart).text, "hello");
  });

  test("load reads back a saved chat", () async {
    final state = makeState("c2");
    final messages = [
      Message(
        id: "m1",
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [const MessagePart.text(text: "hi")],
      ),
      Message(
        id: "m2",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        parts: [const MessagePart.text(text: "hello back")],
      ),
    ];
    await writeChatTo(store, Chat(state: state, messages: messages));

    final loaded = await store.load("c2");
    expect(loaded.state.id, "c2");
    expect(loaded.state.title, "Test chat c2");
    expect(loaded.messages.length, 2);
    expect(loaded.messages[0].role, MessageRole.user);
    expect(loaded.messages[1].role, MessageRole.assistant);
    expect(
      (loaded.messages[0].parts.first as TextPart).text,
      "hi",
    );
  });

  test("list returns summaries sorted by updatedAt desc", () async {
    final older = ChatState(
      id: "older",
      title: "Older",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final newer = ChatState(
      id: "newer",
      title: "Newer",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
    );
    await store.saveState(older);
    await store.saveState(newer);

    final summaries = await store.list();
    expect(summaries.length, 2);
    expect(summaries.first.id, "newer");
    expect(summaries.last.id, "older");
  });

  test("list skips dirs without state.json", () async {
    Directory(p.join(config.chatsDir(), "junk")).createSync();
    await store.saveState(makeState("real"));

    final summaries = await store.list();
    expect(summaries.length, 1);
    expect(summaries.first.id, "real");
  });

  test("list handles empty chats dir", () async {
    final summaries = await store.list();
    expect(summaries, isEmpty);
  });

  test("delete removes the chat directory and the workspace it ran in", () async {
    await store.saveState(makeState("c3"));
    expect(Directory(config.chatDir("c3")).existsSync(), isTrue);

    await store.delete("c3");
    expect(Directory(config.chatDir("c3")).existsSync(), isFalse);
    expect(Directory(config.workspaceDir("c3")).existsSync(), isFalse);
  });

  test("saveResource writes bytes under resources/ and reads them back", () async {
    await store.saveState(makeState("c4"));

    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final resource = await store.saveResource("c4", "test.bin", bytes);
    expect(resource, endsWith("test.bin"));
    expect(File(p.join(config.resourcesDir("c4"), resource)).readAsBytesSync(), bytes);
    expect(await store.readResource("c4", resource), bytes);
  });

  test("saveResource sanitizes unsafe filename characters", () async {
    await store.saveState(makeState("c5"));

    final resource = await store.saveResource("c5", "../bad name.txt", Uint8List(0));
    expect(resource, contains("bad_name.txt"));
    expect(resource, isNot(contains("..")));
  });

  // Two turns attaching the same filename must not overwrite each other.
  test("saveResource gives each attachment its own name", () async {
    await store.saveState(makeState("c5b"));

    final first = await store.saveResource("c5b", "shot.png", Uint8List.fromList([1]));
    final second = await store.saveResource("c5b", "shot.png", Uint8List.fromList([2]));

    expect(first, isNot(second));
    expect(await store.readResource("c5b", first), [1]);
    expect(await store.readResource("c5b", second), [2]);
  });

  test("readResource is null for a resource that is not there", () async {
    await store.saveState(makeState("c5c"));

    expect(await store.readResource("c5c", "missing.png"), isNull);
  });

  group("projects", () {
    test("a chat in one is written under it, not at the top level", () async {
      await store.saveState(makeState("p1", project: "work"));

      expect(File(config.stateFile("p1", project: "work")).existsSync(), isTrue);
      expect(Directory(config.workspaceDir("p1", project: "work")).existsSync(), isTrue);
      expect(File(config.stateFile("p1")).existsSync(), isFalse);
    });

    test("creating one lays down its chats and its shared workspace", () async {
      await store.createProject("work");

      expect(Directory(config.chatsDir(project: "work")).existsSync(), isTrue);
      expect(Directory(config.projectWorkspaceDir(project: "work")).existsSync(), isTrue);
      expect(await store.listProjects(), ["work"]);
    });

    test("list returns every project's chats, each saying which it is in", () async {
      await store.saveState(makeState("here"));
      await store.saveState(makeState("there", project: "work"));

      final all = await store.list();
      expect(all.map((c) => c.id), containsAll(["here", "there"]));
      expect(all.firstWhere((c) => c.id == "here").project, isNull);
      expect(all.firstWhere((c) => c.id == "there").project, "work");
    });

    // A chat is addressed by its id alone, so a store that has not listed
    // anything yet still has to find one that is not in the default project.
    test("a chat in one is found by id by a store that has never listed", () async {
      await store.saveState(makeState("p2", project: "work"));

      final fresh = FileChatStore(config);
      expect((await fresh.load("p2")).state.project, "work");
      expect(await fresh.projectOf("p2"), "work");
    });

    test("deleting one takes its chats and its workspace with it", () async {
      await store.saveState(makeState("p3", project: "work"));

      await store.deleteProject("work");

      expect(Directory(config.projectDir(project: "work")).existsSync(), isFalse);
      expect(await store.list(), isEmpty);
      expect(await store.listProjects(), isEmpty);
    });

    test("moving a chat takes its files and its own workspace", () async {
      await writeChatTo(store, Chat(
        state: makeState("p4"),
        messages: [
          Message(
            id: "m1",
            role: MessageRole.user,
            createdAt: DateTime.utc(2026, 1, 1),
            parts: [const MessagePart.text(text: "hi")],
          ),
        ],
      ));
      final resource = await store.saveResource("p4", "note.txt", Uint8List.fromList([7]));

      await store.moveChat("p4", "work");

      expect(Directory(config.chatDir("p4")).existsSync(), isFalse);
      expect(Directory(config.workspaceDir("p4", project: "work")).existsSync(), isTrue);
      final moved = await store.load("p4");
      expect(moved.state.project, "work");
      expect(moved.messages, hasLength(1));
      expect(await store.readResource("p4", resource), [7]);
    });

    test("what was in the chat's workspace moves with it", () async {
      await store.saveState(makeState("p7"));
      File("${config.workspaceDir("p7")}/note.txt").writeAsStringSync("mine");

      await store.moveChat("p7", "work");

      expect(File("${config.workspaceDir("p7", project: "work")}/note.txt")
          .readAsStringSync(), "mine");
      expect(Directory(config.workspaceDir("p7")).existsSync(), isFalse);
    });

    test("a moved chat says so in its state.json", () async {
      await store.saveState(makeState("p5"));
      await store.moveChat("p5", "work");

      final json = jsonDecode(File(config.stateFile("p5", project: "work")).readAsStringSync())
          as Map<String, dynamic>;
      expect(json["project"], "work");
    });

    // The UI can be holding a copy from before the move; saving it must not
    // write the chat back where it used to be.
    test("saving a stale copy does not put the chat back", () async {
      await store.saveState(makeState("p6"));
      await store.moveChat("p6", "work");

      await store.saveState(makeState("p6"));

      expect(Directory(config.chatDir("p6")).existsSync(), isFalse);
      expect((await store.load("p6")).state.project, "work");
    });

    // Deleting one deletes a directory, so a name that climbs out of
    // `projects/` would delete something that is not a project. The check is
    // `AppConfig.projectDir`'s, which every project path goes through.
    test("a name that is not one directory under projects/ is refused", () {
      expect(() => store.createProject("../elsewhere"), throwsArgumentError);
      expect(() => store.deleteProject(".."), throwsArgumentError);
      expect(() => store.moveChat("p8", "a/b"), throwsArgumentError);
    });

    test("a stray directory under projects/ is not offered as one", () async {
      Directory(p.join(config.projectsDir, ".git")).createSync(recursive: true);
      await store.createProject("work");

      expect(await store.listProjects(), ["work"]);
      expect(await store.list(), isEmpty);
    });

    // The directory a chat is in is what it is in, whatever the file says.
    test("a chat moved by hand is listed under where it ended up", () async {
      await store.saveState(makeState("p7"));
      await config.ensureProjectDirs(project: "work");
      Directory(config.chatDir("p7")).renameSync(config.chatDir("p7", project: "work"));

      final fresh = FileChatStore(config);
      expect((await fresh.list()).single.project, "work");
    });
  });

  test("round-trips tool call and tool result parts", () async {
    final state = makeState("c6");
    final messages = [
      Message(
        id: "m1",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [
          MessagePart.toolCall(
            toolCall: const ToolCall(id: "tc1", name: "bash", argumentsText: "ls -la"),
          ),
        ],
      ),
      Message(
        id: "m2",
        role: MessageRole.tool,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        parts: [
          MessagePart.toolResult(
            result: const ToolResult(callId: "tc1", returnCode: 0, output: "total 0"),
          ),
        ],
      ),
    ];
    await writeChatTo(store, Chat(state: state, messages: messages));
    final loaded = await store.load("c6");
    expect(loaded.messages[0].parts.first, isA<ToolCallPart>());
    expect((loaded.messages[0].parts.first as ToolCallPart).toolCall.name, "bash");
    expect(loaded.messages[1].parts.first, isA<ToolResultPart>());
    expect((loaded.messages[1].parts.first as ToolResultPart).result.output, "total 0");
  });

  group("artifacts", () {
    test("createArtifact copies a workspace dir and returns an id", () async {
      await store.saveState(makeState("a1"));
      // Write a workspace dir with files to copy from.
      final ws = config.workspaceDir("a1");
      final src = p.join(ws, "report");
      await Directory(src).create(recursive: true);
      await File(p.join(src, "index.html")).writeAsString("<h1>hi</h1>");
      await Directory(p.join(src, "css")).create();
      await File(p.join(src, "css", "style.css")).writeAsString("body{color:red}");

      final id = await store.createArtifact("a1", src, "index.html");
      expect(id, isNotEmpty);
      final dir = Directory(config.artifactDir("a1", id));
      expect(dir.existsSync(), isTrue);
      // The base stylesheet is injected into the entry file at publish time.
      final entry = File(p.join(dir.path, "index.html")).readAsStringSync();
      expect(entry, contains("<h1>hi</h1>"));
      expect(entry, contains("entoli-base-css"));
      expect(File(p.join(dir.path, "css", "style.css")).readAsStringSync(), "body{color:red}");
      // The workspace copy the model reads is untouched.
      expect(File(p.join(src, "index.html")).readAsStringSync(), "<h1>hi</h1>");
    });

    test("createArtifact accepts a single file (copies parent dir)", () async {
      await store.saveState(makeState("a1"));
      final ws = config.workspaceDir("a1");
      await Directory(p.join(ws, "page")).create();
      final filePath = p.join(ws, "page", "index.html");
      await File(filePath).writeAsString("<p>page</p>");

      final id = await store.createArtifact("a1", filePath, "index.html");
      final dir = Directory(config.artifactDir("a1", id));
      expect(File(p.join(dir.path, "index.html")).readAsStringSync(), contains("<p>page</p>"));
    });

    test("updateArtifact replaces the contents", () async {
      await store.saveState(makeState("a1"));
      final ws = config.workspaceDir("a1");
      final src1 = p.join(ws, "v1");
      await Directory(src1).create(recursive: true);
      await File(p.join(src1, "index.html")).writeAsString("v1");
      await File(p.join(src1, "old.txt")).writeAsString("old");

      final id = await store.createArtifact("a1", src1, "index.html");
      final dir = Directory(config.artifactDir("a1", id));
      expect(File(p.join(dir.path, "old.txt")).existsSync(), isTrue);

      // Update with a new version.
      final src2 = p.join(ws, "v2");
      await Directory(src2).create(recursive: true);
      await File(p.join(src2, "index.html")).writeAsString("v2");
      await File(p.join(src2, "new.txt")).writeAsString("new");

      await store.updateArtifact("a1", id, src2, "index.html");
      expect(File(p.join(dir.path, "index.html")).readAsStringSync(), contains("v2"));
      expect(File(p.join(dir.path, "index.html")).readAsStringSync(), contains("entoli-base-css"));
      expect(File(p.join(dir.path, "new.txt")).readAsStringSync(), "new");
      expect(File(p.join(dir.path, "old.txt")).existsSync(), isFalse);
    });

    test("readArtifactFile reads back what was copied", () async {
      await store.saveState(makeState("a1"));
      final ws = config.workspaceDir("a1");
      final src = p.join(ws, "report");
      await Directory(src).create(recursive: true);
      final png = Uint8List.fromList([1, 2, 3, 4]);
      await Directory(p.join(src, "assets")).create();
      await File(p.join(src, "assets", "logo.png")).writeAsBytes(png);
      await File(p.join(src, "index.html")).writeAsString("<p>");

      final id = await store.createArtifact("a1", src, "index.html");
      expect(await store.readArtifactFile("a1", id, "assets/logo.png"), png);
      expect(await store.readArtifactFile("a1", id, "missing.txt"), isNull);
    });

    test("readArtifactZip carries the files named from the artifact root",
        () async {
      await store.saveState(makeState("a1"));
      final ws = config.workspaceDir("a1");
      final src = p.join(ws, "report");
      await Directory(src).create(recursive: true);
      final png = Uint8List.fromList([1, 2, 3, 4]);
      await Directory(p.join(src, "assets")).create();
      await File(p.join(src, "assets", "logo.png")).writeAsBytes(png);
      await File(p.join(src, "index.html")).writeAsString("<p>");

      final id = await store.createArtifact("a1", src, "index.html");
      final zip = await store.readArtifactZip("a1", id);
      expect(zip, isNotNull);

      final decoded = ZipDecoder().decodeBytes(zip!);
      final names = [for (final member in decoded) member.name]..sort();
      expect(names, ["assets/", "assets/logo.png", "index.html"]);
      final entry = decoded.findFile("index.html")!.readBytes();
      expect(utf8.decode(entry ?? Uint8List(0)), contains("<p>"));
      expect(decoded.findFile("assets/logo.png")!.readBytes(), png);
    });

    test("readArtifactZip answers null where there is no artifact", () async {
      await store.saveState(makeState("a1"));
      expect(await store.readArtifactZip("a1", "nope"), isNull);
    });
  });
}