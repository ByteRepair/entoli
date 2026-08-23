import "package:flutter/foundation.dart";

/// Something went wrong and the app carried on.
///
/// Most failures here are caught and dropped on purpose — a launcher that
/// refuses an icon, a platform that will not hold the process, a cache that
/// answers 501 — because none of them is worth taking a turn down for. What
/// that costs is that they become indistinguishable from nothing having
/// happened, which is how a whole feature can be broken in nine places and
/// report none of them. This is the line that makes the difference.
///
/// [tag] is the layer, so a log can be read by whoever it is sent to: `sync`,
/// `files`, `icon`. Keep it short and reuse the ones already here.
///
/// **Nothing sensitive goes in one.** No secrets or keys, no message or file
/// contents, no prompt, no model output. A user pastes a log into an issue
/// without reading it; assume this one will be. An id and a reason.
///
/// Not gated on the build: a release is what somebody is running when they
/// tell you it did not work. For volume rather than failure — a subprocess's
/// output, a cache hit — use [logDetail].
void logFailure(String tag, String what, [Object? error]) =>
    debugPrint(error == null ? "[$tag] $what" : "[$tag] $what: $error");

/// The same, for what is worth seeing while developing and would drown a real
/// log: a subprocess line by line, a hit that is not a failure at all.
void logDetail(String tag, String what) {
  if (kDebugMode) debugPrint("[$tag] $what");
}
