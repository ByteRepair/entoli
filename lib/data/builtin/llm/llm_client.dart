import "dart:convert";
import "dart:typed_data";

/// The conversation as a provider sees it. Deliberately not `Message` from the
/// domain: that is what Entoli persists, this is what goes over the wire,
/// and the two diverge (a tool result is a message here, a part there).
enum LlmRole { system, user, assistant, tool }

class LlmToolCall {
  const LlmToolCall({required this.id, required this.name, required this.argumentsJson});

  final String id;
  final String name;
  final String argumentsJson;
}

/// A file the user attached, as the provider takes it. Text is inlined into
/// the prompt; an image goes as its own block; anything else is named, because
/// a model that cannot read it is better told it exists than handed bytes.
class LlmAttachment {
  LlmAttachment({required this.filename, required this.mimeType, required this.bytes});

  final String filename;
  final String mimeType;
  final Uint8List bytes;

  bool get isImage => mimeType.startsWith("image/");

  bool get isText => mimeType.startsWith("text/") || mimeType == "application/json";

  /// Encoded once and kept. An attachment stays in the session for the life of
  /// the chat, and every step of every later turn resends the whole
  /// conversation — so encoding on use would re-encode the same megabytes
  /// dozens of times.
  late final String base64 = base64Encode(bytes);

  late final String asText = utf8.decode(bytes, allowMalformed: true);
}

class LlmMessage {
  const LlmMessage({
    required this.role,
    this.text = "",
    this.toolCalls = const [],
    this.toolCallId,
    this.reasoning,
    this.reasoningSignature,
    this.attachments = const [],
  });

  final LlmRole role;
  final String text;
  final List<LlmToolCall> toolCalls;

  /// Set on a [LlmRole.tool] message: which call it answers.
  final String? toolCallId;

  /// What the model thought before replying. Kept because Anthropic rejects a
  /// tool-use turn whose thinking was dropped once thinking is enabled —
  /// [reasoningSignature] is the token it checks that against.
  final String? reasoning;
  final String? reasoningSignature;

  final List<LlmAttachment> attachments;
}

class LlmTool {
  const LlmTool({required this.name, required this.description, required this.schema});

  final String name;
  final String description;
  final Map<String, dynamic> schema;
}

/// Streamed output. Text and reasoning arrive in pieces; [LlmCompletion] closes
/// the turn with the assembled message, so a provider that streams nothing
/// still reports one.
sealed class LlmChunk {
  const LlmChunk();
}

class LlmTextChunk extends LlmChunk {
  const LlmTextChunk(this.text);
  final String text;
}

class LlmReasoningChunk extends LlmChunk {
  const LlmReasoningChunk(this.text);
  final String text;
}

/// The signature Anthropic stamps a thinking block with. Its own chunk because
/// it arrives while the block is still open — before the reply's first token —
/// so the block can be closed already carrying it, rather than being written a
/// second time once the response completes.
class LlmReasoningSignature extends LlmChunk {
  const LlmReasoningSignature(this.signature);
  final String signature;
}

class LlmCompletion extends LlmChunk {
  const LlmCompletion({required this.message, this.finishReason});

  final LlmMessage message;

  /// Why the model stopped. `length` means it was cut off mid-thought, which
  /// reads as a missing tool call and would otherwise be blamed on the model.
  final String? finishReason;
}

/// A provider said no. [retryable] is the difference between waiting and
/// giving up: a rate limit clears, a bad key does not.
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => statusCode == null ? message : "HTTP $statusCode: $message";
}

abstract class LlmClient {
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  });

  /// What the endpoint says it can run. Empty when it does not offer a list —
  /// the provider's configured models stand in for it.
  Future<List<String>> listModels();

  void close();
}
