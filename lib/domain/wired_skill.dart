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
/// read [wiredSkillFromText] beside [shellBypassCommand]. The enum is the
/// closed set, which is why the match is by name alone: a build-stable name
/// has none of the staleness hazard that made `Message.documents` necessary
/// for `/skills`, and the reader of a turn being resent cannot ask what the
/// frontmatter said when it ran.
enum WiredSkill {
  compact,
}

/// The wired skills by name — the enum is the closed set, so this is the one
/// lookup the dispatch and the name-only match share.
final _byName = {for (final s in WiredSkill.values) s.name: s};

/// Whether [name] is one this build implements a callback for. The name-only
/// half of [wiredSkillFromText]: the reader of a log asks it where the library
/// the turn was sent under is not there to ask.
bool isWiredSkillName(String name) => _byName.containsKey(name);

/// The callback [text] would run, with the arguments after the name, or null
/// where it dispatches as an ordinary message. The same [skillReference] shape
/// the expansion reads — the whole message is `/name arguments` — so a text the
/// composer's menu could offer is one this answers, and anything else is prose.
///
/// Read beside [shellBypassCommand] by the dispatch and by every caller that
/// must not hand a callback message to a model: the title namer, the resume
/// offer, and the composer's dress-up.
({WiredSkill skill, String arguments})? wiredSkillFromText(String text) {
  final match = skillReference.firstMatch(text.trim());
  if (match == null) return null;
  return switch (_byName[match.group(1)!]) {
    null => null,
    final skill => (skill: skill, arguments: match.group(2) ?? ""),
  };
}