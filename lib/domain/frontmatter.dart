// The frontmatter a skill or agent file carries, parsed. Its own file so the
// build-time generators can read it without dragging in the freezed models —
// `tool/prepare.sh` runs them before build_runner, on a checkout where the
// generated parts do not exist yet.
//
/// One file's frontmatter and body: the top-level scalars, the nested
/// `metadata:` map, and the text after the closing fence. Only what the menu
/// and the tool gates need is read; everything else — nested lists, deeper
/// maps — is dropped.
class Frontmatter {
  const Frontmatter(
      {this.scalars = const {}, this.metadata = const {}, this.body = ""});

  /// Top-level scalar keys: `name`, `description`, and the rest of the spec's.
  final Map<String, String> scalars;

  /// The `metadata:` map — the spec's extension point, and where Entoli's own
  /// per-client keys live (`argument-hint`, `user-invocable`,
  /// `disable-model-invocation`).
  final Map<String, String> metadata;

  final String body;

  String? get name => scalars["name"];

  String? get description => scalars["description"];

  factory Frontmatter.parse(String source) {
    final text = source.replaceAll("\r\n", "\n");
    if (!text.startsWith("---\n")) {
      return Frontmatter(body: text.trim());
    }
    final close = text.indexOf("\n---", 3);
    if (close < 0) return Frontmatter(body: text.trim());

    final scalars = <String, String>{};
    final metadata = <String, String>{};
    var inMetadata = false;
    int? metadataIndent;
    for (final line in text.substring(4, close + 1).split("\n")) {
      final match = _scalar.firstMatch(line);
      if (match == null) {
        // An indented line belongs to the block the last empty-value key
        // opened — the `metadata:` map, where the spec keeps client keys.
        // Entries sit at the first entry's indentation; a deeper line is a
        // nested value and is dropped, the map being string to string.
        final nested = _indentedScalar.firstMatch(line);
        if (inMetadata && nested != null) {
          final indent = line.length - line.trimLeft().length;
          metadataIndent ??= indent;
          final value = nested.group(2)!.trim();
          if (indent == metadataIndent && value.isNotEmpty) {
            metadata[nested.group(1)!] = _unquote(value);
          }
        }
        continue;
      }
      final key = match.group(1)!;
      final value = match.group(2)!;
      if (value.isEmpty) {
        // An empty value opens a nested block. Only `metadata:` is read out
        // of one; any other nested block has its lines skipped.
        inMetadata = key == "metadata";
        continue;
      }
      inMetadata = false;
      if (key == "metadata") continue;
      scalars[key] = _unquote(value.trim());
    }

    final newline = text.indexOf("\n", close + 1);
    return Frontmatter(
      scalars: scalars,
      metadata: metadata,
      body: newline < 0 ? "" : text.substring(newline + 1).trim(),
    );
  }

  static final _scalar = RegExp(r"^([A-Za-z0-9_.-]+):[ \t]*(.*)$");

  /// An indented scalar under a block opener — one entry of the `metadata:`
  /// map, read at the first entry's indentation. A deeper line is a nested
  /// value and is dropped.
  static final _indentedScalar = RegExp(r"^[ \t]+([A-Za-z0-9_.-]+):[ \t]*(.*)$");

  static String _unquote(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}