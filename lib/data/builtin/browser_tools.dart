import "llm/llm_client.dart";

/// The browser tools, offered where Settings > Agent Browser has picked one.
/// Every one but the screenshot answers with the page as the call left it:
/// what is in view, its interactive elements numbered for `browser_click` and
/// `browser_type`. See "The browser" in AGENTS.md.
const browserGotoToolName = "browser_goto_url";
const browserSearchToolName = "browser_search";
const browserClickToolName = "browser_click";
const browserTypeToolName = "browser_type";
const browserDragToolName = "browser_drag";
const browserScrollToolName = "browser_scroll";
const browserBackToolName = "browser_back";
const browserPageTextToolName = "browser_page_text";
const browserScreenshotToolName = "browser_screenshot";

/// What acts on a page: a click or a typed Enter can submit a form, post or
/// pay, so these are gated the way a command is. Reading and moving about a
/// page are not.
const browserActingTools = {
  browserClickToolName,
  browserTypeToolName,
  browserDragToolName,
};

const _point = {
  "type": "object",
  "properties": {
    "x": {"type": "number"},
    "y": {"type": "number"},
  },
  "required": ["x", "y"],
};

const browserGotoTool = LlmTool(
  name: browserGotoToolName,
  description: "Open a URL in the browser, a real one with the user's window "
      "and logins, and return what is in view. Use it over `webfetch` for a "
      "page that needs JavaScript, a login, or one that refused `webfetch`.",
  schema: {
    "type": "object",
    "properties": {
      "url": {"type": "string", "description": "The URL to open."},
    },
    "required": ["url"],
  },
);

const browserSearchTool = LlmTool(
  name: browserSearchToolName,
  description: "Search the web in the browser and return the results page.",
  schema: {
    "type": "object",
    "properties": {
      "query": {"type": "string", "description": "The search query."},
    },
    "required": ["query"],
  },
);

const browserClickTool = LlmTool(
  name: browserClickToolName,
  description: "Click an element by its number from the last page "
      "description, or a point by x and y in viewport pixels (what a "
      "screenshot shows). Use x and y for what has no number, such as the "
      "inside of a frame.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {"type": "integer", "description": "The element's number."},
      "x": {"type": "number"},
      "y": {"type": "number"},
    },
  },
);

const browserTypeTool = LlmTool(
  name: browserTypeToolName,
  description: "Replace the text in a field with `text`, by the field's "
      "number. On a select, picks the option whose label matches. Set "
      "`submit` to press Enter after.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {"type": "integer", "description": "The field's number."},
      "text": {"type": "string"},
      "submit": {"type": "boolean"},
    },
    "required": ["ref", "text"],
  },
);

const browserDragTool = LlmTool(
  name: browserDragToolName,
  description: "Press at `from`, move, and release at `to`, in viewport "
      "pixels: for a slider.",
  schema: {
    "type": "object",
    "properties": {"from": _point, "to": _point},
    "required": ["from", "to"],
  },
);

const browserScrollTool = LlmTool(
  name: browserScrollToolName,
  description: "Scroll one screen down, or up, and return what is then in "
      "view.",
  schema: {
    "type": "object",
    "properties": {
      "direction": {
        "type": "string",
        "enum": ["down", "up"],
      },
    },
  },
);

const browserBackTool = LlmTool(
  name: browserBackToolName,
  description: "Go back to the previous page.",
  schema: {"type": "object", "properties": {}},
);

const browserPageTextTool = LlmTool(
  name: browserPageTextToolName,
  description: "The whole page's text and every interactive element, not "
      "just what is in view. Long pages come in chunks: pass `offset` to read "
      "on.",
  schema: {
    "type": "object",
    "properties": {
      "offset": {"type": "integer"},
    },
  },
);

const browserScreenshotTool = LlmTool(
  name: browserScreenshotToolName,
  description: "Take a screenshot of the viewport, or of one element by "
      "number. One image pixel is one viewport pixel, so a point in it can "
      "be clicked by x and y; for an element's screenshot, add the offset "
      "the result gives.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {"type": "integer"},
    },
  },
);

/// The tools, in the order they are offered. [screenshot] only where the
/// model reads images: one that cannot would be paying for pictures it is
/// sent as nothing.
List<LlmTool> browserTools({required bool screenshot}) => [
      browserGotoTool,
      browserSearchTool,
      browserClickTool,
      browserTypeTool,
      browserDragTool,
      browserScrollTool,
      browserBackTool,
      browserPageTextTool,
      if (screenshot) browserScreenshotTool,
    ];
