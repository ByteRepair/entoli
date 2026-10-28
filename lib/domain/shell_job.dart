import "dart:convert";

import "package:flutter/foundation.dart" show ValueListenable;

import "models.dart" show JobEnd;

/// A command the agent ran with `background: true`: its call answered as soon
/// as it started, and it runs on, its output going to a log in the chat's
/// workspace, until it exits or is stopped. Lives as long as the app does.
class ShellJob {
  const ShellJob({
    required this.id,
    required this.callId,
    required this.command,
    required this.logPath,
    this.pid,
  });

  /// Numbered per chat from 1, which is what the agent and the pill call it.
  final int id;

  /// The `bash` call that started it, which names its log and its end.
  final String callId;
  final String command;

  /// The log on the host, which the pill's sheet tails.
  final String logPath;
  final int? pid;
}

/// One chat's running background jobs, as the chat page reaches them.
abstract class ChatShellJobs {
  /// The jobs still running; one leaves the list when it ends.
  ValueListenable<List<ShellJob>> get jobs;

  Future<void> stop(int id);

  /// The end of [job]'s log as it grows, closing once the job has ended.
  Stream<String> log(ShellJob job);

  /// Each job as it ends, by the call that started it. Not one the app
  /// killed on its way out: that one has no end to record.
  Stream<({String callId, JobEnd end})> get ended;
}

/// How a `bash` call that started a job answers, ahead of the job's number:
/// what tells a job's call from one asking for the background where the
/// shell had none, and ran in the foreground.
const backgroundStarted = "Started in the background as job";

/// The log of the job [callId] started, relative to the chat workspace. Named
/// by the call rather than the job's number, which starts again with the app,
/// so a chat's label never opens another job's log.
String backgroundLog(String callId) =>
    ".entoli-jobs/${callId.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_")}.log";

/// What the chat keeps of a job's log: its last [lines] lines, cut from the
/// top to the last [maxBytes] where those are longer, behind "…".
String jobTail(String log, {int lines = 10, int maxBytes = 1024}) {
  final all = log.trimRight().split("\n");
  var tail = all.skip(all.length > lines ? all.length - lines : 0).join("\n");
  if (utf8.encode(tail).length <= maxBytes) return tail;
  // Back from the end a code point at a time, so the cut is never inside one.
  var bytes = 0;
  var start = tail.length;
  for (final rune in tail.runes.toList().reversed) {
    final size = utf8.encode(String.fromCharCode(rune)).length;
    if (bytes + size > maxBytes - 3) break;
    bytes += size;
    start -= rune > 0xFFFF ? 2 : 1;
  }
  return "…${tail.substring(start)}";
}

/// A command's first line, cut to [max].
String firstLine(String command, {int max = 80}) {
  final line = command.trim().split("\n").first;
  return line.length <= max ? line : "${line.substring(0, max - 1)}…";
}
