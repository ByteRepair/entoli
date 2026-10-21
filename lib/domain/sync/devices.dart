import "dart:convert";

import "identity.dart" show SyncIdentity;

/// A paired device, as the registry holds it. Everything here is public:
/// the pairing secret that authenticates reconnects is kept beside it in the
/// [SecretStore], never in this record.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.addedAt,
    DateTime? lastSeenAt,
    this.addresses = const [],
  }) : lastSeenAt = lastSeenAt ?? addedAt;

  /// The peer's identity id — derived from its public key, so it travels with
  /// every handshake and a connection claiming another id refuses to open.
  final String id;
  final String name;
  final String publicKey;

  final DateTime addedAt;
  DateTime lastSeenAt;

  /// Every host:port its LAN signaling server was last known on, the one that
  /// answered first. A hint for reconnecting, not a promise — LAN addresses
  /// move, though a tailnet's do not.
  List<String> addresses;

  /// The record as [name] addresses it: what a rename is. The name is final
  /// on the record, so a rename is this replacement — every other fact
  /// carried over whole — rather than a field write.
  PairedDevice withName(String name) => PairedDevice(
        id: id,
        name: name,
        publicKey: publicKey,
        addedAt: addedAt,
        lastSeenAt: lastSeenAt,
        addresses: addresses,
      );

  /// The fingerprint over this record's stored key, or null where it will
  /// not decode. A record this app wrote, so only a hand-edit breaks one;
  /// the code itself comes from [SyncIdentity.fingerprintOf], so both ends'
  /// screens derive the same answer from the same key by construction.
  String? get fingerprint {
    try {
      return SyncIdentity.fingerprintOf(base64Decode(publicKey));
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "publicKey": publicKey,
        "addedAt": addedAt.toIso8601String(),
        "lastSeenAt": lastSeenAt.toIso8601String(),
        if (addresses.isNotEmpty) "addresses": addresses,
      };

  static PairedDevice fromJson(Map<String, dynamic> json) => PairedDevice(
        id: json["id"] as String,
        name: json["name"] as String,
        publicKey: json["publicKey"] as String,
        addedAt: DateTime.parse(json["addedAt"] as String),
        lastSeenAt: json["lastSeenAt"] == null
            ? null
            : DateTime.parse(json["lastSeenAt"] as String),
        // `lastAddress` is the one address a record held before it held all.
        addresses: (json["addresses"] as List<Object?>?)?.cast<String>() ??
            [?json["lastAddress"] as String?],
      );
}

/// The devices this one may talk to, and where their pairing secrets live.
abstract interface class DeviceRegistry {
  Future<List<PairedDevice>> list();

  Future<PairedDevice?> byId(String id);

  /// Inserts or replaces by [PairedDevice.id]. The pairing secret travels
  /// separately: [setPairingSecret] before [add] when creating a pair.
  Future<void> add(PairedDevice device);

  /// Drops the record and its stored pairing secret with it.
  Future<void> remove(String id);

  Future<void> markSeen(String id, {List<String>? addresses});

  /// What this device addresses [id] by, from now on. A name in this
  /// registry is the one this device files the peer under, for its own rows —
  /// the other device keeps its own, the way it keeps this device's.
  Future<void> rename(String id, String name);

  /// The shared secret this pair authenticated with, or null.
  Future<String?> pairingSecret(String id);

  Future<void> setPairingSecret(String id, String secretB64);
}
