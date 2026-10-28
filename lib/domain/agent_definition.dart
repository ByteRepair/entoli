import "dart:convert";

import "models.dart";
import "prompt_library.dart";

/// An agent: its instructions and the tools it may use, whichever way it runs
/// — the main agent, a `task` sub-agent, or a room member. Built over the
/// agent's `.md` [document], which stays the source of everything this does
/// not read, so writing it back keeps keys a newer build or a hand edit put
/// there.
///
/// [tools] is the `tools:` frontmatter as tool ids: exactly what the agent is
/// offered among the tools that can be granted, or null for each tool's own
/// default. See "Tools per agent" in `lib/domain/AGENTS.md`.
class AgentDefinition {
  const AgentDefinition._(this.document, this.tools);

  /// The agent a turn runs as when nobody else was asked for: no
  /// instructions of its own, and every tool at its default.
  static const main = AgentDefinition._(null, null);

  factory AgentDefinition.of(PromptDocument document) =>
      AgentDefinition._(document, _parse(document.frontmatter[toolsKey]));

  /// A new agent, as the editor starts one.
  factory AgentDefinition.named(String name) => AgentDefinition.of(PromptDocument(
      kind: CompletionKind.agent, name: name, frontmatter: const {}, body: ""));

  static const toolsKey = "tools";

  final PromptDocument? document;

  final Set<String>? tools;

  String get name => document?.name ?? "";

  String get description => document?.description ?? "";

  String get instructions => document?.body ?? "";

  /// Whether a tool the agent may be granted is offered to it: the list
  /// decides where there is one, the tool's own default where there is not.
  bool offers(String id, {required bool byDefault}) =>
      tools?.contains(id) ?? byDefault;

  AgentDefinition edited({
    required String name,
    required String description,
    required String instructions,
    required Set<String>? tools,
  }) {
    final desc = description.trim();
    final frontmatter = {...?document?.frontmatter}
      ..remove("description")
      ..remove(toolsKey);
    return AgentDefinition._(
      PromptDocument(
        kind: CompletionKind.agent,
        name: name,
        frontmatter: {
          if (desc.isNotEmpty) "description": desc,
          ...frontmatter,
          if (tools != null) toolsKey: tools.join(", "),
        },
        metadata: document?.metadata ?? const {},
        body: instructions.trim(),
      ),
      tools,
    );
  }

  /// The `.md` source: the frontmatter [PromptDocument.parse] reads back,
  /// then the instructions.
  String toSource() {
    final doc = document;
    if (doc == null) return "";
    final lines = [
      for (final MapEntry(:key, :value) in doc.frontmatter.entries)
        if (key == toolsKey)
          // An empty value would read back as a nested block, not an empty list.
          "$key: ${value.isEmpty ? "[]" : value}"
        else
          // JSON's quoting is YAML's double-quoted scalar, and survives a `: `.
          "$key: ${jsonEncode(value)}",
      if (doc.metadata.isNotEmpty) ...[
        "metadata:",
        for (final MapEntry(:key, :value) in doc.metadata.entries)
          "  $key: ${jsonEncode(value)}",
      ],
    ];
    final head = lines.isEmpty ? "" : "---\n${lines.join("\n")}\n---\n\n";
    return "$head${doc.body.trim()}";
  }

  /// Null where the key is absent. A YAML list reaches here comma-joined (see
  /// `Frontmatter`); the brackets are the legacy parser's reading of `[]`.
  static Set<String>? _parse(String? value) {
    if (value == null) return null;
    final bare = value.trim();
    final inner = bare.startsWith("[") && bare.endsWith("]")
        ? bare.substring(1, bare.length - 1)
        : bare;
    return {
      for (final id in inner.split(","))
        if (id.trim().isNotEmpty) id.trim(),
    };
  }
}
