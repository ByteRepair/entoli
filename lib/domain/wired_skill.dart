import "models.dart";
import "prompt_library.dart";

/// A skill whose frontmatter says `invocation: callback` runs code rather than
/// expanding its body as a prompt template — the same one `/` namespace the
/// opencode-era offered commands under, where the frontmatter decided what a
/// send meant. What it runs is one of these, by skill name: a name the enum
/// does not carry means the callback is not implemented, and the skill falls
/// back to being the ordinary template expansion it would have been without
/// the key.
///
/// A callback turn is never sent to a model — the same pre-model route the `!`
/// shell bypass takes — so the places that must not route a message to a model
/// read [wiredSkillFrom] beside [shellBypassCommand].
enum WiredSkill {
  compact,
}

/// The callback [document] runs, or null where it is not one: not flagged, or
/// flagged under a name this build does not implement.
WiredSkill? wiredSkillFrom(PromptDocument? document) {
  if (document == null || !document.isCallback) return null;
  return _byName[document.name];
}

/// The wired skills by name — the enum is the closed set, so this is the one
/// lookup both dispatch and the name-only match share.
final _byName = {for (final s in WiredSkill.values) s.name: s};

/// Whether [name] is one this build implements a callback for. The name-only
/// half of [wiredSkillFrom]: the reader of a log asks it where the library the
/// turn was sent under is not there to ask.
bool isWiredSkillName(String name) => _byName.containsKey(name);

/// The callback [text] would run, with the arguments after the name, or null
/// where it dispatches as an ordinary message. The same `_skillReference` shape
/// the expansion reads — the whole message is `/name arguments` — so a text the
/// composer's menu could offer is one this answers, and anything else is prose.
///
/// Read beside [shellBypassCommand] by the dispatch and by every caller that
/// must not hand a callback message to a model: the title namer, the resume
/// offer, and the composer's dress-up.
({WiredSkill skill, String arguments})? wiredSkillFromText(
    String text, PromptLibrary? library) {
  final match =
      RegExp(r"^/([^\s/]+)(?:\s+([\s\S]*))?$").firstMatch(text.trim());
  if (match == null) return null;
  // The name answers before the library does: a name in the enum is the
  // app's own, and a message naming one dispatches whether or not the library
  // it is being read against still holds the skill — the reader of a turn
  // being resent cannot ask what the frontmatter said when it ran.
  final name = match.group(1)!;
  if (_byName[name] case final skill?) {
    return (skill: skill, arguments: match.group(2) ?? "");
  }
  final skill = wiredSkillFrom(library?.find(CompletionKind.skill, name));
  if (skill == null) return null;
  return (skill: skill, arguments: match.group(2) ?? "");
}