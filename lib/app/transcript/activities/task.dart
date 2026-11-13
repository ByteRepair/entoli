import "../../../domain/agent_backend.dart" show taskToolName;
import "../../../domain/tool_arg.dart";
import "../../settings/spec.dart" show SettingReader;
import "../../sub_agent_transcript.dart" show subAgentLiveProvider;
import "../activity.dart";
import "tool_run.dart";

/// A sub-agent's call, read from the call's own arguments.
final class TaskActivity extends ToolActivity {
  const TaskActivity();

  @override
  String get tool => taskToolName;

  @override
  String get spoken => "Ran a sub-agent";

  SubAgentActivity _agentOf(Run run) => SubAgentActivity(
    agent: stringArg(run.call?.argumentsJson, "agent") ?? "task",
  );

  @override
  ActivityNode node(SettingReader reader, Run run) =>
      _agentOf(run).node(reader, run);

  @override
  ActivityDetail detail(SettingReader reader, Run run) =>
      _agentOf(run).detail(reader, run);
}

/// A sub-agent's run: the sub-agent that ran, and behind it its own
/// transcript as it is written — the same activities a reply has — with the
/// text it returned standing in where there is no transcript. Shown for the
/// call in the reply and for the sub-agent's pill alike; the prompt is the
/// call's where the call is to hand, [prompt] until then.
final class SubAgentActivity extends Activity {
  const SubAgentActivity({required this.agent, this.prompt = ""});

  final String agent;
  final String prompt;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final result = run.result;
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.subAgent,
      text: result == null
          ? "Running sub-agent @$agent"
          : "Sub-agent @$agent ${run.failed ? "failed" : "finished"}",
      isError: run.failed,
      busy: run.going && result == null,
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) {
    final result = run.result;
    final sub = (chatId: run.chatId, callId: run.callId!);
    final source = subAgentLiveProvider(sub);
    final live = reader.watch(source);
    final transcript = live.message;
    final drawn = transcript != null && transcript.parts.isNotEmpty;
    return ActivityDetail(
      title: "Sub-agent @$agent",
      glyph: TranscriptGlyph.subAgent,
      sections: [
        DetailSection(
          label: "Prompt",
          body: stringArg(run.call?.argumentsJson, "prompt") ?? prompt,
        ),
        // The transcript's text joined, so left out where it is drawn.
        if (!drawn) DetailSection(label: "Output", body: result?.output),
        DetailSection(
          label: "Error",
          body: result?.exceptionInfo,
          isError: true,
        ),
      ],
      transcript: drawn
          ? NestedTranscript(
              chatId: run.chatId,
              message: transcript,
              running: live.running,
              source: source,
            )
          : null,
    );
  }
}
