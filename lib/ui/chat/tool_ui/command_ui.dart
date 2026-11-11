import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../../domain/models.dart";
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/shell.dart" show bashToolName;
import "../../../domain/shell_job.dart";
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";
import "../../widgets/dialogs.dart" show catchAndSay;
import "../../widgets/text_file_page.dart";
import "../../../app/mirror_controller.dart" show chatViewProvider;
import "../activity/activity.dart";
import "../activity/card.dart" show ActivityStatus, DrawerAction;
import "../activity/tool_run.dart" show toolRunView;
import "../widgets/running_pill.dart" show RunningThing;
import "tool_ui.dart";

/// What voice mode says of a command, whoever ran it — the model through
/// `bash`, or the user through `!`.
const ranACommand = "Ran a command";

class BashUI extends ToolUI {
  const BashUI();

  @override
  String get tool => bashToolName;

  @override
  String get spoken => ranACommand;

  @override
  (IconData, String) get approval => (Icons.terminal, "Run this command?");

  /// The command set apart and its exit code under the title; a call that
  /// started a job is drawn as the job, once it has.
  @override
  RunView view(WidgetRef ref, Run run) {
    final result = run.result;
    final jobId = result?.jobId;
    if (jobId != null) {
      return JobActivity(
        command: stringArg(run.call?.argumentsJson, "command") ?? "",
        jobId: jobId,
      ).view(ref, run);
    }
    return toolRunView(
      run,
      commandArg: "command",
      status: result == null
          ? (text: "Running", isError: false)
          : (
              text: "Exit code ${result.returnCode}",
              isError: result.returnCode != 0,
            ),
    );
  }
}

/// A background job, by the call that started it: its state rather than the
/// call's, since the call was over the moment the job started. Running, the
/// drawer tails its log and can stop it; ended, it says how, shows what the
/// chat kept of the log, and opens the whole log while the workspace has it.
/// Drawn for the call in the reply and for the job's pill alike.
class JobActivity extends LabelledActivity {
  const JobActivity({required this.command, required this.jobId});

  final String command;
  final int jobId;

  @override
  RunView view(WidgetRef ref, Run run) {
    final callId = run.callId!;
    final (:state, :mirrored) = ref.watch(
      chatViewProvider(
        run.chatId,
      ).select((v) => (state: v.jobOf(callId), mirrored: v.mirrored)),
    );
    final line = firstLine(command);
    final title = "Background job $jobId";
    if (state case JobRunning(:final job)) {
      return RunView(
        icon: Icons.terminal,
        label: "Running in the background: $line",
        busy: true,
        drawer: (ref) {
          final log = ref
              .watch(jobLogProvider((chatId: run.chatId, job: job)))
              .value;
          return RunDrawer(
            title: title,
            command: command,
            status: (
              text: "Running${job.pid == null ? "" : " · pid ${job.pid}"}",
              isError: false,
            ),
            actions: [
              DrawerAction(
                label: "Stop",
                run: (context) => catchAndSay(
                  context,
                  () => ref
                      .read(agentBackendProvider)
                      .jobsOf(run.chatId)
                      .stop(job.id),
                ),
              ),
            ],
            mono: true,
            live: true,
            sections: [
              (
                label: "Output",
                body: log == null || log.isEmpty
                    ? "(nothing printed yet)"
                    : log,
                isError: false,
              ),
            ],
          );
        },
      );
    }
    final end = switch (state) {
      JobEnded(:final end) => end,
      _ => null,
    };
    final status = switch (state) {
      JobEnded(:final end) => _jobStatus(end),
      JobUnheard() => (text: "Not heard from", isError: false),
      _ => (text: "Ended with the app", isError: false),
    };
    return RunView(
      icon: Icons.terminal,
      label: "Background job ${status.text.toLowerCase()}: $line",
      isError: status.isError,
      drawer: (ref) => RunDrawer(
        title: title,
        command: command,
        status: status,
        // A mirror's workspace, and the log in it, is the other device's.
        actions: [if (!mirrored) _openLog(ref, run.chatId, callId)],
        mono: true,
        sections: [(label: "Output", body: end?.tail, isError: false)],
      ),
    );
  }
}

/// The background jobs running, a pill each, opening the job's drawer.
List<RunningThing> jobsRunning(
  WidgetRef ref,
  ChatViewState view,
  String chatId,
) => [
  for (final job in view.runningJobs.values)
    RunningThing(
      group: "background task",
      label: firstLine(job.command),
      mono: true,
      tooltip: "Background job ${job.id}",
      open: (context) => JobActivity(
        command: job.command,
        jobId: job.id,
      ).open(context, Run(chatId: chatId, callId: job.callId)),
    ),
];

/// How a job ended, for a status line.
ActivityStatus _jobStatus(JobEnd end) {
  final code = end.exitCode;
  if (code == null) return (text: "Stopped", isError: false);
  return (text: "Exited with code $code", isError: code != 0);
}

/// The end of a running job's log as it grows, for its drawer.
final jobLogProvider = StreamProvider.autoDispose
    .family<String, ({String chatId, ShellJob job})>(
      (ref, of) =>
          ref.watch(agentBackendProvider).jobsOf(of.chatId).log(of.job),
    );

/// Opens a job's whole log in the file viewer, while the workspace still has
/// it.
DrawerAction _openLog(WidgetRef ref, String chatId, String callId) {
  final path = p.join(
    ref
        .read(appConfigProvider)
        .workspaceDir(
          chatId,
          project: ref.read(chatViewProvider(chatId)).chat?.state.project,
        ),
    backgroundLog(callId),
  );
  if (!File(path).existsSync()) {
    return const DrawerAction(
      label: "Open log",
      why: "The log is no longer in the workspace",
    );
  }
  return DrawerAction(
    label: "Open log",
    run: (context) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TextFilePage(path: path, name: p.basename(path), popsBinary: false),
      ),
    ),
  );
}
