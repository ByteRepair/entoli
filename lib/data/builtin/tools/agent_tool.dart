import "../../../domain/agent_backend.dart";
import "../../../domain/agent_browser.dart" show BrowserUploadPolicy;
import "../../../domain/builtin_project.dart";
import "../../../domain/models.dart";
import "../../../domain/prompt_library.dart";
import "../../../domain/shell.dart";
import "../llm/llm_client.dart";
import "turn.dart";

/// What a turn may be offered: the platform's facts minus what the turn is
/// not offered — a headless turn's takes and a built-in project's. The input
/// to [ToolOffer], resolved by whoever starts the turn, before the agent
/// narrows it by what it was actually handed.
class AgentCapabilities {
  const AgentCapabilities({
    required this.commands,
    required this.webSearch,
    required this.ask,
    required this.task,
    required this.artifact,
    required this.createSkill,
    this.trigger = false,
    this.browser = false,
  });

  /// The full set, before the platform's facts or a project's takes away any
  /// of it: what a top-level turn in a user's project is offered.
  static const AgentCapabilities full = AgentCapabilities(
    commands: true,
    webSearch: true,
    ask: true,
    task: true,
    artifact: true,
    createSkill: true,
    trigger: true,
  );

  /// Whether a command can run at all: the platform's fact, which a project
  /// does not widen or narrow.
  final bool commands;
  final bool webSearch;
  final bool ask;
  final bool task;
  final bool artifact;
  final bool createSkill;
  final bool trigger;

  /// Whether the browser tools are offered: a browser picked in Settings >
  /// Agent Browser, on a platform that can drive one. Off in [full], since
  /// it is a pick rather than something every device has.
  final bool browser;

  /// What this device can offer, minus what [disabled] takes away — the
  /// project's takes, and a headless turn's.
  AgentCapabilities.forTurn({
    required bool commands,
    required bool webSearch,
    required Set<AgentCapability> disabled,
    bool browser = false,
  }) : this(
          commands: commands,
          webSearch: webSearch && !disabled.contains(AgentCapability.webSearch),
          ask: !disabled.contains(AgentCapability.ask),
          task: !disabled.contains(AgentCapability.task),
          artifact: !disabled.contains(AgentCapability.artifact),
          createSkill: !disabled.contains(AgentCapability.createSkill),
          trigger: !disabled.contains(AgentCapability.trigger),
          browser: browser,
        );

  /// What a sub-agent runs under: unattended, so it asks nothing, fans out
  /// nothing, and publishes nothing — there is no viewer to open what it made.
  AgentCapabilities get unattended => AgentCapabilities(
        commands: commands,
        webSearch: webSearch,
        ask: false,
        task: false,
        artifact: false,
        createSkill: false,
        trigger: false,
      );
}

/// Everything that decides which tools a turn is offered and how each is
/// worded, and nothing else. One value because the tool list and the system
/// prompt are both built from it: a prompt that advertises a tool the list
/// does not carry is a call the model makes into silence. The live turn's is
/// `BuiltinAgent.offer`; the prefill builds the default one, and a turn that
/// differs from it misses the warmed prefix rather than the two disagreeing.
class ToolOffer {
  const ToolOffer({
    this.caps = AgentCapabilities.full,
    this.skills = const [],
    this.memory = false,
    this.images = false,
    this.screenshots = false,
    this.uploads = BrowserUploadPolicy.classifier,
    this.oneShot = false,
    this.sandboxed = false,
    this.background = false,
    this.participants,
    this.member = false,
    this.customizing = false,
    this.attachments = false,
  });

  /// What the turn may have, already narrowed by what the agent was handed.
  final AgentCapabilities caps;

  /// The whole skill library, both invocation halves: the `skill` tool reads
  /// the model-invocable half, and so does its section of the prompt.
  final List<PromptDocument> skills;

  /// A memory store is there to save to and search.
  final bool memory;

  /// An image model is set, and there is somewhere to keep what it makes.
  final bool images;

  /// The model reads images, and there is somewhere to keep a screenshot.
  final bool screenshots;

  /// Who picks what `browser_upload` sends.
  final BrowserUploadPolicy uploads;

  /// A sub-agent's turn: commands one-shot, no plan, no triggers, no browser.
  final bool oneShot;

  /// The terminal environment enforces a sandbox, so leaving it means
  /// something and `bash` offers it.
  final bool sandboxed;

  /// The shell can leave a run going, and this turn hears how it ended.
  final bool background;

  /// The room's members, on an Omada turn; null on any other.
  final List<PromptDocument>? participants;

  /// The turn answers as a member of the room rather than the house.
  final bool member;

  /// The session loaded the customization skill.
  final bool customizing;

  /// The chat has a `resources/` to copy attachments out of.
  final bool attachments;
}

/// One tool the model can call: everything about it in one place — what the
/// model is told, when it is offered, what it adds to the system prompt, and
/// what it does. The tool list, the dispatch and the prompt are all read off
/// the registry (`registry.dart`), so adding a tool is a class and a line
/// there.
///
/// Built per turn over the turn's [offer], so every member is a getter a
/// tool answers from it: a constant for most, worked out for the few whose
/// wording depends on the turn.
abstract class AgentTool {
  AgentTool(this.offer);

  final ToolOffer offer;

  /// What the model calls it by, and what the log records.
  String get name;

  String get description;

  /// The JSON schema of the arguments.
  Map<String, dynamic> get schema;

  /// Whether this turn is offered it. A call to a tool the turn was not
  /// offered is answered as an unknown tool.
  bool get offered => true;

  /// What the spinner says while it runs, or null for the ones that finish
  /// too fast to be worth naming: a label that flashes is worse than none.
  String? get runningLabel => null;

  /// What the system prompt's "you call a tool when you need to" says this
  /// tool is for. A group that shares one (the browser's, the plan's) says it
  /// once, on one of its members.
  String? get fragment => null;

  /// Its own section of the system prompt, where the description is not room
  /// enough. Shared by a group the way [fragment] is.
  String? get section => null;

  /// Run [call], reporting it and answering it: every call is reported with
  /// a [ToolCallEvent] and answered with a [ToolResultEvent], whatever else
  /// happens between — a provider that sees a call with no result rejects
  /// the next turn.
  Stream<AgentEvent> run(LlmToolCall call, Turn turn);

  /// The tool as the request carries it.
  LlmTool get definition =>
      LlmTool(name: name, description: description, schema: schema);
}

/// [call] as reported, with [text] as what the label shows of it.
ToolCallEvent toolCalled(LlmToolCall call, [String? text]) =>
    ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: text,
      signature: call.signature,
    ));

ToolResultEvent toolOk(LlmToolCall call, String output) =>
    ToolResultEvent(ToolResult(callId: call.id, returnCode: 0, output: output));

ToolResultEvent toolFailed(LlmToolCall call, String problem) =>
    ToolResultEvent(ToolResult(
        callId: call.id, returnCode: -1, output: "", exceptionInfo: problem));

/// A call that could not be run at all: the UI still sees the pair, and the
/// model still gets told why.
Stream<AgentEvent> toolRejected(LlmToolCall call, String problem) async* {
  yield toolCalled(call);
  yield toolFailed(call, problem);
}

/// What decided a call, the tiers that spoke, and the verdict.
typedef Decision = ({
  PermissionSource source,
  List<PermissionTier> tiers,
  PermissionDecision decided,
});

/// A command's outcome as the result of the call that asked for it: one that
/// ran, one that was refused, one that was never reached. The directory the
/// shell was left in rides on it as a fact, and [decision] — what let it run
/// or refused it — beside it.
ToolResult toolRan(LlmToolCall call, ShellResult result, {Decision? decision}) =>
    ToolResult(
      callId: call.id,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
      cwd: result.cwd,
      decidedBy: decision?.source,
      decidedTier: decision?.tiers ?? const [],
      decided: decision?.decided,
    );
