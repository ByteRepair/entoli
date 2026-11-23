/// How the agent is asked to word its replies, one sentence each, rendered
/// into the system prompt by `profileSection`'s neighbour. `none` emits
/// nothing, so the prompt and the warmed prefix over it keep the bytes they
/// had — the same bargain an empty [Profile] makes.
///
/// Declaration order is the order the settings pages offer them in.
enum Tone {
  none("Default"),
  direct("Direct"),
  kind("Kind"),
  formal("Formal");

  const Tone(this.label);

  final String label;

  /// The sentence the prompt carries. Only [Tone.none] has none.
  String? get instruction => switch (this) {
    none => null,
    direct =>
      "Word replies directly and to the point, plainly and "
          "without ceremony.",
    kind =>
      "Word replies warmly and encouragingly, while staying "
          "concrete and brief.",
    formal =>
      "Word replies in a formal, professional register, with "
          "no slang or contractions.",
  };
}
