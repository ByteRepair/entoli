import "../../core/log.dart";

/// What went wrong on the wire, as [logFailure] under the `sync` tag.
///
/// Sync fails in places nothing draws: a send that threw, a frame that would
/// not parse, an offer nobody answered, a peer that vanished mid-handshake.
/// Every one of those is caught and dropped — it has to be, since none is
/// worth taking the app down for — and the result was that "it will not pair"
/// came with nothing at all to go on, in a log or on screen.
///
/// Its own name because nine call sites read better for it. The rules are
/// [logFailure]'s: failures rather than traffic, and nothing in one that
/// should not leave the machine — no pairing secret, no SDP, nothing out of a
/// conversation.
void syncLog(String what, [Object? error]) => logFailure("sync", what, error);
