import "dart:convert";
import "dart:typed_data";

import "package:collection/collection.dart";

/// The conversation as a provider sees it. Deliberately not `Message` from the
/// domain: that is what Entoli persists, this is what goes over the wire,
/// and the two diverge (a tool result is a message here, a part there).
enum LlmRole { system, user, assistant, tool }

class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
    this.signature,
  });

  final String id;
  final String name;
  final String argumentsJson;

  /// Gemini's thought signature for the call, which it rejects the call's
  /// replay without. See [ToolCall.signature].
  final String? signature;

  /// By field: the session's wordings are built twice over the same records
  /// (live, and read back), and every parity check between them compares
  /// these by value.
  @override
  bool operator ==(Object other) =>
      other is LlmToolCall &&
      id == other.id &&
      name == other.name &&
      argumentsJson == other.argumentsJson &&
      signature == other.signature;

  @override
  int get hashCode => Object.hash(id, name, argumentsJson, signature);
}

/// A file the user attached, as the provider takes it. Text is inlined into
/// the prompt; an image or a PDF goes as its own block; anything else is
/// named, because a model that cannot read it is better told it exists than
/// handed bytes.
class LlmAttachment {
  LlmAttachment({
    required this.filename,
    required this.mimeType,
    required this.bytes,
  });

  final String filename;
  final String mimeType;
  final Uint8List bytes;

  bool get isImage => mimeType.startsWith("image/");

  bool get isPdf => mimeType == "application/pdf";

  /// Sent as a block of its own rather than folded into the text.
  bool get isBlock => isImage || isPdf;

  /// Roughly: page objects counted in the raw bytes. One kept in a compressed
  /// object stream is invisible to this, so a file showing none is guessed at
  /// a page per 100 KB instead.
  late final int pdfPages = () {
    final pages = _pageObjects(bytes);
    return pages > 0 ? pages : bytes.length ~/ 100000 + 1;
  }();

  bool get isText =>
      mimeType.startsWith("text/") || mimeType == "application/json";

  /// Encoded once and kept. An attachment stays in the session for the life of
  /// the chat, and every step of every later turn resends the whole
  /// conversation — so encoding on use would re-encode the same megabytes
  /// dozens of times.
  late final String base64 = base64Encode(bytes);

  late final String asText = utf8.decode(bytes, allowMalformed: true);

  /// By field, as [LlmToolCall]'s — the bytes read back from the same file
  /// are the same bytes, two instances or not.
  @override
  bool operator ==(Object other) =>
      other is LlmAttachment &&
      filename == other.filename &&
      mimeType == other.mimeType &&
      const ListEquality<int>().equals(bytes, other.bytes);

  @override
  int get hashCode =>
      Object.hash(filename, mimeType, const ListEquality<int>().hash(bytes));
}

/// `/Type /Page` and not `/Pages`, over the bytes as they are: a decode
/// would copy the whole file to find a few dozen markers.
int _pageObjects(Uint8List bytes) {
  const type = [0x2f, 0x54, 0x79, 0x70, 0x65]; // /Type
  const page = [0x2f, 0x50, 0x61, 0x67, 0x65]; // /Page
  bool at(int i, List<int> word) {
    if (i + word.length > bytes.length) return false;
    for (var k = 0; k < word.length; k++) {
      if (bytes[i + k] != word[k]) return false;
    }
    return true;
  }

  var count = 0;
  for (var i = bytes.indexOf(0x2f); i >= 0; i = bytes.indexOf(0x2f, i + 1)) {
    if (!at(i, type)) continue;
    var j = i + type.length;
    while (j < bytes.length &&
        const [0x20, 0x0a, 0x0d, 0x09].contains(bytes[j])) {
      j++;
    }
    if (!at(j, page)) continue;
    final next = j + page.length;
    final letter =
        next < bytes.length &&
        (bytes[next] | 0x20) >= 0x61 &&
        (bytes[next] | 0x20) <= 0x7a;
    if (!letter) count++;
  }
  return count;
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

/// The system messages as one standing prompt, the join Anthropic's `system`
/// parameter and the Apple bridge's instructions both make: the system roles
/// in order, empty texts dropped, blank lines between.
String joinedSystemText(List<LlmMessage> messages) => [
  for (final message in messages)
    if (message.role == LlmRole.system && message.text.isNotEmpty) message.text,
].join("\n\n");

class LlmTool {
  const LlmTool({
    required this.name,
    required this.description,
    required this.schema,
  });

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

/// How far the provider has got through the prompt, before it has generated
/// anything at all.
///
/// llama.cpp's `prompt_progress`, and only ever that — no hosted provider
/// reports it, and none is asked to. It exists because prefill on a phone is
/// minutes: without it the whole of that wait is a spinner that cannot be told
/// apart from a hang.
///
/// [cache] is the part of [total] that was already in the KV cache and so cost
/// nothing, which is why a second turn in the same chat starts most of the way
/// through.
class LlmPromptProgress extends LlmChunk {
  const LlmPromptProgress({
    required this.processed,
    required this.total,
    required this.cache,
  });

  final int processed;
  final int total;
  final int cache;

  /// Null where the provider said the prompt was empty, rather than a division
  /// by zero or a confident 100%.
  double? get fraction =>
      total <= 0 ? null : (processed / total).clamp(0.0, 1.0);
}

class LlmCompletion extends LlmChunk {
  const LlmCompletion({required this.message, this.finishReason, this.usage});

  final LlmMessage message;

  /// Why the model stopped. `length` means it was cut off mid-thought, which
  /// reads as a missing tool call and would otherwise be blamed on the model.
  final String? finishReason;

  /// What the provider said the request cost, where it said anything. The
  /// auto-compact threshold reads it — a provider that reports nothing leaves
  /// [usage] null and the estimate stands in.
  final LlmUsage? usage;
}

/// What a provider said one request and its answer cost. Input counts the
/// whole conversation sent, so the newest completion carries what the session
/// is weighing; cache is the part of it that did not have to be re-read.
class LlmUsage {
  const LlmUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// What the request put in front of the model, cached tokens included —
  /// they occupy the context window whether or not they cost anything.
  int get totalInputTokens => inputTokens + cacheReadTokens + cacheWriteTokens;

  /// The context this one exchange leaves behind: the input, grown by the
  /// reply that will be sent back with it on the next call.
  int get contextTokens => totalInputTokens + outputTokens;
}

/// A provider said no. [retryable] is the difference between waiting and
/// giving up: a rate limit clears, a bad key does not.
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() =>
      statusCode == null ? message : "HTTP $statusCode: $message";
}

abstract class LlmClient {
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  });

  void close();
}

/// Clients kept by name, rebuilt when what they were built from changes.
///
/// `LlmRegistry` holds one, keyed by provider id over the API shape, URL and
/// key. The close on eviction is the half that is easy to leave out, and an
/// `http.Client` that is dropped rather than closed holds its connections until
/// the isolate ends.
///
/// [signature] is whatever "still the same client" means to the holder. It is a
/// string because the holder composes one out of several fields, and comparing
/// a record would mean a type parameter for the sake of an `==`.
class LlmClientCache {
  final _entries = <String, ({String signature, LlmClient client})>{};

  LlmClient of(String name, String signature, LlmClient Function() build) {
    final cached = _entries[name];
    if (cached != null && cached.signature == signature) return cached.client;
    cached?.client.close();
    final client = build();
    _entries[name] = (signature: signature, client: client);
    return client;
  }

  void close() {
    for (final entry in _entries.values) {
      entry.client.close();
    }
    _entries.clear();
  }
}
