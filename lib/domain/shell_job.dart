import "package:flutter/foundation.dart" show ValueListenable;

/// A command the agent ran with `background: true`: its call answered as soon
/// as it started, and it runs on, its output going to a log in the chat's
/// workspace, until it exits or is stopped. Lives as long as the app does.
class ShellJob {
  const ShellJob({
    required this.id,
    required this.command,
    required this.logPath,
    this.pid,
    this.exitCode,
  });

  /// Numbered per chat from 1, which is what the agent and the pill call it.
  final int id;
  final String command;

  /// The log on the host, which the pill's sheet tails.
  final String logPath;
  final int? pid;

  /// How it ended: its exit code, or -1 where it was stopped or timed out.
  /// Null while it runs.
  final int? exitCode;

  bool get running => exitCode == null;

  ShellJob ended(int code) => ShellJob(
      id: id, command: command, logPath: logPath, pid: pid, exitCode: code);
}

/// One chat's background jobs, as the chat page reaches them.
abstract class ChatShellJobs {
  /// The jobs as they start and end, the ended ones until dismissed.
  ValueListenable<List<ShellJob>> get jobs;

  /// Stop a running job. One already over is left as it is.
  Future<void> stop(int id);

  /// Take an ended job off the list.
  void dismiss(int id);

  /// The end of a job's log as it grows, closing once the job has ended.
  Stream<String> log(int id);
}

/// A command's first line, cut to [max].
String firstLine(String command, {int max = 80}) {
  final line = command.trim().split("\n").first;
  return line.length <= max ? line : "${line.substring(0, max - 1)}…";
}
