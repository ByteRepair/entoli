import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/embed_text.dart";

/// A quote, as the core sees one: a paragraph of `> ` lines.
class _Quote implements Embed {
  const _Quote(this.said);

  final String said;

  static _Quote? read(String block) =>
      block.startsWith("> ") ? _Quote(block.substring(2)) : null;

  @override
  bool get block => true;

  @override
  String get markdown => "> $said";

  @override
  bool operator ==(Object other) => other is _Quote && other.said == said;

  @override
  int get hashCode => said.hashCode;
}

void main() {
  late EmbedText<_Quote> embeds;

  setUp(() => embeds = EmbedText(readers: [_Quote.read]));

  test("an embed is one character of the text, and its markdown sent", () {
    final text = embeds.appended("", const _Quote("this"));
    expect(text.length, 2, reason: "the embed's character and the line under");
    expect(embeds.messageOf("${text}that"), "> this\n\nthat");
  });

  test("a message taken back comes back as it was composed", () {
    final text = embeds.textOf("> this\n\nthat");
    expect(embeds.embedsIn(text), [const _Quote("this")]);
    expect(embeds.messageOf(text), "> this\n\nthat");
  });

  test("what was said goes ahead of what was typed since", () {
    final text = embeds.prepended("later", "> first");
    expect(embeds.messageOf(text), "> first\n\nlater");
  });

  test("taking an embed out takes its line and moves the caret back", () {
    const quote = _Quote("gone");
    final text = "${embeds.appended("", quote)}kept";
    final out = embeds.removed(
      text,
      quote,
      base: text.length,
      extent: text.length,
    )!;
    expect(out.text, "kept");
    expect((out.base, out.extent), (4, 4));
  });
}
