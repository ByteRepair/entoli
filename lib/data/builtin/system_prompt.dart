import "../../domain/profile.dart";
import "../../domain/tone.dart";
import "templates.dart";
import "tools/agent_tool.dart";
import "tools/registry.dart";

/// The rules the agent operates under. Ported from mini-swe-agent's `mini.yaml`
/// and adapted for a conversation: upstream runs one task and exits, this is
/// asked something else once the turn is over.
///
/// **Nothing per-conversation is in here**, which is what makes it one string
/// for a device and a [ToolOffer] and so one cacheable prefix. What is
/// per-chat — the workspace, an `@agent`'s own instructions — is
/// [turnPrompt], a second system message after this one. See "Prefilling the
/// system prompt" in `lib/data/local/AGENTS.md` for what that buys.
///
/// What the turn can call is said by the tools it is offered: each one's
/// fragment in the sentence about calling a tool, and each one's section in
/// registry order, so a tool the turn is not offered is not named.
String systemPrompt({
  required String platform,
  Profile? profile,
  Tone tone = Tone.none,
  bool citations = false,
  ToolOffer offer = const ToolOffer(),
}) {
  final tools = offeredTools(offer);
  final calls = _either([for (final tool in tools) ?tool.fragment]);
  final sections = [
    for (final tool in tools)
      if (tool.section case final section? when section.isNotEmpty)
        section.trim(),
    systemProse("style"),
  ];
  final body = offer.caps.commands
      ? substitute(systemProse("shell"), {
          "tools": calls,
          "shell": systemProse(
            offer.oneShot ? "shell-oneshot" : "shell-persistent",
          ),
          "sections": [
            ...sections,
            systemProse("finish"),
            "<system_information>\n$platform\n</system_information>",
            systemProse("examples"),
          ].join("\n\n"),
        })
      // No shell: the file tools still work on the workspace through the
      // app's own filesystem, so a device without one can still produce files
      // and artifacts. The turn ends the same way, on a reply with no call.
      : "You are a helpful assistant.\n\n"
            "${substitute(systemProse("no-shell"), {"tools": calls})}\n\n"
            "${sections.join("\n\n")}\n";
  return body + profileSection(profile) + styleSection(tone, citations);
}

/// [items] as one sentence's list: "a", "a or b", "a, b, or c".
String _either(List<String> items) {
  if (items.length <= 1) return items.join();
  final head = items.sublist(0, items.length - 1).join(", ");
  return items.length == 2
      ? "$head or ${items.last}"
      : "$head, or ${items.last}";
}
