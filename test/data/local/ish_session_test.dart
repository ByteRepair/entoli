import "dart:async" show Completer;
import "dart:convert" show base64, utf8;

import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/ish_shell.dart";
import "package:agent_chat/domain/shell.dart";

/// The session logic of the iSH shell, over [FakeIshTransport] — the seam the
/// tests run through, since `ishLinked` is false everywhere the suite runs and
/// the worker would answer nothing. What is pinned here is what a command's
/// start, stop, timeout and close decide: that a stop reaches the bridge while
/// its run is still pending rather than queueing behind it, and what a guest
/// that ignores the SIGINT is answered with. That a real guest honours the
/// 130, and that a hangup unblocks a worker parked in its read, is confirmed
/// by hand on the simulator, the way the wire and the WebRTC are elsewhere.
void main() {
  const cwd = "/ws/chats/cb764c2a";
  const home = "/ws";

  IshShell ishShell(IshTransport transport) => IshShell(
        rootfsDir: () => "/rootfs",
        dataDir: "/data",
        environment: () => {},
        platformDescription: () => "iSH",
        transport: transport,
      );

  group("a session command", () {
    test("the cwd row is seeded with the guest's words, not the host path", () {
      final fake = FakeIshTransport();
      final shell = ishShell(fake);
      shell.sessionCwd("$home/chats/x", home: home);
      final notifier = shell.sessionCwd("$home/chats/x", home: home);
      expect(notifier!.value, "/root/chats/x");
    });

    test("a stop is delivered while the run is pending, and ends it", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport();
        final shell = ishShell(fake);
        final run = shell.start("sleep 60",
            cwd: cwd, home: home, timeout: const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(fake.runs.single, base64.encode(utf8.encode("sleep 60")));
        final handle = fake.lastHandle!;
        expect(fake.destroys, isEmpty);

        await run.kill();
        expect(fake.interrupts, [handle]);
        expect(fake.hangups, isEmpty);
        final result = await run.result;
        expect(result.returnCode, 130);
        expect(fake.destroys, isEmpty);
      });
    });

    test("a guest that ignores the SIGINT is hung up a second later", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..interruptEnds = false;
        final shell = ishShell(fake);
        final run = shell.start("trap '' INT; sleep 60",
            cwd: cwd, home: home, timeout: const Duration(minutes: 5));
        async.flushMicrotasks();
        final handle = fake.lastHandle!;
        final session = fake.lastSession!;

        await run.kill();
        expect(fake.interrupts, [handle]);
        // The guest ignored it; the run is still in the worker's hands.
        expect(fake.pendingSessions, isNotEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(fake.hangups, [handle]);
        final result = await run.result;
        expect(result.returnCode, -1);
        expect(result.exceptionInfo, "The command did not complete.");
        expect(fake.destroys, [session]);
      });
    });

    test("the timeout interrupts on its own, then escalates the same way", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..interruptEnds = false;
        final shell = ishShell(fake);
        final run = shell.start("sleep 60",
            cwd: cwd, home: home, timeout: const Duration(seconds: 2));
        async.flushMicrotasks();
        final handle = fake.lastHandle!;

        async.elapse(const Duration(seconds: 2));
        expect(fake.interrupts, [handle]);
        expect(fake.hangups, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(fake.hangups, [handle]);
        final result = await run.result;
        expect(result.returnCode, -1);
      });
    });

    test("a command after a hung-up run starts a session cold", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..interruptEnds = false;
        final shell = ishShell(fake);
        shell.start("sleep 60",
            cwd: cwd, home: home, timeout: const Duration(seconds: 2));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        expect(fake.destroys, isNotEmpty);

        shell.start("echo hi",
            cwd: cwd, home: home, timeout: const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(fake.inits.length, 2);
        expect(fake.runs.length, 2);
      });
    });

    test("an init that fails completes the run failed", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..initError = "no rootfs";
        final shell = ishShell(fake);
        final run = shell.start("echo hi",
            cwd: cwd, home: home, timeout: const Duration(minutes: 5));
        final result = await run.result;
        expect(result.exceptionInfo, contains("no rootfs"));
      });
    });

    test("a session command says so where no iSH is linked, and stays cold",
        () async {
      final fake = FakeIshTransport()..answersNotLinked = true;
      final shell = ishShell(fake);
      final run = shell.start("echo hi",
          cwd: cwd, home: home, timeout: const Duration(minutes: 5));
      final result = await run.result;
      expect(result.exceptionInfo, contains("not available"));
      expect(fake.runs, isEmpty);
      expect(fake.destroys, isEmpty);
      // Nothing was taken for an id, so a next command inits again rather
      // than reusing one the worker never had.
      shell.start("echo hi",
          cwd: cwd, home: home, timeout: const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      expect(fake.inits.length, 2);
    });
  });

  group("close", () {
    test("answers every run the session holds, queued ones included", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport();
        final shell = ishShell(fake);
        final first = shell.start("a", cwd: cwd, home: home,
            timeout: const Duration(minutes: 5));
        final second = shell.start("b", cwd: cwd, home: home,
            timeout: const Duration(minutes: 5));
        async.flushMicrotasks();
        final session = fake.lastSession!;

        shell.closeSession(cwd);
        expect(fake.destroys, [session]);
        // The queued body is answered, not booted: one init, one guest.
        expect(fake.inits.length, 1);
        final one = await first.result;
        final two = await second.result;
        expect(one.exceptionInfo, contains("restarted"));
        expect(two.exceptionInfo, contains("restarted"));
      });
    });
  });

  group("a one-shot run", () {
    test("interrupts and escalates like a session's", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..interruptEnds = false;
        final shell = ishShell(fake);
        final run = shell.start("sleep 60",
            cwd: cwd,
            home: home,
            timeout: const Duration(minutes: 5),
            oneShot: true);
        async.flushMicrotasks();
        final handle = fake.lastHandle!;

        await run.kill();
        expect(fake.interrupts, [handle]);
        async.elapse(const Duration(seconds: 1));
        expect(fake.hangups, [handle]);
        final result = await run.result;
        expect(result.returnCode, -1);
        expect(fake.destroys, isNotEmpty);
      });
    });

    test("says so where no iSH is linked, without running anything", () {
      fakeAsync((async) async {
        final fake = FakeIshTransport()..answersNotLinked = true;
        final shell = ishShell(fake);
        final run = shell.start("echo hi",
            cwd: cwd,
            home: home,
            timeout: const Duration(minutes: 5),
            oneShot: true);
        final result = await run.result;
        expect(result.exceptionInfo, contains("not available"));
        expect(fake.runs, isEmpty);
        expect(fake.destroys, isEmpty);
      });
    });
  });

  group("two sessions", () {
    test("another chat's command answers while a run holds the first",
        () async {
      final fake = FakeIshTransport();
      final shell = ishShell(fake);
      final a = shell.start("sleep 30",
          cwd: "$home/chats/a",
          home: home,
          timeout: const Duration(minutes: 5));
      final b = shell.start("echo hi",
          cwd: "$home/chats/b",
          home: home,
          timeout: const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      // Both sessions were served: two guests, two inits, two pending runs.
      expect(fake.pendingSessions.length, 2);
      final bId = fake.pendingSessions.last;
      fake._settle(bId, const ShellResult(returnCode: 0, output: "hi"));
      expect((await b.result).returnCode, 0);
      // A's run was never touched by B's answer.
      expect(fake.pendingSessions.length, 1);
      fake._settle(fake.pendingSessions.single,
          const ShellResult(returnCode: 130, output: ""));
      expect((await a.result).returnCode, 130);
    });

    test("closing one session destroys its guest and not the other's",
        () async {
      final fake = FakeIshTransport();
      final shell = ishShell(fake);
      shell.start("sleep 30",
          cwd: "$home/chats/a",
          home: home,
          timeout: const Duration(minutes: 5));
      final b = shell.start("echo hi",
          cwd: "$home/chats/b",
          home: home,
          timeout: const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      final bId = fake.pendingSessions.last;

      shell.closeSession("$home/chats/a");
      expect(fake.destroys, isNot(contains(bId)));
      expect(fake.pendingSessions, [bId]);
      fake._settle(bId, const ShellResult(returnCode: 0, output: ""));
      expect((await b.result).returnCode, 0);
    });
  });

  group("a worker isolate", () {
    test("one spawn answers two concurrent first users", () async {
      final worker = IshWorker();
      await Future.wait([
        worker.ensureStarted(),
        worker.ensureStarted(),
      ]);
      expect(worker.spawnCount, 1);
    });
  });
}

/// What the worker would answer, in the test's hands. Sessions are handed
/// out straight away; a run is held in [pendingSessions] until the test or
/// the fake's own rules — the interrupt's 130, the hangup's "did not
/// complete" — resolve it, which is how the timing of a stop against a run
/// is pinned without a real guest.
class FakeIshTransport implements IshTransport {
  int _nextSession = 0;
  int _nextHandle = 0x1000;

  /// init throws this where set.
  String? initError;

  /// init answers not-linked where true: id -1, no handle.
  bool answersNotLinked = false;

  /// interrupt answers its run with the dispatcher's 130 where true; where
  /// false the guest ignored the SIGINT and the run stays pending for the
  /// hangup.
  bool interruptEnds = true;

  final List<String> inits = [];
  final List<String> runs = [];
  final List<int> interrupts = [];
  final List<int> hangups = [];
  final List<int> destroys = [];
  final Map<int, Completer<ShellResult>> pending = {};

  /// The sessions whose run is still held — what the test asks to tell a run
  /// the worker would still be parked in from one already over.
  List<int> get pendingSessions => pending.keys.toList();

  int? lastSession;
  int? lastHandle;

  ShellResult hungUp(int sessionId) => ShellResult(
        returnCode: -1,
        output: "",
        exceptionInfo: "The command did not complete.",
      );

  void _settle(int sessionId, ShellResult result) {
    final c = pending.remove(sessionId);
    if (c != null && !c.isCompleted) c.complete(result);
  }

  @override
  Future<({int sessionId, int handle})> init({
    required String rootfsDir,
    required String dataDir,
    required String home,
    required String cwd,
    required Map<String, String> env,
  }) async {
    if (initError != null) throw StateError(initError!);
    inits.add(cwd);
    _nextSession++;
    _nextHandle++;
    lastSession = _nextSession;
    lastHandle = answersNotLinked ? null : _nextHandle;
    return answersNotLinked
        ? (sessionId: -1, handle: 0)
        : (sessionId: _nextSession, handle: _nextHandle);
  }

  @override
  Future<ShellResult> run({
    required int sessionId,
    required String scriptB64,
    required Duration timeout,
  }) {
    runs.add(scriptB64);
    final c = pending.putIfAbsent(sessionId, Completer.new);
    return c.future;
  }

  @override
  void interrupt(int handle) {
    interrupts.add(handle);
    if (interruptEnds) {
      pending.keys.toList().forEach(
          (id) => _settle(id, const ShellResult(returnCode: 130, output: "")));
    }
  }

  @override
  void hangup(int handle) {
    hangups.add(handle);
    pending.keys.toList().forEach((id) => _settle(id, hungUp(id)));
  }

  @override
  void destroy(int sessionId) {
    destroys.add(sessionId);
    pending.remove(sessionId);
  }

  @override
  void stop() {}
}
