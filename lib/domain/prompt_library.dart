import "package:collection/collection.dart";

import "frontmatter.dart";
import "models.dart";

/// One skill or agent, exactly as Entoli stores it: YAML frontmatter, then the
/// template a skill expands to or the system prompt an agent runs under.
class PromptDocument {
  const PromptDocument({
    required this.kind,
    required this.name,
    required this.frontmatter,
    required this.body,
    this.metadata = const {},
  });

  final CompletionKind kind;
  final String name;
  final Map<String, String> frontmatter;
  final String body;

  /// The nested `metadata:` map — the spec's extension point, and where
  /// Entoli's own per-client keys live (`argument-hint`, `user-invocable`,
  /// `disable-model-invocation`).
  final Map<String, String> metadata;

  String? get description => frontmatter["description"];

  String? get argumentHint => metadata["argument-hint"];

  /// Whether the `/` menu offers it. False is the model's half alone: a skill
  /// the user can only reach by the model deciding to load it.
  bool get userInvocable => metadata["user-invocable"]?.toLowerCase() != "false";

  /// Whether the model may load it through the `skill` tool. False is the
  /// user's half alone: the tool refuses it, reserved for `/name`.
  bool get modelInvocable =>
      metadata["disable-model-invocation"]?.toLowerCase() != "true";

  /// Whether sending `/name` runs code rather than expanding the body as a
  /// prompt template. What it dispatches to is the closed set in
  /// `wired_skill.dart`; the body is then the skill's user-facing note, never
  /// something a model reads.
  ///
  /// This is the decider where the document is in hand — composition time,
  /// and the `skill` tool's gate — while the dispatch itself matches by name
  /// alone, a build-stable set the reader of a resent turn can still answer.
  bool get isCallback => metadata["invocation"] == "callback";

  CompletionOption get option => CompletionOption(
        name: name,
        description: description,
        argumentHint: argumentHint,
      );

  /// Only the top-level scalars and one nested `metadata:` map are read,
  /// because `description` and the metadata keys are all the menu and the
  /// tool gates need. Everything else — nested lists, deeper maps — is
  /// dropped. The parsing lives in [Frontmatter], its own file so the
  /// build-time generators can share it without the freezed models.
  factory PromptDocument.parse(CompletionKind kind, String name, String source) {
    final parsed = Frontmatter.parse(source);
    return PromptDocument(
      kind: kind,
      name: name,
      frontmatter: parsed.scalars,
      metadata: parsed.metadata,
      body: parsed.body,
    );
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
final RegExp skillReference = RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$");

/// `@name` addresses an agent, but only where the handle starts, so an email
/// address (`me@general`) and a path (`a@b.c`) are not mentions. Markdown
/// dressing around a handle — `**@murasaki**` — does not stop it being one.
final _mention = RegExp(r"(?<![\w.-])@([\w.-]+)");

/// What the library says [text]'s references mean, ready to be written into the
/// message as [Message.documents] and read back by [expandedPrompt] and
/// [agentPromptFrom] — see "Skills and agents" in `lib/domain/AGENTS.md`.
///
/// Keyed by the reference as written, sigil included, so a skill and an agent
/// of the same name do not collide. A name the library does not know is left
/// out: it is more likely a path, or prose, than a document nobody defined.
Map<String, String> promptDocuments(String text, PromptLibrary? library) => {
      // A wired callback is not a thing the model is told what it meant: the
      // turn runs code, and the skill's body is the user-facing note —
      // expanded into the conversation it would be prose the model reads
      // where no model is reading. The document in hand is what answers, and
      // this is where it is in hand: the reload-staleness hazard the
      // documents map exists for does not apply at composition time.
      if (skillReference.firstMatch(text.trim())?.group(1) case final name?)
        if (library?.find(CompletionKind.skill, name)
            case final document? when !document.isCallback)
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
  final match = skillReference.firstMatch(text.trim());
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

/// The member [documents] shows addressed, as typed — the first agent key in
/// write order. Null where the message names no member at all. A message that
/// addresses one member and names another as a handoff target ("check X, then
/// hand it to @reviewer") is still addressed to one: the first mention is the
/// addressee, the later one the routing the reply will carry out.
/// The member [documents] shows addressed, as typed — the first agent key in
/// write order. Null where the message names no member at all. A message that
/// addresses one member and names another as a handoff target ("check X, then
/// hand it to @reviewer") is still addressed to one: the first mention is the
/// addressee, the later one the routing the reply will carry out.
String? authorFrom(Map<String, String> documents) => authorKeys(documents).firstOrNull;

/// The members [documents] address, in the order they were written — the
/// agent keys as typed, sigil on. Empty where the message names no member.
List<String> authorKeys(Map<String, String> documents) =>
    agentEntriesFrom(documents).keys.toList();

/// The member name an author stamp carries — the sigil off, the library's
/// name for them. An unnamed stamp names nothing.
String? nameOf(String? author) =>
    author == null
        ? null
        : author.startsWith(CompletionKind.agent.trigger)
            ? author.substring(CompletionKind.agent.trigger.length)
            : null;

/// Whether the room sent [message] to the participant called [viewer]: the
/// house for null, a member's bare name otherwise. A say addressed away from
/// both is somebody else's mail — the fact [Message.addressees] records and
/// the projection words per viewer. Names are compared bare: the sigil is
/// spelling, not identity, the same dialect [nameOf] reads in.
bool addressedTo(Message message, String? viewer) {
  final to = message.addressees;
  if (viewer == null) return to.isEmpty;
  return to.map(nameOf).contains(viewer);
}

/// The one member [text] mentions by handle, as the composer's own `_mention`
/// reads one and [library] knows them. Null where it names none, or more than
/// one — a multi-mention is a round, not a single address.
String? singleAgentMention(String text, PromptLibrary library) {
  final known = mentionsIn(text, library);
  return known.length == 1 ? known.single : null;
}

/// The members [text] addresses, in the order it names them. A name the
/// library does not know is prose, not an address — a member signing their own
/// reply (`@scout reporting`) is not addressed by their own signature. The
/// empty list is no address at all.
List<String> mentionsIn(String text, PromptLibrary library) =>
    _mention
        .allMatches(text)
        .map((m) => m.group(1)!)
        .where((name) => library.find(CompletionKind.agent, name) != null)
        .toSet()
        .toList();
