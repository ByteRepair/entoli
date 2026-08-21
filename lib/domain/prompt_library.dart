import "models.dart";

/// One command or agent, exactly as Entoli stores it: YAML frontmatter,
/// then the template a command expands to or the system prompt an agent runs
/// under.
class PromptDocument {
  const PromptDocument({
    required this.kind,
    required this.name,
    required this.frontmatter,
    required this.body,
  });

  final CompletionKind kind;
  final String name;
  final Map<String, String> frontmatter;
  final String body;

  String? get description => frontmatter["description"];

  CompletionOption get option => CompletionOption(name: name, description: description);

  /// Only the top-level scalars are read, because [description] is all the menu
  /// shows. Everything else — nested permissions, tool maps — is dropped.
  factory PromptDocument.parse(CompletionKind kind, String name, String source) {
    final (frontmatter, body) = _split(source.replaceAll("\r\n", "\n"));
    return PromptDocument(
      kind: kind,
      name: name,
      frontmatter: frontmatter,
      body: body,
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
/// Entoli owns the list, rather than asking a backend what it knows.
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

/// A message that is nothing but `/name` plus arguments runs that command. The
/// name may not hold a slash, so `/usr/bin/foo is broken` stays prose. It is
/// the whole of the message and there is at most one, which is what anchoring
/// both ends says. Matches what `activeCompletionToken` offers in the
/// composer's menu — anything it can offer has to dispatch here.
final _command = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

/// `@name` addresses an agent, but only where a word starts, so an email
/// address is not a mention.
final _mention = RegExp(r"(?<=^|\s)@([\w.-]+)");

/// What the library says [text]'s references mean, ready to be written into the
/// message as [Message.documents] and read back by [expandedPrompt] and
/// [agentPromptFrom] — see "Commands and agents" in `lib/domain/CLAUDE.md`.
///
/// Keyed by the reference as written, sigil included, so a command and an agent
/// of the same name do not collide. A name the library does not know is left
/// out: it is more likely a path, or prose, than a document nobody defined.
Map<String, String> promptDocuments(String text, PromptLibrary? library) => {
      if (_command.firstMatch(text.trim())?.group(1) case final name?)
        if (library?.find(CompletionKind.command, name) case final document?)
          "${CompletionKind.command.trigger}$name": document.body,
      for (final match in _mention.allMatches(text))
        if (library?.find(CompletionKind.agent, match.group(1)!)
            case final document?)
          "${CompletionKind.agent.trigger}${match.group(1)}": document.body,
    };

/// The task the model is given: a command's template with the arguments in it,
/// or the message unchanged where it names no command this one recorded.
String expandedPrompt(String text, Map<String, String> documents) {
  if (documents.isEmpty) return text;
  final match = _command.firstMatch(text.trim());
  if (match == null) return text;
  final body = documents["${CompletionKind.command.trigger}${match.group(1)}"];
  if (body == null) return text;
  final arguments = match.group(2) ?? "";
  if (body.contains(r"$ARGUMENTS")) return body.replaceAll(r"$ARGUMENTS", arguments);
  return arguments.isEmpty ? body : "$body\n\n$arguments";
}

/// The `@agent` instructions the message asked for, joined in the order they
/// were written — what `turnPrompt` puts under the system prompt for the turn.
/// Null where it named none.
///
/// Off the record rather than the text: the mentions were resolved when the
/// message was composed, and a name mentioned twice was recorded once.
String? agentPromptFrom(Map<String, String> documents) {
  final bodies = [
    for (final entry in documents.entries)
      if (entry.key.startsWith(CompletionKind.agent.trigger)) entry.value,
  ];
  return bodies.isEmpty ? null : bodies.join("\n\n");
}
