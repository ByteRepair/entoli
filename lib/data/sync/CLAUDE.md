# Sync: paired devices, live mirrors, remote control

Two Entoli devices pair over a QR or typed code, open a WebRTC data channel
between them, and one mirrors the other's chats or drives them remotely.
Commands always run on the chat's home device; control moves only who
types/prompts/approves.

## The threat model and how it is answered

| Threat | Answer |
|---|---|
| Passive eavesdropping (Wi-Fi, ISP) | DTLS (mandatory in WebRTC, no opt-out) + app-layer ChaCha20-Poly1305 on every message. Defense in depth: a libwebrtc regression leaks nothing readable. |
| Malicious signaling relay / TURN | Relays shuttle opaque ciphertext. After the handshake everything is AEAD — chat records, titles, even signaling envelopes — under keys the relay never sees. |
| MITM during pairing | The pairing secret travels out-of-band (QR / typed code, 128-bit). The handshake mixes it into HKDF over the full transcript (psk, both ephemeral X25519 keys, both Ed25519 identity keys). Both screens show the resulting SAS; an altered key changes it visibly. |
| Impersonation on reconnect | Each device has a persistent Ed25519 keypair. Peer keys are pinned in `devices.json`; reconnects verify the peer's identity via signed transcript and `requirePeerId` refuses a different key. |
| Stolen/replayed pairing payload | Pairing secrets are single-use for fresh pairs; reconnect tokens are derived per-pair. Channel keys are per-connection via ephemeral X25519. |
| Message injection/replay/ordering | AEAD nonces are monotonic per-direction counters; a replayed or reordered frame fails its MAC. Role enforcement at dispatch disconnects on violation. |
| Compromised paired device | Devices are individually revocable. Mirrors are RAM-only on the viewing device — never written to the data dir, so never in backups or IndexedDB. |

Key hygiene: secrets never enter logs, errors, or `conv.jsonl`. The first wire
message is the handshake itself — no plaintext `hello` before it.

## The handshake

`handshake.dart` runs over a fresh `ByteChannel` before any application
message. Three plaintext messages:

    initiator -> joiner  {"v","role":"i","id","pk","eph","name"}
    joiner -> initiator  {"v","role":"j", ...same..., "sig"}
    initiator -> joiner  {"v","role":"i","sig"}

Both sides sign the transcript (both ephemeral keys, both identity keys, in
fixed role order) with their Ed25519 identity key. Channel keys are
HKDF-SHA256 over the X25519 shared secret and the pairing secret; the pairing
secret never crossed the network. The SAS (eight base32 characters, forty
bits) is derived beside the keys for human confirmation — regrouped five bits
at a time rather than through one 40-bit integer, since a shift past 32 bits is
truncated on the web.

Role order in that transcript is the whole of what makes the two signatures
comparable: signing local-then-remote has each side hashing its own ordering
and every handshake failing to verify. It shipped that way in Phase 1 and was
caught by the first test to run two hubs against each other.

The handshake initiator is always the WebRTC *answer* side (`!weOffered`),
so whichever route brought the two together needs no extra message to decide
who speaks first.

## The framing layer

`framing.dart` wraps a `ByteChannel` in ChaCha20-Poly1305 AEAD. Every frame:

    [type: 1 byte][counter: 4 bytes BE][AEAD(cleartext)]

Counters are per-direction and monotonic — a replayed, reordered or spliced
frame fails its MAC. The header is read with `ByteData.sublistView(frame)`
rather than through `frame.buffer`: a frame off a real data channel is a view
into a larger receive buffer, and going through the buffer ignores where the
view starts. The type byte (control or binary) is associated data, so
a control message can never be mistaken for a resource chunk. `SecureChannel`
exposes `sendJson` / `jsonIncoming` for the NDJSON control protocol and
`sendBinary` for 16KB resource chunks.

## Three rendezvous transports

1. **Same-LAN** (`signaling_server.dart`): HTTP server binding `0.0.0.0` on an
   ephemeral port, serving CORS + Private-Network-Access preflights. QR
   carries `{hosts, port, one-time code, psk}`. The joiner POSTs its offer;
   the host answers in the same response.
2. **Internet relay** (`relay_signaler.dart`): both sides dial a user-supplied
   `wss://` URL and join the same room — derived from the pairing secret's
   SHA-256, so the relay learns nothing. A reference relay is
   `tool/sync_relay_server.dart`.
3. **Manual copy-paste**: the SDP rides in the pairing blob itself, pasted
   through a human. Universal fallback; the only route that works with no
   network beyond the data channel's own ICE.

Web builds are relay/manual-paste only — a browser cannot bind a socket, and
HTTPS Pages makes plain-http LAN dialing mixed-content-blocked. So a browser
can only ever *join*: `createLanSignaling` answers null there, and the Sync
page says as much rather than drawing a button that does nothing.
`startPairingWindow` throws `SyncHub.noRoute` where neither route is
available, and the wording differs by platform because what is missing does —
a desktop is short of both, a browser only of the relay.

## The SyncHub

`sync_hub.dart` owns the three decisions above the wire:

- **Who speaks first.** Handshake initiator = `!weOffered`, per route.
- **Who may dial again.** A pairing window arms its one-time code; every
  completed pair also arms a reconnect token derived from the pair's secret,
  so paired devices redial without re-pairing while the app's server is up.
- **What the relay learns.** Nothing readable. Rooms are derived from pairing
  secrets; SDP blobs are opaque; channel keys come from material that never
  crossed any network.

`SyncHub` lives in `AppSession`, torn down in `dispose` beside the sweep and
the backend. It is built in `main` after the config and store, reads settings
through a closure deferred to the container, and is injected via
`syncHubProvider` (throw-unimplemented, overridden in main, faked in tests).

## Mirroring a chat

`protocol.dart` is one freezed sealed union, `SyncMessage`, for everything two
Entolis say once the channel is up — so the dispatcher cannot forget an arm:
adding a message stops every switch over it compiling until it is handled. The
handshake and the `hello` either side of it are *not* in it; they run before
any application traffic and stay hand-rolled JSON beside it.

The serving side is driven by `ChatRepository.changes`, a broadcast stream of
`RepoEvent` — `Appended`, `StateChanged`, `MetaChanged`, `Moved`, `Deleted`.
The repository knows nothing about who listens, and nobody listening is the
ordinary case for every test that predates sync. `SyncHub._onRepoEvent` fans
each one out to the peers subscribed to that chat. Deletions reach every peer
rather than only subscribers: one holding a mirror of something gone has to be
told even if it never opened the records.

`_onMirror` is the one door into a mirror: it looks the chat up, refuses a
peer talking about one it is not the home device for, and notifies. An arm
that did its own lookup could forget either. `_toSubscribers` is the same
consolidation the other way — every serving-side message goes out through it,
so no arm can forget the subscription check. The exception is a deletion,
which reaches every peer rather than only subscribers.

A chat created after the mirrors were told about the list would otherwise not
appear until a reconnect, so `_announced` holds the ids last sent and a
`StateChanged` naming one that is not in it re-sends the list. Ids rather than
a re-read per event: `saveState` runs several times a turn.

The mirroring side keeps `MirrorChat`s **in RAM only** — never under
`<dataDir>`, so never in a backup, never in IndexedDB, and gone when the
process is. That is what makes a mirror safe on a borrowed device, and it is
also why a resume is a line count rather than a file: `chatOpen{fromLine}` asks
for the log from where this device got to, and `chatSnapshot{totalLines}` is
where the next resume counts from. A reconnect therefore costs the records
added while it was away, not the whole conversation.

A peer that goes away keeps its mirrors, marked stale. `_peerGone` notifies in
both directions — the chats this device served them, and the ones it mirrors
from them — because a mirror's page has a banner to raise and nothing else
tells it the snapshot has stopped moving. `revoke` is the other end of that:
the row, the mirrors and the cached bytes all go with the device, since
`_refreshPeers` only fills gaps from the registry and would leave an unpaired
device listed, and online, until a restart.

`ChatState` and `ChatRecord` ride inside those messages, which is what
`build.yaml` is for: `explicit_to_json: true` globally, because a nested
freezed object left to `toJson`'s default comes out as a live instance rather
than a map, and a raw `_ChatState` in the payload is a cast failure on the far
side.

### Attachments

An attachment's bytes are requested by `resourceRequest{id}` and answered by a
run of `resourceChunk{id, bytesB64, done}` — base64 inside ordinary control
frames, 48KB of source bytes each. Correlation stays trivial and every frame
rides the same AEAD as the rest of the traffic; binary framing can come later
with no protocol change, since the type byte already separates the streams. A
resource that is not there answers with an empty final chunk, so the asking
side gets a null rather than a hang.

`SyncByteCache` holds what came back, bounded at 64MB of bytes rather than a
count of entries — an image-heavy conversation is where the megabytes are. It
belongs to the `SyncHub` rather than to the page that shows them, so a mirror
being dropped takes its bytes with it.

### What a mirror looks like

`MirrorChatController` is deliberately its own provider family rather than an
arm of `chatControllerProvider`: that one's build hits the local disk and wires
appends into the repository, both of which are exactly wrong for a chat whose
home device is elsewhere. Records replay through the same pure
`chatFrom`/`replayTree` a reload uses, so the page draws the log rather than a
second rendering of it.

`ChatPage` branches on `isMirroredChatProvider` and draws a read-only page:
`ViewOnlyBar` where the composer goes, an `OfflineBanner` over the conversation
when the home device is away, no expiry check and no chat settings — nothing on
that page may touch the repository. The sidebar's Remotes section sits below
the local list rather than among its date groups, since a mirror answers to no
date this device could place, and its rows carry none of a local chat's menu.

`remoteChatsProvider` bridges the hub's `ValueNotifier` into Riverpod, and is
deliberately separate from `chatListProvider`, which reads the local store and
stays sync-unaware. Two sources of truth, never merged.

## Control, and driving a turn from the other end

**Nothing about a turn ever moves.** A prompt typed on a mirror is *run* on the
chat's home device, by the same `ChatController` a locally typed one goes
through — same model, same workspace, same log, and the reply comes back as the
ordinary record stream that was already mirroring. What crosses the wire is the
asking and the answering. The commands stay where the files are, which is the
whole reason the chat has a home device at all.

**The lock is the home device's answer.** `controlRequest` is a request:
`_control` maps a chat to the one device id holding it, first asker wins, and
`controlGrant` plus a `controlState` to every subscriber says what happened. A
mirror never decides it has control — `holdsControl` compares the holder the
home end sent against this device's own id — which is what makes a race between
two phones resolve rather than double up. Re-asking while already holding it is
granted, since a mirror that reconnected does not know it never lost the lock.

Every arm that drives a turn — `promptSend`, `turnResume`, `turnAbort`,
`approvalRespond`, `questionsRespond` — is refused at the home device unless
the sender holds the chat. **A page drawing a composer is not what permits a
turn**; the guard on the mirror side only exists so it does not shout into the
void. A lock is released by `controlRelease`, by the chat being deleted, or by
the connection carrying it going away — one that outlived its connection would
leave the chat unusable at both ends until somebody restarted.

**The turn-scoped state is its own message.** Whether a turn is running, what
it is waiting to be allowed, what it is waiting to be told, the line the
spinner is on: none of that is in `conv.jsonl`, so `turnState` carries the lot
on every change. Whole rather than a diff — it is small, and a diff would be a
second account of what is pending. An `ask_user` travels as `SyncAsk{id,
argumentsJson}` and the mirror rebuilds the questions with the same
`askQuestionsFrom` the home device used, so the panel is the model's own words
rather than a second encoding of them. `AskRequest.argumentsJson` exists for
that and nothing else reads it.

`RemoteTurnDriver` is the home end, read once in `main` for its effect the way
`TurnKeepAlive` is. It holds one `ChatController` open per **watched** chat —
not per held one — because a mirror that is only reading still has to see a
turn happening; that is what `SyncHub.servedChats` is for. Publishing is the
same subscription's other half, and it is deduplicated: `ChatViewState` has no
`==` and is replaced on every flush of a streaming reply, tens of times a
second, while none of what `turnState` carries changes between them. The words
themselves cross as records.

`TurnDriver` is the interface the two controllers meet on, so `TurnSurface`,
`TurnQuestions`, `Composer` and the approval banner are the same widgets at
both ends. `ChatController` implements it by running the turn;
`MirrorChatController` implements it by sending. Attachments are the one verb
missing: their bytes would have to cross to be saved under a chat on the other
side.

Offline outranks everything a mirror last heard. A status line from before the
connection dropped is a turn claiming to still be alive, and an approval
nothing can carry the answer to is worse than no approval — so `_viewOf` blanks
them all.

The home device says so too: `drivenChats` is chat id to the name of the device
driving it, and the local chat page draws it as a title line. Prompts arriving
that nobody here typed are otherwise unexplained.

### Testing it

### The pairing secret is not a valid base64 length

`generatePsk` is 32 random bytes as base64url with the padding stripped, so a
secret fits a QR without an `=` in it — 43 characters, which is not a multiple
of four. `base64Decode` refuses that outright, so the handshake normalises
first. Every literal anyone reached for in a test happened to be a length the
strict decoder accepted, which is why no test found it and the first real
pairing did.

### Two things a loopback channel will not tell you

Both of these shipped, and both passed every test over a loopback
`ByteChannel`. They are here because the next change to this layer can make
either mistake again and nothing automated will notice.

**A frame off a real data channel is a view into a larger buffer.** The header
is read with `ByteData.sublistView(frame)`; `ByteData.view(frame.buffer)`
ignores where the view starts, so the counter came out of whatever happened to
be in front of it. A loopback channel hands back freshly allocated lists at
offset zero, where the two spellings agree.

**Nothing may be awaited between the decrypt loop starting and the pump being
attached.** `channel.listen()` starts decrypting into a broadcast stream, so
anything arriving before there is a listener is dropped rather than queued.
The subscription therefore goes on *first* — before the codes-matched gate,
which is the widest window there could be, since it waits for a person. The
other side sends the moment *its* human has confirmed, which can be a long
time before ours has. What arrives before this side has agreed is held rather
than handled: a welcome applied before the codes matched would leave mirrors
behind from a pairing that was then refused.

That one subscription is attached before the hello goes out, and
the hello is read off it rather than through a second `firstWhere`. Both sides
answer the moment they have the other's hello and send their welcome straight
after, and the stream is broadcast — so subscribing after the send, or
awaiting anything between the reply and the pump, drops whichever message
lands in the gap. That gap is a microtask on a loopback channel — where it
never once opened — and a whole turn of the event loop on a real one, where it
opened every time.

`SyncHub.establishForTest` is the seam: it runs the shared tail of every route
— handshake, codes-matched gate, hello, filing the peer — over a `ByteChannel`
a test supplies, so `sync_hub_pair_test.dart` stands two real hubs on a
loopback pair and proves welcome, snapshot, appends, resources, offline and
resume-from-line with no transport, offer or signaling underneath. It opens a
pairing card first, because every real route does and the codes-matched gate
has nowhere to ask otherwise.

Widget tests do not go through a hub at all: `TestApp.create(remotes:,
mirrors:, control:, drivenBy:)` overrides the four providers the pages read,
which is also what keeps every sync-unaware test working, since there is no
`SyncHub` in the container to throw. `sendForTest` is the other seam on the
hub: it sends past the mirror-side guard, which is the only way to check that
the *home* device is what refuses a peer holding nothing.

## What a device is called

The sync device name is the machine's own hostname where it has one, falling
back to the first characters of the key fingerprint. A user's own name for it
wins over both. The hostname comes in as a constructor argument rather than
being read in the hub: `Platform.localHostname` is `dart:io`'s, and a browser
has no name of its own to give — `location.hostname` is the server the page
came from, which is a different machine entirely.

## What the Sync page can do about a peer

Connect, disconnect, revoke, and one line saying why the last dial failed.
`connect` words that reason once and uses it twice — the row keeps it and the
thrown exception puts the device's name on the front — because the row holding
a null while the snack bar held a sentence was the honest half going missing.
A `Future` handed to `onPressed` is dropped and its failure is unhandled, so
every one of those buttons goes through a catch that reports.

Revoking asks first, and says what it does not do: the other device keeps this
one until somebody revokes there too.

## Secrets at rest

`SecretStore` is the interface; the port picks the implementation:

- **Linux**: `KeyringSecretStore` over the FreeDesktop Secret Service API
  (`freedesktop_secret`), items labelled "Entoli — sync identity" and
  "Entoli — paired devices". Falls back to `FileSecretStore` where no service
  answers (headless, minimal WM, the dev toolbox).
- **Android**: `FileSecretStore` under app-private storage — already out of
  every other app's reach — until Keystore wiring lands.
- **Web**: `FileSecretStore` in origin-scoped IndexedDB. The weakest of the
  three; the Sync page says so rather than pretending otherwise.

`encrypted` says which a build got. Nothing reads it yet — the Sync page
should say so on the web, where the keys sit in ordinary IndexedDB, and does
not.

## Data dir layout

```
<dataDir>/sync/identity.json   # public: device id, name, public key
<dataDir>/sync/devices.json    # public: paired peers, addresses, last seen
<dataDir>/sync/secrets.json    # private: only where no keyring answered
```

Backups skip `sync/` entirely (`writeBackup` passes `skipDir` to `archiveOf`):
a backup must not carry private keys, and a restore wipes the data directory
first — so `sync/` in a backup would silently unpair this device on every
restore. The identity key itself lives in the keyring where there is one, not
in `identity.json`, which holds only public facts.

No migration entry: the chain is additive and nothing existing moved.
