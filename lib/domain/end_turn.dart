import "models.dart";

/// The tool a room member calls to say nothing. Named in the domain because
/// the controller, the projection and the page all read a reply by it.
const endTurnToolName = "end_turn";

/// Whether [message] is a reply that ended with `end_turn` and said nothing:
/// on the log for the record, absent from the page and from every other
/// participant's reading of the room. A reply that wrote text as well is a
/// reply.
bool endedSilently(Message message) =>
    message.role == MessageRole.assistant &&
    !message.hasText &&
    message.parts.any(
      (p) => p is ToolCallPart && p.toolCall.name == endTurnToolName,
    );
