import "package:agent_chat/data/builtin/duckduckgo_search.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

/// The shape of DuckDuckGo Lite's result table, trimmed to what is parsed.
const _page = """
<table>
  <tr><td><a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdart.dev%2Fguides&amp;rut=x">Dart guides</a></td></tr>
  <tr><td class="result-snippet">The <b>Dart</b> language tour.</td></tr>
  <tr><td><span class="link-text">dart.dev/guides</span></td></tr>
  <tr><td><a class="result-link" href="https://flutter.dev/docs">Flutter docs</a></td></tr>
  <tr><td class="result-snippet">Build apps.</td></tr>
  <tr><td><span class="link-text">flutter.dev/docs</span></td></tr>
  <tr><td><a class="result-link" href="//pub.dev/packages/http">http package</a></td></tr>
  <tr><td class="result-snippet">A HTTP client.</td></tr>
  <tr><td><span class="link-text">pub.dev/packages/http</span></td></tr>
</table>
""";

void main() {
  test("parses redirect and direct links, titles and snippets", () async {
    final search = DuckDuckGoSearch(
      httpClient: MockClient((_) async => http.Response(_page, 200)),
    );

    final result = await search.search("dart");

    expect(result.returnCode, 0);
    expect(result.output, """
1. Dart guides
   https://dart.dev/guides
   (dart.dev/guides)
   The Dart language tour.

2. Flutter docs
   https://flutter.dev/docs
   (flutter.dev/docs)
   Build apps.

3. http package
   https://pub.dev/packages/http
   (pub.dev/packages/http)
   A HTTP client.""");
  });
}
