import "goal.dart";
import "prompt_library.dart";

/// A skill whose frontmatter says `invocation: callback` runs code rather than
/// expanding its body as a prompt template — the same one `/` namespace the
/// opencode-era offered commands under, where the frontmatter decided what a
/// send meant. What it runs is one of these, by skill name: a name the enum
/// does not carry means the callback is not implemented, and the skill falls
/// back to being the ordinary template expansion it would have been without
/// the key.
///
/// A callback turn is not sent to a model as typed — the same pre-model route
/// the `!` shell bypass takes — so the places that must not route a message to
/// a model read [wiredSkillFromText] beside [shellBypassCommand]. The enum is
/// the closed set, which is why the match is by name alone: a build-stable
/// name is answered the same by every reader, and the reader of a turn being
/// resent cannot ask what the frontmatter said when it ran.
///
/// `goal` is the one whose callback can end in a model turn: setting a goal
/// and resuming one change the chat's goal and then start the work, the
/// projection wording the message as the kickoff — see [wiredRunsModel].
enum WiredSkill { compact, goal }

/// A callback message read: which one, and what followed its name.
typedef WiredCall = ({WiredSkill skill, String arguments});

/// The wired skills by name — the enum is the closed set, so this is the one
/// lookup the dispatch shares.
final _byName = {for (final s in WiredSkill.values) s.name: s};

/// The callback [text] would run, with the arguments after the name, or null
/// where it dispatches as an ordinary message. The same [skillReference] shape
/// the expansion reads — the whole message is `/name arguments` — so a text the
/// composer's menu could offer is one this answers, and anything else is prose.
///
/// Read beside [shellBypassCommand] by the dispatch and by every caller that
/// must not hand a callback message to a model: the title namer, the resume
/// offer, and the composer's dress-up.
WiredCall? wiredSkillFromText(String text) {
  final match = skillReference.firstMatch(text.trim());
  if (match == null) return null;
  return switch (_byName[match.group(1)!]) {
    null => null,
    final skill => (skill: skill, arguments: match.group(2) ?? ""),
  };
}

/// Whether the callback [text] runs hands a turn to a model after all: a goal
/// being set or resumed. Such a turn is resumable like any other, and its
/// message is worded for the model by the projection rather than kept from
/// it; every other callback appends nothing a model wrote.
bool wiredRunsModel(String text) => switch (wiredSkillFromText(text)) {
  (skill: WiredSkill.goal, :final arguments) => goalCommandRunsModel(arguments),
  _ => false,
};

/// The objective a `/goal` message sets, or null where [wired] sets none.
String? goalObjectiveOf(WiredCall wired) => switch (wired) {
  (skill: WiredSkill.goal, :final arguments) => switch (goalCommandOf(
    arguments,
  )) {
    GoalSet(:final objective) => objective,
    _ => null,
  },
  _ => null,
};
