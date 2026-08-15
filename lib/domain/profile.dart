/// The user's profile, injected at the end of the system prompt so the model
/// has context about who it is talking to. App-level by default; a project can
/// override it via [ProjectSettings]. Every field is optional, and null means
/// "not set" — both on disk and in the rendered prompt, where a field that is
/// null is omitted rather than shown as blank.
class Profile {
  const Profile({
    this.preferencesPrompt,
    this.name,
    this.dateOfBirth,
    this.religion,
    this.profession,
  });

  /// Free-text general preferences the user wants applied to every turn.
  final String? preferencesPrompt;
  final String? name;

  /// ISO `YYYY-MM-DD`. Stored as a string to avoid imposing a date format on
  /// the file; the UI picks it with a date picker and serializes it here.
  final String? dateOfBirth;
  final String? religion;
  final String? profession;

  bool get isEmpty =>
      (preferencesPrompt == null || preferencesPrompt!.isEmpty) &&
      (name == null || name!.isEmpty) &&
      (dateOfBirth == null || dateOfBirth!.isEmpty) &&
      (religion == null || religion!.isEmpty) &&
      (profession == null || profession!.isEmpty);

  Map<String, dynamic> toJson() => {
        if (preferencesPrompt != null && preferencesPrompt!.isNotEmpty)
          "preferencesPrompt": preferencesPrompt,
        if (name != null && name!.isNotEmpty) "name": name,
        if (dateOfBirth != null && dateOfBirth!.isNotEmpty) "dateOfBirth": dateOfBirth,
        if (religion != null && religion!.isNotEmpty) "religion": religion,
        if (profession != null && profession!.isNotEmpty) "profession": profession,
      };

  static Profile? fromJson(Object? value) {
    if (value is! Map) return null;
    String? field(String key) {
      final v = value[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final profile = Profile(
      preferencesPrompt: field("preferencesPrompt"),
      name: field("name"),
      dateOfBirth: field("dateOfBirth"),
      religion: field("religion"),
      profession: field("profession"),
    );
    return profile.isEmpty ? null : profile;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile &&
          preferencesPrompt == other.preferencesPrompt &&
          name == other.name &&
          dateOfBirth == other.dateOfBirth &&
          religion == other.religion &&
          profession == other.profession;

  @override
  int get hashCode => Object.hash(
        preferencesPrompt,
        name,
        dateOfBirth,
        religion,
        profession,
      );
}