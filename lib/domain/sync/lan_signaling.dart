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

  /// This machine's addresses a peer on the same network could reach, best
  /// first. What goes into the QR beside the port.
  Future<List<String>> addresses();

  /// The host's half of an exchange: completes the offer [id] names.
  void postAnswer(String id, String sdp);

  /// Arms a reconnect token so a paired device can dial again without
  /// re-pairing. Derived from the pair's secret by the hub.
  void allowReconnect(String token);

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
