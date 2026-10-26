import "dart:async";
import "dart:convert";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../../domain/shell_job.dart";
import "../../domain/shell.dart";

/// Every chat's background jobs, held by the backend so a job outlives the
/// turn that started it. The agent starts them through [ChatJobs]; the chat
/// page lists them through [of]; the next tool call the agent makes in that
/// chat, this turn or a later one, hears how the finished ones ended.
class BackgroundJobs {
  BackgroundJobs(this.fs);

  final FileSystem fs;

  /// How many may run at once in one chat: enough for a server and a build
  /// beside it, few enough that a model looping on `background` stops.
  static const maxRunning = 4;

  /// How long one may run before it is killed. A job nobody stopped is still
  /// a process the user did not ask to keep forever.
  static const timeout = Duration(hours: 12);

  final _jobs = <String, ValueNotifier<List<ShellJob>>>{};
  final _runs = <String, Map<int, ShellRun>>{};
  final _notes = <String, List<String>>{};
  final _stopped = <String, Set<int>>{};
  final _counts = <String, int>{};

  ValueListenable<List<ShellJob>> of(String chatId) => _list(chatId);

  ValueNotifier<List<ShellJob>> _list(String chatId) =>
      _jobs.putIfAbsent(chatId, () => ValueNotifier(const []));

  /// [chatId]'s face for the agent.
  ChatJobs forChat(String chatId) => ChatJobs._(this, chatId);

  Future<ShellJob> _start(String chatId,
      {required int id,
      required String command,
      required String logPath,
      required ShellRun run}) async {
    final job = ShellJob(
      id: id,
      command: command,
      logPath: logPath,
      startedAt: DateTime.now(),
      pid: await run.pid,
    );
    (_runs[chatId] ??= {})[id] = run;
    final list = _list(chatId);
    list.value = [...list.value, job];
    unawaited(run.result.then((r) => _end(chatId, id, r.returnCode)));
    return job;
  }

  void _end(String chatId, int id, int code) {
    _runs[chatId]?.remove(id);
    final list = _jobs[chatId];
    if (list == null) return;
    final job = list.value.firstWhere((j) => j.id == id);
    list.value = [
      for (final j in list.value) j.id == id ? j.ended(code, DateTime.now()) : j,
    ];
    final byUser = _stopped[chatId]?.remove(id) ?? false;
    final how = byUser
        ? "was stopped by the user"
        : code == -1
            ? "was stopped (killed, or out of time)"
            : "exited with code $code";
    (_notes[chatId] ??= []).add(
        "Background job ${job.id} (`${_short(job.command)}`) $how.");
  }

  /// Stop a running job, from the chat page.
  Future<void> stop(String chatId, int id) async {
    final run = _runs[chatId]?[id];
    if (run == null) return;
    (_stopped[chatId] ??= {}).add(id);
    await run.kill();
  }

  /// Take a finished job off the chat page.
  void dismiss(String chatId, int id) {
    final list = _jobs[chatId];
    if (list == null) return;
    list.value = [
      for (final j in list.value)
        if (j.id != id || j.running) j,
    ];
  }

  /// The end of [id]'s log, read again every [every] until the stream is
  /// cancelled: what the pill's sheet shows.
  Stream<String> tail(String chatId, int id,
      {Duration every = const Duration(milliseconds: 500)}) async* {
    final job = _jobs[chatId]?.value.where((j) => j.id == id).firstOrNull;
    if (job == null) return;
    String? last;
    while (true) {
      final text = await _tailOf(job.logPath);
      if (text != last) yield last = text;
      final still = _jobs[chatId]?.value.where((j) => j.id == id).firstOrNull;
      if (still == null || !still.running) {
        // Once more after the end, for what it printed last.
        final end = await _tailOf(job.logPath);
        if (end != last) yield end;
        return;
      }
      await Future<void>.delayed(every);
    }
  }

  static const _tailBytes = 32 * 1024;

  Future<String> _tailOf(String path) async {
    final file = fs.file(path);
    if (!await file.exists()) return "";
    final size = (await file.stat()).size;
    final start = max(0, size - _tailBytes);
    final bytes = await file
        .openRead(start, size)
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Kill [chatId]'s jobs and forget them: the chat is being deleted.
  Future<void> closeChat(String chatId) async {
    final runs = _runs.remove(chatId)?.values ?? const <ShellRun>[];
    _jobs.remove(chatId)?.dispose();
    _notes.remove(chatId);
    _stopped.remove(chatId);
    _counts.remove(chatId);
    await Future.wait(runs.map((r) => r.kill()));
  }

  /// Kill every job: the app is going.
  Future<void> close() => Future.wait([..._jobs.keys].map(closeChat));

  static String _short(String command) {
    final line = command.trim().split("\n").first;
    return line.length <= 80 ? line : "${line.substring(0, 79)}…";
  }
}

/// Job [id]'s log, relative to the chat workspace it starts in.
String backgroundLog(int id) => ".entoli-jobs/$id.log";

/// What a job's shell runs: its streams pointed at its log and at nothing
/// before [command] starts, so a child it leaves behind holds no pipe of the
/// app's, then [command] as written.
String backgroundScript(int id, String command) =>
    "mkdir -p .entoli-jobs && exec >${backgroundLog(id)} 2>&1 </dev/null\n"
    "$command";

/// One chat's jobs, as the agent sees them.
class ChatJobs {
  ChatJobs._(this._jobs, this.chatId);

  final BackgroundJobs _jobs;
  final String chatId;

  int get running => _jobs.of(chatId).value.where((j) => j.running).length;

  /// Never reused while the app runs, dismissed jobs included: the number
  /// names the log, and a reused one would write over a log still being read.
  int get nextId => _jobs._counts[chatId] = (_jobs._counts[chatId] ?? 0) + 1;

  Future<ShellJob> start(
          {required int id,
          required String command,
          required String logPath,
          required ShellRun run}) =>
      _jobs._start(chatId,
          id: id, command: command, logPath: logPath, run: run);

  /// How the jobs that ended since the last call ended, once each.
  List<String> takeNotes() => _jobs._notes.remove(chatId) ?? const [];
}
