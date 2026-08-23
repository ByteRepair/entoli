import "package:flutter/foundation.dart";

/// What went wrong on the wire.
///
/// Sync fails in places nothing draws: a send that threw, a frame that would
/// not parse, an offer nobody answered, a peer that vanished mid-handshake.
/// Every one of those is caught and dropped — it has to be, since none of
/// them is worth taking the app down for — and the result was that "it will
/// not pair" came with nothing at all to go on, in a log or on screen.
///
/// One line per failure, and only failures: this is not a trace of the
/// traffic, which would be both enormous and full of things that must not be
/// written down. Nothing here may carry a secret, an SDP blob, or anything
/// out of a conversation — a device id and a reason, no more.
void syncLog(String what, [Object? error]) =>
    debugPrint(error == null ? "[sync] $what" : "[sync] $what: $error");
