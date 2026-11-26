import "dart:convert";

import "package:crypto/crypto.dart";

/// What two paired devices keep in step of their settings, item by item:
/// the profile, and each provider by its id. An item is its fields as JSON
/// values, or null where the device does not have it.
typedef SyncedItems = Map<String, Map<String, Object?>?>;

/// The key the profile is synced under.
const profileItem = "profile";

/// The key a provider is synced under, by its id.
String providerItem(String id) => "provider:$id";

/// The provider id [item] names, or null for an item that is not one.
String? providerIdOf(String item) =>
    item.startsWith("provider:") ? item.substring("provider:".length) : null;

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
/// key could be read back out of. Null where they have never agreed, which
/// is their first sync.
class MergeBase {
  const MergeBase(this.items);

  /// Per item, per field, the hash of the value agreed; an item agreed
  /// absent is null.
  final Map<String, Map<String, String>?> items;

  static MergeBase of(SyncedItems items) => MergeBase({
    for (final MapEntry(:key, :value) in items.entries)
      key: value == null
          ? null
          : {for (final field in value.entries) field.key: hashOf(field.value)},
  });

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

  Map<String, Object?> toJson() => items;

  static MergeBase? fromJson(Object? json) {
    if (json is! Map) return null;
    return MergeBase({
      for (final MapEntry(:key, :value) in json.entries)
        "$key": value is Map
            ? {
                for (final field in value.entries)
                  "${field.key}": "${field.value}",
              }
            : null,
    });
  }
}

/// [local] and [remote] made one, against what the two last agreed: where
/// only one side changed a field since, its edit is kept; where both changed
/// it, differently, the [localWins] side's is. An item one side removed and
/// the other left alone goes; one removed against an edit is the winner's
/// to keep or drop.
///
/// On a first sync there is nothing agreed, so an item only one side has is
/// kept and one both have and that differs is taken whole from the winner:
/// the profile the user chose to keep, not a mix of the two.
///
/// Symmetric: the other device, passing its own side as [local] and the
/// opposite [localWins], reaches the same items.
SyncedItems mergeSettings({
  required SyncedItems local,
  required SyncedItems remote,
  required MergeBase? base,
  required bool localWins,
}) {
  final merged = <String, Map<String, Object?>?>{};
  for (final key in {...local.keys, ...remote.keys}) {
    final mine = local[key];
    final theirs = remote[key];
    final Map<String, Object?>? item;
    if (base == null || !base.items.containsKey(key)) {
      item = mine == null || theirs == null
          ? mine ?? theirs
          : _same(mine, theirs)
          ? mine
          : (localWins ? mine : theirs);
    } else {
      item = _mergeItem(mine, theirs, base.items[key], localWins);
    }
    merged[key] = item;
  }
  return merged;
}

Map<String, Object?>? _mergeItem(
  Map<String, Object?>? mine,
  Map<String, Object?>? theirs,
  Map<String, String>? agreed,
  bool localWins,
) {
  bool unchanged(Map<String, Object?>? item) =>
      item == null ? agreed == null : agreed != null && _matches(item, agreed);
  if (mine == null || theirs == null) {
    if (mine == null && theirs == null) return null;
    // One side has it gone: kept only where the other changed it since,
    // and then only if that side wins.
    final present = mine ?? theirs!;
    if (unchanged(present)) return null;
    if (agreed == null) return present;
    final presentWins = (mine != null) == localWins;
    return presentWins ? present : null;
  }
  final fields = <String, Object?>{};
  for (final field in {...mine.keys, ...theirs.keys}) {
    final a = mine[field], b = theirs[field];
    final was = agreed?[field];
    final aHash = MergeBase.hashOf(a), bHash = MergeBase.hashOf(b);
    final Object? value;
    if (aHash == bHash) {
      value = a;
    } else if (aHash == (was ?? MergeBase.hashOf(null))) {
      value = b;
    } else if (bHash == (was ?? MergeBase.hashOf(null))) {
      value = a;
    } else {
      value = localWins ? a : b;
    }
    if (value != null) fields[field] = value;
  }
  return fields;
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) =>
    MergeBase.hashOf(a) == MergeBase.hashOf(b);

bool _matches(Map<String, Object?> item, Map<String, String> agreed) {
  final fields = {
    for (final MapEntry(:key, :value) in item.entries)
      if (value != null) key: MergeBase.hashOf(value),
  };
  final nonNull = {
    for (final MapEntry(:key, :value) in agreed.entries)
      if (value != MergeBase.hashOf(null)) key: value,
  };
  return fields.length == nonNull.length &&
      fields.entries.every((e) => nonNull[e.key] == e.value);
}

/// Whether [a] and [b] hold the same items, field for field.
bool sameItems(SyncedItems a, SyncedItems b) =>
    MergeBase.hashOf(a) == MergeBase.hashOf(b);
