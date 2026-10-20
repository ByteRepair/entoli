import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/memory/instructions.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  late Directory tmp;
  late String dataDir;
  late String projectWorkspace;
  late String chatWorkspace;
  late String global;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("instructions_test_");
    dataDir = p.join(tmp.path, "data");
    projectWorkspace = p.join(dataDir, "projects", "default", "workspace");
    chatWorkspace = p.join(projectWorkspace, "chats", "chat-1");
    Directory(chatWorkspace).createSync(recursive: true);
    global = p.join(dataDir, "AGENTS.md");
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final file = File(p.join(projectWorkspace, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writeGlobal(String content) {
    final file = File(global);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<List<InstructionFile>> load(
          {bool imports = false, List<String> excludes = const []}) =>
      loadInstructions(fileSystemIo,
          projectWorkspace: projectWorkspace,
          global: global,
          imports: imports,
          excludes: excludes);

  List<String> pathsOf(List<InstructionFile> files) =>
      [for (final f in files) p.relative(f.path, from: dataDir)];

  test("nothing loaded when there are no AGENTS.md files", () async {
    expect(await load(), isEmpty);
  });

  test("the global file loads first, before the project's", () async {
    writeGlobal("global rules");
    write("AGENTS.md", "project rules");

    final files = await load();

    expect(pathsOf(files), ["AGENTS.md", "projects/default/workspace/AGENTS.md"]);
    expect(files.first.kind, InstructionKind.global);
    expect(files.last.kind, InstructionKind.project);
  });

  // Only the workspace root's AGENTS.md loads: the chat's own and any
  // intermediate directory's wait for a read reaching them.
  test("a chat's own AGENTS.md is not loaded up front", () async {
    write("AGENTS.md", "project rules");
    write("chats/chat-1/AGENTS.md", "chat rules");
    write("chats/AGENTS.md", "shared chat rules");

    final files = await load();

    expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    expect(files.single.kind, InstructionKind.project);
  });

  test("nothing above the project workspace is read, the global named aside",
      () async {
    write("AGENTS.md", "project rules");
    File(p.join(tmp.path, "AGENTS.md")).writeAsStringSync("outside rules");
    File(p.join(dataDir, "elsewhere", "AGENTS.md"))
      ..createSync(recursive: true)
      ..writeAsStringSync("a data dir file");

    final files = await load();

    expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
  });

  test("an empty file is skipped", () async {
    writeGlobal("   \n  ");
    write("AGENTS.md", "project rules");
    expect(pathsOf(await load()), ["projects/default/workspace/AGENTS.md"]);
  });

  test("a file over the cap is skipped", () async {
    write("AGENTS.md", "x" * (maxInstructionBytes + 1));
    expect(await load(), isEmpty);
  });

  group("imports", () {
    test("an @path reference pulls the file in after its importer", () async {
      write("AGENTS.md", "see @./notes.md");
      write("notes.md", "the notes");

      final files = await load(imports: true);

      expect(
          pathsOf(files),
          ["projects/default/workspace/AGENTS.md",
              "projects/default/workspace/notes.md"]);
      expect(files.last.kind, InstructionKind.imported);
      expect(files.last.depth, 1);
    });

    test("imports are off by default", () async {
      write("AGENTS.md", "see @./notes.md");
      write("notes.md", "the notes");

      final files = await load();

      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("a reference in the global file is left as text", () async {
      writeGlobal("see @./global-notes.md");
      write("AGENTS.md", "project rules");

      final files = await load(imports: true);

      expect(pathsOf(files), ["AGENTS.md", "projects/default/workspace/AGENTS.md"]);
    });

    test("a reference outside the workspaces is refused", () async {
      write("AGENTS.md", "see @/etc/passwd");
      final files = await load(imports: true);
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("a missing import is left as text, not an error", () async {
      write("AGENTS.md", "see @./nope.md");
      final files = await load(imports: true);
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("a chain deeper than the cap stops expanding", () async {
      write("AGENTS.md", "see @./a.md");
      for (var i = 0; i < maxImportDepth + 2; i++) {
        write("${String.fromCharCode(97 + i)}.md",
            "see @./${String.fromCharCode(98 + i)}.md");
      }
      final files = await load(imports: true);
      // The cap is on depth, not count: a chain of depth 5 loads 6 files.
      expect(files.length, maxImportDepth + 1);
    });

    test("a cycle stops rather than looping", () async {
      write("AGENTS.md", "see @./a.md");
      write("a.md", "see @./b.md");
      write("b.md", "see @./a.md");
      final files = await load(imports: true);
      expect(
          pathsOf(files),
          ["projects/default/workspace/AGENTS.md",
              "projects/default/workspace/a.md",
              "projects/default/workspace/b.md"]);
    });

    test("code blocks and comments are not read as references", () async {
      write("AGENTS.md", "```\n@./a.md\n```\n<!-- @./b.md -->\nsee @./c.md");
      write("c.md", "c");
      final files = await load(imports: true);
      expect(
          pathsOf(files),
          ["projects/default/workspace/AGENTS.md",
              "projects/default/workspace/c.md"]);
    });
  });

  group("budget", () {
    test("a block over the budget drops the deepest files first", () async {
      write("AGENTS.md", "see @./a.md\n${"p" * 100}");
      write("a.md", "a" * (instructionBudgetChars - 50));
      final files = await load(imports: true);
      // The imported file alone exceeds the budget, so it is dropped and the
      // root survives.
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("the global file is dropped before the project's", () async {
      writeGlobal("g" * (instructionBudgetChars - 50));
      write("AGENTS.md", "p" * (instructionBudgetChars - 50));
      final files = await load();
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });
  });

  group("render", () {
    test("renders the header and each file with its kind", () {
      final text = renderInstructions([
        const InstructionFile(
            path: "/data/AGENTS.md",
            kind: InstructionKind.global,
            content: "global rules"),
        const InstructionFile(
            path: "/ws/AGENTS.md",
            kind: InstructionKind.project,
            content: "project rules"),
        const InstructionFile(
            path: "anonymous",
            kind: InstructionKind.bundled,
            content: "this is an anonymous chat"),
      ]);
      expect(text, contains("Workspace instructions are shown below."));
      expect(
          text,
          contains("Contents of /data/AGENTS.md "
              "(the user's global instructions, for every project):"));
      expect(text,
          contains("Contents of /ws/AGENTS.md (project workspace instructions):"));
      expect(text,
          contains("From the app, about this kind of chat:\n\n"
              "this is an anonymous chat"));
      expect(text, isNot(contains("Contents of anonymous")));
      expect(text, isNot(contains("IMPORTANT")));
      expect(text, contains("global rules"));
      expect(text, contains("project rules"));
      expect(text, contains("this is an anonymous chat"));

      // Nothing to render: nothing.
      expect(renderInstructions(const []), isEmpty);
    });
  });

  group("excludes", () {
    test("** spans directories, * and ? do not", () {
      final path = "/data/projects/work/workspace/vendor/lib/AGENTS.md";
      expect(isExcludedPath(fileSystemIo, path, ["**/vendor/**"]), isTrue);
      expect(isExcludedPath(fileSystemIo, path, ["**/vendor"]), isFalse);
      expect(isExcludedPath(fileSystemIo, path,
              ["/data/projects/*/workspace/AGENTS.md"]),
          isFalse);
      expect(isExcludedPath(fileSystemIo,
              "/data/projects/work/workspace/AGENTS.md",
              ["/data/projects/*/workspace/AGENTS.md"]),
          isTrue);
      expect(isExcludedPath(fileSystemIo, path, ["/data/projects/*/AGENTS.md"]),
          isFalse);
      expect(
          isExcludedPath(fileSystemIo, path,
              ["/data/projects/wor?/workspace/vendor/lib/AGENTS.md"]),
          isTrue);
      expect(isExcludedPath(fileSystemIo, path, const []), isFalse);
      expect(isExcludedPath(fileSystemIo, path, ["", "  "]), isFalse);
    });

    test("a pattern without a slash names a file name, anywhere", () {
      expect(
          isExcludedPath(fileSystemIo, "/a/b/AGENTS.md", ["AGENTS.md"]),
          isTrue);
      expect(isExcludedPath(fileSystemIo, "/a/b/notes.md", ["AGENTS.md"]),
          isFalse);
      expect(isExcludedPath(fileSystemIo, "/a/b/AGENTS.md", ["*.md"]), isTrue);
    });

    test("a project file the pattern names is not loaded", () async {
      write("AGENTS.md", "project rules");
      final files = await load(
          excludes: ["$projectWorkspace/AGENTS.md"]);
      expect(files, isEmpty);
    });

    test("a global file the pattern names is not loaded", () async {
      writeGlobal("global rules");
      write("AGENTS.md", "project rules");
      final files = await load(excludes: [global]);
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("an import the pattern names is not expanded", () async {
      write("AGENTS.md", "see @./notes.md");
      write("notes.md", "the notes");
      final files = await load(
          imports: true, excludes: ["**/notes.md"]);
      expect(pathsOf(files), ["projects/default/workspace/AGENTS.md"]);
    });

    test("a nested file the pattern names is not pulled in by a read",
        () async {
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {},
          excludes: ["**/sub/AGENTS.md"]);
      expect(found, isEmpty);
    });
  });

  group("nested", () {
    test("finds the nearest AGENTS.md above a read file", () async {
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {});
      expect(found.single.path, p.join(chatWorkspace, "sub", "AGENTS.md"));
    });

    test("a nested file above the project root's own loads too", () async {
      write("AGENTS.md", "project rules");
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {p.join(projectWorkspace, "AGENTS.md")});
      expect(found.single.path, p.join(chatWorkspace, "sub", "AGENTS.md"));
    });

    test("skips files already loaded", () async {
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {p.join(chatWorkspace, "sub", "AGENTS.md")});
      expect(found, isEmpty);
    });

    test("a file outside the workspaces finds its repository's", () async {
      final repo = p.join(tmp.path, "elsewhere");
      Directory(p.join(repo, "src")).createSync(recursive: true);
      File(p.join(repo, "AGENTS.md")).writeAsStringSync("repo rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(repo, "src", "notes.txt"),
          alreadyLoaded: {});
      expect(found.single.path, p.join(repo, "AGENTS.md"));
    });

    test("walks past the project workspace's root", () async {
      File(p.join(tmp.path, "AGENTS.md")).writeAsStringSync("above rules");
      write("chats/chat-1/sub/AGENTS.md", "sub rules");
      final found = await findNestedInstructions(fileSystemIo,
          p.join(chatWorkspace, "sub", "notes.txt"),
          alreadyLoaded: {});
      expect(found.map((f) => f.path), [
        p.join(chatWorkspace, "sub", "AGENTS.md"),
        p.join(tmp.path, "AGENTS.md"),
      ]);
    });
  });
}
