import "dart:async";
import "dart:typed_data";

import "package:flutter_webrtc/flutter_webrtc.dart" as webrtc;

import "../../core/log.dart";
import "channel.dart";

/// A WebRTC peer connection reduced to what a data channel needs: negotiate
/// SDP out-of-band (the signaling layer's business), wait for the channel,
/// then behave as a [ByteChannel].
///
/// Negotiation is trickle-less — the local description is only handed over
/// once gathering has finished — which costs a second or two and buys a
/// single blob per side, the thing manual pairing pastes through a human.
class RtcLink {
  RtcLink._(this._pc);

  final webrtc.RTCPeerConnection _pc;
  final _ready = Completer<ByteRtcChannel>();
  ByteRtcChannel? _channel;
  Timer? _grace;
  var _closed = false;

  static const defaultStun = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
  ];

  /// Creates the connection. [iceServers] is STUN/TURN as the settings page
  /// holds them; empty means the public defaults, which is right for most
  /// networks and wrong for none that works without them anyway.
  static Future<RtcLink> create({List<Map<String, Object>>? iceServers}) async {
    final pc = await webrtc.createPeerConnection({
      "iceServers": iceServers ?? [
        for (final url in defaultStun) {"urls": url},
      ],
      "sdpSemantics": "unified-plan",
    });
    final link = RtcLink._(pc);
    pc.onConnectionState = link._onState;
    return link;
  }

  /// A peer that dies sends no close, so the data channel never ends on its
  /// own: ICE goes on probing every path it had, and only the heartbeat
  /// would notice, a minute or more later. ICE says it within seconds.
  /// Disconnected can recover by itself — a phone changing networks — so it
  /// gets a moment first; failed is final.
  void _onState(webrtc.RTCPeerConnectionState state) {
    switch (state) {
      case webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _grace?.cancel();
        _grace = null;
      case webrtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _grace ??= Timer(const Duration(seconds: 5), () => _lost(state));
      case webrtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _lost(state);
      default:
    }
  }

  void _lost(webrtc.RTCPeerConnectionState state) {
    if (_closed) return;
    logFailure("sync", "peer connection ${state.name}, closing it");
    if (!_ready.isCompleted) {
      // Nobody may be waiting on [open] yet; whoever does still gets it.
      _ready.future.ignore();
      _ready.completeError(const ChannelClosedException());
    }
    _channel?.lost();
    unawaited(_dispose());
  }

  /// The initiator's half: owns the data channel, produces the offer to send
  /// through whatever rendezvous brought these two together.
  Future<String> offer() async {
    final channel = await _pc.createDataChannel(
      "entoli",
      webrtc.RTCDataChannelInit()
        ..ordered = true
        ..binaryType = "binary",
    );
    _watch(channel);
    return _localDescription(() => _pc.createOffer({}));
  }

  /// The joiner's half: no channel of its own; [answer] carries back the
  /// remote offer and this returns the answer to send.
  Future<String> answer(String remoteSdp) async {
    await _pc.setRemoteDescription(
        webrtc.RTCSessionDescription(remoteSdp, "offer"));
    _pc.onDataChannel = (channel) => _watch(channel);
    return _localDescription(() => _pc.createAnswer({}));
  }

  /// Completes the joiner once the initiator's answer arrives.
  Future<void> acceptAnswer(String remoteSdp) async {
    await _pc.setRemoteDescription(
        webrtc.RTCSessionDescription(remoteSdp, "answer"));
  }

  Future<String> _localDescription(
      Future<webrtc.RTCSessionDescription> Function() make) async {
    final description = await make();
    await _pc.setLocalDescription(description);
    final gathering = Completer<void>();
    void onState(webrtc.RTCIceGatheringState state) {
      if (state == webrtc.RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathering.isCompleted) {
        gathering.complete();
      }
    }

    _pc.onIceGatheringState = onState;
    // Gathering usually finishes in well under a second on a LAN; the timer
    // is for networks where a candidate never resolves and waiting forever is
    // the one outcome worse than an address that would have worked.
    await gathering.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    _pc.onIceGatheringState = null;
    final local = await _pc.getLocalDescription();
    return local?.sdp ?? description.sdp ?? "";
  }

  void _watch(webrtc.RTCDataChannel channel) {
    if (!_ready.isCompleted) {
      _ready.complete(_channel = ByteRtcChannel(channel, _dispose));
    }
  }

  /// The channel once it is open. Throws when the peer goes away instead.
  Future<ByteChannel> open({Duration timeout = const Duration(seconds: 30)}) =>
      _ready.future.timeout(timeout);

  Future<void> close() => _dispose();

  Future<void> _dispose() async {
    if (_closed) return;
    _closed = true;
    _grace?.cancel();
    try {
      await _pc.close();
    } catch (_) {}
  }
}

/// [ByteChannel] over an open RTCDataChannel. SCTP preserves message
/// boundaries, so one send is exactly one receive.
class ByteRtcChannel implements ByteChannel {
  ByteRtcChannel(this._channel, this._onClose) {
    _subscription = _channel.messageStream.listen(
      (message) {
        if (!message.isBinary) return;
        _controller.add(message.binary);
      },
      onError: _controller.addError,
      onDone: () {
        _controller.close();
      },
    );
  }

  final webrtc.RTCDataChannel _channel;
  final Future<void> Function() _onClose;
  late final StreamSubscription<dynamic> _subscription;
  // Single-subscription, so bytes that arrive before the reader is attached
  // are held rather than dropped. See [ByteChannel.incoming].
  final _controller = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  /// The connection under it has gone: end what readers are waiting on.
  void lost() {
    if (!_controller.isClosed) _controller.close();
  }

  @override
  Future<void> send(Uint8List bytes) =>
      _channel.send(webrtc.RTCDataChannelMessage.fromBinary(bytes));

  @override
  Future<void> close() async {
    await _subscription.cancel();
    try {
      await _channel.close();
    } catch (_) {}
    await _onClose();
  }
}
