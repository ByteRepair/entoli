import "llm/llm_client.dart";

const imageGenerationToolName = "image_generation";

const imageGenerationTool = LlmTool(
  name: imageGenerationToolName,
  description: "Generate an image from a text description. The image is shown "
      "to the user in the chat and attached to the result. Describe the "
      "subject, style and composition in full: the image model has no other "
      "context.",
  schema: {
    "type": "object",
    "properties": {
      "prompt": {
        "type": "string",
        "description": "What the image should show.",
      },
    },
    "required": ["prompt"],
  },
);
