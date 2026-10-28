// The frontmatter a skill or agent file carries, parsed. Its own file so the
// build-time generators can read it without dragging in the freezed models —
// `tool/prepare.sh` runs them before build_runner, on a checkout where the
// generated parts do not exist yet.
//
// Real YAML (the `yaml` package) is the frontmatter grammar the Agent Skills
// spec allows: folded and literal block scalars, comments, quoting — none of
// which the regex subset below could read. The regex parser is kept as the
// fallback for legacy content already shipped in skills that is *not* valid
// YAML (unquoted `: ` in `description:` values), which strict parsing alone
// would refuse; new content should be spec YAML, where the strict path wins.
import "package:yaml/yaml.dart";

/// One file's frontmatter and body: the top-level scalars (an agent's
/// `tools` list comma-joined into one), the nested `metadata:` map, and the
/// text after the closing fence. Only what the menu and the tool gates need
/// is read; everything else — other lists, deeper maps — is dropped.
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

  /// The keys whose value is a list, read as one comma-joined scalar. Only
  /// these: a list under any other key stays dropped, which is what keeps a
  /// skill's unknown list key out of the spec check.
  static const listKeys = {"tools"};

  factory Frontmatter.parse(String source) {
    final text = source.replaceAll("\r\n", "\n");
    final split = _splitBlock(text);
    if (split == null) return Frontmatter(body: text.trim());
    final (block, body) = split;

    // Strict YAML first, on the untouched block. Only where it refuses is a
    // tab-indent prepass retried (tabs are legal YAML content but not legal
    // indentation, so a block indented with tabs is what the prepass is for)
    // and then the legacy regex parser.
    final yamlParsed = _fromYaml(block, body);
    if (yamlParsed != null) return yamlParsed;
    if (block.contains("\t")) {
      final tabbed = _fromYaml(
        block.replaceAll(_tabIndent, "  "),
        body,
      );
      if (tabbed != null) return tabbed;
    }
    return _fromScalars(body: body, block: block);
  }

  /// Splits normalized [text] at the fences: (block text, body text). Null
  /// where there is no block — no opener, or an opener with no closer —
  /// which the caller reads as all body.
  static (String, String)? _splitBlock(String text) {
    final firstLineEnd = text.indexOf("\n");
    if (firstLineEnd < 0) {
      return _fence.hasMatch(text) ? null : null;
    }
    final opener = text.substring(0, firstLineEnd);
    if (!_fence.hasMatch(opener)) return null;
    // The closing fence: a line that is only `---`. The empty block's closer
    // rides the opener's own newline ("---\n---", the "---" at
    // firstLineEnd + 1), so an empty block is detected first; otherwise
    // the search runs after the opener's newline.
    if (text.startsWith("---", firstLineEnd + 1)) {
      return ("", _afterFence(text, firstLineEnd + 3));
    }
    final close = text.indexOf("\n---", firstLineEnd + 1);
    if (close < 0) return null;
    return (
      text.substring(firstLineEnd + 1, close),
      _afterFence(text, close + 3),
    );
  }

  /// The body after a closing fence at [fenceStart]: up to the fence line's
  /// end newline if there is one, then the rest, trimmed.
  static String _afterFence(String text, int fenceStart) {
    final lineEnd = text.indexOf("\n", fenceStart);
    return lineEnd < 0 ? "" : text.substring(lineEnd + 1).trim();
  }

  static final RegExp _fence = RegExp(r"^---[ \t]*$");
  static final RegExp _tabIndent = RegExp(r"^\t+", multiLine: true);

  /// The string a scalar node carries: plain values come through as Dart
  /// scalars, stringified the way a reader would see it — quotes resolved,
  /// booleans and numbers at their YAML spelling.
  static String _scalarString(YamlNode node) => node.value?.toString() ?? "";

  /// The strict-YAML parse: null where the block is not a YAML mapping (the
  /// caller then tries the legacy parser), frontmatter where it is.
  static Frontmatter? _fromYaml(String block, String body) {
    final Object? document;
    try {
      document = loadYamlNode(block);
    } on YamlException {
      return null;
    }
    if (document is! YamlMap) return null;

    final scalars = <String, String>{};
    final metadata = <String, String>{};
    document.nodes.forEach((keyNode, valueNode) {
      final key = keyNode.value;
      if (key is! String) return;
      final value = valueNode.value;
      if (key == "metadata") {
        if (valueNode is! YamlMap) return;
        valueNode.nodes.forEach((k, v) {
          // A list value the map's string type cannot carry (flow-sequence
          // tags, say) is stringified ("[a, b]") rather than dropped — the
          // shape the legacy parser produced there too. A nested map stays
          // dropped, the map being string to string.
          if (k.value is String && v.value is! YamlMap) {
            metadata[k.value as String] = _scalarString(v);
          }
        });
        return;
      }
      if (valueNode is YamlList) {
        if (listKeys.contains(key) &&
            valueNode.nodes.every((n) => n is YamlScalar)) {
          scalars[key] = valueNode.nodes.map(_scalarString).join(", ");
        }
        return;
      }
      if (value == null || value is YamlMap) return;
      scalars[key] = _scalarString(valueNode);
    });
    return Frontmatter(scalars: scalars, metadata: metadata, body: body);
  }

  /// The legacy regex parse of the block the strict path refused — the port
  /// of the parser this file carried before the yaml package arrived.
  static Frontmatter _fromScalars({
    required String body,
    required String block,
  }) {
    final scalars = <String, String>{};
    final metadata = <String, String>{};
    var inMetadata = false;
    int? metadataIndent;
    for (final line in block.split("\n")) {
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
      final scalar = _unquote(value.trim());
      // A flow list the strict parse refused, as the strict path joins it.
      scalars[key] = listKeys.contains(key) &&
              scalar.startsWith("[") &&
              scalar.endsWith("]")
          ? scalar.substring(1, scalar.length - 1).trim()
          : scalar;
    }
    return Frontmatter(scalars: scalars, metadata: metadata, body: body);
  }

  static final RegExp _scalar = RegExp(r"^([A-Za-z0-9_.-]+):[ \t]*(.*)$");

  /// An indented scalar under a block opener — one entry of the `metadata:`
  /// map, read at the first entry's indentation. A deeper line is a nested
  /// value and is dropped.
  static final RegExp _indentedScalar =
      RegExp(r"^[ \t]+([A-Za-z0-9_.-]+):[ \t]*(.*)$");

  static String _unquote(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}