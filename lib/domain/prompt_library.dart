import "models.dart";

/// One skill or agent, exactly as Entoli stores it: YAML frontmatter, then the
/// template a skill expands to or the system prompt an agent runs under.
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

  String? get argumentHint => frontmatter["argument-hint"];

  /// Whether the `/` menu offers it. False is the model's half alone: a skill
  /// the user can only reach by the model deciding to load it.
  bool get userInvocable => frontmatter["user-invocable"]?.toLowerCase() != "false";

  /// Whether the model may load it through the `skill` tool. False is the
  /// user's half alone: the tool refuses it, reserved for `/name`.
  bool get modelInvocable =>
      frontmatter["disable-model-invocation"]?.toLowerCase() != "true";

  CompletionOption get option => CompletionOption(
        name: name,
        description: description,
        argumentHint: argumentHint,
      );

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

  /// The `.md` source for a document: a `description` frontmatter where there
  /// is one, then the body. The inverse of [parse] for the scalars an agent
  /// editor writes — `description` is the only one, and an empty description
  /// is omitted rather than written as an empty value, which [parse] reads as
  /// the opening of a nested block.
  static String toSource({String? description, required String body}) {
    final desc = description?.trim() ?? "";
    final head = desc.isEmpty ? "" : "---\ndescription: $desc\n---\n\n";
    return "$head${body.trim()}";
  }
}

/// Somewhere prompt files come from — the app's own assets, or a directory the
/// user drops files into.
abstract class PromptSource {
  Future<List<PromptDocument>> load(CompletionKind kind);
}

/// Every skill and agent the app offers, whichever backend is running the
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

  /// What the composer's menus offer. `user-invocable: false` leaves a
  /// document out of here — that is the whole of what the flag does, and it
  /// applies to agents as well as skills, since a prompt file either belongs
  /// in a menu or it does not.
  List<CompletionOption> options(CompletionKind kind) => [
        for (final document in entries(kind))
          if (document.userInvocable) document.option,
      ];

  PromptDocument? find(CompletionKind kind, String name) => _byKind[kind]?[name];
}

/// A message that is nothing but `/name` plus arguments runs that skill. The
/// name may not hold a slash, so `/usr/bin/foo is broken` stays prose. It is
/// the whole of the message and there is at most one, which is what anchoring
/// both ends says. Matches what `activeCompletionToken` offers in the
/// composer's menu — anything it can offer has to dispatch here.
final _skillReference = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

/// `@name` addresses an agent, but only where a word starts, so an email
/// address is not a mention.
final _mention = RegExp(r"(?<=^|\s)@([\w.-]+)");

/// What the library says [text]'s references mean, ready to be written into the
/// message as [Message.documents] and read back by [expandedPrompt] and
/// [agentPromptFrom] — see "Skills and agents" in `lib/domain/CLAUDE.md`.
///
/// Keyed by the reference as written, sigil included, so a skill and an agent
/// of the same name do not collide. A name the library does not know is left
/// out: it is more likely a path, or prose, than a document nobody defined.
Map<String, String> promptDocuments(String text, PromptLibrary? library) => {
      if (_skillReference.firstMatch(text.trim())?.group(1) case final name?)
        if (library?.find(CompletionKind.skill, name) case final document?)
          "${CompletionKind.skill.trigger}$name": document.body,
      for (final match in _mention.allMatches(text))
        if (library?.find(CompletionKind.agent, match.group(1)!)
            case final document?)
          "${CompletionKind.agent.trigger}${match.group(1)}": document.body,
    };

/// The task the model is given: a skill's template with the arguments in it,
/// or the message unchanged where it names no skill this one recorded.
String expandedPrompt(String text, Map<String, String> documents) {
  if (documents.isEmpty) return text;
  final match = _skillReference.firstMatch(text.trim());
  if (match == null) return text;
  final body = documents["${CompletionKind.skill.trigger}${match.group(1)}"];
  if (body == null) return text;
  return withArguments(body, match.group(2) ?? "");
}

/// A template with the user's arguments in it: substituted where the template
/// left a `$ARGUMENTS` placeholder, appended where it left none. The one rule
/// for both halves of a skill — the composer's `/name` expansion and the
/// `skill` tool's result — so the model reads the same words whichever route
/// it arrived by.
String withArguments(String body, String arguments) {
  if (body.contains(r"$ARGUMENTS")) return body.replaceAll(r"$ARGUMENTS", arguments);
  return arguments.isEmpty ? body : "$body\n\n$arguments";
}

/// What the message's `@agent` references meant, keyed as written. The one
/// sweep of the agent half of a documents map, which both readers below walk.
Map<String, String> agentEntriesFrom(Map<String, String> documents) => {
      for (final entry in documents.entries)
        if (entry.key.startsWith(CompletionKind.agent.trigger))
          entry.key: entry.value,
    };

/// The `@agent` instructions the message asked for, joined in the order they
/// were written — what `turnPrompt` puts under the system prompt for the turn.
/// Null where it named none.
///
/// Off the record rather than the text: the mentions were resolved when the
/// message was composed, and a name mentioned twice was recorded once.
String? agentPromptFrom(Map<String, String> documents) {
  final bodies = agentEntriesFrom(documents).values.toList();
  return bodies.isEmpty ? null : bodies.join("\n\n");
}

/// The one agent key in [documents], as typed; null where there is none or
/// more than one.
String? authorFrom(Map<String, String> documents) {
  final named = agentEntriesFrom(documents).keys.toList();
  return named.length == 1 ? named.single : null;
}
