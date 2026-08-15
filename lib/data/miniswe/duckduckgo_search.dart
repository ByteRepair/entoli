import "dart:async";

import "package:http/http.dart" as http;
import "package:html/parser.dart";

import "../../domain/shell.dart";
import "../../domain/web_search.dart";

/// DuckDuckGo Lite, reached through plain HTTP — no API key, no rate limit to
/// speak of. The search page is HTML, not JSON, so the results are parsed out
/// of the table it renders. `webfetch` is a plain GET with markup stripped to
/// text, the same way the model would read a page if it could.
class DuckDuckGoSearch extends WebSearch {
  DuckDuckGoSearch({http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Duration timeout;

  static final _uddg = RegExp(r"[?&]uddg=([^&]+)");

  @override
  Future<ShellResult> search(String query) async {
    if (query.trim().isEmpty) {
      return const ShellResult.failed("The search query is empty.");
    }
    try {
      final response = await _http.post(
        Uri.parse("https://lite.duckduckgo.com/lite/"),
        headers: const {
          "User-Agent": _userAgent,
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language": "en-US,en;q=0.5",
          "Referer": "https://lite.duckduckgo.com/",
        },
        body: {"q": query, "kl": "us-en"},
      ).timeout(timeout);

      if (response.statusCode != 200) {
        return ShellResult.failed("DuckDuckGo returned HTTP ${response.statusCode}.");
      }

      final results = _parseResults(response.body);
      if (results.isEmpty) {
        return const ShellResult(
          returnCode: 0,
          output: "No results found.",
        );
      }
      return ShellResult(returnCode: 0, output: results);
    } catch (e) {
      return ShellResult.failed("Search failed: $e");
    }
  }

  @override
  Future<ShellResult> fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return const ShellResult.failed("The URL is not valid.");
    }
    try {
      final response = await _http.get(
        uri,
        headers: const {
          "User-Agent": _userAgent,
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language": "en-US,en;q=0.5",
        },
      ).timeout(timeout);

      if (response.statusCode != 200) {
        return ShellResult.failed("Fetch returned HTTP ${response.statusCode}.");
      }

      final text = _extractText(response.body);
      if (text.trim().isEmpty) {
        return const ShellResult(
          returnCode: 0,
          output: "The page has no readable text content.",
        );
      }
      return ShellResult(returnCode: 0, output: text);
    } catch (e) {
      return ShellResult.failed("Fetch failed: $e");
    }
  }

  @override
  void close() => _http.close();

  /// Parse DuckDuckGo Lite's result table. Each result is three rows: the
  /// title link, the snippet, and the display URL. The actual URL is encoded
  /// in the redirect's `uddg` query parameter.
  String _parseResults(String html) {
    final doc = parse(html);
    final links = doc.querySelectorAll("a.result-link");
    final snippets = doc.querySelectorAll("td.result-snippet");
    final display = doc.querySelectorAll("span.link-text");

    final buf = StringBuffer();
    var count = 0;
    for (var i = 0; i < links.length && count < 10; i++) {
      final title = links[i].text.trim();
      final href = links[i].attributes["href"] ?? "";
      final url = _extractUrl(href);
      final snippet = i < snippets.length ? snippets[i].text.trim() : "";
      final host = i < display.length ? display[i].text.trim() : "";

      if (title.isEmpty) continue;
      count++;
      buf.writeln("$count. $title");
      if (url.isNotEmpty) buf.writeln("   $url");
      if (host.isNotEmpty && host != url) buf.writeln("   ($host)");
      if (snippet.isNotEmpty) buf.writeln("   $snippet");
      buf.writeln();
    }
    return buf.toString().trimRight();
  }

  String _extractUrl(String href) {
    final match = _uddg.firstMatch(href);
    if (match == null) return "";
    return Uri.decodeComponent(match.group(1)!);
  }

  /// Strip markup and return the page's readable text. `<script>` and
  /// `<style>` are removed entirely; the rest is collapsed to plain text with
  /// whitespace normalized.
  String _extractText(String html) {
    final doc = parse(html);
    for (final tag in const ["script", "style", "nav", "header", "footer", "noscript"]) {
      doc.querySelectorAll(tag).forEach((e) => e.remove());
    }
    final raw = doc.body?.text ?? "";
    return _collapseWhitespace(raw);
  }

  String _collapseWhitespace(String s) => s
      .split("\n")
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join("\n")
      .replaceAll(RegExp(r"[ \t]+"), " ");

  static const _userAgent =
      "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0";
}