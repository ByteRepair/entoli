import "llm/llm_client.dart";

/// Capture the screen and hand it to the model as an image. The PNG is written
/// to the chat's `resources/` and the result names it, so the projection can
/// read the bytes back and attach them to the tool message — the same path a
/// user's image attachment takes.
const screenshotTool = LlmTool(
  name: screenshotToolName,
  description: "Capture the current screen and return it as an image. Use it "
      "to see what is on screen before clicking or typing, or to check the "
      "result of an action.",
  schema: {
    "type": "object",
    "properties": {},
  },
);

/// Click at a point on the screen. Primary, secondary or tertiary.
const clickTool = LlmTool(
  name: clickToolName,
  description: "Click at a point on the screen. `button` is 1 for a primary "
      "(left) click, 2 for secondary (right), 3 for tertiary (middle). Use "
      "`screenshot` first to find the coordinates.",
  schema: {
    "type": "object",
    "properties": {
      "x": {"type": "integer", "description": "The x coordinate, in pixels."},
      "y": {"type": "integer", "description": "The y coordinate, in pixels."},
      "button": {
        "type": "integer",
        "description": "1 for primary, 2 for secondary, 3 for tertiary.",
      },
    },
    "required": ["x", "y", "button"],
  },
);

/// Send keyboard input. A single key is text of length one.
const keyTool = LlmTool(
  name: keyToolName,
  description: "Send keyboard input. `text` is what to type: a single key is "
      "text of length one, a longer string is typed as-is. Use it to fill a "
      "field, press a shortcut, or navigate.",
  schema: {
    "type": "object",
    "properties": {
      "text": {"type": "string", "description": "The key or text to send."},
    },
    "required": ["text"],
  },
);

const screenshotToolName = "screenshot";
const clickToolName = "click";
const keyToolName = "key";
