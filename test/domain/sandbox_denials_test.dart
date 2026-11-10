import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/domain/sandbox_denials.dart";
import "package:agent_chat/domain/shell.dart";

void main() {
  late String root;
  late String workspace;
  late String outside;
  late CommandSandbox sandbox;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync("sandbox-denials-test");
    addTearDown(() => dir.deleteSync(recursive: true));
    root = dir.path;
    workspace = p.join(root, "ws");
    outside = p.join(root, "repo");
    Directory(workspace).createSync();
    Directory(outside).createSync();
    sandbox = CommandSandbox(
      workspace: workspace,
      tmp: p.join(root, "tmp"),
      home: "/home/u",
    );
  });

  List<String> denials(String output, {List<String> readOnly = const []}) =>
      sandboxDenials(output, sandbox, cwd: outside, readOnly: readOnly);

  test("reads the path each tool's error names", () {
    final file = p.join(outside, "f");
    // Seatbelt's EPERM and Landlock's EACCES, as BSD and GNU tools, the
    // shell, git, Python and Dart print them.
    for (final line in [
      "touch: $file: Operation not permitted",
      "touch: cannot touch '$file': Permission denied",
      "mkdir: cannot create directory ‘$file’: Permission denied",
      "/bin/sh: $file: Operation not permitted",
      "fatal: Unable to create '$file': Operation not permitted",
      "PermissionError: [Errno 1] Operation not permitted: '$file'",
      "FileSystemException: Cannot create file, path = '$file' "
          "(OS Error: Operation not permitted, errno = 1)",
    ]) {
      expect(denials(line), [file], reason: line);
    }
  });

  test("a relative path is read from where the command stood, ~ from the "
      "home", () {
    expect(denials("touch: lib/x: Operation not permitted"), [
      p.join(outside, "lib", "x"),
    ]);
    expect(denials("bash: ~/.zshrc: Permission denied"), ["/home/u/.zshrc"]);
  });

  test("a granted path, a read-only one and a program name are not "
      "denials", () {
    expect(denials("touch: $workspace/x: Operation not permitted"), isEmpty);
    expect(denials("cp: ${p.join(root, "tmp")}/x: Permission denied"), isEmpty);
    expect(
      denials(
        "touch: $outside/skill/x: Permission denied",
        readOnly: [p.join(outside, "skill")],
      ),
      isEmpty,
    );
    expect(
      denials("sandbox-exec: execvp() of 'ps' failed: Operation not permitted"),
      isEmpty,
    );
  });

  test("a failure that names no refused write is none", () {
    expect(denials(""), isEmpty);
    expect(
      denials("Some tests failed.\nerror: lib/x.dart:3: missing ;"),
      isEmpty,
    );
  });
}
