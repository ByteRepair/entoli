/// Something Shortcuts can ask the app to do, by name. The boundary's own
/// type: what it adapts — `AppCommand`s, [ChatIntents] — does not know it
/// exists, and each adapter owns turning its arguments in and its result
/// out, so every cast between the wire and a typed call is in one place.
///
/// [id] is what a saved shortcut names, so it is never renamed.
abstract interface class IntentAction {
  String get id;

  /// What the action returns, as the wire carries it: null, a string, a bool,
  /// a number, or lists and string-keyed maps of those. Throws
  /// [IntentRefused] where it could not be done, with words for the user.
  Future<Object?> perform(IntentArgs args);
}

/// An action that could not be done, and why — the sentence Shortcuts shows.
final class IntentRefused implements Exception {
  const IntentRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// An action's arguments as they arrived, read by name and type. A missing
/// or mistyped argument is the caller's mistake, refused rather than thrown
/// as a cast error nobody can read.
final class IntentArgs {
  const IntentArgs(this._values);

  final Map<Object?, Object?> _values;

  String string(String name) =>
      optionalString(name) ?? (throw IntentRefused("$name is required."));

  /// Null where the argument is missing or blank: Shortcuts sends an empty
  /// string for a text field left empty, which means the same as none.
  String? optionalString(String name) {
    final value = _typed<String>(name);
    return value == null || value.trim().isEmpty ? null : value;
  }

  /// A list of strings; none is an empty one.
  List<String> strings(String name) {
    final value = _typed<List<Object?>>(name) ?? const [];
    if (value.any((item) => item is! String)) {
      throw IntentRefused("$name is not a list of text.");
    }
    return value.cast<String>();
  }

  bool flag(String name, {required bool orElse}) =>
      _typed<bool>(name) ?? orElse;

  int? optionalInt(String name) => _typed<int>(name);

  T? _typed<T>(String name) {
    final value = _values[name];
    if (value == null || value is T) return value as T?;
    throw IntentRefused("$name is the wrong kind of value.");
  }
}

/// Every action there is, by id: what an incoming call is looked up in.
final class IntentRegistry {
  IntentRegistry(Iterable<IntentAction> actions)
    : _actions = {for (final action in actions) action.id: action};

  final Map<String, IntentAction> _actions;

  Future<Object?> perform(String id, IntentArgs args) async {
    final action = _actions[id];
    if (action == null) {
      throw IntentRefused(
        "This version of Entoli cannot do “$id”. Update it and try again.",
      );
    }
    return action.perform(args);
  }
}
