import "models.dart";

/// One command or agent, exactly as agent-chat stores it: YAML frontmatter,
/// then the template a command expands to or the system prompt an agent runs
/// under.
class PromptDocument {
  const PromptDocument({
    required this.kind,
    required this.name,
    required this.frontmatter,
    required this.body,
    required this.source,
  });

  final CompletionKind kind;
  final String name;
  final Map<String, String> frontmatter;
  final String body;

  /// The file verbatim, for a backend that reads these itself rather than
  /// being handed the parsed pieces.
  final String source;

  String? get description => frontmatter["description"];

  CompletionOption get option => CompletionOption(name: name, description: description);

  /// Only the top-level scalars are read, because [description] is all the
  /// menu shows. Everything else — nested permissions, tool maps — stays in
  /// [source] for whoever understands it.
  factory PromptDocument.parse(CompletionKind kind, String name, String source) {
    final text = source.replaceAll("\r\n", "\n");
    final (frontmatter, body) = _split(text);
    return PromptDocument(
      kind: kind,
      name: name,
      frontmatter: frontmatter,
      body: body,
      source: text,
    );
  }

  static final _scalar = RegExp(r"^([A-Za-z0-9_.-]+):[ \t]*(.*)$");

  static (Map<String, String>, String) _split(String text) {
    if (!text.startsWith("---\n")) return (const {}, text.trim());
    final close = text.indexOf("\n---", 3);
    if (close < 0) return (const {}, text.trim());

    final frontmatter = <String, String>{};
    for (final line in text.substring(4, close + 1).split("\n")) {
      final match = _scalar.firstMatch(line);
      // An empty value opens a nested block; its indented lines never match.
      if (match == null || match.group(2)!.isEmpty) continue;
      frontmatter[match.group(1)!] = _unquote(match.group(2)!.trim());
    }

    final newline = text.indexOf("\n", close + 1);
    return (frontmatter, newline < 0 ? "" : text.substring(newline + 1).trim());
  }

  static String _unquote(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}

/// Somewhere prompt files come from — the app's own assets, or a directory the
/// user drops files into.
abstract class PromptSource {
  Future<List<PromptDocument>> load(CompletionKind kind);
}

/// Every command and agent the app offers, whichever backend is running the
/// chat. This is the whole of what the composer's `/` and `@` menus show:
/// agent-chat owns the list, rather than asking a backend what it knows.
class PromptLibrary {
  /// [documents] are in precedence order, lowest first — a later one replaces
  /// an earlier one of the same kind and name. That is how a file in
  /// `$AGENT_CHAT_CONFIG` overrides the preset it shares a name with.
  PromptLibrary(Iterable<PromptDocument> documents) {
    for (final document in documents) {
      _byKind.putIfAbsent(document.kind, () => {})[document.name] = document;
    }
  }

  static final empty = PromptLibrary(const []);

  final Map<CompletionKind, Map<String, PromptDocument>> _byKind = {};

  static Future<PromptLibrary> from(List<PromptSource> sources) async {
    final documents = <PromptDocument>[];
    for (final source in sources) {
      for (final kind in CompletionKind.values) {
        documents.addAll(await source.load(kind));
      }
    }
    return PromptLibrary(documents);
  }

  List<PromptDocument> entries(CompletionKind kind) {
    final byName = _byKind[kind];
    if (byName == null) return const [];
    return (byName.keys.toList()..sort()).map((name) => byName[name]!).toList();
  }

  List<CompletionOption> options(CompletionKind kind) =>
      entries(kind).map((document) => document.option).toList();

  PromptDocument? find(CompletionKind kind, String name) => _byKind[kind]?[name];
}
