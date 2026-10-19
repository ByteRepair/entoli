import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/web/guest_mux.dart";
import "package:agent_chat/data/web/guest_shell.dart";

/// `entoli-mux`'s half of the line, played by this machine's own processes:
/// the frames are the real ones, so the shell and [GuestMux] are tested
/// against the protocol rather than against a model of it.
class _MachineGuest {
  _MachineGuest() {
    // In order, as the real one reads its line: a write must not overtake
    // the spawn it is for.
    mux = GuestMux((line) => _queue = _queue.then((_) => _hear(line)));
    scheduleMicrotask(() => mux.receive("R"));
  }

  late final GuestMux mux;
  Future<void> _queue = Future.value();
  final Map<int, Process> _processes = {};
  final List<String> heard = [];

  void _say(String line) => scheduleMicrotask(() => mux.receive(line));

  List<String> _list(String field) =>
      utf8.decode(base64.decode(field)).split("\u0000");

  Future<void> _hear(String line) async {
    heard.add(line.split(" ").first);
    final f = line.split(" ");
    final id = f.length > 1 ? int.tryParse(f[1]) ?? 0 : 0;
    switch (f.first) {
      case "O":
        final argv = _list(f[2]);
        final env = {
          for (final kv in f.length > 4 && f[4].isNotEmpty ? _list(f[4]) : <String>[])
            kv.substring(0, kv.indexOf("=")): kv.substring(kv.indexOf("=") + 1),
        };
        final Process process;
        try {
          process = await Process.start("setsid", argv,
              workingDirectory: _list(f[3]).single, environment: env);
        } catch (e) {
          _say("F $id ${base64.encode(utf8.encode("$e"))}");
          return;
        }
        _processes[id] = process;
        // The real mux drops what a dead reader never read; so does this.
        process.stdin.done.ignore();
        var open = 2;
        void closed() {
          if (--open == 0) _say("E $id");
        }

        process.stdout.listen((d) => _say("D $id ${base64.encode(d)}"),
            onDone: closed);
        process.stderr.listen((d) => _say("D $id ${base64.encode(d)}"),
            onDone: closed);
        unawaited(process.exitCode.then((code) => _say(
            "X $id ${code < 0 ? 128 - code : code}")));
      case "I":
        try {
          _processes[id]?.stdin.add(base64.decode(f[2]));
        } on SocketException {
          // A shell that has exited.
        }
      case "C":
        await _processes[id]?.stdin.close();
      case "K":
        final process = _processes[id];
        if (process == null) return;
        final signal = f[2] == "2" ? ProcessSignal.sigint : ProcessSignal.sigkill;
        if (!Process.killPid(-process.pid, signal)) process.kill(signal);
    }
  }
}

void main() {
  late Directory temp;
  late _MachineGuest guest;
  late GuestShell shell;
  late String workspace;
  late String chat;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp("guest-shell");
    workspace = "${temp.path}/workspace";
    chat = "$workspace/chats/c1";
    guest = _MachineGuest();
    shell = GuestShell(
      guest: () async => guest.mux,
      available: () => true,
      description: () => "a test guest",
      environment: () => const {},
      fs: fileSystemIo,
    );
  });

  tearDown(() async {
    shell.closeSession(chat);
    await temp.delete(recursive: true);
  });

  Future<dynamic> run(String command,
          {Duration timeout = const Duration(seconds: 20),
          bool oneShot = false}) =>
      shell
          .start(command,
              cwd: chat, home: workspace, timeout: timeout, oneShot: oneShot)
          .result;

  test("a command's output and code come back, the sentinel stripped",
      () async {
    final result = await run("echo hello; exit_code() { return 3; }; exit_code");
    expect(result.returnCode, 3);
    expect(result.output, "hello\n");
    expect(result.cwd, chat);
  });

  test("the chat's shell keeps its directory and exports, and makes its cwd",
      () async {
    expect(Directory(chat).existsSync(), isFalse);
    await run("mkdir sub && cd sub && export SEEN=yes");
    final result = await run(r"pwd; echo $SEEN; echo $HOME");
    expect(result.output, "$chat/sub\nyes\n$workspace\n");
  });

  test("a stop is a Ctrl-C, and the shell keeps its state", () async {
    await run("cd /");
    final running = shell.start("sleep 30",
        cwd: chat, home: workspace, timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await running.kill();
    final result = await running.result;
    expect(result.returnCode, 130);
    expect(result.exceptionInfo, "The command was interrupted.");
    expect((await run("pwd")).output, "/\n");
  });

  test("a timeout interrupts the command", () async {
    final result = await run("sleep 30",
        timeout: const Duration(milliseconds: 300));
    expect(result.exceptionInfo, contains("timed out"));
  });

  test("an exit takes the shell down, and the next command has a new one",
      () async {
    await run("cd /");
    final gone = await run("exit 4");
    expect(gone.returnCode, 4);
    // LocalShell's contract: the command written while the shell is still
    // dying finds it gone, and whatever follows starts it again.
    await run("pwd");
    expect((await run("pwd")).output, "$chat\n");
  });

  test("a one-shot runs in a fresh shell and reports its exit", () async {
    await run("cd /");
    final result = await run("pwd; echo oops >&2; exit 2", oneShot: true);
    expect(result.returnCode, 2);
    expect(result.output, "$chat\noops\n");
  });

  test("a guest that does not come up fails the command with why", () async {
    final broken = GuestShell(
      guest: () async => throw StateError("no image"),
      available: () => true,
      description: () => "",
      environment: () => const {},
      fs: fileSystemIo,
    );
    final result = await broken
        .start("true", cwd: chat, home: workspace, timeout: const Duration(seconds: 5))
        .result;
    expect(result.returnCode, -1);
    expect(result.exceptionInfo, contains("no image"));
  });

  test("a large command crosses the line in frames", () async {
    final big = "x" * 200000;
    final result = await run("printf '%s' '$big' | wc -c");
    expect(result.output.trim(), "200000");
    expect(guest.heard.where((op) => op == "I").length, greaterThan(1));
  });
}
