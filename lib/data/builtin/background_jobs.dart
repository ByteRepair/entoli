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
/// app's, then [command] as written. A log that cannot be opened ends the
/// job there rather than letting it print into the app.
String backgroundScript(String callId, String command) =>
    "mkdir -p .entoli-jobs; exec >${backgroundLog(callId)} 2>&1 </dev/null || exit 1\n"
    "$command";

/// One chat's jobs.
class ChatJobs implements ChatShellJobs {
  ChatJobs._();

  @override
  final ValueNotifier<List<ShellJob>> jobs = ValueNotifier(const []);
  final _runs = <int, ShellRun>{};
  final _notes = <String>[];
  // Synchronous, so a listener has the end before the list drops the job: the
  // chat never reads a job as neither running nor ended.
  final _ended =
      StreamController<({String callId, JobEnd end})>.broadcast(sync: true);

  @override
  Stream<({String callId, JobEnd end})> get ended => _ended.stream;

  /// What the agent and the pill call a job. Not what names its log, so
  /// starting again with the app overwrites nothing.
  int _count = 0;

  /// Start [command] as the next job for the call [callId], [spawn] running
  /// the script it is wrapped in from [workspace], where its log lands.
  Future<ShellJob> start(String command,
      {required String callId,
      required String workspace,
      required ShellRun Function(String script) spawn}) async {
    final id = ++_count;
    final run = spawn(backgroundScript(callId, command));
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
    final how = code == -1 ? "was stopped" : "exited with code $code";
    _notes.add("Background job ${job.id} (`${firstLine(job.command)}`) $how.");
    var log = "";
    try {
      final file = File(job.logPath);
      log = await _tail(file, file.statSync().size);
    } catch (e) {
      logFailure("jobs", "could not read the log of job ${job.id}", e);
    }
    if (!_ended.isClosed) {
      _ended.add((
        callId: job.callId,
        end: JobEnd(
          jobId: job.id,
          exitCode: code == -1 ? null : code,
          tail: jobTail(log),
        ),
      ));
    }
    jobs.value = [for (final j in jobs.value) if (j.id != job.id) j];
  }

  /// How the jobs that ended since the last call ended, once each.
  List<String> takeNotes() {
    final notes = [..._notes];
    _notes.clear();
    return notes;
  }

  @override
  Future<void> stop(int id) async => _runs[id]?.kill();

  static const _tailBytes = 32 * 1024;

  @override
  Stream<String> log(ShellJob job,
      {Duration every = const Duration(milliseconds: 500)}) {
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
