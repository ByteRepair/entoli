import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/shell_job.dart";
import "../../../providers.dart";
import "../../fonts.dart";
import "../../widgets/dialogs.dart";
import "shell_run.dart";

/// The chat's background jobs as pills, each opening the command and the end
/// of its log. Not turn-scoped: a job outlives the turn that started it. Not
/// on a mirrored chat, whose jobs are the other device's.
class JobStrip extends ConsumerWidget {
  const JobStrip({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isMirroredChatProvider(chatId))) return const SizedBox.shrink();
    final jobs = ref.watch(agentBackendProvider).jobsOf(chatId);
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: jobs.jobs,
      builder: (context, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
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
              for (final job in list)
                _JobPill(
                  job: job,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => JobSheet(jobs: jobs, id: job.id),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ActionChip(
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
      ),
    );
  }
}

String exitWords(ShellJob job) =>
    job.exitCode == -1 ? "stopped" : "exit ${job.exitCode}";

/// One job: the command, how it stands, and the end of its log as it grows.
class JobSheet extends StatefulWidget {
  const JobSheet({super.key, required this.jobs, required this.id});

  final ChatShellJobs jobs;
  final int id;

  @override
  State<JobSheet> createState() => _JobSheetState();
}

class _JobSheetState extends State<JobSheet> {
  // Once, not per build: a new stream per rebuild would restart the tail.
  late final Stream<String> _log = widget.jobs.log(widget.id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: widget.jobs.jobs,
      builder: (context, list, _) {
        final job = list.where((j) => j.id == widget.id).firstOrNull;
        if (job == null) return const SizedBox.shrink();
        return AlertDialog(
          title: Text("Background job ${job.id}"),
          content: SizedBox(
            width: 720,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShellCommandText(command: job.command),
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
                    stream: _log,
                    builder: (context, log) {
                      final text = log.data ?? "";
                      return LiveShellOutput(
                          code: text.isEmpty ? "(nothing printed yet)" : text);
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (job.running)
              TextButton(
                onPressed: () =>
                    catchAndSay(context, () => widget.jobs.stop(job.id)),
                child: const Text("Stop"),
              )
            else
              TextButton(
                onPressed: () {
                  widget.jobs.dismiss(job.id);
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
