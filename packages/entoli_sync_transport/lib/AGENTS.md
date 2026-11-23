# The WebRTC data channel sync runs over

`entoli_sync_transport` is the adapter for the peer connection.
`entoli_sync_transport.dart` is the whole of it: `RtcLink` answers the
core's `PeerLink` (`model/sync/peer_link.dart`) with `flutter_webrtc`, and
`ByteRtcChannel` is the `ByteChannel` over its open data channel. `main`
hands `RtcLink.create` to `SyncHub` as its `PeerLinkFactory`. The ICE
servers, TURN password included, are built by pairing in the app and passed
in; this package reads no settings and no secrets. See "The peer connection"
in `lib/data/sync/AGENTS.md`.

**Negotiation is trickle-less.** The local description is handed over only
once ICE gathering has finished, or after four seconds where a candidate
never resolves. It costs a second or two and buys one blob per side, which
is what manual pairing pastes through a human and what the LAN and relay
routes send in one message.

**One data channel, ordered and binary.** The offering side creates it,
labelled `entoli`; the answering side takes the first one `onDataChannel`
delivers. SCTP keeps message boundaries, so one `send` is one message at the
far end, which is what `ByteChannel` promises. Text messages are dropped. The
incoming stream is single-subscription so nothing that arrives before the
reader attaches is lost (see "Two things a loopback channel will not tell
you" in `lib/data/sync/AGENTS.md`). Closing the channel closes the peer
connection under it.

`flutter_webrtc` is held below 1.6.2, whose Linux plugin segfaults on
registration. `cryptography_flutter` is here too, though nothing in this
package calls it: it registers itself as `Cryptography.instance` on Android
and speeds up the ChaCha20 the framing layer runs on large frames. See "The
handshake" in `lib/data/sync/AGENTS.md` for the trap that comes with it.

Nothing here runs under `flutter test`: the Dart VM has no WebRTC engine, so
this package has no `test/` and the channel is confirmed by hand between two
running instances (see `test/AGENTS.md`).
