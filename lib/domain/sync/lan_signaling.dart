/// The port a device is normally found on. An ephemeral one changes every
/// launch, so an address a peer stored at pairing time is refused the moment
/// either side restarts — and a LAN reconnect could never work twice. Here
/// rather than on the io implementation because the dialling side needs it
/// too, to guess where a device that restarted has gone.
///
/// One port, not a range. A second Entoli on the same machine falls back to
/// an ephemeral one and is then dialable only until it restarts — which is a
/// development arrangement, and not worth multiplying every failed dial's
/// wait by, since a host that drops rather than refuses costs the full
/// timeout per port tried.
const preferredSignalingPort = 47921;

/// Where [LanSignaling.discover] broadcasts from this device's [own]
/// addresses: the limited broadcast, which leaves by the default route only,
/// and the /24 broadcast of each private address, which reaches the LAN
/// when the default route is a VPN's. Public and CGNAT (100.64/10,
/// Tailscale's) addresses get none: those are not a LAN, and a tailnet
/// address does not move anyway.
// shortcut: assumes a /24, since NetworkInterface gives no prefix length;
// a wider home network hears only the /24 this device is in.
List<String> lanBroadcasts(List<String> own) => {
      "255.255.255.255",
      for (final address in own)
        if (address.split(".").map(int.tryParse).toList()
            case [final a?, final b?, final c?, _?]
            when a == 10 ||
                (a == 172 && b >= 16 && b < 32) ||
                (a == 192 && b == 168))
          "$a.$b.$c.255",
    }.toList();

/// The LAN rendezvous a desktop offers while pairing: where a joiner's offer
/// waits for an answer, and the one-time code that gates it.
///
/// An interface rather than the server itself so the web build — which cannot
/// listen — gets a null from `createLanSignaling` and every caller asks
/// whether there is anything to run at all. See `SignalingServer` on the io
/// side for what actually answers.
abstract interface class LanSignaling {
  /// Offers arriving from joiners, newest while you are subscribed.
  Stream<IncomingOffer> get offers;

  /// Arms the one-time code an offer must carry, until [disarm]. Empty
  /// windows refuse everything.
  void arm(String code);

  void disarm();

  /// Binds and answers with the port chosen by the OS — what goes in the QR.
  Future<int> start();

  /// This machine's addresses a peer could reach, in no useful order. What
  /// goes into the QR beside the port.
  Future<List<String>> addresses();

  /// Asks the LAN, by one broadcast, where the device holding [token] is,
  /// and answers every `host:port` that proved it does. Never other devices'
  /// addresses, and never this one's: its own server holds the same token.
  Future<List<String>> discover(String token);

  /// The host's half of an exchange: completes the offer [id] names.
  void postAnswer(String id, String sdp);

  /// Arms a reconnect token so a paired device can dial again without
  /// re-pairing. Derived from the pair's secret by the hub.
  void allowReconnect(String token);

  /// Disarms one. Revoking a device has to reach here, or it goes on being
  /// let in and answered for as long as the process lives.
  void refuseReconnect(String token);

  /// The bound port, or null while not running.
  int? get port;

  Future<void> close();
}

class IncomingOffer {
  IncomingOffer({required this.id, required this.sdp, this.token});

  /// Identifies this offer back to the server when the answer is posted.
  final String id;
  final String sdp;

  /// The reconnect token it came in under, or null for one that used the
  /// pairing window's code. Which pair it is decides the secret the handshake
  /// runs against, so the answer cannot be given without knowing.
  final String? token;
}
