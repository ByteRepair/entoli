import "dart:async";
import "dart:convert";
import "dart:math";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../../domain/shell.dart";
import "../../domain/shell_job.dart";

/// Every chat's background jobs, held by the backend so a job outlives the
/// turn that started it. The agent starts them through a chat's [ChatJobs];
/// the chat page reaches the same object as a [ChatShellJobs]; the next tool
/// call the agent makes in that chat, this turn or a later one, hears how the
/// ended ones ended.
class BackgroundJobs {
  BackgroundJobs(this.fs);

  final FileSystem fs;

  /// How many may run at once in one chat: enough for a server and a build
  /// beside it, few enough that a model looping on `background` stops.
  static const maxRunning = 4;

  /// How long one may run before it is killed. A job nobody stopped is still
  /// a process the user did not ask to keep forever.
  static const timeout = Duration(hours: 12);

  final _chats = <String, ChatJobs>{};

  ChatJobs forChat(String chatId) =>
      _chats.putIfAbsent(chatId, () => ChatJobs._(fs));

  /// Kill [chatId]'s jobs and forget them: the chat is being deleted.
  Future<void> closeChat(String chatId) async =>
      _chats.remove(chatId)?._close();

  /// Kill every job: the app is going.
  Future<void> close() => Future.wait([..._chats.keys].map(closeChat));
}

/// Job [id]'s log, relative to the chat workspace it starts in.
String backgroundLog(int id) => ".entoli-jobs/$id.log";

/// What a job's shell runs: its output pointed at its log before [command]
/// starts, so a child it leaves behind holds no pipe of the app's, then
/// [command] as written. A log that cannot be opened ends the job there
/// rather than letting it print into the app.
String backgroundScript(int id, String command) =>
    "mkdir -p .entoli-jobs; exec >${backgroundLog(id)} 2>&1 || exit 1\n"
    "$command";

/// One chat's jobs.
class ChatJobs implements ChatShellJobs {
  ChatJobs._(this._fs);

  final FileSystem _fs;

  @override
  final ValueNotifier<List<ShellJob>> jobs = ValueNotifier(const []);
  final _runs = <int, ShellRun>{};
  final _notes = <String>[];
  final _stoppedByUser = <int>{};

  /// Never reused while the app runs, dismissed jobs included: the number
  /// names the log, and a reused one would write over a log still being read.
  int _count = 0;

  int get running => _runs.length;

  /// Start [command] as the next job, [spawn] running the script it is
  /// wrapped in from [workspace], where its log lands.
  Future<ShellJob> start(String command,
      {required String workspace,
      required ShellRun Function(String script) spawn}) async {
    final id = ++_count;
    final run = spawn(backgroundScript(id, command));
    _runs[id] = run;
    final job = ShellJob(
      id: id,
      command: command,
      logPath: _fs.path.join(workspace, backgroundLog(id)),
      pid: await run.pid,
    );
    jobs.value = [...jobs.value, job];
    unawaited(run.result.then((r) => _end(job, r.returnCode)));
    return job;
  }

  void _end(ShellJob job, int code) {
    if (_runs.remove(job.id) == null) return;
    jobs.value = [
      for (final j in jobs.value) j.id == job.id ? j.ended(code) : j,
    ];
    final how = _stoppedByUser.remove(job.id)
        ? "was stopped by the user"
        : code == -1
            ? "was stopped (killed, or out of time)"
            : "exited with code $code";
    _notes.add("Background job ${job.id} (`${firstLine(job.command)}`) $how.");
  }

  /// How the jobs that ended since the last call ended, once each.
  List<String> takeNotes() {
    final notes = [..._notes];
    _notes.clear();
    return notes;
  }

  @override
  Future<void> stop(int id) async {
    final run = _runs[id];
    if (run == null) return;
    _stoppedByUser.add(id);
    await run.kill();
  }

  @override
  void dismiss(int id) => jobs.value = [
        for (final j in jobs.value)
          if (j.id != id || j.running) j,
      ];

  static const _tailBytes = 32 * 1024;

  @override
  Stream<String> log(int id,
      {Duration every = const Duration(milliseconds: 500)}) {
    final path = jobs.value.where((j) => j.id == id).firstOrNull?.logPath;
    if (path == null) return const Stream.empty();
    final file = _fs.file(path);
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
      final ended = !(jobs.value.where((j) => j.id == id).firstOrNull?.running ??
          false);
      final stat = await file.stat();
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
    await Future.wait(runs.map((r) => r.kill()));
  }
}
