import "../../domain/ask.dart";
import "../../domain/models.dart";
import "llm/llm_client.dart";
import "templates.dart";

/// The conversation as a provider has to see it, built out of what `conv.jsonl`
/// kept. This is what makes a session that missed the conversation — rewound,
/// or belonging to a chat opened after a restart — answer as though it had been
/// there all along.
///
/// A domain assistant [Message] is a whole turn, and a turn is several provider
/// responses; each has to go back as one assistant message with its own
/// thinking, text and calls, followed by the results answering them. The parts
/// say which response they came out of, so the grouping is read rather than
/// guessed.
List<LlmMessage> project(List<Message> messages) {
  final projected = <LlmMessage>[];
  for (final message in messages) {
    switch (message.role) {
      case MessageRole.user:
        final text = _userText(message);
        if (text.isNotEmpty) projected.add(LlmMessage(role: LlmRole.user, text: text));
      case MessageRole.assistant:
        projected.addAll(_assistant(message));
      case MessageRole.system:
      case MessageRole.tool:
        // The system prompt is rewritten every turn, and a result is a part of
        // the turn that ran it rather than a message of its own.
        break;
    }
  }
  return projected;
}

/// Files are named rather than resent: the bytes are on disk, reading them back
/// would make this asynchronous, and only the turn actually being replayed
/// carries its own attachments.
String _userText(Message message) {
  final text = message.plainText.trim();
  final files = message.files.map((f) => f.filename).join(", ");
  if (files.isEmpty) return text;
  return text.isEmpty ? "(attached: $files)" : "$text\n\n(attached: $files)";
}

Iterable<LlmMessage> _assistant(Message message) sync* {
  for (final response in _responses(message.parts)) {
    final reasoning = StringBuffer();
    final text = StringBuffer();
    String? signature;
    final calls = <LlmToolCall>[];
    final names = <String, String>{};
    final answers = <String, String>{};

    for (final part in response) {
      switch (part) {
        case ReasoningPart():
          reasoning.write(part.text);
          signature ??= part.signature;
        case TextPart():
          text.write(part.text);
        case ToolCallPart(:final toolCall):
          names[toolCall.id] = toolCall.name;
          calls.add(LlmToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJson: toolCall.argumentsJson ?? "{}",
          ));
        case ToolResultPart(:final result):
          answers[result.callId] = _resultText(names[result.callId], result);
        case FilePart():
        case ErrorPart():
          // An error is what the turn reported to the user; the model never
          // saw it, so putting it back would be inventing an exchange.
          break;
      }
    }

    if (reasoning.isEmpty && text.isEmpty && calls.isEmpty) continue;

    yield LlmMessage(
      role: LlmRole.assistant,
      text: text.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      reasoningSignature: signature,
      toolCalls: calls,
    );

    // Every call is answered, including one whose result never landed: a
    // provider that sees a tool call with no result rejects the next turn.
    for (final call in calls) {
      yield LlmMessage(
        role: LlmRole.tool,
        toolCallId: call.id,
        text: answers[call.id] ?? _unanswered,
      );
    }
  }
}

/// The parts of one turn, split into the responses they came out of. A part
/// naming no response — a result, an error — continues the one before it, since
/// that is the response it belongs to.
List<List<MessagePart>> _responses(List<MessagePart> parts) {
  final responses = <List<MessagePart>>[];
  String? current;
  for (final part in parts) {
    final id = _responseIdOf(part);
    if (responses.isEmpty || (id != null && id != current)) {
      responses.add([]);
      current = id;
    }
    responses.last.add(part);
  }
  return responses;
}

String? _responseIdOf(MessagePart part) => switch (part) {
      TextPart(:final responseId) ||
      ReasoningPart(:final responseId) ||
      ToolCallPart(:final responseId) =>
        responseId,
      _ => null,
    };

/// Worded the way the agent worded it when it ran, so a projected conversation
/// is the one the model already answered. An `ask_user` result is the answers
/// themselves; every other call reads as a command's outcome.
String _resultText(String? tool, ToolResult result) => tool == askToolName
    ? result.output
    : observation(
        returnCode: result.returnCode,
        output: result.output,
        exceptionInfo: result.exceptionInfo,
      );

final _unanswered = observation(
  returnCode: -1,
  output: "",
  exceptionInfo: "This command was not executed.",
);
