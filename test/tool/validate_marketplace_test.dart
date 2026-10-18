import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

void main() {
  test("--changed reads the diff under --data-root, not a fixed data/",
      () async {
    final repo = Directory.current.path;
    final tmp = await Directory.systemTemp.createTemp("marketplace");
    addTearDown(() => tmp.delete(recursive: true));
    // An entry with no README.md or SKILL.md: anything that checks it fails.
    await Directory(p.join(tmp.path, "market/skills/broken"))
        .create(recursive: true);
    final changed = File(p.join(tmp.path, "changed.txt"));
    await changed.writeAsString("A\tmarket/skills/broken/notes.txt\n");

    final run = await Process.run(
      "dart",
      [
        "--packages=${p.join(repo, ".dart_tool/package_config.json")}",
        p.join(repo, "tool/validate_marketplace.dart"),
        "--data-root",
        "market",
        "--changed",
        changed.path,
      ],
      workingDirectory: tmp.path,
    );

    expect(run.exitCode, 1, reason: "${run.stdout}${run.stderr}");
    expect(run.stderr, contains("market/skills/broken/SKILL.md"));
  });
}
