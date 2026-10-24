import "llm_client.dart";

/// [inner] for a model or endpoint that cannot take every file the
/// conversation holds: each image or PDF it cannot read is replaced by a line
/// naming it. A provider rejects the whole request over one file it cannot
/// read, and the file stays in the history, so without this every later turn
/// of the chat fails the same way.
class ReadableClient implements LlmClient {
  ReadableClient(this.inner, {required this.images, required this.pdfs});

  final LlmClient inner;
  final bool images;
  final bool pdfs;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) =>
      inner.stream(
        readable(messages, images: images, pdfs: pdfs),
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

/// What the PDFs of one request may add up to, before base64. Anthropic caps
/// a request at 32 MB and OpenAI at 50 MB of files, and base64 is a third
/// again, so this leaves room for the rest of the conversation.
const pdfBudgetBytes = 20 * 1024 * 1024;

/// [messages] with what the model cannot read named instead of sent. PDFs are
/// kept newest first while they fit [pdfBudgetBytes]: every request resends
/// all of them, and the older ones are the ones the model has already read.
List<LlmMessage> readable(List<LlmMessage> messages,
    {required bool images, required bool pdfs}) {
  // By identity: the bytes are megabytes, and hashing them per request is
  // what an equality set would do.
  final keptPdfs = Set<LlmAttachment>.identity();
  if (pdfs) {
    var budget = pdfBudgetBytes;
    for (final m in messages.reversed) {
      for (final a in m.attachments.reversed) {
        if (!a.isPdf || a.bytes.length > budget) continue;
        budget -= a.bytes.length;
        keptPdfs.add(a);
      }
    }
  }
  bool unread(LlmAttachment a) =>
      (a.isImage && !images) || (a.isPdf && !keptPdfs.contains(a));
  String names(Iterable<LlmAttachment> files) =>
      files.map((a) => a.filename).join(", ");
  return [
    for (final m in messages)
      if (!m.attachments.any(unread))
        m
      else
        LlmMessage(
          role: m.role,
          text: [
            m.text,
            if (m.attachments.any((a) => a.isImage && unread(a)))
              "(Not shown, as this model cannot view images: "
                  "${names(m.attachments.where((a) => a.isImage && unread(a)))})",
            if (m.attachments.any((a) => a.isPdf && unread(a)))
              pdfs
                  ? "(Not sent, as the conversation's PDFs are over the size "
                      "a request can carry: "
                      "${names(m.attachments.where((a) => a.isPdf && unread(a)))}. "
                      "Read it with a command instead.)"
                  : "(Not sent, as this model cannot read PDFs here: "
                      "${names(m.attachments.where((a) => a.isPdf && unread(a)))}. "
                      "Read it with a command instead.)",
          ].join("\n\n"),
          toolCalls: m.toolCalls,
          toolCallId: m.toolCallId,
          reasoning: m.reasoning,
          reasoningSignature: m.reasoningSignature,
          attachments: [for (final a in m.attachments) if (!unread(a)) a],
        ),
  ];
}
