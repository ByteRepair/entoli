import "shell.dart";

/// The tools a [WebSearch] answers, named here rather than beside them
/// because the log records the name and the chat draws it.
const websearchToolName = "websearch";
const webfetchToolName = "webfetch";

/// Web search and fetch, reached through DuckDuckGo Lite and plain HTTP. Like
/// [Shell], the result is a [ShellResult] so the agent words it the same way as
/// a command's outcome — the model reads one shape, whatever ran.
abstract class WebSearch {
  const WebSearch();

  /// Search the web for [query], returning titles, URLs and snippets as
  /// readable text the model can extract URLs from.
  Future<ShellResult> search(String query);

  /// Fetch [url] and return its text content with markup stripped.
  Future<ShellResult> fetch(String url);

  /// Release any resources. The default is a no-op; [DuckDuckGoSearch]
  /// overrides it to close its HTTP client.
  void close() {}
}
