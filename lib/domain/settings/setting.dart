import "../model_capability.dart" show ModelRef;

/// The levels a value can be set at, each overriding the one above it: the
/// app's `settings.json`, a project's `project.json`, a chat's `meta.json`.
enum SettingScope { app, project, chat }

/// How a value is kept in a JSON document. [decode] answers null for
/// anything it cannot read, which a document treats as unset: a value a
/// later build wrote, or a file edited by hand, falls back rather than
/// failing the whole load.
abstract class SettingCodec<T extends Object> {
  const SettingCodec();

  T? decode(Object? raw);

  Object? encode(T value);

  /// A value that is the same as none: an empty list is not written, so a
  /// level holding one inherits.
  bool isEmpty(T value) => false;
}

class BoolCodec extends SettingCodec<bool> {
  const BoolCodec();

  @override
  bool? decode(Object? raw) => raw is bool ? raw : null;

  @override
  Object encode(bool value) => value;
}

/// A whole number, held to [min] and [max] where they are given, so a file
/// edited past the bounds reads as the nearest one.
class IntCodec extends SettingCodec<int> {
  const IntCodec({this.min, this.max});

  final int? min;
  final int? max;

  @override
  int? decode(Object? raw) {
    if (raw is! int) return null;
    var value = raw;
    if (min case final min? when value < min) value = min;
    if (max case final max? when value > max) value = max;
    return value;
  }

  @override
  Object encode(int value) => value;
}

/// Text. An empty string reads as unset unless [keepEmpty]: builds before
/// the provider flattening fix wrote empty ids.
class StringCodec extends SettingCodec<String> {
  const StringCodec({this.keepEmpty = false});

  final bool keepEmpty;

  @override
  String? decode(Object? raw) =>
      raw is String && (keepEmpty || raw.isNotEmpty) ? raw : null;

  @override
  Object encode(String value) => value;

  @override
  bool isEmpty(String value) => !keepEmpty && value.isEmpty;
}

/// An enum by name. A name this build does not know is a later build's.
class EnumCodec<E extends Enum> extends SettingCodec<E> {
  const EnumCodec(this.values);

  final List<E> values;

  @override
  E? decode(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  @override
  Object encode(E value) => value.name;
}

class StringListCodec extends SettingCodec<List<String>> {
  const StringListCodec();

  @override
  List<String>? decode(Object? raw) => raw is List
      ? [for (final item in raw) ?(item is String ? item : null)]
      : null;

  @override
  Object encode(List<String> value) => value;

  @override
  bool isEmpty(List<String> value) => value.isEmpty;
}

/// Names to values, as a command's environment is.
///
/// A map holding anything but strings reads as unset, rather than as the
/// strings in it: what a command runs under is all or nothing.
class StringMapCodec extends SettingCodec<Map<String, String>> {
  const StringMapCodec();

  @override
  Map<String, String>? decode(Object? raw) {
    if (raw is! Map || !raw.values.every((v) => v is String)) return null;
    return Map.unmodifiable({
      for (final entry in raw.entries)
        entry.key.toString(): entry.value as String,
    });
  }

  @override
  Object encode(Map<String, String> value) => value;

  @override
  bool isEmpty(Map<String, String> value) => value.isEmpty;
}

/// Models as `[providerId, modelId]` pairs, in order.
class ModelRefListCodec extends SettingCodec<List<ModelRef>> {
  const ModelRefListCodec();

  @override
  List<ModelRef>? decode(Object? raw) => raw is List
      ? [
          for (final pair in raw)
            if (pair case [final String providerId, final String modelId])
              (providerId: providerId, modelId: modelId),
        ]
      : null;

  @override
  Object encode(List<ModelRef> value) => [
    for (final m in value) [m.providerId, m.modelId],
  ];

  @override
  bool isEmpty(List<ModelRef> value) => value.isEmpty;
}

/// A type with a JSON form of its own.
class JsonCodec<T extends Object> extends SettingCodec<T> {
  const JsonCodec(this._decode, this._encode, {this.empty});

  final T? Function(Object? raw) _decode;
  final Object? Function(T value) _encode;
  final bool Function(T value)? empty;

  @override
  T? decode(Object? raw) => _decode(raw);

  @override
  Object? encode(T value) => _encode(value);

  @override
  bool isEmpty(T value) => empty?.call(value) ?? false;
}

/// One value a settings document holds: the key it is under, how it is
/// kept, and the levels it may be set at.
class Setting<T extends Object> {
  const Setting(
    this.key,
    this.codec, {
    this.scopes = const {SettingScope.app},
    this.legacy,
    this.retired = const [],
  });

  final String key;
  final SettingCodec<T> codec;
  final Set<SettingScope> scopes;

  /// What a file from before this key existed says instead, read where the
  /// key is absent. A document listing this among its upgrades moves it
  /// under [key] as it loads.
  final T? Function(Map<String, Object?> json)? legacy;

  /// The keys [legacy] reads, dropped from the file on a write.
  final List<String> retired;

  @override
  String toString() => "Setting($key)";
}

/// A [Setting] with a value where nothing is set: what the app does with no
/// settings file at all.
class DefaultedSetting<T extends Object> extends Setting<T> {
  const DefaultedSetting(
    super.key,
    super.codec, {
    required this.fallback,
    super.scopes,
    super.legacy,
    super.retired,
  });

  final T fallback;
}

/// One level's settings: a JSON document read through [Setting]s. The JSON
/// is the source of truth, so a key this build does not know — a later
/// build's — is kept through a save. What a key decodes to is cached, since
/// some are read on every model call.
class SettingsDocument {
  /// [root] is the app's level, where nothing above inherits: a value equal
  /// to its setting's fallback is not written there, so a file that predates
  /// a default says nothing and gets it. Each of [upgrades] that a file holds
  /// only under its old name is moved under its own, so the next save writes
  /// the file in today's shape.
  SettingsDocument({
    Map<String, Object?>? json,
    this.root = false,
    List<Setting> upgrades = const [],
  }) : _json = {...?json} {
    for (final setting in upgrades) {
      _upgrade(setting);
    }
  }

  void _upgrade<T extends Object>(Setting<T> setting) {
    if (!setting.retired.any(_json.containsKey)) return;
    set(setting, read(setting));
  }

  final bool root;
  final Map<String, Object?> _json;
  final _cache = <Setting, Object?>{};

  /// What this level holds for [setting], or null where it holds nothing.
  T? read<T extends Object>(Setting<T> setting) {
    if (_cache.containsKey(setting)) return _cache[setting] as T?;
    final raw = _json[setting.key];
    final value = raw == null
        ? setting.legacy?.call(_json)
        : setting.codec.decode(raw);
    _cache[setting] = value;
    return value;
  }

  /// What this level holds for [setting], or its fallback.
  T of<T extends Object>(DefaultedSetting<T> setting) =>
      read(setting) ?? setting.fallback;

  /// Sets [setting] to [value], or clears it where [value] is null, empty, or
  /// the fallback at the [root].
  void set<T extends Object>(Setting<T> setting, T? value) {
    for (final key in setting.retired) {
      _json.remove(key);
    }
    final unset =
        value == null ||
        setting.codec.isEmpty(value) ||
        (root && setting is DefaultedSetting<T> && value == setting.fallback);
    if (unset) {
      _json.remove(setting.key);
    } else {
      _json[setting.key] = setting.codec.encode(value);
    }
    _cache.remove(setting);
  }

  bool get isEmpty => _json.isEmpty;

  Map<String, Object?> toJson() => {..._json};

  SettingsDocument copy() => SettingsDocument(json: _json, root: root);
}
