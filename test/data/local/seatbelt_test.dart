import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/seatbelt.dart";
import "package:agent_chat/domain/shell.dart";

void main() {
  // `sandbox-exec` is run for real: what Seatbelt denies is decided in the
  // kernel, and nothing short of it says whether the profile does what it
  // claims. Only a Mac has it.
  final skip = Platform.isMacOS ? null : "Seatbelt is macOS's";

  late Directory root;
  late String workspace;
  late String outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync("entoli_seatbelt_");
    workspace = p.join(root.path, "a workspace with 'quotes' (and parens)");
    outside = p.join(root.path, "outside");
    Directory(workspace).createSync();
    Directory(outside).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> run(CommandSandbox sandbox, String script) async {
    final prefix = await SeatbeltSandboxHelper().prefixFor(sandbox);
    expect(prefix, isNotNull);
    return Process.run(prefix!.first, [
      ...prefix.skip(1),
      "/bin/bash",
      "-c",
      script,
    ]);
  }

  test("writes inside the grant and nowhere else, reading freely", () async {
    // The temp root is under /var, a symlink to /private/var: the grant only
    // matches because the helper resolves it.
    final result = await run(
      CommandSandbox(workspace: workspace),
      'echo in > "$workspace/in" && cat /etc/hosts >/dev/null && '
      'echo out > "$outside/out"',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains("Operation not permitted"));
    expect(File(p.join(workspace, "in")).readAsStringSync(), "in\n");
    expect(File(p.join(outside, "out")).existsSync(), isFalse);
  }, skip: skip);

  test("tmp and the extra writes are granted, a file as well as a "
      "directory", () async {
    final tmp = p.join(root.path, "tmp");
    final extraDir = p.join(root.path, "extra");
    final extraFile = p.join(outside, "granted.txt");
    Directory(tmp).createSync();
    Directory(extraDir).createSync();
    File(extraFile).writeAsStringSync("");

    final result = await run(
      CommandSandbox(
        workspace: workspace,
        tmp: tmp,
        extraWrites: [extraDir, extraFile],
      ),
      'echo t > "$tmp/t" && echo d > "$extraDir/d" && echo f > "$extraFile" '
      '&& echo x > /dev/null && echo n > "$outside/sibling"',
    );

    expect(result.exitCode, isNot(0));
    expect(File(p.join(tmp, "t")).existsSync(), isTrue);
    expect(File(p.join(extraDir, "d")).existsSync(), isTrue);
    expect(File(extraFile).readAsStringSync(), "f\n");
    expect(File(p.join(outside, "sibling")).existsSync(), isFalse);
  }, skip: skip);

  test("a missing binary fails closed", () async {
    final helper = SeatbeltSandboxHelper(binary: p.join(root.path, "none"));

    expect(await helper.prefixFor(CommandSandbox(workspace: workspace)), null);
  });

  test("a path not there yet resolves through its nearest ancestor", () {
    final real = Directory(root.path).resolveSymbolicLinksSync();

    expect(
      realPath(p.join(root.path, "not", "yet")),
      p.join(real, "not", "yet"),
    );
  }, skip: skip);
}
