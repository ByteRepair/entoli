/// How the agent is asked to word its replies, one sentence each, rendered
/// into the system prompt by `profileSection`'s neighbour. `none` emits
/// nothing, so the prompt and the warmed prefix over it keep the bytes they
/// had — the same bargain an empty [Profile] makes.
enum Tone {
  none,
  direct,
  kind,
  formal;

  /// The sentence the prompt carries. Only [Tone.none] has none.
  String? get instruction => switch (this) {
        none => null,
        direct => "Word replies directly and to the point, plainly and "
            "without ceremony.",
        kind => "Word replies warmly and encouragingly, while staying "
            "concrete and brief.",
        formal => "Word replies in a formal, professional register, with "
            "no slang or contractions.",
      };

  /// What the settings pages call each one. Beside the enum so the project
  /// page's inherited entry and the app page's dropdown name them the same.
  static const labels = {
    none: "Default",
    direct: "Direct",
    kind: "Kind",
    formal: "Formal",
  };

  static Tone fromJson(Object? value) => switch (value) {
        "direct" => direct,
        "kind" => kind,
        "formal" => formal,
        _ => none,
      };

  String toJson() => name;
}