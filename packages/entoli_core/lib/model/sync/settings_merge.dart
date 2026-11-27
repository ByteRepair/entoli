import "dart:convert";

import "package:collection/collection.dart";
import "package:crypto/crypto.dart";

/// What two paired devices keep in step of their settings, item by item:
/// the profile, and each provider by its name. An item is its fields as JSON
/// values; one the device does not have is not in the map.
typedef SyncedItems = Map<String, Map<String, Object?>>;

/// The key the profile is synced under.
const profileItem = "profile";

/// The key a provider is synced under: its name, as the user tells two apart,
/// and not its id, which each device mints for itself. Two devices that each
/// added Ollama Cloud have one Ollama Cloud between them.
String providerItem(String name) => "provider:${name.trim().toLowerCase()}";

/// Whether [item] is a provider's.
bool isProviderItem(String item) => item.startsWith("provider:");

const _deep = DeepCollectionEquality();

/// Who wins where both devices changed the same thing since they last
/// agreed: one of the two, or neither, which is the two not syncing these at
/// all. Chosen on one device, the first time the two meet, and carried to
/// the other with the time it was chosen, so a later choice on either wins.
class SyncPrecedence {
  const SyncPrecedence({required this.winner, required this.decidedAt});

  /// The device whose edit is kept, or null where these are not synced.
  final String? winner;
  final DateTime decidedAt;

  bool get syncs => winner != null;

  Map<String, Object?> toJson() => {
    "winner": winner,
    "decidedAt": decidedAt.toUtc().toIso8601String(),
  };

  static SyncPrecedence? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse("${json["decidedAt"]}");
    if (at == null) return null;
    final winner = json["winner"];
    return SyncPrecedence(
      winner: winner is String ? winner : null,
      decidedAt: at,
    );
  }

  /// The later of [a] and [b]; on the same instant, the one naming the
  /// greater winner, so both devices settle on the same one.
  static SyncPrecedence? later(SyncPrecedence? a, SyncPrecedence? b) {
    if (a == null || b == null) return a ?? b;
    final order = a.decidedAt.compareTo(b.decidedAt);
    if (order != 0) return order > 0 ? a : b;
    return (a.winner ?? "").compareTo(b.winner ?? "") >= 0 ? a : b;
  }

  @override
  bool operator ==(Object other) =>
      other is SyncPrecedence &&
      other.winner == winner &&
      other.decidedAt == decidedAt;

  @override
  int get hashCode => Object.hash(winner, decidedAt);
}

/// What two devices last agreed each item was, field by field, as hashes:
/// enough to tell which side changed a field since, and nothing a provider's
/// key could be read back out of. A field that is null is not in it.
class MergeBase {
  const MergeBase(this.items);

  /// Per item, per field, the hash of the value agreed.
  final Map<String, Map<String, String>> items;

  static MergeBase of(SyncedItems items) => MergeBase({
    for (final MapEntry(:key, :value) in items.entries) key: fieldsOf(value),
  });

  /// [item]'s fields that hold anything, each as its hash.
  static Map<String, String> fieldsOf(Map<String, Object?> item) => {
    for (final MapEntry(:key, :value) in item.entries)
      if (value != null) key: hashOf(value),
  };

  /// One value's hash, over its JSON with keys in order, so two maps that
  /// differ only in how they were built hash the same.
  static String hashOf(Object? value) =>
      "${sha256.convert(utf8.encode(jsonEncode(_canonical(value))))}";

  static Object? _canonical(Object? value) => switch (value) {
    final Map<dynamic, dynamic> map => {
      for (final key in map.keys.map((k) => "$k").toList()..sort())
        key: _canonical(map[key]),
    },
    final List<dynamic> list => [for (final v in list) _canonical(v)],
    _ => value,
  };

  /// Whether [items] is what was agreed.
  bool agrees(SyncedItems items) => _deep.equals(this.items, of(items).items);

  Map<String, Object?> toJson() => items;

  static MergeBase? fromJson(Object? json) {
    if (json is! Map) return null;
    return MergeBase({
      for (final MapEntry(:key, :value) in json.entries)
        if (value is Map)
          "$key": {
            for (final field in value.entries) "${field.key}": "${field.value}",
          },
    });
  }
}

/// [local] and [remote] made one, against what the two last agreed: where
/// only one side changed a field since, its edit is kept; where both changed
/// it, differently, the [localWins] side's is. An item one side removed and
/// the other left alone goes; one removed against an edit is the winner's
/// to keep or drop.
///
/// An item the two never agreed on — every item at a first sync — is kept
/// where only one side has it, and taken whole from the winner where both
/// do: the profile the user chose to keep, not a mix of the two.
///
/// Symmetric: the other device, passing its own side as [local] and the
/// opposite [localWins], reaches the same items.
SyncedItems mergeSettings({
  required SyncedItems local,
  required SyncedItems remote,
  required MergeBase? base,
  required bool localWins,
}) => {
  for (final key in {...local.keys, ...remote.keys})
    key: ?_mergeItem(local[key], remote[key], base?.items[key], localWins),
};

Map<String, Object?>? _mergeItem(
  Map<String, Object?>? mine,
  Map<String, Object?>? theirs,
  Map<String, String>? agreed,
  bool localWins,
) {
  if (mine == null || theirs == null) {
    final present = mine ?? theirs;
    // Gone from one side: kept only where the other changed it since, and
    // then only if that side wins.
    if (present == null || agreed == null) return present;
    if (const MapEquality<String, String>().equals(
      MergeBase.fieldsOf(present),
      agreed,
    )) {
      return null;
    }
    return (mine != null) == localWins ? present : null;
  }
  if (agreed == null) return localWins ? mine : theirs;
  final fields = <String, Object?>{};
  for (final field in {...mine.keys, ...theirs.keys}) {
    final a = mine[field], b = theirs[field];
    final was = agreed[field];
    final aHash = a == null ? null : MergeBase.hashOf(a);
    final bHash = b == null ? null : MergeBase.hashOf(b);
    final value = aHash == bHash || bHash == was
        ? a
        : aHash == was
        ? b
        : (localWins ? a : b);
    if (value != null) fields[field] = value;
  }
  return fields;
}

/// Whether [a] and [b] hold the same items, field for field, a null field
/// being no field.
bool sameItems(SyncedItems a, SyncedItems b) =>
    _deep.equals(_filled(a), _filled(b));

SyncedItems _filled(SyncedItems items) => {
  for (final MapEntry(:key, :value) in items.entries)
    key: {
      for (final field in value.entries)
        if (field.value != null) field.key: field.value,
    },
};
