import "llm/llm_client.dart";

/// Search the web via DuckDuckGo Lite — no API key. Returns titles, URLs, and
/// snippets as readable text the model can extract URLs from.
const websearchTool = LlmTool(
  name: websearchToolName,
  description: "Search the web. Returns up to 10 results with titles, URLs, "
      "and snippets. Use it to find sources, check facts, or discover what is "
      "out there. Extract URLs from the results and pass them to `webfetch` to "
      "read the full page.",
  schema: {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query.",
      },
    },
    "required": ["query"],
  },
);

/// Fetch a URL and return its text content with markup stripped. Use it to
/// read a page the model found via `websearch` or was given directly.
const webfetchTool = LlmTool(
  name: webfetchToolName,
  description: "Fetch a web page and return its text content. HTML is stripped "
      "to readable text, so what you get is the page's words rather than its "
      "markup. Use it to read a source in full after `websearch` found it, or "
      "any URL you need the content of.",
  schema: {
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "The URL to fetch.",
      },
    },
    "required": ["url"],
  },
);

const websearchToolName = "websearch";
const webfetchToolName = "webfetch";