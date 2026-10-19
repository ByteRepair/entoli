import "llm_client.dart";

/// [inner] for a model that cannot take images: every image in a request is
/// replaced by a line naming it. A provider rejects the whole request over one
/// image its model cannot read, and the image stays in the history, so without
/// this every later turn of the chat fails the same way.
class TextOnlyClient implements LlmClient {
  TextOnlyClient(this.inner);

  final LlmClient inner;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) =>
      inner.stream(
        withoutImages(messages),
        model: model,
        tools: tools,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
      );

  @override
  Future<List<String>> listModels() => inner.listModels();

  @override
  void close() => inner.close();
}

List<LlmMessage> withoutImages(List<LlmMessage> messages) => [
      for (final m in messages)
        if (!m.attachments.any((a) => a.isImage))
          m
        else
          LlmMessage(
            role: m.role,
            text: "${m.text}\n\n(Not shown, as this model cannot view images: "
                "${m.attachments.where((a) => a.isImage).map((a) => a.filename).join(", ")})",
            toolCalls: m.toolCalls,
            toolCallId: m.toolCallId,
            reasoning: m.reasoning,
            reasoningSignature: m.reasoningSignature,
            attachments: [for (final a in m.attachments) if (!a.isImage) a],
          ),
    ];
