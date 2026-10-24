import "../../domain/agent_browser.dart" show BrowserUploadPolicy;
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
const browserPressToolName = "browser_press";

/// What acts on a page: a click or a typed Enter can submit a form, post or
/// pay, so these are gated the way a command is. Reading and moving about a
/// page are not.
const browserActingTools = {
  browserClickToolName,
  browserTypeToolName,
  browserPressToolName,
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
      "inside of a frame. A file the page downloads is saved into "
      "`downloads/` in your workspace, and a later browser result says when "
      "it has arrived.",
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
  description: "Type text. With `ref`, replaces the text in that field (on a "
      "select, picks the option whose label matches). Without `ref`, types "
      "at whatever has focus, key by key, as a keyboard does: what an editor "
      "that draws its own text needs, such as Google Docs or Slides, where "
      "you first click into the text and then type with no `ref`. A newline "
      "is Enter. Set `submit` to press Enter after.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {
        "type": "integer",
        "description": "The field's number; leave out to type at the focus.",
      },
      "text": {"type": "string"},
      "submit": {"type": "boolean"},
    },
    "required": ["text"],
  },
);

const browserPressTool = LlmTool(
  name: browserPressToolName,
  description: "Press one key at the focus, optionally with modifiers held: "
      "Enter, Tab, Escape, Backspace, an arrow, or a shortcut such as "
      "Control+b for bold or Control+a to select all (Meta on a Mac site "
      "that wants Cmd).",
  schema: {
    "type": "object",
    "properties": {
      "key": {
        "type": "string",
        "description": "The DOM key name (Enter, Tab, Escape, Backspace, "
            "Delete, ArrowDown, Home, PageDown, F5) or one character.",
      },
      "modifiers": {
        "type": "array",
        "items": {
          "type": "string",
          "enum": ["Control", "Shift", "Alt", "Meta"],
        },
      },
    },
    "required": ["key"],
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
      "view. The wheel turns over the middle of the viewport and scrolls "
      "whatever is under it. To scroll a panel or frame of its own, such as "
      "a mail's body or a list beside the page, give its `ref`, or a point "
      "inside it by x and y (what a screenshot shows).",
  schema: {
    "type": "object",
    "properties": {
      "direction": {
        "type": "string",
        "enum": ["down", "up"],
      },
      "ref": {
        "type": "integer",
        "description": "The number of the element to scroll inside.",
      },
      "x": {"type": "number"},
      "y": {"type": "number"},
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
      "the result gives. Set `last_click` after clicking by x and y to see "
      "where the click landed.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {"type": "integer"},
      "last_click": {
        "type": "boolean",
        "description": "Mark the last click on this page with a red dot.",
      },
    },
  },
);

const browserShowToolName = "browser_show";

const browserShowTool = LlmTool(
  name: browserShowToolName,
  description: "Open the browser, which runs hidden, in a window on the "
      "current page, so the user can finish what you cannot, such as a "
      "human-verification check. Then ask them to, and carry on once they "
      "say it is done.",
  schema: {"type": "object", "properties": {}},
);

const browserCredentialsPromptToolName = "browser_credentials_prompt";
const browserCredentialsHideToolName = "browser_credentials_hide";

const browserCredentialsPromptTool = LlmTool(
  name: browserCredentialsPromptToolName,
  description: "Ask the user to fill in a sign-in on the current page. They "
      "type into a panel in the app, which types it into the fields and "
      "makes the submit clicks itself; you never see what they type, and "
      "must never ask for a password or code in chat. Waits for them. For a "
      "sign-in over several pages (email, Next, then password), call once "
      "per page.",
  schema: {
    "type": "object",
    "properties": {
      "reason": {
        "type": "string",
        "description": "Shown to the user, e.g. \"Sign in to GitHub\".",
      },
      "fields": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "ref": {"type": "integer", "description": "The field's number."},
            "label": {"type": "string", "description": "e.g. \"Password\"."},
            "secret": {
              "type": "boolean",
              "description": "Obscure what the user types.",
            },
          },
          "required": ["ref", "label"],
        },
      },
      "submit": {
        "type": "array",
        "description": "The clicks that submit the fields, in order: an "
            "element's number, or a point.",
        "items": {
          "type": "object",
          "properties": {
            "ref": {"type": "integer"},
            "x": {"type": "number"},
            "y": {"type": "number"},
          },
        },
      },
    },
    "required": ["reason", "fields"],
  },
);

const browserCredentialsHideTool = LlmTool(
  name: browserCredentialsHideToolName,
  description: "Hide the browser from yourself and hand it to the user, for "
      "a sign-in the prompt cannot do: a multi-step login, a code sent to "
      "their phone, a passkey. A button labelled with `reason` appears in "
      "the chat and opens the browser for them. Waits until they give it "
      "back; the page is then as they left it.",
  schema: {
    "type": "object",
    "properties": {
      "reason": {
        "type": "string",
        "description":
            "The button's label, e.g. \"Please sign in to Google to proceed\".",
      },
    },
    "required": ["reason"],
  },
);

const browserUploadToolName = "browser_upload";

const browserUploadTool = LlmTool(
  name: browserUploadToolName,
  description: "Upload files from your workspace through the page: give the "
      "number of the upload button or file field, and the files' paths. The "
      "page's file chooser is filled in for you, with no dialog. Only upload "
      "what the task needs.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {
        "type": "integer",
        "description": "The upload button's or file field's number.",
      },
      "paths": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Files to upload, as the file tools take paths.",
      },
    },
    "required": ["ref", "paths"],
  },
);

/// [browserUploadTool] where the user alone chooses what is uploaded: no
/// paths, and the call waits on them.
const browserUploadByUserTool = LlmTool(
  name: browserUploadToolName,
  description: "Ask the user to upload a file through the page: give the "
      "number of the upload button or file field. The user chooses the file "
      "in the app, which you cannot do here; the call waits for them, and "
      "says what they chose or that they cancelled.",
  schema: {
    "type": "object",
    "properties": {
      "ref": {
        "type": "integer",
        "description": "The upload button's or file field's number.",
      },
    },
    "required": ["ref"],
  },
);

/// The tools, in the order they are offered. [screenshot] only where the
/// model reads images: one that cannot would be paying for pictures it is
/// sent as nothing. [show] only where the browser runs hidden. [credentials]
/// only where someone is there to answer them.
List<LlmTool> browserTools({
  required bool screenshot,
  bool show = false,
  bool credentials = false,
  BrowserUploadPolicy? upload,
}) =>
    [
      browserGotoTool,
      browserSearchTool,
      browserClickTool,
      browserTypeTool,
      browserPressTool,
      browserDragTool,
      browserScrollTool,
      browserBackTool,
      browserPageTextTool,
      if (screenshot) browserScreenshotTool,
      if (show) browserShowTool,
      if (credentials) ...[
        browserCredentialsPromptTool,
        browserCredentialsHideTool,
      ],
      ?switch (upload) {
        BrowserUploadPolicy.user => browserUploadByUserTool,
        null => null,
        _ => browserUploadTool,
      },
    ];
