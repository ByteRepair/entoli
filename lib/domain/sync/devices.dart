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
    this.lastAddress,
  }) : lastSeenAt = lastSeenAt ?? addedAt;

  /// The peer's identity id — derived from its public key, so it travels with
  /// every handshake and a connection claiming another id refuses to open.
  final String id;
  final String name;
  final String publicKey;

  final DateTime addedAt;
  DateTime lastSeenAt;

  /// The host:port its LAN signaling server answered on last time. A hint for
  /// reconnecting, not a promise — ports move across restarts.
  String? lastAddress;

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "publicKey": publicKey,
        "addedAt": addedAt.toIso8601String(),
        "lastSeenAt": lastSeenAt.toIso8601String(),
        if (lastAddress != null) "lastAddress": lastAddress,
      };

  static PairedDevice fromJson(Map<String, dynamic> json) => PairedDevice(
        id: json["id"] as String,
        name: json["name"] as String,
        publicKey: json["publicKey"] as String,
        addedAt: DateTime.parse(json["addedAt"] as String),
        lastSeenAt: json["lastSeenAt"] == null
            ? null
            : DateTime.parse(json["lastSeenAt"] as String),
        lastAddress: json["lastAddress"] as String?,
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

  Future<void> markSeen(String id, {String? address});

  /// The shared secret this pair authenticated with, or null.
  Future<String?> pairingSecret(String id);

  Future<void> setPairingSecret(String id, String secretB64);
}
