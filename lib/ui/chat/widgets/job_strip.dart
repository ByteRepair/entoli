import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/shell_job.dart";
import "../../../providers.dart";
import "../../fonts.dart";

/// The chat's background jobs as pills, each opening the command and the end
/// of its log. Not turn-scoped: a job outlives the turn that started it. Not
/// on a mirrored chat, whose jobs are the other device's.
class JobStrip extends ConsumerWidget {
  const JobStrip({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isMirroredChatProvider(chatId))) return const SizedBox.shrink();
    final backend = ref.watch(agentBackendProvider);
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: backend.backgroundJobs(chatId),
      builder: (context, jobs, _) {
        if (jobs.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final job in jobs)
                _JobPill(
                  job: job,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => JobSheet(chatId: chatId, id: job.id),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _JobPill extends StatelessWidget {
  const _JobPill({required this.job, required this.onPressed});

  final ShellJob job;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = !job.running && job.exitCode != 0;
    final (fg, bg) = job.running
        ? (scheme.onPrimaryContainer, scheme.primaryContainer)
        : failed
            ? (scheme.onErrorContainer, scheme.errorContainer)
            : (scheme.onSurfaceVariant, scheme.surfaceContainer);
    return ActionChip(
      avatar: job.running
          ? SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: fg),
            )
          : Icon(failed ? Icons.error_outline : Icons.check, size: 16, color: fg),
      label: Text(
        "${firstLine(job.command)}${job.running ? "" : " · ${exitWords(job)}"}",
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: fg),
      ),
      backgroundColor: bg,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact,
      tooltip: "Background job ${job.id}",
      onPressed: onPressed,
    );
  }
}

/// A command's first line, cut to fit a pill.
String firstLine(String command) {
  final line = command.trim().split("\n").first;
  return line.length <= 40 ? line : "${line.substring(0, 39)}…";
}

String exitWords(ShellJob job) =>
    job.exitCode == -1 ? "stopped" : "exit ${job.exitCode}";

/// One job: the command, how it stands, and the end of its log as it grows.
class JobSheet extends ConsumerWidget {
  const JobSheet({super.key, required this.chatId, required this.id});

  final String chatId;
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(agentBackendProvider);
    final theme = Theme.of(context);
    final mono = TextStyle(fontFamily: monoFamily, fontSize: 12.5,
        color: theme.colorScheme.onSurface);
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: backend.backgroundJobs(chatId),
      builder: (context, jobs, _) {
        final job = jobs.where((j) => j.id == id).firstOrNull;
        if (job == null) return const SizedBox.shrink();
        return AlertDialog(
          title: Text("Background job ${job.id}"),
          content: SizedBox(
            width: 720,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(job.command, style: mono),
                ),
                const SizedBox(height: 8),
                Text(
                  job.running
                      ? "Running${job.pid == null ? "" : " · pid ${job.pid}"}"
                      : "Ended · ${exitWords(job)}",
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: StreamBuilder<String>(
                    // Keyed on the run, so the stream is not restarted by every
                    // rebuild the job list causes.
                    key: ValueKey(job.running),
                    stream: backend.backgroundJobLog(chatId, id),
                    builder: (context, log) {
                      final text = log.data ?? "";
                      return Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 120),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: SelectableText(
                            text.isEmpty ? "(nothing printed yet)" : text,
                            style: mono,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (job.running)
              TextButton(
                onPressed: () => backend.stopBackgroundJob(chatId, id),
                child: const Text("Stop"),
              )
            else
              TextButton(
                onPressed: () {
                  backend.dismissBackgroundJob(chatId, id);
                  Navigator.of(context).pop();
                },
                child: const Text("Dismiss"),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }
}
