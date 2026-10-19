import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/browser_reach.dart";

void main() {
  const pages = "https://byterepair.github.io";

  test("a local Ollama is told the page's origin to allow", () {
    final note = browserReachNote(Uri.parse("http://localhost:11434/v1"),
        origin: pages);
    expect(note, contains("OLLAMA_ORIGINS=$pages"));
  });

  test("a page served from this machine needs nothing of Ollama", () {
    expect(
        browserReachNote(Uri.parse("http://127.0.0.1:11434/v1"),
            origin: "http://127.0.0.1:8087"),
        isNull);
  });

  test("Ollama Cloud points at a local Ollama instead", () {
    final note =
        browserReachNote(Uri.parse("https://ollama.com/v1"), origin: pages);
    expect(note, contains("ollama signin"));
  });

  test("a provider that allows every origin has nothing to say", () {
    expect(browserReachNote(Uri.parse("https://api.anthropic.com/v1"),
        origin: pages), isNull);
  });

  test("an unreachable request names the origin and the fix", () {
    final why = browserUnreachable(
        Uri.parse("http://localhost:11434/v1/chat/completions"),
        origin: pages);
    expect(why, contains("($pages)"));
    expect(why, contains("OLLAMA_ORIGINS=$pages"));
  });
}
