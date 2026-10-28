import "dart:async";

import "package:fs_shim/fs.dart";

import "../../domain/agent_backend.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/safe_command.dart" show SegmentReach, profileSegment;
import "../../domain/shell.dart";
import "../../domain/shell_command_analysis.dart";
import "../../domain/web_search.dart" show webfetchToolName;
import "llm/llm_client.dart";
import "templates.dart" show notExecuted;
import "tools/tool_outcome.dart";

/// How one gated call came out, filled in by the gate for the call that made
/// it: what ran or refused it ([result]), what decided ([decision]), and
/// whether a person answered a banner before the run ([byPerson]). A value
/// the caller holds rather than state on the gate, so nothing of one call can
/// be read as another's.
class GateOutcome {
  ShellResult? result;
  Decision? decision;

  /// The run sits behind a banner a person read and answered. The command
  /// parse reads it to stand down: a parse vetoing what a person approved is
  /// the machine overriding its keeper.
  bool byPerson = false;

  /// The outcome as [call]'s result.
  ToolResult resultOf(LlmToolCall call) =>
      toolRan(call, result!, decision: decision);
}

/// What stands between a call and its run: the standing rules, then the
/// approval mode — the banner, the classifier, or nothing. One per turn,
/// holding what is the turn's: the policy as this call reads it, the
/// directories granted mid-turn, and auto mode's circuit breaker. See
/// "Approvals" in AGENTS.md.
class ApprovalGate {
  ApprovalGate({
    required this.policy,
    this.approveMode,
    required this.classifier,
    required this.approve,
    required this.fs,
    required this.workspace,
    required this.projectWorkspace,
    required this.shell,
    required this.resolvePath,
    required this.cancelled,
    required this.stopped,
    this.sandboxHelper,
  });

  /// What the permission pages set, read afresh at every gated call: a rule
  /// saved while the turn runs — a banner's "always" included — covers the
  /// next call.
  final PolicyReader policy;

  /// How a call the rules leave uncovered is decided, where the turn keeps
  /// one of its own; null reads the chat's from [policy].
  final ApproveMode? approveMode;

  /// Answers [ApproveMode.auto]; null asks for every call.
  final PermissionClassifier? classifier;

  /// Raises the banner and waits for the answer.
  final Future<ApprovalResponse> Function(ToolApproval approval) approve;

  final FileSystem fs;
  final String workspace;
  final String projectWorkspace;
  final Shell shell;

  /// A file-tool path as the turn resolves one, for the `~` in a rule.
  final String Function(String path) resolvePath;

  /// Whether the turn was stopped, and the moment it was.
  final bool Function() cancelled;
  final Future<void> stopped;

  /// The sandbox helper a test hands in, where the shell is a fake with no
  /// driver behind it; the shell's own wins where both exist.
  final SandboxHelper? sandboxHelper;

  Future<StandingPermissions>? _callPolicy;

  /// Directories an `add_directory` banner agreed to, for the rest of this
  /// turn — the tier's copy of an "always" is read too, and a mirrored
  /// chat's plain Allow writes none.
  final Set<String> _runtimeDirs = {};

  /// Circuit breaker for auto mode: too many escalations means the classifier
  /// is not confident enough to be useful, so the turn falls back to asking.
  int _consecutiveAsks = 0;
  int _totalAsks = 0;
  bool _autoPaused = false;

  /// [policy] as this call reads it: once per tool call, so the gate and the
  /// run it decides see one answer; `~` read the way a file-tool path is, so
  /// a rule is in the same words as the call it is matched against, guest or
  /// host; and this turn's own grants beside the writable ones.
  Future<StandingPermissions> permissions() => _callPolicy ??= _read();

  /// A new call: the policy is read again when it is next asked for.
  void nextCall() => _callPolicy = null;

  Future<StandingPermissions> _read() async {
    final read = await policy();
    return StandingPermissions(
      permissions: [for (final rule in read.permissions) rule.withPaths(_tilde)],
      writableDirs: [
        for (final dir in read.writableDirs) _tilde(dir),
        ..._runtimeDirs,
      ],
      sandboxed: read.sandboxed,
      approveMode: read.approveMode,
    );
  }

  String _tilde(String path) =>
      path == "~" || path.startsWith("~/") ? resolvePath(path) : path;

  /// Grants [dirs] for the rest of this turn.
  void grant(Iterable<String> dirs) {
    _runtimeDirs.addAll(dirs);
    _callPolicy = null;
  }

  /// The confinement a command runs under, from the shell's driver. Only
  /// ever offered where the machine itself is the driver — a guest's rootfs
  /// is already the boundary, and Android's per-app sandbox is the OS's.
  SandboxHelper? get helper => sandboxHelper ?? shell.driverSandboxHelper;

  /// The sandbox a command runs in under [permissions]: the chat's workspace,
  /// its tmp, the project's workspace beside it — where work another
  /// conversation should find goes — and the granted directories.
  CommandSandbox? _sandboxFor(StandingPermissions permissions) {
    if (!permissions.sandboxed) return null;
    if (helper == null) return null;
    return CommandSandbox(
      workspace: workspace,
      tmp: shell.tmpDirFor(workspace),
      home: shell.machineHome,
      extraWrites: [
        if (projectWorkspace != workspace) projectWorkspace,
        ...permissions.writableDirs,
      ],
    );
  }

  /// The sandbox [analysis]'s command runs under once the rules have their
  /// word on it — none where a no-sandbox rule covers every segment that
  /// could write, the rules' own folders added where they match. One answer
  /// for the gate asking whether leaving it is being asked for, and the run.
  Future<CommandSandbox?> confinementOf(ShellCommandAnalysis analysis) async {
    final permissions = await this.permissions();
    final sandbox = _sandboxFor(permissions);
    if (sandbox == null) return null;
    final ruled = rulesSandbox(
        permissions.permissions, analysis.modelableSegments ?? const []);
    if (ruled.unconfined) return null;
    return ruled.writes.isEmpty
        ? sandbox
        : sandbox.copyWith(extraWrites: [...sandbox.extraWrites, ...ruled.writes]);
  }

  /// Run [run] gated by the rules, then the mode, into [outcome]. Rules are
  /// the standing decision, so they are consulted first in every mode: an
  /// allow runs, a deny refuses without running or asking, an ask escalates —
  /// and no match falls through to what the mode answers.
  ///
  /// What a rule is matched against is the caller's to say: [ruleSubject] —
  /// the path for a file tool, the URL for a fetch, null where the rules
  /// match the tool alone — or [analysis] for a command, judged segment by
  /// segment, so an allow that covers the head but not the tail escalates
  /// the whole. The rule's reach stops where the parse's does: a
  /// command with findings is escalated to the banner even under an allow
  /// rule, and refused in `never` mode, where nobody is there to ask.
  ///
  /// [argumentsText] is what the banner shows, worded where the call is in
  /// hand rather than parsed back out of the JSON by whoever draws it. [mode]
  /// stands in for the turn's own, as the browser's does.
  Stream<AgentEvent> decide(
    LlmToolCall call,
    String toolName,
    Future<ShellResult> Function() run,
    GateOutcome outcome, {
    String? argumentsText,
    String? ruleSubject,
    ShellCommandAnalysis? analysis,
    ApproveMode? mode,
    bool unsandboxed = false,
  }) async* {
    final policy = await permissions();
    final rules = policy.permissions;
    final turnMode = approveMode ?? policy.approveMode;
    final verdict = rulesDecideTraced(rules, toolName,
        path: ruleSubject,
        url: ruleSubject,
        segments: analysis?.modelableSegments);
    switch (verdict?.decision) {
      case PermissionDecision.deny:
        outcome.decision = (
          source: PermissionSource.rule,
          tiers: verdict!.tiers,
          decided: PermissionDecision.deny,
        );
        outcome.result = const ShellResult.failed(_deniedByRule);
        return;
      case PermissionDecision.allow:
        // Allowing a command is not allowing it out of the sandbox.
        if (unsandboxed) break;
        // An allow rule is a standing decision, but only for commands the
        // parse can vouch for: a compound command whose later segments the
        // rule does not cover runs with them unanswered. Findings here are a
        // banner, in every mode but never — where nobody is watching.
        final note = analysis?.escalationNote;
        if (note != null) {
          if (turnMode == ApproveMode.never) {
            outcome.result = ShellResult.failed(note);
            return;
          }
          yield* _ask(call, toolName, run, outcome, argumentsText);
          return;
        }
        outcome.decision = (
          source: PermissionSource.rule,
          tiers: verdict!.tiers,
          decided: PermissionDecision.allow,
        );
        outcome.result = await run();
        return;
      case PermissionDecision.ask:
      case null:
        break;
    }
    // Where the rules left the command uncovered, the deterministic tiers
    // answer before any mode does: a segment the parse proves
    // non-modifying, or a fetch the network rules allow — every segment
    // covered, or none is. An "always show me" ask rule on any segment
    // outranks the tier that would cover it, the banner being what the user
    // asked for there.
    if (verdict == null && analysis != null && !unsandboxed) {
      final tiered = _deterministicVerdict(analysis, rules);
      if (tiered != null) {
        outcome.decision = tiered;
        outcome.result = tiered.decided == PermissionDecision.allow
            ? await run()
            : const ShellResult.failed(_deniedByRule);
        return;
      }
    }
    switch (mode ?? turnMode) {
      case ApproveMode.ask:
        yield* _ask(call, toolName, run, outcome, argumentsText,
            unsandboxed: unsandboxed);
      case ApproveMode.auto:
        yield* _classify(call, toolName, run, outcome, argumentsText,
            unsandboxed: unsandboxed);
      case ApproveMode.never when unsandboxed:
        // Nobody to ask, and the sandbox is the one guard an unwatched turn
        // has: only a rule takes it away.
        outcome.result = const ShellResult.failed(_unsandboxedRefused);
      case ApproveMode.never:
        outcome.decision = (
          source: PermissionSource.mode,
          tiers: const [],
          decided: PermissionDecision.allow,
        );
        outcome.result = await run();
    }
  }

  /// Run [run] behind the workspace gate, into [outcome]: a [path] the
  /// workspaces (or [granted]) hold runs straight, one past them goes through
  /// [decide], with [ruleSubject] as it takes one.
  ///
  /// A throw inside [run] is the tool failing, not the turn: it is answered
  /// as a failed result the model reads — a decode failure on a binary file
  /// used to end the turn.
  Stream<AgentEvent> path(
    LlmToolCall call,
    String path,
    String toolName,
    Future<ShellResult> Function() run,
    GateOutcome outcome, {
    List<String> granted = const [],
    String? ruleSubject,
  }) async* {
    if (outsideWorkspaces(fs, path, workspace, projectWorkspace,
        granted: granted)) {
      yield* decide(call, toolName, () => _guarded(run), outcome,
          argumentsText: path, ruleSubject: ruleSubject);
    } else {
      outcome.result = await _guarded(run);
    }
  }

  /// Answer what [run] throws as a failed result, so an unexpected failure —
  /// a decode, a full disk, a write that could not land — is one the model
  /// reads and works around rather than one that ends the turn.
  static Future<ShellResult> _guarded(Future<ShellResult> Function() run) async {
    try {
      return await run();
    } catch (e) {
      return ShellResult.failed("$e");
    }
  }

  /// Emit the approval banner, wait for the user, and run [run] if allowed.
  Stream<AgentEvent> _ask(
    LlmToolCall call,
    String toolName,
    Future<ShellResult> Function() run,
    GateOutcome outcome,
    String? argumentsText, {
    bool unsandboxed = false,
  }) async* {
    final approval = ToolApproval(
      id: call.id,
      toolName: toolName,
      argumentsJson: call.argumentsJson,
      argumentsText: argumentsText,
      unsandboxed: unsandboxed,
    );
    yield ApprovalRequestEvent(approval);
    // An "always" answer's rule is written by the repository before the
    // answer arrives, and the next call's policy read finds it.
    final answer = await approve(approval);
    final allowed = answer.isAllow;
    outcome.decision = (
      source: PermissionSource.human,
      tiers: [
        switch (answer) {
          ApprovalResponse.alwaysAllowChat => PermissionTier.chat,
          ApprovalResponse.alwaysAllowProject => PermissionTier.project,
          _ => PermissionTier.once,
        },
      ],
      decided: allowed ? PermissionDecision.allow : PermissionDecision.deny,
    );
    outcome.byPerson = true;
    outcome.result =
        allowed ? await run() : const ShellResult.failed(_deniedByUser);
  }

  /// Classify the call, then allow (run), deny (refuse), or ask (escalate to
  /// the banner).
  Stream<AgentEvent> _classify(
    LlmToolCall call,
    String toolName,
    Future<ShellResult> Function() run,
    GateOutcome outcome,
    String? argumentsText, {
    bool unsandboxed = false,
  }) async* {
    if (_autoPaused) {
      yield* _ask(call, toolName, run, outcome, argumentsText,
          unsandboxed: unsandboxed);
      return;
    }

    // Raced with a stop: a turn outliving its abort ran on into the next
    // turn, clearing its banner and rewriting the session under it.
    final decision = await Future.any([
      (classifier ?? const NoClassifier()).classify(toolName, call.argumentsJson,
          workspace: workspace,
          alsoWritable: [
            if (projectWorkspace != workspace) projectWorkspace,
            ...(await permissions()).writableDirs,
          ]),
      stopped.then((_) => PermissionDecision.ask),
    ]);
    if (cancelled()) {
      outcome.result = const ShellResult.failed(notExecuted);
      return;
    }

    if (decision != PermissionDecision.ask) {
      _consecutiveAsks = 0;
      outcome.decision = (
        source: PermissionSource.classifier,
        tiers: const [],
        decided: decision,
      );
    }
    switch (decision) {
      case PermissionDecision.allow:
        outcome.result = await run();
      case PermissionDecision.deny:
        outcome.result = const ShellResult.failed(
            "Denied by auto mode as dangerous. Do not retry this command; "
            "tell the user what you were trying to do and let them decide.");
      case PermissionDecision.ask:
        _consecutiveAsks++;
        _totalAsks++;
        if (_consecutiveAsks >= 3 || _totalAsks >= 20) {
          _autoPaused = true;
          yield InfoEvent("Auto mode paused: too many uncertain commands. "
              "Asking for every command for the rest of this turn.");
        }
        yield* _ask(call, toolName, run, outcome, argumentsText,
            unsandboxed: unsandboxed);
    }
  }

  static const _deniedByUser = "The user denied this command. Ask them what "
      "to do instead, or try something else.";

  static const _unsandboxedRefused = "Running this outside the sandbox needs "
      "the user's approval, and nobody is here to give it. Do it inside the "
      "workspaces, or tell the user what needs to run unsandboxed.";

  static const _deniedByRule = "Denied by a permission rule you set. Do not "
      "retry this command; tell the user what you were trying to do and let "
      "them decide.";

  /// The deterministic command tiers the rules leave standing: every segment
  /// covered by a rule allow, proven non-modifying by its own text, or
  /// allowed by the network rules as a fetch. Null where any segment is
  /// uncovered, and where an ask rule wanted to see any of it — the mode's own
  /// path decides those, every time. A deny from the network rules is
  /// returned as one, refusal being what the rule said.
  Decision? _deterministicVerdict(
    ShellCommandAnalysis analysis,
    List<PermissionRule> rules,
  ) {
    final segments = analysis.modelableSegments;
    if (segments == null || segments.isEmpty) return null;
    final tiers = <PermissionTier>{};
    var ruled = false;
    for (final segment in segments) {
      final profile = profileSegment(segment);
      if (!profile.modelable) return null;
      final verdict = segmentVerdict(rules, segment);
      switch (verdict?.decision) {
        case PermissionDecision.deny:
          return (
            source: PermissionSource.rule,
            tiers: verdict!.tiers.toList(),
            decided: PermissionDecision.deny,
          );
        case PermissionDecision.ask:
          return null;
        case PermissionDecision.allow:
          tiers.addAll(verdict!.tiers);
          ruled = true;
          continue;
        case null:
          break;
      }
      switch (profile.reach) {
        case SegmentReach.nonModifying:
          continue;
        case SegmentReach.network:
          // The same consult a `webfetch` call takes — one standing answer
          // covers the tool and the fetcher commands alike — with the
          // segment's host as the subject. A fetch whose host no rule speaks
          // for is uncovered, wherever the mode asks about it next.
          final network =
              rulesDecideTraced(rules, webfetchToolName, url: profile.url);
          switch (network?.decision) {
            case PermissionDecision.deny:
              return (
                source: PermissionSource.rule,
                tiers: network!.tiers.toList(),
                decided: PermissionDecision.deny,
              );
            case PermissionDecision.allow:
              tiers.addAll(network!.tiers);
              ruled = true;
              continue;
            case PermissionDecision.ask:
            case null:
              return null;
          }
        case SegmentReach.other:
          return null;
      }
    }
    return (
      source: ruled ? PermissionSource.rule : PermissionSource.parse,
      tiers: ruled ? tiers.toList() : const <PermissionTier>[],
      decided: PermissionDecision.allow,
    );
  }
}
