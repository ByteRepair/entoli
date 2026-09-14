import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/landlock.dart";
import "package:agent_chat/domain/shell.dart";

void main() {
  // The helper is compiled and run for real: Landlock is a kernel API, and
  // the whole of what it denies is decided there. A kernel older than 5.13
  // skips the confinement assertions; everything else still holds.
  late Directory cache;
  late Directory tmp;
  late LandlockSandboxHelper helper;

  /// Runs [script] through the helper, the way a confined command runs.
  late Future<({int code, String out, String err})> Function(String script,
      {CommandSandbox? sandboxOverride}) run0;

  setUpAll(() async {
    cache = Directory.systemTemp.createTempSync("agent_chat_landlock_");
    tmp = Directory(p.join(cache.path, "tmp"))..createSync();
    final helper0 = LandlockSandboxHelper(cacheDir: cache.path);
    final sandbox = CommandSandbox(
        workspace: p.join(cache.path, "ws"), tmp: tmp.path);
    Directory(sandbox.workspace).createSync();
    // The first prefix compiles the helper; a machine without the kernel or
    // the compiler answers null and every confined assertion is skipped.
    final prefix = await helper0.prefixFor(sandbox);
    helper = helper0;
    if (!Platform.isLinux) return;
    landlockUsable = prefix != null;
    if (prefix == null) return;
    // The helper's own shape: helper exec --workspace ... -- argv...
    Future<({int code, String out, String err})> confinedRun(String script,
        {CommandSandbox? sandboxOverride}) async {
      final s = sandboxOverride ?? sandbox;
      final prefixNow = await helper.prefixFor(s);
      final result = await Process.start(prefixNow!.first,
          [...prefixNow.skip(1), "/bin/sh", "-c", script],
          workingDirectory: s.workspace,
          environment: {"PATH": "/usr/bin:/bin", "HOME": cache.path});
      final out = StringBuffer();
      final err = StringBuffer();
      // Drained to completion rather than read after the exit code: the
      // process's exit event is not ordered after the last pipe chunk
      // through the event loop, and under load the tail of a pipe — the
      // "Permission denied" line, the last echo — loses that race. Both
      // futures together are the process being over.
      final drained = Future.wait([
        result.stdout.transform(const SystemEncoding().decoder).forEach(out.write),
        result.stderr.transform(const SystemEncoding().decoder).forEach(err.write),
      ]);
      final code = await result.exitCode;
      await drained;
      return (code: code, out: out.toString(), err: err.toString());
    }

    run0 = confinedRun;
  });

  tearDownAll(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test("the helper compiles once and is reused", () async {
    if (!Platform.isLinux) return;
    final sandbox = CommandSandbox(
        workspace: p.join(cache.path, "ws"), tmp: tmp.path);
    final first = await helper.prefixFor(sandbox);
    final second = await helper.prefixFor(sandbox);
    expect(first, isNotNull);
    expect(second, first);
  });

  test("a write inside the workspace is allowed", () async {
    if (!landlockUsable) return;
    final r = await run0("echo test > written.txt");
    expect(r.code, 0, reason: "out=${r.out} err=${r.err}");
  });

  test("a write outside the workspace is denied by the kernel", () async {
    if (!landlockUsable) return;
    final outside = p.join(cache.path, "outside.txt");
    File(outside).writeAsStringSync("keep\n");
    final r = await run0("echo test > $outside");
    expect(r.err, contains("Permission denied"));
    expect(File(outside).readAsStringSync(), "keep\n",
        reason: "the denial took nothing away that was already there");
  });

  test("reading outside the workspace is allowed", () async {
    if (!landlockUsable) return;
    final outside = p.join(cache.path, "outside.txt");
    File(outside).writeAsStringSync("readable\n");
    final r = await run0("cat $outside");
    expect(r.out, contains("readable"));
  });

  test("a write into HOME's profile files is denied", () async {
    if (!landlockUsable) return;
    final home = Directory(p.join(cache.path, "home"))..createSync();
    File(p.join(home.path, ".bashrc")).writeAsStringSync("orig\n");
    final r = await run0("echo evil >> ${home.path}/.bashrc",
        sandboxOverride: CommandSandbox(
            workspace: p.join(cache.path, "ws"),
            tmp: tmp.path,
            home: home.path));
    expect(r.err, contains("Permission denied"));
    expect(File(p.join(home.path, ".bashrc")).readAsStringSync(), "orig\n");
  });

  test("a write into tmp is allowed", () async {
    if (!landlockUsable) return;
    final r = await run0("echo scratch > ${tmp.path}/x.txt");
    expect(r.code, 0);
  });

  test("git works inside the workspace", () async {
    if (!landlockUsable) return;
    final r = await run0(
        "cd ${p.join(cache.path, "ws")} && git init -q . 2>/dev/null; "
        "git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x");
    expect(r.code, 0, reason: "git needs /dev/null and a writable workspace");
  });

  test("a command that throws away output through /dev/null runs", () async {
    if (!landlockUsable) return;
    final r = await run0("echo noisy > /dev/null && echo quiet");
    expect(r.out.trim(), "quiet");
  });

  test("creating a file or a symlink outside the workspace is denied", () async {
    // A first draft of this ruleset left MAKE_REG and MAKE_SYM unhandled,
    // and an unhandled right is granted everywhere — a confined command
    // could create a symlink at a well-known path outside its boundary.
    if (!landlockUsable) return;
    final home = Directory(p.join(cache.path, "home"))..createSync();
    final r = await run0(
        "touch ${home.path}/new.txt; ln -s /etc/passwd ${home.path}/link",
        sandboxOverride: CommandSandbox(
            workspace: p.join(cache.path, "ws"),
            tmp: tmp.path,
            home: home.path));
    expect(r.err, contains("Permission denied"));
    expect(File(p.join(home.path, "new.txt")).existsSync(), isFalse,
        reason: "a make outside the granted set is a refusal, not a hole");
    expect(File(p.join(home.path, "link")).existsSync(), isFalse);
  });

  test("a file and a symlink are created inside the workspace", () async {
    if (!landlockUsable) return;
    final r = await run0("touch in.txt && ln -s in.txt link && echo made");
    expect(r.out.trim(), "made");
  });

  test("the violations note names what was denied", () {
    final note = CommandSandbox.violationsNote(["writing /etc/passwd"]);
    expect(note, contains("/etc/passwd"));
    expect(note, contains("sandbox"));
  });
}

/// Whether the helper is there on this machine. Set by `setUpAll`'s first
/// prefix build; every confined test is skipped where it is false, which is
/// what a kernel without Landlock or a machine without a compiler answers.
bool landlockUsable = false;

dynamic run0;