import "../../../domain/agent_backend.dart";
import "../../../domain/shell.dart";
import "../../../domain/tool_arg.dart";
import "../../../domain/web_search.dart";
import "../approval_gate.dart";
import "../llm/llm_client.dart";
import "../templates.dart" show systemProse;
import "agent_tool.dart";
import "browser_tools.dart" show browserGotoToolName;
import "turn.dart";

/// Search the web via DuckDuckGo Lite — no API key. Returns titles, URLs, and
/// snippets as readable text the model can extract URLs from. Read-only, so
/// no approval. Offered with [WebFetchTool] wherever a [WebSearch] is
/// reachable, and carries the pair's words in the prompt.
class WebSearchTool extends AgentTool {
  WebSearchTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.web;

  @override
  String get name => websearchToolName;

  @override
  bool get offered => offer.caps.webSearch;

  @override
  String get runningLabel => "Searching the web";

  @override
  String get fragment => "`websearch` to search the web, `webfetch` to read a page";

  @override
  String get section => systemProse("websearch");

  @override
  String get description => "Search the web. Returns up to 10 results with "
      "titles, URLs, and snippets. Use it to find sources, check facts, or "
      "discover what is out there. Extract URLs from the results and pass them "
      "to `webfetch` to read the full page.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "The search query."},
        },
        "required": ["query"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final query = stringArg(call.argumentsJson, "query");
    if (query == null) {
      yield* toolRejected(call, 'The $websearchToolName tool takes {"query": "..."}.');
      return;
    }
    yield toolCalled(call, query);
    yield ToolResultEvent(toolRan(call, await turn.webSearch!.search(query)));
  }
}

/// Fetch a URL and return its text content with markup stripped. The network
/// rules answer for it — the same family a `curl` or `wget` segment in a
/// command consults — and the banner is where one standing answer comes from.
class WebFetchTool extends AgentTool {
  WebFetchTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.web;

  @override
  String get name => webfetchToolName;

  @override
  bool get offered => offer.caps.webSearch;

  @override
  String get runningLabel => "Fetching a page";

  @override
  String get description => "Fetch a web page and return its text content. "
      "HTML is stripped to readable text, so what you get is the page's words "
      "rather than its markup. Use it to read a source in full after "
      "`websearch` found it, or any URL you need the content of.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "url": {"type": "string", "description": "The URL to fetch."},
        },
        "required": ["url"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final url = stringArg(call.argumentsJson, "url");
    if (url == null) {
      yield* toolRejected(call, 'The $webfetchToolName tool takes {"url": "..."}.');
      return;
    }
    yield toolCalled(call, url);
    final outcome = GateOutcome();
    yield* turn.gate.decide(
        call, webfetchToolName, () => turn.webSearch!.fetch(url), outcome,
        argumentsText: url, ruleSubject: url);
    outcome.result = _withBrowserHint(outcome.result!);
    yield ToolResultEvent(outcome.resultOf(call));
  }

  /// A fetch that met a wall a browser gets past: a refusal, a challenge, or
  /// a page that is nothing until its script runs. Pointed at the browser
  /// where this turn has one.
  ShellResult _withBrowserHint(ShellResult result) {
    if (!offer.caps.browser) return result;
    final text = "${result.output}\n${result.exceptionInfo ?? ""}";
    final walled = RegExp(r"HTTP (401|403|429|503)\b").hasMatch(text) ||
        result.output == "The page has no readable text content." ||
        RegExp(r"enable javascript|just a moment|verify you are human|captcha",
                caseSensitive: false)
            .hasMatch(text.length > 3000 ? text.substring(0, 3000) : text);
    if (!walled) return result;
    const hint = "\n\nThis page may need a real browser: try "
        "`$browserGotoToolName` with the same URL.";
    return result.returnCode == 0
        ? ShellResult(returnCode: 0, output: "${result.output}$hint")
        : ShellResult.failed("${result.exceptionInfo ?? result.output}$hint");
  }
}
