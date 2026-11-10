import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/models.dart" show JobEnd;
import "../../domain/shell.dart";
import "../../domain/shell_job.dart";

/// Every chat's background jobs, held by the backend so a job outlives the
/// turn that started it. The agent starts them through a chat's [ChatJobs];
/// the chat page reaches the same object as a [ChatShellJobs]; the next tool
/// call the agent makes in that chat, this turn or a later one, hears how the
/// ended ones ended.
class BackgroundJobs {
  BackgroundJobs();

  /// How long one may run before it is killed. A job nobody stopped is still
  /// a process the user did not ask to keep forever.
  static const timeout = Duration(hours: 12);

  final _chats = <String, ChatJobs>{};

  ChatJobs forChat(String chatId) =>
      _chats.putIfAbsent(chatId, () => ChatJobs._());

  /// Kill [chatId]'s jobs and forget them: the chat is being deleted.
  Future<void> closeChat(String chatId) async =>
      _chats.remove(chatId)?._close();

  /// Kill every job: the app is going.
  Future<void> close() => Future.wait([..._chats.keys].map(closeChat));
}

/// What a job's shell runs: its streams pointed at its log and at nothing
/// before [command] starts, so a child it leaves behind holds no pipe of the
/// app's, then [command] as written — from [startIn] where the chat's
/// commands have moved, so a job runs where the commands before it did. The
/// log is opened first, so it lands in the workspace wherever the job runs.
/// A log that cannot be opened ends the job there rather than letting it
/// print into the app.
String backgroundScript(String callId, String command, {String? startIn}) =>
    "mkdir -p .entoli-jobs; exec >${backgroundLog(callId)} 2>&1 </dev/null || exit 1\n"
    "${startIn == null ? "" : "cd -- ${shellQuoted(startIn)} || exit 1\n"}"
    "$command";

/// One chat's jobs.
class ChatJobs implements ChatShellJobs {
  ChatJobs._();

  @override
  final ValueNotifier<List<ShellJob>> jobs = ValueNotifier(const []);
  final _runs = <int, ShellRun>{};

  /// The ends the agent has not heard yet, by job: what the next tool result
  /// words as its notes, and what the room asks after when a turn is over.
  final _unheard = <int, EndedJob>{};
  // Synchronous, so a listener has the end before the list drops the job: the
  // chat never reads a job as neither running nor ended.
  final _ended = StreamController<EndedJob>.broadcast(sync: true);

  @override
  Stream<EndedJob> get ended => _ended.stream;

  /// What the agent and the pill call a job. Not what names its log, so
  /// starting again with the app overwrites nothing.
  int _count = 0;

  /// Start [command] as the next job for the call [callId], [spawn] running
  /// the script it is wrapped in from [workspace], where its log lands.
  Future<ShellJob> start(
    String command, {
    required String callId,
    required String workspace,
    String? startIn,
    required ShellRun Function(String script) spawn,
  }) async {
    final id = ++_count;
    final run = spawn(backgroundScript(callId, command, startIn: startIn));
    _runs[id] = run;
    final job = ShellJob(
      id: id,
      callId: callId,
      command: command,
      logPath: p.join(workspace, backgroundLog(callId)),
      pid: await run.pid,
    );
    jobs.value = [...jobs.value, job];
    unawaited(run.result.then((r) => _end(job, r.returnCode)));
    return job;
  }

  Future<void> _end(ShellJob job, int code) async {
    if (_runs.remove(job.id) == null) return;
    var log = "";
    try {
      final file = File(job.logPath);
      log = await _tail(file, file.statSync().size);
    } catch (e) {
      logFailure("jobs", "could not read the log of job ${job.id}", e);
    }
    final ended = (
      callId: job.callId,
      command: job.command,
      end: JobEnd(
        jobId: job.id,
        exitCode: code == -1 ? null : code,
        tail: jobTail(log),
      ),
    );
    _unheard[job.id] = ended;
    if (!_ended.isClosed) _ended.add(ended);
    jobs.value = [
      for (final j in jobs.value)
        if (j.id != job.id) j,
    ];
  }

  /// How the jobs that ended since the last call ended, once each.
  List<String> takeNotes() {
    final notes = [
      for (final (:command, :end, callId: _) in _unheard.values)
        "Background job ${end.jobId} (`${firstLine(command)}`) "
            "${end.exitCode == null ? "was stopped" : "exited with code ${end.exitCode}"}.",
    ];
    _unheard.clear();
    return notes;
  }

  @override
  void told(int id) => _unheard.remove(id);

  @override
  List<EndedJob> get unheard => [..._unheard.values];

  @override
  Future<void> stop(int id) async => _runs[id]?.kill();

  static const _tailBytes = 32 * 1024;

  @override
  Stream<String> log(
    ShellJob job, {
    Duration every = const Duration(milliseconds: 500),
  }) {
    final file = File(job.logPath);
    late final StreamController<String> out;
    Timer? timer;
    var busy = false;
    (int, DateTime)? seen;
    String? last;
    // Read again only where the file changed; close once a read after the
    // job ended has had what it printed last.
    Future<void> tick() async {
      if (busy || out.isClosed) return;
      busy = true;
      final ended = !_runs.containsKey(job.id);
      final stat = file.statSync();
      final now = (stat.size, stat.modified);
      if (stat.type != FileSystemEntityType.notFound && now != seen) {
        seen = now;
        final text = await _tail(file, stat.size);
        if (text != last && !out.isClosed) out.add(last = text);
      }
      busy = false;
      if (ended) {
        timer?.cancel();
        await out.close();
      }
    }

    out = StreamController<String>(
      onListen: () {
        unawaited(tick());
        timer = Timer.periodic(every, (_) => unawaited(tick()));
      },
      onCancel: () => timer?.cancel(),
    );
    return out.stream;
  }

  Future<String> _tail(File file, int size) async {
    final bytes = BytesBuilder(copy: false);
    await file.openRead(max(0, size - _tailBytes), size).forEach(bytes.add);
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<void> _close() async {
    final runs = [..._runs.values];
    _runs.clear();
    jobs.dispose();
    await _ended.close();
    await Future.wait(runs.map((r) => r.kill()));
  }
}
