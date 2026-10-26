/// A command the agent ran with `background: true`: its call answered as soon
/// as it started, and it runs on, its output going to a log in the chat's
/// workspace, until it exits or is stopped. Lives as long as the app does.
class ShellJob {
  const ShellJob({
    required this.id,
    required this.command,
    required this.logPath,
    required this.startedAt,
    this.pid,
    this.exitCode,
    this.endedAt,
  });

  /// Numbered per chat from 1, which is what the agent and the pill call it.
  final int id;
  final String command;

  /// The log on the host, which the pill's sheet tails.
  final String logPath;
  final int? pid;
  final DateTime startedAt;

  /// How it ended: its exit code, or -1 where it was stopped or timed out.
  final int? exitCode;
  final DateTime? endedAt;

  bool get running => endedAt == null;

  ShellJob ended(int code, DateTime at) => ShellJob(
        id: id,
        command: command,
        logPath: logPath,
        startedAt: startedAt,
        pid: pid,
        exitCode: code,
        endedAt: at,
      );
}
