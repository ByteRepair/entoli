import "../../../domain/agent_backend.dart";
import "../../../domain/safe_command.dart" show readsOnly;
import "../../../domain/shell.dart";
import "../../../domain/shell_command_analysis.dart";
import "../../../domain/shell_job.dart" show backgroundLog;
import "../../../domain/tool_arg.dart";
import "../approval_gate.dart";
import "../background_jobs.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

/// What the spinner says while a command runs, the user's `!` one included.
const runningCommand = "Running a command";

/// The only tool for doing anything to the machine. Everything else — reading
/// a file, editing it, running the tests — is a command.
///
/// One tool, worded three ways: in the chat's persistent shell; with an
/// `unsandboxed` argument where the terminal environment enforces a sandbox,
/// the one place leaving it means anything; and one-shot for a sub-agent,
/// whose commands keep no state for a `restart` to drop and none the
/// description could promise. A sub-agent is offered no way out of the
/// sandbox, having nobody to approve one, and no background job, nobody
/// hearing how it ended.
class BashTool extends AgentTool {
  BashTool(super.offer);

  @override
  String get name => bashToolName;

  @override
  ToolGroup get group => ToolGroup.shell;

  @override
  bool get offered => offer.caps.commands;

  @override
  String get runningLabel => runningCommand;

  @override
  String get fragment => "`bash` to run a command";

  @override
  String get description => offer.oneShot
      ? "Execute a bash command. Every command runs in a fresh subshell that "
            "starts in the workspace directory, so a `cd` or an export does not "
            "carry over to the next command: prefix what it needs, or use "
            "absolute paths."
      : "Execute a bash command in the chat's persistent shell, which starts "
            "in the workspace directory and keeps its state between commands: a "
            "`cd` or an export made by one command is still there for the next.";

  /// Whether a call may ask to leave the sandbox: only where there is one to
  /// leave, and a person to approve leaving it.
  bool get leavesSandbox => !offer.oneShot && offer.sandboxed;

  /// Why [analysis] is not run at all, ahead of the gate; null runs it.
  String? refusalOf(ShellCommandAnalysis analysis) => null;

  @override
  Map<String, dynamic> get schema => {
    "type": "object",
    "properties": {
      ..._common,
      if (!offer.oneShot) ..._restart,
      if (leavesSandbox) ..._unsandboxed,
      if (!offer.oneShot && offer.background) ..._background,
    },
    "required": ["command"],
  };

  static const _common = {
    "command": {"type": "string", "description": "The bash command to execute"},
    "timeout": {
      "type": "integer",
      "description":
          "How long the command may run, in milliseconds. Set this to give a "
          "command a different deadline than the default 60000; values above "
          "180000 (3 minutes) are capped to it.",
    },
  };

  static const _restart = {
    "restart": {
      "type": "boolean",
      "description":
          "Restart the shell before running, discarding any directory a "
          "`cd` moved it to and anything an export gave it. Use it when a "
          "command's failure looks like the shell's state is the problem.",
    },
  };

  static const _unsandboxed = {
    "unsandboxed": {
      "type": "boolean",
      "description":
          "Run this command outside the sandbox. Commands normally run "
          "sandboxed: they can write only to the workspaces and the folders "
          "the user granted, and a write anywhere else fails with "
          "\"Permission denied\" or \"Operation not permitted\". When a "
          "command needs to write elsewhere (container tools like podman or "
          "toolbox, installers, caches under ~), call it again with this "
          "set. The user is asked to approve it unless a rule already "
          "allows it. Never set it to get around a failure the sandbox did "
          "not cause.",
    },
  };

  static const _background = {
    "background": {
      "type": "boolean",
      "description":
          "Start the command and answer at once, leaving it running: for a "
          "server, a watcher, or anything that does not exit on its own. It "
          "runs in a fresh shell that starts in the chat workspace (an earlier "
          "`cd` does not apply) with no input, and everything it prints goes "
          "to a log file the answer names: read it with `tail` or the read "
          "tool. The answer gives its process id to stop it with, and your "
          "next call after it exits says how it ended. Use this rather than "
          "`&`, `nohup` or `setsid`, which leave a command holding the call "
          "open.",
    },
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final command = stringArg(call.argumentsJson, "command");
    if (command == null) {
      yield* toolRejected(
        call,
        "The bash tool takes {\"command\": \"...\"}; that argument was missing "
        "or was not valid JSON.",
      );
      return;
    }
    // One parse carried the whole way: the rule gate reads its segments, the
    // deterministic tier its answer, and the run's confinement its words.
    final analysis = ShellCommandAnalysis.parse(
      command,
      isWindows: turn.shell.platformIsWindows,
    );
    yield toolCalled(call, command);
    if (refusalOf(analysis) case final refused?) {
      yield toolFailed(call, refused);
      return;
    }
    // Leaving the sandbox is part of what is asked: where one would confine
    // the run and no no-sandbox rule covers it, the call goes to the mode.
    final leave = leavesSandbox && boolArg(call.argumentsJson, "unsandboxed");
    final escaping = leave && await turn.gate.confinementOf(analysis) != null;
    final outcome = GateOutcome();
    yield* turn.gate.decide(
      call,
      bashToolName,
      () => _execute(turn, call, command, analysis, outcome, unconfined: leave),
      outcome,
      argumentsText: command,
      analysis: analysis,
      unsandboxed: escaping,
    );
    yield ToolResultEvent(outcome.resultOf(call));
  }

  Future<ShellResult> _execute(
    Turn turn,
    LlmToolCall call,
    String command,
    ShellCommandAnalysis analysis,
    GateOutcome outcome, {
    bool unconfined = false,
  }) async {
    if (turn.cancelled) {
      return const ShellResult.failed(
        "The turn was stopped before this command ran.",
      );
    }
    // The model's own bound for this command, capped at what the chat allows:
    // a small model's estimate of a build is as likely to be too short as too
    // long, and a cap is the only one that is never wrong.
    final cap = turn.options.commandTimeout.inMilliseconds;
    final requested = intArg(call.argumentsJson, "timeout");
    final timeout = Duration(
      milliseconds: requested == null || requested <= 0
          ? cap
          : requested.clamp(0, cap),
    );
    // What the command parses to, decided before anything asks a model about
    // it. The parse answers for the deterministic safe side — reads, and
    // writes the workspace can hold — and refuses what it cannot answer for:
    // a command that cannot be modeled is one the model decided the wording
    // of, and one that assigns to a variable that rewrites where its own
    // writes land is not answering for itself.
    //
    // The gate is on only where a sandbox exists to make the boundary hold:
    // without one the parse has nothing to enforce, and refusing on its word
    // would be trusting the same text-only read the sandbox exists to back.
    // And it stands down where a person has decided: a run behind the
    // approval banner was read and answered by a human, and a parse vetoing
    // what the human approved is the machine overriding its keeper. The
    // banner, not the mode, is what carries that — auto mode reaches the
    // banner through the classifier's ask — so the gate reads what the
    // outcome says of the run.
    final sandbox = unconfined ? null : await turn.gate.confinementOf(analysis);
    if (sandbox != null && !outcome.byPerson) {
      final note = analysis.escalationNote;
      if (note != null) return ShellResult.failed(note);
    }
    final jobs = turn.backgroundJobs;
    if (jobs != null && boolArg(call.argumentsJson, "background")) {
      return _startBackground(turn, jobs, call.id, command, sandbox);
    }
    return turn.track(
      call,
      turn.shell.start(
        command,
        cwd: turn.workspace,
        home: turn.projectWorkspace,
        timeout: timeout,
        environment: turn.environment,
        oneShot: offer.oneShot,
        restart: boolArg(call.argumentsJson, "restart"),
        project: turn.project,
        sandbox: sandbox,
        readOnly: turn.readOnlyDirs,
      ),
    );
  }

  /// Start [command] as a background job and answer with where it went. A
  /// one-shot run, so its own shell is all it holds, under the sandbox the
  /// gate decided; its streams are its log and nothing, which is what lets a
  /// `toolbox run` or a server in it stop holding anything open.
  Future<ShellResult> _startBackground(
    Turn turn,
    ChatJobs jobs,
    String callId,
    String command,
    CommandSandbox? sandbox,
  ) async {
    final job = await jobs.start(
      command,
      callId: callId,
      workspace: turn.workspace,
      spawn: (script) => turn.shell.start(
        script,
        cwd: turn.workspace,
        home: turn.projectWorkspace,
        timeout: BackgroundJobs.timeout,
        environment: turn.environment,
        oneShot: true,
        project: turn.project,
        sandbox: sandbox,
        readOnly: turn.readOnlyDirs,
      ),
    );
    final log = backgroundLog(callId);
    final where = turn.shell.guestRoot == null ? " (${job.logPath})" : "";
    final pid = job.pid;
    final stop = pid == null
        ? ""
        : " Its process id is $pid, the leader of its group: "
              "`kill -- -$pid` stops it and everything it started.";
    return ShellResult(
      returnCode: 0,
      jobId: job.id,
      output:
          "Started in the background as job ${job.id}.$stop Its output "
          "goes to $log in the chat workspace$where: read it with `tail` or "
          "the read tool at chat:$log. Your next call after it exits says "
          "how it ended.",
    );
  }
}

/// `bash` for an agent that only looks: a command runs only where the parse
/// proves every segment changes nothing (`safe_command.dart`), and anything
/// else is refused as the call's result. The refusal is the tool's, after the
/// one parse and ahead of the gate, so no mode and no rule can let a write through — a sub-agent
/// runs under `never`, and its prompt asking it not to write is all that
/// would stand in the way otherwise.
class ReadOnlyBashTool extends BashTool {
  ReadOnlyBashTool(super.offer);

  @override
  String get id => "$bashToolName(readonly)";

  @override
  bool get onByDefault => false;

  @override
  String get fragment => "`bash` to run a command that only reads";

  /// The sandbox confines writes, and nothing this runs writes: leaving it
  /// would only put a banner in front of the user.
  @override
  bool get leavesSandbox => false;

  @override
  String get description =>
      "${super.description} Read-only: only commands "
      "that change nothing run — reading, listing and searching (ls, find, "
      "grep, rg, cat, head, git log, git diff and the like). A command that "
      "writes a file, installs, fetches or cannot be checked is refused.";

  @override
  String? refusalOf(ShellCommandAnalysis analysis) {
    final segments = analysis.modelableSegments;
    if (segments == null) {
      return "Not run: this shell is read-only and this command cannot be "
          "checked. Write it as plain commands, without substitutions or "
          "expansions.";
    }
    for (final segment in segments) {
      if (!readsOnly(segment)) {
        return "Not run: this shell is read-only, and `$segment` is not a "
            "command that only reads.";
      }
    }
    return null;
  }
}
