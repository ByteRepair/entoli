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

/// Where one job is, read by the call that started it: running, ended with
/// what the chat kept of it, or lost — it ended with the app, or on a mirror,
/// its end has not arrived. See `ChatViewState.jobOf`.
sealed class JobState {
  const JobState();
}

final class JobRunning extends JobState {
  const JobRunning(this.job);

  final ShellJob job;

  @override
  bool operator ==(Object other) =>
      other is JobRunning && identical(other.job, job);

  @override
  int get hashCode => job.hashCode;
}

final class JobEnded extends JobState {
  const JobEnded(this.end);

  final JobEnd end;

  @override
  bool operator ==(Object other) => other is JobEnded && other.end == end;

  @override
  int get hashCode => end.hashCode;
}

final class JobLost extends JobState {
  const JobLost();

  @override
  bool operator ==(Object other) => other is JobLost;

  @override
  int get hashCode => 0;
}

/// One chat's running background jobs, as the room reaches them.
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
  final bytes = utf8.encode(tail);
  if (bytes.length <= maxBytes) return tail;
  // "…" is three bytes; the cut moves past continuation bytes so it is never
  // inside a character.
  var start = bytes.length - (maxBytes - 3);
  while ((bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  return "…${utf8.decode(bytes.sublist(start))}";
}

/// A command's first line, cut to [max].
String firstLine(String command, {int max = 80}) {
  final line = command.trim().split("\n").first;
  return line.length <= max ? line : "${line.substring(0, max - 1)}…";
}
