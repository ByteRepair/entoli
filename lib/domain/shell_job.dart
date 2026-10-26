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
  });

  /// Numbered per chat from 1, which is what the agent and the pill call it.
  final int id;
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
}

/// A command's first line, cut to [max].
String firstLine(String command, {int max = 80}) {
  final line = command.trim().split("\n").first;
  return line.length <= max ? line : "${line.substring(0, max - 1)}…";
}
