/// A passage of the conversation the user is answering: what was selected and,
/// in an Omada room, the handle of the member who wrote it. The composer draws
/// it as a card; the message sent carries it as a markdown blockquote, so the
/// model reads it the way the conversation shows it — and the handle inside is
/// an ordinary `@mention`, which is what routes the reply to that member.
class Quote {
  const Quote(this.text, {this.handle});

  /// What was selected, as markdown.
  final String text;

  /// `@name` — the sigil on, the way a mention is typed. Null where the
  /// passage is nobody's to answer: the main agent's, or a direct chat's.
  final String? handle;

  /// The blockquote this sends as. The handle is a paragraph of its own, so
  /// the conversation draws it on its own line as the card does.
  String get markdown {
    final lines = [
      if (handle != null) ...[handle!, ""],
      ...text.trim().split("\n"),
    ];
    return [
      for (final line in lines) line.isEmpty ? ">" : "> $line",
    ].join("\n");
  }

  /// The quote [block] spells, or null where it is not one: every line a
  /// `>` line. The inverse of [markdown], so a message taken back comes back
  /// as cards.
  static Quote? tryParse(String block) {
    final lines = block.split("\n");
    if (lines.isEmpty || !lines.every((l) => l.startsWith(">"))) return null;
    final body = [
      for (final line in lines)
        line.startsWith("> ") ? line.substring(2) : line.substring(1),
    ];
    final handle =
        body.length > 2 && _handle.hasMatch(body.first) && body[1].isEmpty
        ? body.first
        : null;
    final text = body.skip(handle == null ? 0 : 2).join("\n").trim();
    return text.isEmpty ? null : Quote(text, handle: handle);
  }

  static final _handle = RegExp(r"^@[\w.-]+$");

  @override
  bool operator ==(Object other) =>
      other is Quote && other.text == text && other.handle == handle;

  @override
  int get hashCode => Object.hash(text, handle);
}
