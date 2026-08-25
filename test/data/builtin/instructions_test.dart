import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/memory/instructions.dart";

void main() {
  late Directory tmp;
  late String chatWorkspace;
  late String projectWorkspace;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("instructions_test_");
    projectWorkspace = p.join(tmp.path, "project-workspace");
    chatWorkspace = p.join(projectWorkspace, "chats", "chat-1");
    Directory(chatWorkspace).createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final file = File(p.join(projectWorkspace, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  List<String> pathsOf(List<InstructionFile> files) =>
      [for (final f in files) p.relative(f.path, from: projectWorkspace)];

  test("nothing loaded when there are no AGENTS.md files", () async {
    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);
    expect(files, isEmpty);
  });

  test("the chat workspace file and the project file both load", () async {
    write("AGENTS.md", "project rules");
    write("chats/chat-1/AGENTS.md", "chat rules");

    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);

    expect(pathsOf(files), ["AGENTS.md", "chats/chat-1/AGENTS.md"]);
    expect(files.first.kind, InstructionKind.project);
    expect(files.last.kind, InstructionKind.chat);
  });

  test("an intermediate directory's AGENTS.md loads as project", () async {
    write("chats/AGENTS.md", "shared chat rules");
    write("chats/chat-1/AGENTS.md", "chat rules");

    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);

    expect(pathsOf(files), ["chats/AGENTS.md", "chats/chat-1/AGENTS.md"]);
    expect(files.first.kind, InstructionKind.project);
  });

  test("nothing above the project workspace is read", () async {
    write("AGENTS.md", "project rules");
    File(p.join(tmp.path, "AGENTS.md")).writeAsStringSync("outside rules");

    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);

    expect(pathsOf(files), ["AGENTS.md"]);
  });

  test("an empty file is skipped", () async {
    write("AGENTS.md", "   \n  ");
    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);
    expect(files, isEmpty);
  });

  test("a file over the cap is skipped", () async {
    write("AGENTS.md", "x" * (maxInstructionBytes + 1));
    final files = await loadInstructions(fileSystemIo,
        chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);
    expect(files, isEmpty);
  });

  group("imports", () {
    test("an @path reference pulls the file in after its importer", () async {
      write("AGENTS.md", "see @./notes.md");
      write("notes.md", "the notes");

      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);

      expect(pathsOf(files), ["AGENTS.md", "notes.md"]);
      expect(files.last.kind, InstructionKind.imported);
      expect(files.last.depth, 1);
    });

    test("imports are off by default", () async {
      write("AGENTS.md", "see @./notes.md");
      write("notes.md", "the notes");

      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace, projectWorkspace: projectWorkspace);

      expect(pathsOf(files), ["AGENTS.md"]);
    });

    test("a reference outside the workspaces is refused", () async {
      write("AGENTS.md", "see @/etc/passwd");
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      expect(pathsOf(files), ["AGENTS.md"]);
    });

    test("a missing import is left as text, not an error", () async {
      write("AGENTS.md", "see @./nope.md");
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      expect(pathsOf(files), ["AGENTS.md"]);
    });

    test("a chain deeper than the cap stops expanding", () async {
      write("AGENTS.md", "see @./a.md");
      for (var i = 0; i < maxImportDepth + 2; i++) {
        write("${String.fromCharCode(97 + i)}.md",
            "see @./${String.fromCharCode(98 + i)}.md");
      }
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      // The cap is on depth, not count: a chain of depth 5 loads 6 files.
      expect(files.length, maxImportDepth + 1);
    });

    test("a cycle stops rather than looping", () async {
      write("AGENTS.md", "see @./a.md");
      write("a.md", "see @./b.md");
      write("b.md", "see @./a.md");
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      expect(pathsOf(files), ["AGENTS.md", "a.md", "b.md"]);
    });

    test("code blocks and comments are not read as references", () async {
      write("AGENTS.md", "```\n@./a.md\n```\n<!-- @./b.md -->\nsee @./c.md");
      write("c.md", "c");
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      expect(pathsOf(files), ["AGENTS.md", "c.md"]);
    });
  });

  group("budget", () {
    test("a block over the budget drops the deepest files first", () async {
      write("AGENTS.md", "see @./a.md\n${"p" * 100}");
      write("a.md", "a" * (instructionBudgetChars - 50));
      final files = await loadInstructions(fileSystemIo,
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace,
          imports: true);
      // The imported file alone exceeds the budget, so it is dropped and the
      // root survives.
      expect(pathsOf(files), ["AGENTS.md"]);
    });
  });

  group("render", () {
    test("renders the header and each file with its kind", () {
      final text = renderInstructions([
        const InstructionFile(
            path: "/ws/AGENTS.md",
            kind: InstructionKind.project,
            content: "project rules"),
        const InstructionFile(
            path: "/ws/chats/1/AGENTS.md",
            kind: InstructionKind.chat,
            content: "chat rules"),
      ]);
      expect(text, contains("Workspace instructions are shown below."));
      expect(text, contains("Contents of /ws/AGENTS.md (project workspace instructions):"));
      expect(text, contains("Contents of /ws/chats/1/AGENTS.md (chat workspace instructions):"));
      expect(text, contains("project rules"));
      expect(text, contains("chat rules"));
    });

    test("renders nothing for an empty list", () {
      expect(renderInstructions(const []), isEmpty);
    });
  });

  group("nested", () {
    test("finds the nearest AGENTS.md above a read file", () async {
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {},
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace);
      expect(found.single.path, p.join(chatWorkspace, "sub", "AGENTS.md"));
    });

    test("skips files already loaded", () async {
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {p.join(chatWorkspace, "sub", "AGENTS.md")},
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace);
      expect(found, isEmpty);
    });

    test("a file outside the workspaces finds nothing", () async {
      final found = await findNestedInstructions(fileSystemIo,
          p.join(tmp.path, "elsewhere", "notes.txt"),
          alreadyLoaded: {},
          chatWorkspace: chatWorkspace,
          projectWorkspace: projectWorkspace);
      expect(found, isEmpty);
    });
  });
}
