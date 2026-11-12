import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../../domain/models.dart";
import "../../../domain/shell.dart" show bashToolName;
import "../../../domain/shell_job.dart";
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";
import "../../mirror_controller.dart" show chatViewProvider;
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// What voice mode says of a command, whoever ran it — the model through
/// `bash`, or the user through `!`.
const ranACommand = "Ran a command";

final class BashActivity extends ToolActivity {
  const BashActivity();

  @override
  String get tool => bashToolName;

  @override
  String get spoken => ranACommand;

  @override
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.terminal, "Run this command?");

  @override
  String get commandArg => "command";

  /// The call's `description`, the model's word for what it runs, where it
  /// gave one.
  @override
  String? summary(Run run) {
    final said = stringArg(run.call?.argumentsJson, "description")?.trim();
    return said == null || said.isEmpty ? null : said.split("\n").first;
  }

  @override
  DetailStatus status(Run run) {
    final result = run.result;
    if (result == null) return const DetailStatus("Running");
    return DetailStatus(
      "Exit code ${result.returnCode}",
      isError: result.returnCode != 0,
    );
  }

  /// The job a call started, once it has: drawn as the job rather than the
  /// call, since the call was over the moment the job started.
  JobActivity? _jobOf(Run run) {
    final jobId = run.result?.jobId;
    if (jobId == null) return null;
    return JobActivity(
      command: stringArg(run.call?.argumentsJson, "command") ?? "",
      jobId: jobId,
    );
  }

  @override
  ActivityNode node(SettingReader reader, Run run) =>
      _jobOf(run)?.node(reader, run) ?? super.node(reader, run);

  @override
  ActivityDetail? detail(SettingReader reader, Run run) =>
      _jobOf(run)?.detail(reader, run) ?? super.detail(reader, run);
}

/// A background job, by the call that started it: its state rather than the
/// call's. Running, the detail tails its log and can stop it; ended, it says
/// how, shows what the chat kept of the log, and opens the whole log while
/// the workspace has it. Shown for the call in the reply and for the job's
/// pill alike.
final class JobActivity extends Activity {
  const JobActivity({required this.command, required this.jobId});

  final String command;
  final int jobId;

  JobState _state(SettingReader reader, Run run) => reader.watch(
    chatViewProvider(run.chatId).select((v) => v.jobOf(run.callId!)),
  );

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final state = _state(reader, run);
    final line = firstLine(command);
    if (state is JobRunning) {
      return LabelNode(
        this,
        run,
        glyph: TranscriptGlyph.terminal,
        text: "Running in the background: $line",
        busy: true,
      );
    }
    final status = _statusOf(state);
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.terminal,
      text: "Background job ${status.text.toLowerCase()}: $line",
      isError: status.isError,
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) {
    final state = _state(reader, run);
    final title = "Background job $jobId";
    if (state case JobRunning(:final job)) {
      final log = reader
          .watch(jobLogProvider((chatId: run.chatId, job: job)))
          .value;
      return ActivityDetail(
        title: title,
        glyph: TranscriptGlyph.terminal,
        command: command,
        status: DetailStatus(
          "Running${job.pid == null ? "" : " · pid ${job.pid}"}",
        ),
        actions: [
          DetailAction(
            label: "Stop",
            run: (handOff) => handOff.attempt(
              () => reader
                  .read(agentBackendProvider)
                  .jobsOf(run.chatId)
                  .stop(job.id),
            ),
          ),
        ],
        mono: true,
        live: true,
        sections: [
          DetailSection(
            label: "Output",
            body: log == null || log.isEmpty ? "(nothing printed yet)" : log,
          ),
        ],
      );
    }
    final end = switch (state) {
      JobEnded(:final end) => end,
      _ => null,
    };
    final mirrored = reader.watch(
      chatViewProvider(run.chatId).select((v) => v.mirrored),
    );
    return ActivityDetail(
      title: title,
      glyph: TranscriptGlyph.terminal,
      command: command,
      status: _statusOf(state),
      // A mirror's workspace, and the log in it, is the other device's.
      actions: [if (!mirrored) _openLog(reader, run.chatId, run.callId!)],
      mono: true,
      sections: [DetailSection(label: "Output", body: end?.tail)],
    );
  }
}

DetailStatus _statusOf(JobState state) => switch (state) {
  JobEnded(:final end) => _jobStatus(end),
  JobUnheard() => const DetailStatus("Not heard from"),
  _ => const DetailStatus("Ended with the app"),
};

/// How a job ended, for a status line.
DetailStatus _jobStatus(JobEnd end) {
  final code = end.exitCode;
  if (code == null) return const DetailStatus("Stopped");
  return DetailStatus("Exited with code $code", isError: code != 0);
}

/// The end of a running job's log as it grows, for its detail.
final jobLogProvider = StreamProvider.autoDispose
    .family<String, ({String chatId, ShellJob job})>(
      (ref, of) =>
          ref.watch(agentBackendProvider).jobsOf(of.chatId).log(of.job),
    );

/// Opens a job's whole log, while the workspace still has it.
DetailAction _openLog(SettingReader reader, String chatId, String callId) {
  final path = p.join(
    reader
        .read(appConfigProvider)
        .workspaceDir(
          chatId,
          project: reader.read(chatViewProvider(chatId)).chat?.state.project,
        ),
    backgroundLog(callId),
  );
  if (!File(path).existsSync()) {
    return const DetailAction(
      label: "Open log",
      why: "The log is no longer in the workspace",
    );
  }
  return DetailAction(
    label: "Open log",
    run: (handOff) => handOff.openFile(path),
  );
}
