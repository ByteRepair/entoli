import "../../../domain/agent_backend.dart";
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

const imageGenerationToolName = "image_generation";

/// Generate an image and show it in the reply. Offered only where Settings >
/// Image Generation names a model and there is somewhere to keep what it
/// makes. Not gated: it touches neither the workspace nor the shell, and the
/// setting is the user's consent.
class ImageGenerationTool extends AgentTool {
  ImageGenerationTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.images;

  @override
  String get name => imageGenerationToolName;

  @override
  bool get offered => offer.images;

  @override
  String get runningLabel => "Generating an image";

  @override
  String get description =>
      "Generate an image from a text description. The "
      "image is shown to the user in the chat and attached to the result. "
      "Describe the subject, style and composition in full: the image model "
      "has no other context.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "prompt": {
        "type": "string",
        "description": "What the image should show.",
      },
    },
    "required": ["prompt"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final prompt = stringArg(call.argumentsJson, "prompt");
    if (prompt == null) {
      yield* toolRejected(
        call,
        'The $imageGenerationToolName tool takes {"prompt": "..."}.',
      );
      return;
    }
    yield toolCalled(call, prompt);
    final List<ImageEvent> saved;
    try {
      final images = await turn.generateImage!(prompt);
      saved = [for (final image in images) await turn.saved(image)];
    } catch (e) {
      yield toolFailed(call, "$e");
      return;
    }
    if (saved.isEmpty) {
      yield toolFailed(call, "The image model returned no image.");
      return;
    }
    yield* Stream.fromIterable(saved);
    yield toolOk(
      call,
      "Generated ${saved.length} image(s), attached below and "
      "shown to the user in the chat.",
    );
  }
}
